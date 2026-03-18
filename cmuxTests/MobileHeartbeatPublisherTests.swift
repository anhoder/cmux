import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class MobileHeartbeatPublisherTests: XCTestCase {
    override func tearDown() {
        URLProtocolRecorder.reset()
        TerminalNotificationStore.shared.clearAll()
        super.tearDown()
    }

    func testPublishNowPostsMachineSessionAndHeartbeatWithDirectConnect() async throws {
        let suiteName = "MobileHeartbeatPublisherTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let settingsStore = AuthSettingsStore(userDefaults: defaults)
        let user = CMUXAuthUser(
            id: "user_123",
            primaryEmail: "lawrence@cmux.dev",
            displayName: "Lawrence"
        )
        settingsStore.saveCachedUser(user)
        settingsStore.selectedTeamID = "team_alpha"

        let authManager = AuthManager(
            client: StubAuthClient(
                user: user,
                teams: [AuthTeamSummary(id: "team_alpha", displayName: "Alpha")]
            ),
            tokenStore: StubStackTokenStore(
                accessToken: "access-123",
                refreshToken: "refresh-123"
            ),
            settingsStore: settingsStore,
            urlOpener: { _ in }
        )

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [URLProtocolRecorder.self]
        let session = URLSession(configuration: sessionConfiguration)
        let identityStore = MachineIdentityStore(defaults: defaults)
        let identity = identityStore.identity()

        URLProtocolRecorder.handler = { request in
            switch request.url?.path {
            case "/api/mobile/machine-session":
                let payload = try XCTUnwrap(URLProtocolRecorder.bodyData(for: request))
                let object = try XCTUnwrap(
                    try JSONSerialization.jsonObject(with: payload) as? [String: String]
                )
                XCTAssertEqual(object["teamSlugOrId"], "team_alpha")
                XCTAssertEqual(object["machineId"], identity.machineID)
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-123")

                let response = HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                let body = """
                {
                  "token": "machine-session-token",
                  "teamId": "team_alpha",
                  "userId": "user_123",
                  "machineId": "\(identity.machineID)",
                  "expiresAt": 1700003600000
                }
                """.data(using: .utf8)!
                return (response, body)
            case "/api/mobile/heartbeat":
                let response = HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 202,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, Data("{\"accepted\":true}".utf8))
            default:
                throw NSError(domain: "MobileHeartbeatPublisherTests", code: 404)
            }
        }

        let workspace = Workspace(title: "Alpha", workingDirectory: "/tmp/alpha")
        let tabManager = TabManager(initialWorkingDirectory: "/tmp/alpha")
        tabManager.tabs = [workspace]

        let directDaemonManager = MobileDirectDaemonManager(
            resolveBinaryPath: { "/tmp/cmuxd-remote" },
            getApplicationSupportDirectory: {
                FileManager.default.temporaryDirectory.appendingPathComponent(
                    "MobileHeartbeatPublisherTests-\(UUID().uuidString)",
                    isDirectory: true
                )
            },
            allocatePort: { 9443 },
            ensureMaterial: { _, _ in
                MobileDirectDaemonMaterial(
                    certPath: "/tmp/server.crt",
                    keyPath: "/tmp/server.key",
                    ticketSecret: "ticket-secret",
                    pin: "sha256:test-pin",
                    hosts: []
                )
            },
            spawn: { _, _ in
                MobileDirectDaemonProcessHandle(
                    processIdentifier: 42,
                    waitUntilReady: { },
                    terminate: { }
                )
            }
        )

        let publisher = MobileHeartbeatPublisher(
            identityStore: identityStore,
            tailscaleStatusProvider: TailscaleStatusProvider { _, _ in
                """
                {
                  "BackendState": "Running",
                  "Self": {
                    "HostName": "Lawrence MacBook Pro",
                    "DNSName": "macbook.tail-scale.ts.net.",
                    "TailscaleIPs": ["100.64.0.7"]
                  }
                }
                """
            },
            machineSessionClient: MachineSessionClient(
                session: session,
                authManager: authManager,
                now: { Date(timeIntervalSince1970: 1_700_000_000) }
            ),
            workspaceSnapshotBuilder: WorkspaceSnapshotBuilder(
                notificationStore: TerminalNotificationStore.shared,
                now: { Date(timeIntervalSince1970: 1_700_000_000) }
            ),
            directDaemonManager: directDaemonManager,
            tabManagerProvider: { tabManager },
            authManager: authManager,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        try await publisher.publishNow()

        let requests = URLProtocolRecorder.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer machine-session-token")

        let heartbeatBody = try XCTUnwrap(requests[1].httpBody)
        let heartbeat = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: heartbeatBody) as? [String: Any]
        )
        XCTAssertEqual(heartbeat["machineId"] as? String, identity.machineID)
        XCTAssertEqual(heartbeat["displayName"] as? String, "Lawrence MacBook Pro")
        XCTAssertEqual(heartbeat["status"] as? String, "online")
        XCTAssertEqual(heartbeat["tailscaleHostname"] as? String, "macbook.tail-scale.ts.net")

        let directConnect = try XCTUnwrap(heartbeat["directConnect"] as? [String: Any])
        XCTAssertEqual(directConnect["directPort"] as? Int, 9443)
        XCTAssertEqual(directConnect["ticketSecret"] as? String, "ticket-secret")
        XCTAssertEqual(directConnect["directTlsPins"] as? [String], ["sha256:test-pin"])

        let workspaces = try XCTUnwrap(heartbeat["workspaces"] as? [[String: Any]])
        XCTAssertEqual(workspaces.count, 1)
        XCTAssertEqual(workspaces[0]["title"] as? String, "Alpha")
        XCTAssertEqual(workspaces[0]["preview"] as? String, "/tmp/alpha")
    }
}

private struct StubAuthClient: AuthClientProtocol {
    let user: CMUXAuthUser?
    let teams: [AuthTeamSummary]

    func currentUser() async throws -> CMUXAuthUser? {
        user
    }

    func listTeams() async throws -> [AuthTeamSummary] {
        teams
    }
}

private actor StubStackTokenStore: StackAuthTokenStoreProtocol {
    private var accessToken: String?
    private var refreshToken: String?

    init(accessToken: String?, refreshToken: String?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
    }

    func seed(accessToken: String, refreshToken: String) async {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
    }

    func clear() async {
        accessToken = nil
        refreshToken = nil
    }

    func currentAccessToken() async -> String? {
        accessToken
    }

    func currentRefreshToken() async -> String? {
        refreshToken
    }
}

private final class URLProtocolRecorder: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    private static let lock = NSLock()
    private static var capturedRequests: [URLRequest] = []

    static var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return capturedRequests
    }

    static func reset() {
        lock.lock()
        capturedRequests = []
        handler = nil
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let capturedRequest = Self.requestByCopyingBody(from: request)
        Self.lock.lock()
        Self.capturedRequests.append(capturedRequest)
        let handler = Self.handler
        Self.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "URLProtocolRecorder", code: 1))
            return
        }

        do {
            let (response, data) = try handler(capturedRequest)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func bodyData(for request: URLRequest) -> Data? {
        request.httpBody
    }

    private static func requestByCopyingBody(from request: URLRequest) -> URLRequest {
        guard request.httpBody == nil,
              let stream = request.httpBodyStream else {
            return request
        }

        var requestWithBody = request
        requestWithBody.httpBodyStream = nil
        requestWithBody.httpBody = readBody(from: stream)
        return requestWithBody
    }

    private static func readBody(from stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)

        while stream.hasBytesAvailable {
            let readCount = stream.read(&buffer, maxLength: bufferSize)
            if readCount <= 0 {
                break
            }
            data.append(buffer, count: readCount)
        }

        return data
    }
}
