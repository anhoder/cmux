import Foundation

@MainActor
final class MobileHeartbeatPublisher {
    private let identityStore: MachineIdentityStore
    private let tailscaleStatusProvider: TailscaleStatusProvider
    private let machineSessionClient: MachineSessionClient
    private let workspaceSnapshotBuilder: WorkspaceSnapshotBuilder
    private let directDaemonManager: MobileDirectDaemonManager
    private let tabManagerProvider: () -> TabManager?
    private let authManager: AuthManager
    private let now: () -> Date

    @MainActor
    init(
        identityStore: MachineIdentityStore = MachineIdentityStore(),
        tailscaleStatusProvider: TailscaleStatusProvider = TailscaleStatusProvider(),
        machineSessionClient: MachineSessionClient? = nil,
        workspaceSnapshotBuilder: WorkspaceSnapshotBuilder? = nil,
        directDaemonManager: MobileDirectDaemonManager = MobileDirectDaemonManager(),
        tabManagerProvider: (() -> TabManager?)? = nil,
        authManager: AuthManager? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        let resolvedAuthManager = authManager ?? .shared
        self.identityStore = identityStore
        self.tailscaleStatusProvider = tailscaleStatusProvider
        self.machineSessionClient = machineSessionClient ?? MachineSessionClient(authManager: resolvedAuthManager)
        self.workspaceSnapshotBuilder = workspaceSnapshotBuilder ?? WorkspaceSnapshotBuilder()
        self.directDaemonManager = directDaemonManager
        self.tabManagerProvider = tabManagerProvider ?? { AppDelegate.shared?.tabManager }
        self.authManager = resolvedAuthManager
        self.now = now
    }

    func publishNow() async throws {
        guard authManager.isAuthenticated,
              let teamID = authManager.selectedTeamID else {
            return
        }
        guard let tailscaleStatus = await tailscaleStatusProvider.currentStatus() else {
            return
        }
        guard let tabManager = tabManagerProvider() else {
            return
        }

        let identity = identityStore.identity()
        let hasReachableTailscaleAddress =
            tailscaleStatus.tailscaleHostname != nil || !tailscaleStatus.tailscaleIPs.isEmpty
        let directConnect: MobileDirectConnectInfo?
        if hasReachableTailscaleAddress {
            directConnect = try? await directDaemonManager.ensureConnection(
                hosts: MobileDirectDaemonHosts(
                    machineID: identity.machineID,
                    hostname: identity.hostname,
                    tailscaleHostname: tailscaleStatus.tailscaleHostname,
                    tailscaleIPs: tailscaleStatus.tailscaleIPs
                )
            )
        } else {
            directConnect = nil
        }
        let machineSession = try await machineSessionClient.machineSession(
            teamID: teamID,
            identity: identity
        )
        let rows = workspaceSnapshotBuilder.rows(for: tabManager.tabs)
        let timestamp = Int(now().timeIntervalSince1970 * 1000)
        let payload = MobileHeartbeatPayload(
            machineID: identity.machineID,
            displayName: tailscaleStatus.displayName ?? identity.displayName,
            tailscaleHostname: tailscaleStatus.tailscaleHostname,
            tailscaleIPs: tailscaleStatus.tailscaleIPs,
            status: "online",
            lastSeenAt: timestamp,
            lastWorkspaceSyncAt: timestamp,
            directConnect: directConnect.map {
                MobileHeartbeatDirectConnectPayload(
                    directPort: $0.directPort,
                    directTLSPins: $0.directTLSPins,
                    ticketSecret: $0.ticketSecret
                )
            },
            workspaces: rows
        )
        try await machineSessionClient.publishHeartbeat(
            sessionToken: machineSession.token,
            payload: payload
        )
    }

    func shutdown() {
        directDaemonManager.shutdown()
    }
}
