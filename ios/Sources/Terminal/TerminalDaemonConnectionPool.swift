import Foundation

/// Process-wide registry of TerminalDaemonConnection actors, keyed by host
/// stableID. Workspace subscription and terminal sessions for the same daemon
/// share one ws + one TerminalRemoteDaemonClient.
final class TerminalDaemonConnectionPool: @unchecked Sendable {
    static let shared = TerminalDaemonConnectionPool()

    private let lock = NSLock()
    private var connections: [String: TerminalDaemonConnection] = [:]
    private var pushConfigObserver: NSObjectProtocol?

    init() {
        // Phase 4.3: forward push configuration changes (new device token,
        // new endpoint, new bearer) to every live daemon connection so they
        // can re-send daemon.configure_notifications.
        pushConfigObserver = NotificationCenter.default.addObserver(
            forName: PushNotificationConfigurator.didChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.reprovisionAllRemotePush()
        }
    }

    deinit {
        if let observer = pushConfigObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func connection(
        stableID: String,
        hostname: String,
        port: Int,
        secret: String
    ) -> TerminalDaemonConnection {
        lock.lock()
        defer { lock.unlock() }
        if let existing = connections[stableID] { return existing }
        let connection = TerminalDaemonConnection(
            hostname: hostname,
            port: port,
            secret: secret
        )
        connections[stableID] = connection
        return connection
    }

    func remove(stableID: String) -> TerminalDaemonConnection? {
        lock.lock()
        defer { lock.unlock() }
        return connections.removeValue(forKey: stableID)
    }

    private func reprovisionAllRemotePush() {
        let snapshot: [TerminalDaemonConnection] = {
            lock.lock()
            defer { lock.unlock() }
            return Array(connections.values)
        }()
        for connection in snapshot {
            Task { await connection.reprovisionRemotePush() }
        }
    }
}
