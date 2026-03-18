import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class TailscaleStatusProviderTests: XCTestCase {
    func testParseRunningStatusTrimsHostnameAndIPs() throws {
        let status = try TailscaleStatusProvider.parse(
            stdout: """
            {
              "BackendState": "Running",
              "Self": {
                "HostName": "Lawrence MacBook Pro",
                "DNSName": "macbook.tail-scale.ts.net.",
                "TailscaleIPs": ["100.64.0.7", " fd7a:115c:a1e0::7 "]
              }
            }
            """
        )

        XCTAssertTrue(status.running)
        XCTAssertEqual(status.displayName, "Lawrence MacBook Pro")
        XCTAssertEqual(status.tailscaleHostname, "macbook.tail-scale.ts.net")
        XCTAssertEqual(status.tailscaleIPs, ["100.64.0.7", "fd7a:115c:a1e0::7"])
    }

    func testCurrentStatusReturnsNilWhenBackendIsNotRunning() async {
        let provider = TailscaleStatusProvider { _, _ in
            """
            {
              "BackendState": "Stopped",
              "Self": {
                "HostName": "Mac Mini",
                "DNSName": "macmini.tail-scale.ts.net.",
                "TailscaleIPs": ["100.64.0.10"]
              }
            }
            """
        }

        let status = await provider.currentStatus()
        XCTAssertNil(status)
    }
}
