import Foundation

@MainActor
final class MobileHeartbeatPublisher {
    private let identityStore: MachineIdentityStore
    private let tailscaleStatusProvider: TailscaleStatusProvider
    private let machineSessionClient: MachineSessionClient
    private let workspaceSnapshotBuilder: WorkspaceSnapshotBuilder
    private let tabManagerProvider: () -> TabManager?
    private let authProvider: any MachineSessionAuthProvider
    private let now: () -> Date

    @MainActor
    init(
        identityStore: MachineIdentityStore = MachineIdentityStore(),
        tailscaleStatusProvider: TailscaleStatusProvider = TailscaleStatusProvider(),
        machineSessionClient: MachineSessionClient? = nil,
        workspaceSnapshotBuilder: WorkspaceSnapshotBuilder? = nil,
        tabManagerProvider: (() -> TabManager?)? = nil,
        authProvider: any MachineSessionAuthProvider,
        now: @escaping () -> Date = Date.init
    ) {
        self.identityStore = identityStore
        self.tailscaleStatusProvider = tailscaleStatusProvider
        self.machineSessionClient = machineSessionClient ?? MachineSessionClient(authProvider: authProvider)
        self.workspaceSnapshotBuilder = workspaceSnapshotBuilder ?? WorkspaceSnapshotBuilder()
        self.tabManagerProvider = tabManagerProvider ?? { AppDelegate.shared?.tabManager }
        self.authProvider = authProvider
        self.now = now
    }

    func publishNow() async throws {
        guard authProvider.isAuthenticated,
              let teamID = authProvider.resolvedTeamID else {
            return
        }
        guard let tailscaleStatus = await tailscaleStatusProvider.currentStatus() else {
            return
        }
        guard let tabManager = tabManagerProvider() else {
            return
        }

        let identity = identityStore.identity()
        let rows = workspaceSnapshotBuilder.rows(for: tabManager.tabs)
        let machineSession = try await machineSessionClient.machineSession(
            teamID: teamID,
            identity: identity
        )
        let timestamp = Int(now().timeIntervalSince1970 * 1000)
        let payload = MobileHeartbeatPayload(
            machineID: identity.machineID,
            displayName: tailscaleStatus.displayName ?? identity.displayName,
            tailscaleHostname: tailscaleStatus.tailscaleHostname,
            tailscaleIPs: tailscaleStatus.tailscaleIPs,
            status: "online",
            lastSeenAt: timestamp,
            lastWorkspaceSyncAt: timestamp,
            directConnect: nil,
            workspaces: rows
        )
        try await machineSessionClient.publishHeartbeat(
            sessionToken: machineSession.token,
            payload: payload
        )
    }
}
