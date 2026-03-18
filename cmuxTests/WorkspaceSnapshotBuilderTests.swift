import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class WorkspaceSnapshotBuilderTests: XCTestCase {
    override func tearDown() {
        TerminalNotificationStore.shared.clearAll()
        super.tearDown()
    }

    func testRowsIncrementSequenceOnlyWhenWorkspaceFingerprintChanges() {
        let workspace = Workspace(title: "Alpha", workingDirectory: "/tmp/alpha")
        let store = TerminalNotificationStore.shared
        store.clearAll()

        var times = [
            Date(timeIntervalSince1970: 1_700_000_000),
            Date(timeIntervalSince1970: 1_700_000_010),
            Date(timeIntervalSince1970: 1_700_000_020),
        ]
        let builder = WorkspaceSnapshotBuilder(
            notificationStore: store,
            now: { times.removeFirst() }
        )

        let first = builder.rows(for: [workspace])
        let second = builder.rows(for: [workspace])

        workspace.currentDirectory = "/tmp/beta"
        let third = builder.rows(for: [workspace])

        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first[0].latestEventSeq, 1)
        XCTAssertEqual(first[0].preview, "/tmp/alpha")

        XCTAssertEqual(second[0].latestEventSeq, 1)
        XCTAssertEqual(second[0].lastActivityAt, first[0].lastActivityAt)
        XCTAssertEqual(second[0].lastEventAt, first[0].lastEventAt)

        XCTAssertEqual(third[0].latestEventSeq, 2)
        XCTAssertEqual(third[0].preview, "/tmp/beta")
        XCTAssertGreaterThan(third[0].lastActivityAt, first[0].lastActivityAt)
        XCTAssertGreaterThan((third[0].lastEventAt ?? 0), (first[0].lastEventAt ?? 0))
    }
}
