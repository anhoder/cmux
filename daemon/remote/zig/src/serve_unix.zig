const std = @import("std");
const json_rpc = @import("json_rpc.zig");
const local_peer_auth = @import("local_peer_auth.zig");
const outbound_queue = @import("outbound_queue.zig");
const server_core = @import("server_core.zig");
const session_service = @import("session_service.zig");
const serve_ws = @import("serve_ws.zig");
const pty_host = @import("pty_host.zig");

pub const Config = struct {
    socket_path: []const u8,
    ws_port: ?u16 = null,
    ws_secret: []const u8 = "",
};

pub fn serve(cfg: Config) !void {
    if (cfg.socket_path.len == 0) return error.MissingSocketPath;

    try ensurePrivateSocketDir(cfg.socket_path);
    try removeStaleSocket(cfg.socket_path);

    // Create a new process group so the cleanup signal handler can kill
    // all children without affecting the parent (macOS app / shell).
    // Then install signal handlers to kill the group on SIGTERM/SIGINT.
    // Without this, orphaned shells accumulate across daemon restarts
    // and exhaust the system PTY limit (kern.tty.ptmx_max).
    std.posix.setpgid(0, 0) catch {};
    installCleanupSignalHandlers();

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var shared = SharedService{
        .service = session_service.Service.init(alloc),
    };
    defer shared.service.deinit();

    // Start WebSocket listener on a separate thread if configured
    if (cfg.ws_port) |ws_port| {
        if (cfg.ws_secret.len > 0) {
            const ws_thread = try std.Thread.spawn(.{}, serve_ws.serveShared, .{
                &shared.service,
                ws_port,
                cfg.ws_secret,
            });
            ws_thread.detach();
        }
    }

    const listener_fd = try createSocket(cfg.socket_path);
    defer {
        std.posix.close(listener_fd);
        deleteSocket(cfg.socket_path) catch {};
    }

    while (true) {
        const client_fd = try std.posix.accept(listener_fd, null, null, std.posix.SOCK.CLOEXEC);
        const thread = try std.Thread.spawn(.{}, handleClientThread, .{ &shared, client_fd });
        thread.detach();
    }
}

const SharedService = struct {
    service: session_service.Service,
};

fn handleClientThread(shared: *SharedService, client_fd: std.posix.fd_t) void {
    handleClient(shared, client_fd) catch {};
}

fn handleClient(shared: *SharedService, client_fd: std.posix.fd_t) !void {
    defer std.posix.close(client_fd);
    try local_peer_auth.authorizeClient(client_fd);

    const service = &shared.service;
    const alloc = service.alloc;

    var stream = std.net.Stream{ .handle = client_fd };

    // Per-connection writer thread + bounded outbound queue. All bytes
    // sent to the client (RPC responses, terminal.output pushes,
    // workspace.changed pushes) flow through this queue so the pump and
    // workspace notifier never block on socket I/O.
    var queue = outbound_queue.OutboundQueue.init(alloc, client_fd);
    try queue.start();
    defer queue.shutdown();

    // Subscription cleanup on disconnect.
    var workspace_subscribed = false;
    defer if (workspace_subscribed) service.subscriptions.remove(&stream);
    defer service.unsubscribeAllForStream(&stream);

    // Stream lock satisfies TerminalSubscription's required type but is
    // not actually used while `queue` is set (writer thread is the sole
    // writer to the fd).
    var write_mutex: std.Thread.Mutex = .{};

    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(alloc);

    var read_buf: [64 * 1024]u8 = undefined;
    while (true) {
        if (queue.isDead()) return;
        const n = std.posix.read(client_fd, &read_buf) catch return;
        if (n == 0) break;

        try pending.appendSlice(alloc, read_buf[0..n]);
        while (std.mem.indexOfScalar(u8, pending.items, '\n')) |newline_index| {
            try handleLine(
                service,
                &queue,
                &stream,
                &write_mutex,
                &workspace_subscribed,
                pending.items[0..newline_index],
            );

            const remaining = pending.items[newline_index + 1 ..];
            std.mem.copyForwards(u8, pending.items[0..remaining.len], remaining);
            pending.items.len = remaining.len;
        }
    }
}

fn handleLine(
    service: *session_service.Service,
    queue: *outbound_queue.OutboundQueue,
    stream: *std.net.Stream,
    write_mutex: *std.Thread.Mutex,
    workspace_subscribed: *bool,
    raw_line: []const u8,
) !void {
    const alloc = service.alloc;
    const trimmed = std.mem.trimRight(u8, raw_line, "\r");
    if (trimmed.len == 0) return;

    var req = json_rpc.decodeRequest(alloc, trimmed) catch {
        const resp = try json_rpc.encodeResponse(alloc, .{
            .ok = false,
            .@"error" = .{ .code = "invalid_request", .message = "invalid JSON request" },
        });
        return enqueueResponse(queue, alloc, resp);
    };
    defer req.deinit(alloc);

    if (std.mem.eql(u8, req.method, "terminal.subscribe")) {
        const resp = try handleTerminalSubscribe(service, queue, stream, write_mutex, &req);
        return enqueueResponse(queue, alloc, resp);
    }
    if (std.mem.eql(u8, req.method, "terminal.unsubscribe")) {
        const resp = try handleTerminalUnsubscribe(service, stream, &req);
        return enqueueResponse(queue, alloc, resp);
    }
    if (std.mem.eql(u8, req.method, "workspace.subscribe") and !workspace_subscribed.*) {
        service.subscriptions.addQueued(alloc, stream, queue) catch {};
        workspace_subscribed.* = true;
        // Fall through so the snapshot is returned by server_core.dispatch.
    }

    const response = try server_core.dispatch(service, &req);
    return enqueueResponse(queue, alloc, response);
}

fn enqueueResponse(queue: *outbound_queue.OutboundQueue, alloc: std.mem.Allocator, payload: []u8) !void {
    // Newline-frame the response and hand ownership to the writer thread.
    const line = try alloc.alloc(u8, payload.len + 1);
    @memcpy(line[0..payload.len], payload);
    line[payload.len] = '\n';
    alloc.free(payload);
    queue.enqueueControl(line) catch |err| {
        alloc.free(line);
        return err;
    };
}

fn handleTerminalSubscribe(
    service: *session_service.Service,
    queue: *outbound_queue.OutboundQueue,
    stream: *std.net.Stream,
    write_mutex: *std.Thread.Mutex,
    req: *const json_rpc.Request,
) ![]u8 {
    const alloc = service.alloc;
    const params_value = req.parsed.value.object.get("params") orelse {
        return errorResp(alloc, req.id, "invalid_params", "terminal.subscribe requires params");
    };
    if (params_value != .object) return errorResp(alloc, req.id, "invalid_params", "params must be object");
    const session_id_v = params_value.object.get("session_id") orelse {
        return errorResp(alloc, req.id, "invalid_params", "terminal.subscribe requires session_id");
    };
    if (session_id_v != .string) return errorResp(alloc, req.id, "invalid_params", "session_id must be string");
    const session_id = session_id_v.string;

    const requested_offset: ?u64 = blk: {
        const off_v = params_value.object.get("offset") orelse break :blk null;
        if (off_v != .integer) break :blk null;
        if (off_v.integer < 0) break :blk null;
        break :blk @intCast(off_v.integer);
    };

    const snap = service.subscribeTerminalQueued(stream, write_mutex, queue, session_id, requested_offset) catch |err| switch (err) {
        error.TerminalSessionNotFound => return errorResp(alloc, req.id, "not_found", "terminal session not found"),
        else => return errorResp(alloc, req.id, "internal_error", @errorName(err)),
    };
    defer alloc.free(snap.data);

    const enc_len = std.base64.standard.Encoder.calcSize(snap.data.len);
    const enc = try alloc.alloc(u8, enc_len);
    defer alloc.free(enc);
    _ = std.base64.standard.Encoder.encode(enc, snap.data);

    return try json_rpc.encodeResponse(alloc, .{
        .id = req.id,
        .ok = true,
        .result = .{
            .session_id = session_id,
            .seq = snap.seq,
            .offset = snap.offset,
            .base_offset = snap.base_offset,
            .truncated = snap.truncated,
            .eof = snap.eof,
            .data = enc,
        },
    });
}

fn handleTerminalUnsubscribe(
    service: *session_service.Service,
    stream: *std.net.Stream,
    req: *const json_rpc.Request,
) ![]u8 {
    const alloc = service.alloc;
    const params_value = req.parsed.value.object.get("params") orelse {
        return errorResp(alloc, req.id, "invalid_params", "terminal.unsubscribe requires params");
    };
    if (params_value != .object) return errorResp(alloc, req.id, "invalid_params", "params must be object");
    const session_id_v = params_value.object.get("session_id") orelse {
        return errorResp(alloc, req.id, "invalid_params", "terminal.unsubscribe requires session_id");
    };
    if (session_id_v != .string) return errorResp(alloc, req.id, "invalid_params", "session_id must be string");

    const removed = service.unsubscribeTerminal(stream, session_id_v.string);
    return try json_rpc.encodeResponse(alloc, .{
        .id = req.id,
        .ok = true,
        .result = .{ .removed = removed },
    });
}

fn errorResp(alloc: std.mem.Allocator, id: ?std.json.Value, code: []const u8, message: []const u8) ![]u8 {
    return try json_rpc.encodeResponse(alloc, .{
        .id = id,
        .ok = false,
        .@"error" = .{ .code = code, .message = message },
    });
}

fn createSocket(socket_path: []const u8) !std.posix.fd_t {
    var unix_addr = try std.net.Address.initUnix(socket_path);
    const listener_fd = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC, 0);
    errdefer std.posix.close(listener_fd);

    try std.posix.bind(listener_fd, &unix_addr.any, unix_addr.getOsSockLen());
    try chmodPath(socket_path, 0o600);
    try std.posix.listen(listener_fd, 128);
    return listener_fd;
}

fn ensurePrivateSocketDir(socket_path: []const u8) !void {
    const dir_path = std.fs.path.dirname(socket_path) orelse return error.MissingSocketDirectory;
    try ensureDirExists(dir_path);

    const stat = try statPath(dir_path);
    if (stat.kind != .directory) return error.SocketDirectoryNotDirectory;
}

fn ensureDirExists(dir_path: []const u8) !void {
    if (std.fs.path.isAbsolute(dir_path)) {
        var root = try std.fs.openDirAbsolute("/", .{});
        defer root.close();
        const relative = std.mem.trimLeft(u8, dir_path, "/");
        if (relative.len > 0) try root.makePath(relative);
    } else {
        try std.fs.cwd().makePath(dir_path);
    }
}

fn removeStaleSocket(socket_path: []const u8) !void {
    const stat = statPath(socket_path) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    if (stat.kind != .unix_domain_socket) return error.SocketPathOccupied;
    try deleteSocket(socket_path);
}

fn statPath(path: []const u8) !std.fs.File.Stat {
    if (std.fs.path.isAbsolute(path)) {
        const dir_path = std.fs.path.dirname(path) orelse return error.FileNotFound;
        const base = std.fs.path.basename(path);
        var dir = try std.fs.openDirAbsolute(dir_path, .{});
        defer dir.close();
        return dir.statFile(base);
    }
    return std.fs.cwd().statFile(path);
}

fn deleteSocket(path: []const u8) !void {
    if (std.fs.path.isAbsolute(path)) return std.fs.deleteFileAbsolute(path);
    return std.fs.cwd().deleteFile(path);
}

/// Install signal handlers for SIGTERM/SIGINT/SIGHUP that kill the
/// entire process group. This ensures child shells from forkpty are
/// cleaned up when the daemon is killed, preventing PTY leaks.
fn installCleanupSignalHandlers() void {
    const act = std.c.Sigaction{
        .handler = .{ .handler = cleanupAndExit },
        .mask = @as(u32, 0),
        .flags = 0,
    };
    _ = std.c.sigaction(std.posix.SIG.TERM, &act, null);
    _ = std.c.sigaction(std.posix.SIG.INT, &act, null);
    _ = std.c.sigaction(std.posix.SIG.HUP, &act, null);
}

fn cleanupAndExit(_: c_int) callconv(.c) noreturn {
    // Kill all registered child processes (shells from forkpty).
    // Children are in their own sessions (setsid via login_tty),
    // so killing our process group alone won't reach them.
    pty_host.killAllChildren();
    // Also kill our process group for any other children.
    _ = std.c.kill(0, std.posix.SIG.KILL);
    std.posix.exit(0);
}

fn chmodPath(path: []const u8, mode: std.posix.mode_t) !void {
    if (std.fs.path.isAbsolute(path)) {
        const dir_path = std.fs.path.dirname(path) orelse return error.FileNotFound;
        const base = std.fs.path.basename(path);
        var dir = try std.fs.openDirAbsolute(dir_path, .{});
        defer dir.close();
        return std.posix.fchmodat(dir.fd, base, mode, 0);
    }
    return std.posix.fchmodat(std.fs.cwd().fd, path, mode, 0);
}
