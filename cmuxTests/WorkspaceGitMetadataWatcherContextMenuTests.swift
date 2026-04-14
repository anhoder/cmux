import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class WorkspaceGitMetadataWatcherContextMenuTests: XCTestCase {
    private func makeRemoteWorkspace(in manager: TabManager) -> Workspace {
        let workspace = manager.addWorkspace(select: false)
        workspace.configureRemoteConnection(
            WorkspaceRemoteConfiguration(
                destination: "cmux-macmini",
                port: nil,
                identityFile: nil,
                sshOptions: [],
                localProxyPort: nil,
                relayPort: 64017,
                relayID: String(repeating: "a", count: 16),
                relayToken: String(repeating: "b", count: 64),
                localSocketPath: "/tmp/cmux-debug-test.sock",
                terminalStartupCommand: "ssh cmux-macmini"
            ),
            autoConnect: false
        )
        return workspace
    }

    func testContextMenuModeShowsEnableWhenWorkspaceWatcherDisabled() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace else {
            XCTFail("Expected selected workspace")
            return
        }

        workspace.gitMetadataWatcherDisabled = true

        XCTAssertEqual(
            ContentView.workspaceGitMetadataWatcherContextMenuMode(
                targetWorkspaces: [workspace],
                globalDisabled: false
            ),
            .enable
        )
    }

    func testContextMenuModeHidesToggleWhenGlobalWatcherDisabled() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace else {
            XCTFail("Expected selected workspace")
            return
        }

        workspace.gitMetadataWatcherDisabled = false

        XCTAssertEqual(
            ContentView.workspaceGitMetadataWatcherContextMenuMode(
                targetWorkspaces: [workspace],
                globalDisabled: true
            ),
            .hidden
        )
    }

    func testContextMenuModeDerivesFromLocalSubsetInMixedSelection() {
        let manager = TabManager()
        guard let localWorkspace = manager.selectedWorkspace else {
            XCTFail("Expected local workspace")
            return
        }

        let remoteWorkspace = makeRemoteWorkspace(in: manager)

        // Local workspace has watcher enabled → mixed selection should offer
        // .disable (the remote workspace is filtered out, not blocking).
        XCTAssertEqual(
            ContentView.workspaceGitMetadataWatcherContextMenuMode(
                targetWorkspaces: [localWorkspace, remoteWorkspace],
                globalDisabled: false
            ),
            .disable
        )

        // With the local workspace disabled, the same mixed selection should
        // offer .enable, still deriving from the local subset.
        localWorkspace.gitMetadataWatcherDisabled = true
        XCTAssertEqual(
            ContentView.workspaceGitMetadataWatcherContextMenuMode(
                targetWorkspaces: [localWorkspace, remoteWorkspace],
                globalDisabled: false
            ),
            .enable
        )
    }

    func testContextMenuModeHidesToggleWhenAllTargetsAreRemote() {
        let manager = TabManager()
        let remote1 = makeRemoteWorkspace(in: manager)
        let remote2 = makeRemoteWorkspace(in: manager)

        XCTAssertEqual(
            ContentView.workspaceGitMetadataWatcherContextMenuMode(
                targetWorkspaces: [remote1, remote2],
                globalDisabled: false
            ),
            .hidden
        )
    }

    func testSetWorkspaceGitMetadataWatcherDisabledSkipsRemoteWorkspace() {
        let manager = TabManager()
        let remoteWorkspace = makeRemoteWorkspace(in: manager)

        XCTAssertTrue(remoteWorkspace.isRemoteWorkspace)

        manager.setWorkspaceGitMetadataWatcherDisabled(
            workspaceIds: [remoteWorkspace.id],
            disabled: true
        )

        XCTAssertFalse(remoteWorkspace.gitMetadataWatcherDisabled)
    }
}
