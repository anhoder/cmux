import Foundation

@MainActor
final class WorkspaceSnapshotBuilder {
    private struct CachedSnapshot {
        let fingerprint: String
        let latestEventSeq: Int
        let lastActivityAt: Int
        let lastEventAt: Int?
    }

    private let notificationStore: TerminalNotificationStore
    private let now: () -> Date
    private var cache: [UUID: CachedSnapshot] = [:]

    init(
        notificationStore: TerminalNotificationStore? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.notificationStore = notificationStore ?? .shared
        self.now = now
    }

    func rows(for workspaces: [Workspace]) -> [MobileWorkspaceHeartbeatRow] {
        let nowMilliseconds = Int(now().timeIntervalSince1970 * 1000)
        var nextCache: [UUID: CachedSnapshot] = [:]

        let rows = workspaces.map { workspace -> MobileWorkspaceHeartbeatRow in
            let preview = workspacePreview(for: workspace)
            let unreadCount = notificationStore.unreadCount(forTabId: workspace.id)
            let phase = workspace.activeRemoteTerminalSessionCount > 0 ? "active" : "idle"
            let fingerprint = [
                workspace.title,
                workspace.currentDirectory,
                preview ?? "",
                phase,
                String(unreadCount),
            ].joined(separator: "|")

            let previous = cache[workspace.id]
            let latestEventSeq = previous?.fingerprint == fingerprint
                ? (previous?.latestEventSeq ?? 1)
                : (previous?.latestEventSeq ?? 0) + 1
            let lastActivityAt = previous?.fingerprint == fingerprint
                ? (previous?.lastActivityAt ?? nowMilliseconds)
                : nowMilliseconds
            let lastEventAt = previous?.fingerprint == fingerprint
                ? previous?.lastEventAt
                : nowMilliseconds

            nextCache[workspace.id] = CachedSnapshot(
                fingerprint: fingerprint,
                latestEventSeq: latestEventSeq,
                lastActivityAt: lastActivityAt,
                lastEventAt: lastEventAt
            )

            return MobileWorkspaceHeartbeatRow(
                workspaceID: workspace.id.uuidString.lowercased(),
                taskID: workspace.id.uuidString.lowercased(),
                taskRunID: nil,
                title: workspace.title,
                preview: preview,
                phase: phase,
                tmuxSessionName: "local-\(workspace.id.uuidString.lowercased())",
                lastActivityAt: lastActivityAt,
                latestEventSeq: latestEventSeq,
                lastEventAt: lastEventAt
            )
        }
        cache = nextCache
        return rows.sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    private func workspacePreview(for workspace: Workspace) -> String? {
        let notification = notificationStore.latestNotification(forTabId: workspace.id)
        let candidates = [
            notification?.body,
            notification?.subtitle,
            workspace.currentDirectory,
        ]
        for candidate in candidates {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }
}
