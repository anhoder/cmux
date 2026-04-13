const std = @import("std");
const proxy_streams = @import("proxy_streams.zig");
const pty_host = @import("pty_host.zig");
const pty_pump = @import("pty_pump.zig");
const serialize = @import("serialize.zig");
const session_registry = @import("session_registry.zig");
const terminal_session = @import("terminal_session.zig");
pub const workspace_registry = @import("workspace_registry.zig");

pub const AttachmentResult = struct {
    attachment_id: []const u8,
    cols: u16,
    rows: u16,
};

pub const OpenTerminalResult = struct {
    status: session_registry.SessionStatus,
    attachment_id: []const u8,
    offset: u64,
};

pub const ReadTerminalResult = struct {
    data: []u8,
    offset: u64,
    base_offset: u64,
    truncated: bool,
    eof: bool,
};

const RuntimeSession = struct {
    pty: pty_host.PtyHost,
    terminal: terminal_session.TerminalSession,
    /// Serializes pump-thread access to `pty`/`terminal` against any
    /// foreground caller (read/write/history/resize/deinit).
    lock: std.Thread.Mutex = .{},

    fn init(alloc: std.mem.Allocator, command: []const u8, cols: u16, rows: u16) !RuntimeSession {
        return .{
            .pty = try pty_host.PtyHost.init(alloc, command, cols, rows),
            .terminal = try terminal_session.TerminalSession.init(alloc, .{
                .cols = cols,
                .rows = rows,
                .max_scrollback = 100_000,
            }),
        };
    }

    fn deinit(self: *RuntimeSession) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.terminal.deinit();
        self.pty.deinit();
    }

    fn resize(self: *RuntimeSession, cols: u16, rows: u16) !void {
        self.lock.lock();
        defer self.lock.unlock();
        try self.pty.resize(cols, rows);
        try self.terminal.resize(cols, rows);
    }

    fn read(self: *RuntimeSession, alloc: std.mem.Allocator, offset: u64, max_bytes: usize, timeout_ms: i32) !ReadTerminalResult {
        const start_ms = std.time.milliTimestamp();

        while (true) {
            self.lock.lock();
            try self.pty.pump(&self.terminal);
            const window = self.terminal.offsetWindow();
            var effective_offset = offset;
            const truncated = effective_offset < window.base_offset;
            if (effective_offset < window.base_offset) effective_offset = window.base_offset;

            if (effective_offset < window.next_offset) {
                defer self.lock.unlock();
                const refreshed = self.terminal.offsetWindow();
                const raw = try self.terminal.readRaw(alloc, offset, max_bytes);
                return .{
                    .data = raw.data,
                    .offset = raw.offset,
                    .base_offset = raw.base_offset,
                    .truncated = raw.truncated,
                    .eof = self.pty.isClosed() and raw.offset >= refreshed.next_offset,
                };
            }

            if (self.pty.isClosed()) {
                defer self.lock.unlock();
                return .{
                    .data = try alloc.dupe(u8, ""),
                    .offset = window.next_offset,
                    .base_offset = window.base_offset,
                    .truncated = truncated,
                    .eof = true,
                };
            }
            self.lock.unlock();

            const wait_ms = if (timeout_ms <= 0) -1 else blk: {
                const elapsed = std.time.milliTimestamp() - start_ms;
                const remaining = @as(i64, timeout_ms) - elapsed;
                if (remaining <= 0) return error.ReadTimeout;
                break :blk @as(i32, @intCast(remaining));
            };
            const ready = try self.pty.waitReadable(wait_ms);
            if (!ready) return error.ReadTimeout;
        }
    }

    fn writeDraining(self: *RuntimeSession, data: []const u8) !void {
        self.lock.lock();
        defer self.lock.unlock();
        try self.pty.writeDraining(&self.terminal, data);
    }

    fn historyDump(self: *RuntimeSession, alloc: std.mem.Allocator, format: serialize.HistoryFormat) ![]u8 {
        self.lock.lock();
        defer self.lock.unlock();
        try self.pty.pump(&self.terminal);
        return self.terminal.history(alloc, format);
    }
};

pub const Service = struct {
    alloc: std.mem.Allocator,
    proxies: proxy_streams.Manager,
    registry: session_registry.Registry,
    runtimes: std.StringHashMap(*RuntimeSession),
    workspace_reg: workspace_registry.Registry,
    subscriptions: workspace_registry.SubscriptionManager = .{},
    pump: ?pty_pump.Pump = null,

    pub fn init(alloc: std.mem.Allocator) Service {
        var service: Service = .{
            .alloc = alloc,
            .proxies = proxy_streams.Manager.init(alloc),
            .registry = session_registry.Registry.init(alloc),
            .runtimes = std.StringHashMap(*RuntimeSession).init(alloc),
            .workspace_reg = workspace_registry.Registry.init(alloc),
        };
        if (pty_pump.supported) {
            if (pty_pump.Pump.init(alloc)) |pump| {
                service.pump = pump;
                service.pump.?.start() catch |err| {
                    std.log.warn("session_service: pump start failed: {s}", .{@errorName(err)});
                    service.pump.?.deinit();
                    service.pump = null;
                };
            } else |err| {
                std.log.warn("session_service: kqueue pump unavailable: {s}", .{@errorName(err)});
            }
        }
        return service;
    }

    pub fn deinit(self: *Service) void {
        // Stop the pump first so it cannot touch sessions while we tear them
        // down. Unregister each runtime fd before destroying it as belt-and-
        // suspenders.
        if (self.pump) |*pump| pump.deinit();
        self.pump = null;

        var iter = self.runtimes.iterator();
        while (iter.next()) |runtime| {
            self.alloc.free(runtime.key_ptr.*);
            runtime.value_ptr.*.deinit();
            self.alloc.destroy(runtime.value_ptr.*);
        }
        self.runtimes.deinit();
        self.proxies.deinit();
        self.registry.deinit();
        self.workspace_reg.deinit();
        self.subscriptions.deinit(self.alloc);
    }

    pub fn openProxy(self: *Service, host: []const u8, port: u16) ![]const u8 {
        return self.proxies.open(host, port);
    }

    pub fn closeProxy(self: *Service, stream_id: []const u8) !void {
        try self.proxies.close(stream_id);
    }

    pub fn writeProxy(self: *Service, stream_id: []const u8, payload: []const u8) !usize {
        return self.proxies.write(stream_id, payload);
    }

    pub fn readProxy(self: *Service, stream_id: []const u8, max_bytes: usize, timeout_ms: i32) !proxy_streams.ReadResult {
        return self.proxies.read(self.alloc, stream_id, max_bytes, timeout_ms);
    }

    pub fn openSession(self: *Service, maybe_session_id: ?[]const u8) !session_registry.SessionStatus {
        const session_id = try self.registry.ensure(maybe_session_id);
        defer self.alloc.free(session_id);
        return self.registry.status(session_id);
    }

    pub fn closeSession(self: *Service, session_id: []const u8) !void {
        try self.registry.close(session_id);
        self.removeRuntime(session_id);
    }

    pub fn attachSession(self: *Service, session_id: []const u8, attachment_id: []const u8, cols: u16, rows: u16) !session_registry.SessionStatus {
        try self.registry.attach(session_id, attachment_id, cols, rows);
        var status = try self.registry.status(session_id);
        errdefer status.deinit(self.alloc);
        try self.resizeRuntimeIfPresent(&status);
        return status;
    }

    pub fn resizeSession(self: *Service, session_id: []const u8, attachment_id: []const u8, cols: u16, rows: u16) !session_registry.SessionStatus {
        try self.registry.resize(session_id, attachment_id, cols, rows);
        var status = try self.registry.status(session_id);
        errdefer status.deinit(self.alloc);
        try self.resizeRuntimeIfPresent(&status);
        return status;
    }

    pub fn detachSession(self: *Service, session_id: []const u8, attachment_id: []const u8) !session_registry.SessionStatus {
        try self.registry.detach(session_id, attachment_id);
        var status = try self.registry.status(session_id);
        errdefer status.deinit(self.alloc);
        try self.resizeRuntimeIfPresent(&status);
        return status;
    }

    pub fn sessionStatus(self: *Service, session_id: []const u8) !session_registry.SessionStatus {
        return self.registry.status(session_id);
    }

    pub fn listSessions(self: *Service) ![]session_registry.SessionListEntry {
        return self.registry.list();
    }

    pub fn openTerminal(self: *Service, maybe_session_id: ?[]const u8, command: []const u8, cols: u16, rows: u16) !OpenTerminalResult {
        const opened = try self.registry.open(maybe_session_id, cols, rows);
        errdefer {
            self.registry.close(opened.session_id) catch {};
            self.alloc.free(opened.session_id);
            self.alloc.free(opened.attachment_id);
        }

        var status = try self.registry.status(opened.session_id);
        errdefer status.deinit(self.alloc);

        const runtime = try self.alloc.create(RuntimeSession);
        errdefer self.alloc.destroy(runtime);
        runtime.* = try RuntimeSession.init(self.alloc, command, status.effective_cols, status.effective_rows);
        errdefer runtime.deinit();

        try self.runtimes.put(opened.session_id, runtime);

        // Register PTY master fd with the kqueue pump so output drains
        // proactively even when no client is calling terminal.read.
        if (self.pump) |*pump| {
            const entry: pty_pump.Entry = .{
                .pty = &runtime.pty,
                .terminal = &runtime.terminal,
                .lock = &runtime.lock,
                .session_id = opened.session_id,
            };
            pump.register(runtime.pty.master_fd, entry) catch |err| {
                std.log.warn("session_service: pump.register failed: {s}", .{@errorName(err)});
            };
        }

        return .{
            .status = status,
            .attachment_id = opened.attachment_id,
            .offset = 0,
        };
    }

    pub fn readTerminal(self: *Service, session_id: []const u8, offset: u64, max_bytes: usize, timeout_ms: i32) !ReadTerminalResult {
        const runtime = self.runtimes.getPtr(session_id) orelse return error.TerminalSessionNotFound;
        return runtime.*.*.read(self.alloc, offset, max_bytes, timeout_ms);
    }

    pub fn writeTerminal(self: *Service, session_id: []const u8, data: []const u8) !usize {
        const runtime = self.runtimes.getPtr(session_id) orelse return error.TerminalSessionNotFound;
        try runtime.*.*.writeDraining(data);
        return data.len;
    }

    pub fn history(self: *Service, session_id: []const u8, format: serialize.HistoryFormat) ![]u8 {
        const runtime = self.runtimes.getPtr(session_id) orelse return error.TerminalSessionNotFound;
        return runtime.*.*.historyDump(self.alloc, format);
    }

    fn resizeRuntimeIfPresent(self: *Service, status: *const session_registry.SessionStatus) !void {
        const runtime = self.runtimes.getPtr(status.session_id) orelse return;
        // Skip the PTY resize if we don't have a real size yet. This avoids
        // spurious ResizeFailed errors during the bootstrap/restore window
        // when an attachment exists but hasn't reported geometry.
        if (status.effective_cols == 0 or status.effective_rows == 0) return;
        try runtime.*.*.resize(status.effective_cols, status.effective_rows);
    }

    fn removeRuntime(self: *Service, session_id: []const u8) void {
        const removed = self.runtimes.fetchRemove(session_id) orelse return;
        if (self.pump) |*pump| pump.unregister(removed.value.pty.master_fd);
        self.alloc.free(removed.key);
        removed.value.deinit();
        self.alloc.destroy(removed.value);
    }
};

test "open terminal returns named session when requested" {
    var service = Service.init(std.testing.allocator);
    defer service.deinit();

    var opened = try service.openTerminal("dev", "printf READY", 80, 24);
    defer opened.status.deinit(std.testing.allocator);
    defer std.testing.allocator.free(opened.attachment_id);

    try std.testing.expectEqualStrings("dev", opened.status.session_id);
    try std.testing.expectEqualStrings("att-1", opened.attachment_id);
}

test "terminal read returns subprocess output" {
    var service = Service.init(std.testing.allocator);
    defer service.deinit();

    var opened = try service.openTerminal(null, "printf READY", 80, 24);
    defer opened.status.deinit(std.testing.allocator);
    defer std.testing.allocator.free(opened.attachment_id);

    const read = try service.readTerminal(opened.status.session_id, 0, 32, 1000);
    defer std.testing.allocator.free(read.data);

    try std.testing.expect(std.mem.indexOf(u8, read.data, "READY") != null);
}

test "list sessions retains last known size after final detach" {
    var service = Service.init(std.testing.allocator);
    defer service.deinit();

    var opened = try service.openTerminal("dev", "printf READY", 120, 40);
    defer opened.status.deinit(std.testing.allocator);
    defer std.testing.allocator.free(opened.attachment_id);

    const initial = try service.listSessions();
    defer {
        for (initial) |*entry| entry.deinit(std.testing.allocator);
        std.testing.allocator.free(initial);
    }

    try std.testing.expectEqual(@as(usize, 1), initial.len);
    try std.testing.expectEqual(@as(usize, 1), initial[0].attachment_count);
    try std.testing.expectEqual(@as(u16, 120), initial[0].effective_cols);
    try std.testing.expectEqual(@as(u16, 40), initial[0].effective_rows);

    var detached = try service.detachSession("dev", opened.attachment_id);
    defer detached.deinit(std.testing.allocator);

    const listed = try service.listSessions();
    defer {
        for (listed) |*entry| entry.deinit(std.testing.allocator);
        std.testing.allocator.free(listed);
    }

    try std.testing.expectEqual(@as(usize, 1), listed.len);
    try std.testing.expectEqual(@as(usize, 0), listed[0].attachment_count);
    try std.testing.expectEqual(@as(u16, 120), listed[0].effective_cols);
    try std.testing.expectEqual(@as(u16, 40), listed[0].effective_rows);
}

test "kqueue pump drains PTY without explicit read" {
    if (!pty_pump.supported) return error.SkipZigTest;

    var service = Service.init(std.testing.allocator);
    defer service.deinit();

    var opened = try service.openTerminal("pump-smoke", "printf 'hello-from-pump\\n'", 80, 24);
    defer opened.status.deinit(std.testing.allocator);
    defer std.testing.allocator.free(opened.attachment_id);

    // Spin briefly waiting for the pump thread to drain output. We never
    // call readTerminal/history; if next_offset grows the pump did its job.
    const runtime_ptr = service.runtimes.get("pump-smoke") orelse return error.MissingRuntime;
    const deadline = std.time.milliTimestamp() + 2000;
    var grew = false;
    while (std.time.milliTimestamp() < deadline) {
        runtime_ptr.lock.lock();
        const window = runtime_ptr.terminal.offsetWindow();
        runtime_ptr.lock.unlock();
        if (window.next_offset > 0) {
            grew = true;
            break;
        }
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
    try std.testing.expect(grew);
}

test "close session removes terminal runtime" {
    var service = Service.init(std.testing.allocator);
    defer service.deinit();

    var opened = try service.openTerminal("dev", "printf READY", 80, 24);
    defer opened.status.deinit(std.testing.allocator);
    defer std.testing.allocator.free(opened.attachment_id);

    try service.closeSession("dev");

    try std.testing.expectError(error.SessionNotFound, service.sessionStatus("dev"));
    try std.testing.expectError(error.TerminalSessionNotFound, service.readTerminal("dev", 0, 32, 0));
    try std.testing.expectError(error.TerminalSessionNotFound, service.writeTerminal("dev", "hello"));
    try std.testing.expectError(error.TerminalSessionNotFound, service.history("dev", .plain));
}
