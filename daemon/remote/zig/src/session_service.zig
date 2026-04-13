const std = @import("std");
const json_rpc = @import("json_rpc.zig");
const outbound_queue = @import("outbound_queue.zig");
const proxy_streams = @import("proxy_streams.zig");
const pty_host = @import("pty_host.zig");
const pty_pump = @import("pty_pump.zig");
const serialize = @import("serialize.zig");
const session_registry = @import("session_registry.zig");
const terminal_session = @import("terminal_session.zig");
pub const workspace_registry = @import("workspace_registry.zig");

/// One client subscription to a terminal session. Pump-driven push events
/// get framed as WebSocket text frames and written to `stream` while
/// `stream_lock` is held to serialize against any RPC response writer
/// running on the connection's reader thread.
pub const TerminalSubscription = struct {
    session_id: []const u8, // borrowed: hashmap key for the runtime
    stream: *std.net.Stream,
    stream_lock: *std.Thread.Mutex,
    /// If set, push frames are enqueued (line-framed) into a per-connection
    /// writer thread. Otherwise the WS sync framing path is used.
    queue: ?*outbound_queue.OutboundQueue = null,
    last_offset: u64,
    seq: u64 = 0,
    dead: std.atomic.Value(bool) = .init(false),
    /// Last bell_count observed when we pushed to this subscriber.
    last_bell_count: u64 = 0,
    /// Last command_seq observed when we pushed to this subscriber.
    last_command_seq: u64 = 0,
    /// Last notification_seq observed when we pushed to this subscriber.
    last_notification_seq: u64 = 0,
};

pub const SubscribeSnapshot = struct {
    data: []u8, // owned
    offset: u64,
    base_offset: u64,
    truncated: bool,
    eof: bool,
    seq: u64,
};

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
    sub_mutex: std.Thread.Mutex = .{},
    terminal_subs: std.ArrayListUnmanaged(*TerminalSubscription) = .empty,

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
                if (service.pump != null) {
                    // Safe per Zig's result-location semantics: `service` is
                    // constructed in the caller's destination, so &service is
                    // already its final address.
                    service.pump.?.setNotify(&service, pumpNotifyTrampoline);
                }
            } else |err| {
                std.log.warn("session_service: kqueue pump unavailable: {s}", .{@errorName(err)});
            }
        }
        return service;
    }

    pub fn deinit(self: *Service) void {
        // Stop the pump first so it cannot touch sessions or subscriptions
        // while we tear them down.
        if (self.pump) |*pump| pump.deinit();
        self.pump = null;

        self.sub_mutex.lock();
        for (self.terminal_subs.items) |sub| self.alloc.destroy(sub);
        self.terminal_subs.deinit(self.alloc);
        self.sub_mutex.unlock();

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
        // Drop any subscriptions pointing at this session_id so their
        // borrowed `session_id` pointer doesn't outlive the hashmap key.
        self.removeSubscriptionsBySessionId(removed.key);
        self.alloc.free(removed.key);
        removed.value.deinit();
        self.alloc.destroy(removed.value);
    }

    /// Atomically: snapshot bytes from `requested_offset` (default = current
    /// next_offset, i.e. no replay) and register `stream` for push events.
    /// Subsequent PTY output is delivered via the `terminal.output` event.
    pub fn subscribeTerminal(
        self: *Service,
        stream: *std.net.Stream,
        stream_lock: *std.Thread.Mutex,
        session_id: []const u8,
        requested_offset: ?u64,
    ) !SubscribeSnapshot {
        return self.subscribeTerminalQueued(stream, stream_lock, null, session_id, requested_offset);
    }

    /// Same as `subscribeTerminal` but routes pushes through a per-connection
    /// outbound queue (used by serve_unix; WS callers pass null).
    pub fn subscribeTerminalQueued(
        self: *Service,
        stream: *std.net.Stream,
        stream_lock: *std.Thread.Mutex,
        queue: ?*outbound_queue.OutboundQueue,
        session_id: []const u8,
        requested_offset: ?u64,
    ) !SubscribeSnapshot {
        const runtime = self.runtimes.get(session_id) orelse return error.TerminalSessionNotFound;
        const key_entry = self.runtimes.getEntry(session_id) orelse return error.TerminalSessionNotFound;
        const canonical_session_id = key_entry.key_ptr.*;

        runtime.lock.lock();
        defer runtime.lock.unlock();

        // Best-effort: drain any pending bytes so the snapshot is fresh.
        runtime.pty.pump(&runtime.terminal) catch {};

        const window = runtime.terminal.offsetWindow();
        const start = requested_offset orelse window.next_offset;

        const max_bytes: usize = 256 * 1024;
        const raw = try runtime.terminal.readRaw(self.alloc, start, max_bytes);
        errdefer self.alloc.free(raw.data);

        const eof_now = runtime.pty.isClosed() and raw.offset >= window.next_offset;

        const sub = try self.alloc.create(TerminalSubscription);
        errdefer self.alloc.destroy(sub);
        sub.* = .{
            .session_id = canonical_session_id,
            .stream = stream,
            .stream_lock = stream_lock,
            .queue = queue,
            .last_offset = raw.offset,
            .seq = 0,
            .last_bell_count = runtime.terminal.bell_count,
            .last_command_seq = runtime.terminal.command_seq,
            .last_notification_seq = runtime.terminal.notification_seq,
        };

        self.sub_mutex.lock();
        defer self.sub_mutex.unlock();
        try self.terminal_subs.append(self.alloc, sub);

        return .{
            .data = raw.data,
            .offset = raw.offset,
            .base_offset = raw.base_offset,
            .truncated = raw.truncated,
            .eof = eof_now,
            .seq = 0,
        };
    }

    pub fn unsubscribeTerminal(
        self: *Service,
        stream: *std.net.Stream,
        session_id: []const u8,
    ) bool {
        self.sub_mutex.lock();
        defer self.sub_mutex.unlock();
        var i: usize = 0;
        while (i < self.terminal_subs.items.len) : (i += 1) {
            const s = self.terminal_subs.items[i];
            if (s.stream == stream and std.mem.eql(u8, s.session_id, session_id)) {
                _ = self.terminal_subs.orderedRemove(i);
                self.alloc.destroy(s);
                return true;
            }
        }
        return false;
    }

    /// Called by the WS handler when a connection closes.
    pub fn unsubscribeAllForStream(self: *Service, stream: *std.net.Stream) void {
        self.sub_mutex.lock();
        defer self.sub_mutex.unlock();
        var i: usize = 0;
        while (i < self.terminal_subs.items.len) {
            const s = self.terminal_subs.items[i];
            if (s.stream == stream) {
                _ = self.terminal_subs.orderedRemove(i);
                self.alloc.destroy(s);
            } else i += 1;
        }
    }

    fn removeSubscriptionsBySessionId(self: *Service, session_id: []const u8) void {
        self.sub_mutex.lock();
        defer self.sub_mutex.unlock();
        var i: usize = 0;
        while (i < self.terminal_subs.items.len) {
            const s = self.terminal_subs.items[i];
            if (std.mem.eql(u8, s.session_id, session_id)) {
                _ = self.terminal_subs.orderedRemove(i);
                self.alloc.destroy(s);
            } else i += 1;
        }
    }

    fn pumpNotifyTrampoline(ctx: ?*anyopaque, entry: pty_pump.Entry) void {
        const self: *Service = @ptrCast(@alignCast(ctx orelse return));
        self.deliverTerminalPushes(entry);
    }

    fn deliverTerminalPushes(self: *Service, entry: pty_pump.Entry) void {
        // Snapshot matching subscriber pointers so we don't hold sub_mutex
        // across PTY/terminal locking and network writes.
        var matching: std.ArrayListUnmanaged(*TerminalSubscription) = .empty;
        defer matching.deinit(self.alloc);

        self.sub_mutex.lock();
        for (self.terminal_subs.items) |sub| {
            if (sub.dead.load(.seq_cst)) continue;
            if (std.mem.eql(u8, sub.session_id, entry.session_id)) {
                matching.append(self.alloc, sub) catch break;
            }
        }
        self.sub_mutex.unlock();

        for (matching.items) |sub| {
            if (sub.dead.load(.seq_cst)) continue;
            self.pushOneSubscriber(entry, sub) catch {
                sub.dead.store(true, .seq_cst);
            };
        }
    }

    fn pushOneSubscriber(self: *Service, entry: pty_pump.Entry, sub: *TerminalSubscription) !void {
        entry.lock.lock();
        const window = entry.terminal.offsetWindow();
        const eof_flag = entry.pty.isClosed();

        // Snapshot notification-related state under lock.
        const cur_bell = entry.terminal.bell_count;
        const cur_cmd_seq = entry.terminal.command_seq;
        const cur_notif_seq = entry.terminal.notification_seq;
        const new_bell = cur_bell != sub.last_bell_count;
        const new_command = cur_cmd_seq != sub.last_command_seq;
        const new_notification = cur_notif_seq != sub.last_notification_seq;

        const exit_code_snapshot: ?i32 = if (new_command) entry.terminal.last_command_exit_code else null;
        var notif_title: ?[]u8 = null;
        var notif_body: ?[]u8 = null;
        if (new_notification) {
            if (entry.terminal.last_notification) |n| {
                if (n.title) |t| notif_title = self.alloc.dupe(u8, t) catch null;
                if (n.body) |b| notif_body = self.alloc.dupe(u8, b) catch null;
            }
        }
        defer if (notif_title) |t| self.alloc.free(t);
        defer if (notif_body) |b| self.alloc.free(b);

        var start = sub.last_offset;
        var truncated = false;
        if (start < window.base_offset) {
            start = window.base_offset;
            truncated = true;
        }
        const has_new_bytes = start < window.next_offset;
        const has_new_notifications = new_bell or new_command or new_notification;

        if (!has_new_bytes and !has_new_notifications) {
            entry.lock.unlock();
            return;
        }

        var raw_data_owned: ?[]u8 = null;
        var raw_offset = sub.last_offset;
        var raw_base_offset = window.base_offset;
        var raw_truncated_flag = false;
        if (has_new_bytes) {
            const want = window.next_offset - start;
            const max_chunk: usize = 256 * 1024;
            const take: usize = if (want > max_chunk) max_chunk else @as(usize, @intCast(want));
            const raw = entry.terminal.readRaw(self.alloc, start, take) catch |err| {
                entry.lock.unlock();
                return err;
            };
            raw_data_owned = raw.data;
            raw_offset = raw.offset;
            raw_base_offset = raw.base_offset;
            raw_truncated_flag = raw.truncated;
        }

        sub.last_offset = raw_offset;
        sub.last_bell_count = cur_bell;
        sub.last_command_seq = cur_cmd_seq;
        sub.last_notification_seq = cur_notif_seq;
        sub.seq += 1;
        const seq_now = sub.seq;
        const eof_now = eof_flag and raw_offset >= window.next_offset;
        entry.lock.unlock();

        defer if (raw_data_owned) |d| self.alloc.free(d);

        const data_bytes: []const u8 = if (raw_data_owned) |d| d else "";
        const enc_len = std.base64.standard.Encoder.calcSize(data_bytes.len);
        const enc = try self.alloc.alloc(u8, enc_len);
        defer self.alloc.free(enc);
        _ = std.base64.standard.Encoder.encode(enc, data_bytes);

        const NotificationsPayload = struct {
            bell: bool,
            command_finished: ?struct { exit_code: ?i32 },
            notification: ?struct { title: ?[]const u8, body: ?[]const u8 },
        };

        const notifications_payload: ?NotificationsPayload = if (has_new_notifications) .{
            .bell = new_bell,
            .command_finished = if (new_command) .{ .exit_code = exit_code_snapshot } else null,
            .notification = if (new_notification) .{
                .title = if (notif_title) |t| t else null,
                .body = if (notif_body) |b| b else null,
            } else null,
        } else null;

        const event = try json_rpc.encodeResponse(self.alloc, .{
            .event = "terminal.output",
            .seq = seq_now,
            .session_id = sub.session_id,
            .data = enc,
            .offset = raw_offset,
            .base_offset = raw_base_offset,
            .truncated = truncated or raw_truncated_flag,
            .eof = eof_now,
            .notifications = notifications_payload,
        });

        if (sub.queue) |q| {
            // Newline-frame for line-delimited Unix transport. enqueue takes
            // ownership of `line` on success.
            const line = try self.alloc.alloc(u8, event.len + 1);
            @memcpy(line[0..event.len], event);
            line[event.len] = '\n';
            self.alloc.free(event);
            q.enqueueTerminal(line) catch |err| {
                self.alloc.free(line);
                return err;
            };
            return;
        }

        defer self.alloc.free(event);
        sub.stream_lock.lock();
        defer sub.stream_lock.unlock();
        try sendWsTextFrame(sub.stream, event);
    }
};

fn sendWsTextFrame(stream: *std.net.Stream, data: []const u8) !void {
    var header: [10]u8 = undefined;
    header[0] = 0x81; // FIN + text
    var header_len: usize = 2;
    if (data.len <= 125) {
        header[1] = @intCast(data.len);
    } else if (data.len <= 65535) {
        header[1] = 126;
        std.mem.writeInt(u16, header[2..4], @intCast(data.len), .big);
        header_len = 4;
    } else {
        header[1] = 127;
        std.mem.writeInt(u64, header[2..10], @intCast(data.len), .big);
        header_len = 10;
    }
    _ = try stream.write(header[0..header_len]);
    if (data.len > 0) _ = try stream.write(data);
}

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

test "terminal.subscribe snapshot + pump pushes terminal.output" {
    if (!pty_pump.supported) return error.SkipZigTest;

    var service = Service.init(std.testing.allocator);
    defer service.deinit();

    var opened = try service.openTerminal(
        "sub-smoke",
        "printf INITIAL; sleep 0.2; printf LATER",
        80,
        24,
    );
    defer opened.status.deinit(std.testing.allocator);
    defer std.testing.allocator.free(opened.attachment_id);

    // Give the first printf time to land before subscribing so we can verify
    // subscribing at the current offset returns no replay (snap.data empty).
    std.Thread.sleep(80 * std.time.ns_per_ms);

    var fds: [2]std.c.fd_t = undefined;
    if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &fds) != 0) {
        return error.SocketPairFailed;
    }
    defer std.posix.close(fds[1]);
    var stream = std.net.Stream{ .handle = fds[0] };
    // Make the read side non-blocking so the polling loop below doesn't wedge.
    const flags = try std.posix.fcntl(fds[1], std.posix.F.GETFL, 0);
    _ = try std.posix.fcntl(fds[1], std.posix.F.SETFL, flags | @as(u32, @bitCast(std.posix.O{ .NONBLOCK = true })));

    var write_mutex: std.Thread.Mutex = .{};

    const snap = try service.subscribeTerminal(&stream, &write_mutex, "sub-smoke", null);
    std.testing.allocator.free(snap.data);

    // Wait until the pump pushes a terminal.output frame containing LATER.
    var buf: [4096]u8 = undefined;
    var accum: std.ArrayListUnmanaged(u8) = .empty;
    defer accum.deinit(std.testing.allocator);

    const deadline = std.time.milliTimestamp() + 3000;
    var got_event = false;
    var got_later = false;
    while (std.time.milliTimestamp() < deadline) {
        const n = std.posix.read(fds[1], &buf) catch |err| switch (err) {
            error.WouldBlock => {
                std.Thread.sleep(15 * std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };
        if (n == 0) break;
        try accum.appendSlice(std.testing.allocator, buf[0..n]);
        if (std.mem.indexOf(u8, accum.items, "\"event\":\"terminal.output\"") != null) {
            got_event = true;
        }
        if (std.mem.indexOf(u8, accum.items, "TEFURVI=") != null or // base64("LATER")
            std.mem.indexOf(u8, accum.items, "TEFURVI") != null)
        {
            got_later = true;
        }
        if (got_event and got_later) break;
    }
    try std.testing.expect(got_event);
    try std.testing.expect(got_later);

    _ = service.unsubscribeTerminal(&stream, "sub-smoke");
}

test "queued terminal.subscribe routes pushes through OutboundQueue" {
    if (!pty_pump.supported) return error.SkipZigTest;

    var service = Service.init(std.testing.allocator);
    defer service.deinit();

    var opened = try service.openTerminal(
        "queued-smoke",
        "printf INITIAL; sleep 0.2; printf LATER",
        80,
        24,
    );
    defer opened.status.deinit(std.testing.allocator);
    defer std.testing.allocator.free(opened.attachment_id);

    std.Thread.sleep(80 * std.time.ns_per_ms);

    var fds: [2]std.c.fd_t = undefined;
    if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &fds) != 0) {
        return error.SocketPairFailed;
    }
    defer std.posix.close(fds[1]);
    var stream = std.net.Stream{ .handle = fds[0] };
    const flags = try std.posix.fcntl(fds[1], std.posix.F.GETFL, 0);
    _ = try std.posix.fcntl(fds[1], std.posix.F.SETFL, flags | @as(u32, @bitCast(std.posix.O{ .NONBLOCK = true })));

    var queue = outbound_queue.OutboundQueue.init(std.testing.allocator, fds[0]);
    try queue.start();
    defer queue.shutdown();

    var write_mutex: std.Thread.Mutex = .{};
    const snap = try service.subscribeTerminalQueued(&stream, &write_mutex, &queue, "queued-smoke", null);
    std.testing.allocator.free(snap.data);

    var buf: [4096]u8 = undefined;
    var accum: std.ArrayListUnmanaged(u8) = .empty;
    defer accum.deinit(std.testing.allocator);

    const deadline = std.time.milliTimestamp() + 3000;
    var got_event = false;
    var got_later = false;
    var got_newline = false;
    while (std.time.milliTimestamp() < deadline) {
        const n = std.posix.read(fds[1], &buf) catch |err| switch (err) {
            error.WouldBlock => {
                std.Thread.sleep(15 * std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };
        if (n == 0) break;
        try accum.appendSlice(std.testing.allocator, buf[0..n]);
        if (std.mem.indexOf(u8, accum.items, "\"event\":\"terminal.output\"") != null) got_event = true;
        if (std.mem.indexOf(u8, accum.items, "TEFURVI") != null) got_later = true;
        if (std.mem.indexOfScalar(u8, accum.items, '\n') != null) got_newline = true;
        if (got_event and got_later and got_newline) break;
    }
    try std.testing.expect(got_event);
    try std.testing.expect(got_later);
    try std.testing.expect(got_newline);

    _ = service.unsubscribeTerminal(&stream, "queued-smoke");
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

test "terminal.output carries notifications:{bell:true} once then null" {
    if (!pty_pump.supported) return error.SkipZigTest;

    var service = Service.init(std.testing.allocator);
    defer service.deinit();

    var opened = try service.openTerminal("notif-smoke", "sleep 5", 80, 24);
    defer opened.status.deinit(std.testing.allocator);
    defer std.testing.allocator.free(opened.attachment_id);

    var fds: [2]std.c.fd_t = undefined;
    if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &fds) != 0) {
        return error.SocketPairFailed;
    }
    defer std.posix.close(fds[1]);
    var stream = std.net.Stream{ .handle = fds[0] };
    const flags = try std.posix.fcntl(fds[1], std.posix.F.GETFL, 0);
    _ = try std.posix.fcntl(fds[1], std.posix.F.SETFL, flags | @as(u32, @bitCast(std.posix.O{ .NONBLOCK = true })));

    var write_mutex: std.Thread.Mutex = .{};

    const snap = try service.subscribeTerminal(&stream, &write_mutex, "notif-smoke", null);
    std.testing.allocator.free(snap.data);

    const runtime = service.runtimes.get("notif-smoke") orelse return error.MissingRuntime;
    const entry: pty_pump.Entry = .{
        .pty = &runtime.pty,
        .terminal = &runtime.terminal,
        .lock = &runtime.lock,
        .session_id = "notif-smoke",
    };

    // Inject a BEL + printable byte, so the push has both a notification and new bytes.
    runtime.lock.lock();
    try runtime.terminal.feed("\x07x");
    runtime.lock.unlock();

    service.deliverTerminalPushes(entry);

    var buf: [4096]u8 = undefined;
    var accum: std.ArrayListUnmanaged(u8) = .empty;
    defer accum.deinit(std.testing.allocator);

    const deadline = std.time.milliTimestamp() + 1000;
    while (std.time.milliTimestamp() < deadline) {
        const n = std.posix.read(fds[1], &buf) catch |err| switch (err) {
            error.WouldBlock => {
                std.Thread.sleep(5 * std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };
        if (n == 0) break;
        try accum.appendSlice(std.testing.allocator, buf[0..n]);
        if (std.mem.indexOf(u8, accum.items, "\"bell\":true") != null) break;
    }
    try std.testing.expect(std.mem.indexOf(u8, accum.items, "\"bell\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, accum.items, "\"notifications\":null") == null);

    accum.clearRetainingCapacity();
    runtime.lock.lock();
    try runtime.terminal.feed("y");
    runtime.lock.unlock();

    service.deliverTerminalPushes(entry);

    const deadline2 = std.time.milliTimestamp() + 1000;
    while (std.time.milliTimestamp() < deadline2) {
        const n = std.posix.read(fds[1], &buf) catch |err| switch (err) {
            error.WouldBlock => {
                std.Thread.sleep(5 * std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };
        if (n == 0) break;
        try accum.appendSlice(std.testing.allocator, buf[0..n]);
        if (std.mem.indexOf(u8, accum.items, "\"notifications\":null") != null) break;
    }
    try std.testing.expect(std.mem.indexOf(u8, accum.items, "\"notifications\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, accum.items, "\"bell\":true") == null);

    _ = service.unsubscribeTerminal(&stream, "notif-smoke");
}
