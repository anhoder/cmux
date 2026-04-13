import AppKit
import Combine
import Foundation

/// Single persistent bidirectional Unix-socket connection to cmuxd.
///
/// Replaces WorkspaceDaemonBridge (workspace.sync push) and DaemonTerminalBridge
/// (per-surface read/write sockets). One socket per app process, regardless of
/// the number of terminals or workspaces.
///
/// Architecture:
///   - Persistent socket with dedicated reader thread.
///   - Reader routes by message shape: presence of `id` => RPC response, presence
///     of `event` => push notification.
///   - Writer is serial via a dedicated DispatchQueue (no main-thread blocking).
///   - Pending RPCs: `id -> continuation` map, fulfilled by reader.
///   - Terminal subscriptions: `session_id -> handlers` map, drained by reader.
///   - On reconnect: re-send hello, re-subscribe workspace + every active terminal.
final class DaemonConnection: @unchecked Sendable {
    static let shared = DaemonConnection()

    // Required server capabilities for this client to function.
    private static let requiredCapabilities: Set<String> = [
        "workspace.sync",
        "terminal.subscribe",
        "workspace.subscribe",
    ]

    private let socketPath: String
    private var fd: Int32 = -1
    private let stateLock = NSLock()
    private var connecting = false
    private var nextRpcID: Int = 0
    private let writeQueue = DispatchQueue(label: "cmux.daemon-connection.write", qos: .userInitiated)
    private var pending: [Int: (Result<[String: Any], Error>) -> Void] = [:]
    private var terminalHandlers: [String: TerminalSubscription] = [:]
    private var workspaceSubscribed = false
    private var workspaceSyncProvider: (() -> [String: Any]?)?

    /// Set by AppDelegate after the TabManager is wired up. Called whenever the
    /// daemon (re)connects so we can push the current workspace snapshot.
    func setWorkspaceSyncProvider(_ provider: @escaping () -> [String: Any]?) {
        stateLock.lock()
        workspaceSyncProvider = provider
        let connected = fd >= 0
        stateLock.unlock()
        if connected { performWorkspaceSync() }
    }

    private struct TerminalSubscription {
        let onOutput: (Data) -> Void
        let onDisconnect: (String?) -> Void
        var attachmentID: String
        var cols: Int
        var rows: Int
        var shellCommand: String
        var lastOffset: UInt64
    }

    static var defaultSocketPath: String {
        let env = ProcessInfo.processInfo.environment
        if let path = env["CMUXD_UNIX_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            return path
        }
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?.appendingPathComponent("cmux").path ?? "/tmp"
        let tag = env["CMUX_TAG"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return tag.isEmpty ? "\(appSupport)/cmuxd.sock" : "\(appSupport)/cmuxd-dev-\(tag).sock"
    }

    init(socketPath: String = DaemonConnection.defaultSocketPath) {
        self.socketPath = socketPath
        connectAsync()
    }

    var isConnected: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return fd >= 0
    }

    var statusDescription: String { isConnected ? "connected" : "disconnected" }
    var currentSocketPath: String { socketPath }

    // MARK: - Compatibility statics (drop-in replacements for DaemonTerminalBridge)

    /// Stable across app restarts; uses surface ID only because it persists in snapshots
    /// while workspace IDs are regenerated.
    static func computeSessionID(workspaceID: UUID, surfaceID: UUID) -> String {
        "ws-\(surfaceID.uuidString.lowercased())"
    }

    /// Pre-create a daemon session so iOS clients can attach before the desktop
    /// surface is materialized. Idempotent (already_exists is treated as success).
    static func preCreateSession(
        socketPath: String = DaemonConnection.defaultSocketPath,
        workspaceID: UUID,
        surfaceID: UUID,
        shellCommand: String,
        cols: Int = 80,
        rows: Int = 24,
        sessionID: String? = nil
    ) {
        let sid = sessionID ?? computeSessionID(workspaceID: workspaceID, surfaceID: surfaceID)
        DaemonConnection.shared.preCreate(sessionID: sid, shellCommand: shellCommand, cols: cols, rows: rows)
    }

    private func preCreate(sessionID: String, shellCommand: String, cols: Int, rows: Int) {
        sendRPCAsync(method: "terminal.open", params: [
            "session_id": sessionID,
            "command": shellCommand,
            "cols": cols,
            "rows": rows,
        ]) { [weak self] result in
            guard let self else { return }
            // Detach the bootstrap attachment so the session has zero attachments
            // until something subscribes (matches old preCreateSession behavior).
            if case .success(let resp) = result,
               let ok = resp["ok"] as? Bool, ok,
               let r = resp["result"] as? [String: Any],
               let bootstrap = r["attachment_id"] as? String {
                self.sendRPCAsync(method: "session.detach", params: [
                    "session_id": sessionID,
                    "attachment_id": bootstrap,
                ], completion: nil)
            }
        }
    }

    // MARK: - Public API: workspace sync (replaces WorkspaceDaemonBridge.performSync)

    func sendWorkspaceSync(_ params: [String: Any]) {
        sendRPCAsync(method: "workspace.sync", params: params, completion: nil)
    }

    private func performWorkspaceSync() {
        if let provider = workspaceSyncProvider, let params = provider() {
            sendWorkspaceSync(params)
        }
    }

    // MARK: - Public API: terminal subscribe (replaces DaemonTerminalBridge.start)

    /// Subscribe to a terminal session. Opens the session if it doesn't exist.
    /// The output callback is invoked on the reader thread; resize/write are async.
    func subscribeTerminal(
        sessionID: String,
        shellCommand: String,
        cols: Int,
        rows: Int,
        onOutput: @escaping (Data) -> Void,
        onDisconnect: @escaping (String?) -> Void
    ) {
        let attachmentID = "bridge-\(UUID().uuidString.prefix(8).lowercased())"
        let sub = TerminalSubscription(
            onOutput: onOutput,
            onDisconnect: onDisconnect,
            attachmentID: attachmentID,
            cols: max(1, cols),
            rows: max(1, rows),
            shellCommand: shellCommand,
            lastOffset: 0
        )

        stateLock.lock()
        terminalHandlers[sessionID] = sub
        let connected = fd >= 0
        stateLock.unlock()

        if connected {
            issueTerminalSubscribe(sessionID: sessionID)
        }
    }

    func unsubscribeTerminal(sessionID: String) {
        stateLock.lock()
        terminalHandlers.removeValue(forKey: sessionID)
        let connected = fd >= 0
        stateLock.unlock()
        if connected {
            sendRPCAsync(method: "terminal.unsubscribe", params: ["session_id": sessionID], completion: nil)
        }
    }

    func writeToSession(sessionID: String, data: Data) {
        sendRPCAsync(method: "terminal.write", params: [
            "session_id": sessionID,
            "data": data.base64EncodedString(),
        ], completion: nil)
    }

    func resizeSession(sessionID: String, cols: Int, rows: Int) {
        stateLock.lock()
        guard let sub = terminalHandlers[sessionID] else { stateLock.unlock(); return }
        var updated = sub
        updated.cols = max(1, cols)
        updated.rows = max(1, rows)
        terminalHandlers[sessionID] = updated
        let attachmentID = updated.attachmentID
        let connected = fd >= 0
        stateLock.unlock()
        if connected {
            sendRPCAsync(method: "session.resize", params: [
                "session_id": sessionID,
                "attachment_id": attachmentID,
                "cols": max(1, cols),
                "rows": max(1, rows),
            ], completion: nil)
        }
    }

    private func issueTerminalSubscribe(sessionID: String) {
        stateLock.lock()
        guard let sub = terminalHandlers[sessionID] else { stateLock.unlock(); return }
        let attachmentID = sub.attachmentID
        let cols = sub.cols
        let rows = sub.rows
        let shellCommand = sub.shellCommand
        let lastOffset = sub.lastOffset
        stateLock.unlock()

        // Ensure the session exists, then attach with our stable ID, then subscribe.
        sendRPCAsync(method: "terminal.open", params: [
            "session_id": sessionID,
            "command": shellCommand,
            "cols": cols,
            "rows": rows,
        ]) { [weak self] result in
            guard let self else { return }
            if case .success(let resp) = result,
               let ok = resp["ok"] as? Bool, ok,
               let r = resp["result"] as? [String: Any],
               let bootstrap = r["attachment_id"] as? String {
                self.sendRPCAsync(method: "session.detach", params: [
                    "session_id": sessionID,
                    "attachment_id": bootstrap,
                ], completion: nil)
            }
            self.sendRPCAsync(method: "session.attach", params: [
                "session_id": sessionID,
                "attachment_id": attachmentID,
                "cols": cols,
                "rows": rows,
            ], completion: nil)
            self.sendRPCAsync(method: "terminal.subscribe", params: [
                "session_id": sessionID,
                "offset": lastOffset,
            ]) { [weak self] subResult in
                if case .success(let r) = subResult,
                   let ok = r["ok"] as? Bool, ok,
                   let result = r["result"] as? [String: Any] {
                    if let base64 = result["data"] as? String,
                       let data = Data(base64Encoded: base64), !data.isEmpty {
                        self?.deliverTerminalOutput(sessionID: sessionID, data: data)
                    }
                    if let off = result["offset"] as? UInt64 {
                        self?.updateTerminalOffset(sessionID: sessionID, offset: off)
                    } else if let off = result["offset"] as? Int {
                        self?.updateTerminalOffset(sessionID: sessionID, offset: UInt64(off))
                    }
                }
            }
        }
    }

    private func updateTerminalOffset(sessionID: String, offset: UInt64) {
        stateLock.lock()
        if var sub = terminalHandlers[sessionID] {
            sub.lastOffset = offset
            terminalHandlers[sessionID] = sub
        }
        stateLock.unlock()
    }

    private func deliverTerminalOutput(sessionID: String, data: Data) {
        stateLock.lock()
        let handler = terminalHandlers[sessionID]?.onOutput
        stateLock.unlock()
        handler?(data)
    }

    // MARK: - RPC core

    @discardableResult
    private func nextID() -> Int {
        stateLock.lock(); defer { stateLock.unlock() }
        nextRpcID += 1
        return nextRpcID
    }

    private func sendRPCAsync(
        method: String,
        params: [String: Any],
        completion: (((Result<[String: Any], Error>)) -> Void)?
    ) {
        let id = nextID()
        if let completion {
            stateLock.lock()
            pending[id] = completion
            stateLock.unlock()
        }

        writeQueue.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let fd = self.fd
            self.stateLock.unlock()
            guard fd >= 0 else {
                self.fulfill(id: id, with: .failure(NSError(domain: "DaemonConnection", code: -1)))
                self.connectAsync()
                return
            }
            let payload: [String: Any] = ["id": id, "method": method, "params": params]
            guard var data = try? JSONSerialization.data(withJSONObject: payload) else {
                self.fulfill(id: id, with: .failure(NSError(domain: "DaemonConnection", code: -2)))
                return
            }
            data.append(0x0A)
            let n = data.withUnsafeBytes { ptr -> Int in
                Darwin.write(fd, ptr.baseAddress, ptr.count)
            }
            if n <= 0 {
                self.fulfill(id: id, with: .failure(NSError(domain: "DaemonConnection", code: -3)))
                self.handleSocketFailure()
            }
        }
    }

    private func fulfill(id: Int, with result: Result<[String: Any], Error>) {
        stateLock.lock()
        let cb = pending.removeValue(forKey: id)
        stateLock.unlock()
        cb?(result)
    }

    // MARK: - Connection lifecycle

    private func connectAsync() {
        stateLock.lock()
        guard fd < 0, !connecting else { stateLock.unlock(); return }
        connecting = true
        stateLock.unlock()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.connectBlocking()
        }
    }

    private func connectBlocking() {
        let newFD = openSocket()
        guard newFD >= 0 else {
            stateLock.lock(); connecting = false; stateLock.unlock()
            scheduleReconnect()
            return
        }

        // Send hello synchronously and verify capabilities before exposing the fd.
        guard performHello(fd: newFD) else {
            Darwin.close(newFD)
            stateLock.lock(); connecting = false; stateLock.unlock()
            scheduleReconnect()
            return
        }

        stateLock.lock()
        fd = newFD
        connecting = false
        let sessions = Array(terminalHandlers.keys)
        let needsWorkspaceSubscribe = !workspaceSubscribed
        let provider = workspaceSyncProvider
        stateLock.unlock()

        // Start reader thread
        let reader = Thread { [weak self] in self?.readerLoop(fd: newFD) }
        reader.name = "cmux.daemon-connection.reader"
        reader.qualityOfService = .userInteractive
        reader.start()

        // Re-subscribe workspace
        if needsWorkspaceSubscribe {
            sendRPCAsync(method: "workspace.subscribe", params: [:]) { [weak self] _ in
                self?.stateLock.lock()
                self?.workspaceSubscribed = true
                self?.stateLock.unlock()
            }
        }

        // Re-subscribe every terminal we know about
        for sid in sessions {
            issueTerminalSubscribe(sessionID: sid)
        }

        // Push current workspace snapshot
        if let provider, let params = provider() {
            sendWorkspaceSync(params)
        }
    }

    private func openSocket() -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathSize = MemoryLayout.size(ofValue: addr.sun_path)
        socketPath.withCString { cstr in
            _ = memcpy(&addr.sun_path, cstr, min(Int(strlen(cstr)), pathSize - 1))
        }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(fd, sockaddrPtr, addrLen)
            }
        }
        if result != 0 {
            Darwin.close(fd)
            return -1
        }
        var sendTimeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    /// Send hello synchronously on a freshly opened fd, before reader thread starts.
    /// Returns true if the server reports all required capabilities.
    private func performHello(fd: Int32) -> Bool {
        let payload: [String: Any] = [
            "id": 0,
            "method": "hello",
            "params": ["client": "cmux-macos", "version": 1],
        ]
        guard var data = try? JSONSerialization.data(withJSONObject: payload) else { return false }
        data.append(0x0A)
        let n = data.withUnsafeBytes { ptr -> Int in Darwin.write(fd, ptr.baseAddress, ptr.count) }
        guard n > 0 else { return false }

        var accumulated = Data()
        var buf = [UInt8](repeating: 0, count: 8192)
        var rcv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &rcv, socklen_t(MemoryLayout<timeval>.size))
        while !accumulated.contains(0x0A) {
            let r = Darwin.read(fd, &buf, buf.count)
            if r <= 0 { return false }
            accumulated.append(contentsOf: buf[0..<r])
        }
        // Reset to no recv timeout for the reader loop (blocking read).
        var noTimeout = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &noTimeout, socklen_t(MemoryLayout<timeval>.size))

        guard let nlIdx = accumulated.firstIndex(of: 0x0A),
              let json = try? JSONSerialization.jsonObject(with: accumulated[..<nlIdx]) as? [String: Any],
              let ok = json["ok"] as? Bool, ok,
              let result = json["result"] as? [String: Any] else {
            return false
        }
        let caps = (result["capabilities"] as? [String]).map(Set.init) ?? []
        let missing = DaemonConnection.requiredCapabilities.subtracting(caps)
        if !missing.isEmpty {
            NSLog("📱 DaemonConnection: missing required capabilities: %@", missing.joined(separator: ","))
            return false
        }
        return true
    }

    private func handleSocketFailure() {
        stateLock.lock()
        if fd >= 0 { Darwin.close(fd); fd = -1 }
        workspaceSubscribed = false
        // Fail all pending RPCs
        let pendingCopy = pending
        pending.removeAll()
        // Notify subscribers of disconnect
        let disconnects = terminalHandlers.values.map { $0.onDisconnect }
        stateLock.unlock()
        for cb in pendingCopy.values {
            cb(.failure(NSError(domain: "DaemonConnection", code: -10)))
        }
        for cb in disconnects {
            cb("daemon disconnected")
        }
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.connectAsync()
        }
    }

    // MARK: - Reader thread

    private func readerLoop(fd: Int32) {
        var accumulated = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = Darwin.read(fd, &buf, buf.count)
            if n <= 0 {
                handleSocketFailure()
                return
            }
            accumulated.append(contentsOf: buf[0..<n])
            while let nlIdx = accumulated.firstIndex(of: 0x0A) {
                let line = accumulated[accumulated.startIndex..<nlIdx]
                accumulated.removeSubrange(accumulated.startIndex...nlIdx)
                guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    continue
                }
                handleIncoming(obj)
            }
        }
    }

    private func handleIncoming(_ obj: [String: Any]) {
        if let event = obj["event"] as? String {
            handleEvent(event, obj)
            return
        }
        if let id = obj["id"] as? Int {
            stateLock.lock()
            let cb = pending.removeValue(forKey: id)
            stateLock.unlock()
            cb?(.success(obj))
        }
    }

    private func handleEvent(_ event: String, _ obj: [String: Any]) {
        switch event {
        case "terminal.output":
            guard let params = obj["params"] as? [String: Any],
                  let sid = params["session_id"] as? String else { return }
            if let base64 = params["data"] as? String,
               let data = Data(base64Encoded: base64), !data.isEmpty {
                deliverTerminalOutput(sessionID: sid, data: data)
            }
            if let off = params["offset"] as? UInt64 {
                updateTerminalOffset(sessionID: sid, offset: off)
            } else if let off = params["offset"] as? Int {
                updateTerminalOffset(sessionID: sid, offset: UInt64(off))
            }
            if let eof = params["eof"] as? Bool, eof {
                stateLock.lock()
                let cb = terminalHandlers[sid]?.onDisconnect
                terminalHandlers.removeValue(forKey: sid)
                stateLock.unlock()
                cb?(nil)
            }
        case "workspace.changed":
            // macOS app is the source of workspace state, not a consumer; ignore.
            break
        default:
            break
        }
    }
}
