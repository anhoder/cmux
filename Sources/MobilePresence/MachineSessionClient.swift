import Foundation

struct MobileMachineSession: Decodable, Equatable, Sendable {
    let token: String
    let teamID: String
    let userID: String
    let machineID: String
    let expiresAt: Date

    private enum CodingKeys: String, CodingKey {
        case token
        case teamID = "teamId"
        case userID = "userId"
        case machineID = "machineId"
        case expiresAt
    }
}

struct MobileWorkspaceHeartbeatRow: Encodable, Equatable, Sendable {
    let workspaceID: String
    let taskID: String?
    let taskRunID: String?
    let title: String
    let preview: String?
    let phase: String
    let tmuxSessionName: String
    let lastActivityAt: Int
    let latestEventSeq: Int
    let lastEventAt: Int?

    private enum CodingKeys: String, CodingKey {
        case workspaceID = "workspaceId"
        case taskID = "taskId"
        case taskRunID = "taskRunId"
        case title
        case preview
        case phase
        case tmuxSessionName
        case lastActivityAt
        case latestEventSeq
        case lastEventAt
    }
}

struct MobileHeartbeatPayload: Encodable, Equatable, Sendable {
    let machineID: String
    let displayName: String
    let tailscaleHostname: String?
    let tailscaleIPs: [String]
    let status: String
    let lastSeenAt: Int
    let lastWorkspaceSyncAt: Int
    let directConnect: MobileHeartbeatDirectConnectPayload?
    let workspaces: [MobileWorkspaceHeartbeatRow]

    private enum CodingKeys: String, CodingKey {
        case machineID = "machineId"
        case displayName
        case tailscaleHostname
        case tailscaleIPs
        case status
        case lastSeenAt
        case lastWorkspaceSyncAt
        case directConnect
        case workspaces
    }
}

struct MobileHeartbeatDirectConnectPayload: Encodable, Equatable, Sendable {
    let directPort: Int
    let directTLSPins: [String]
    let ticketSecret: String

    private enum CodingKeys: String, CodingKey {
        case directPort
        case directTLSPins = "directTlsPins"
        case ticketSecret
    }
}

final class MachineSessionClient: @unchecked Sendable {
    private actor SessionCache {
        private var value: MobileMachineSession?

        func current(
            teamID: String,
            machineID: String,
            now: Date
        ) -> MobileMachineSession? {
            guard let value,
                  value.teamID == teamID,
                  value.machineID == machineID,
                  value.expiresAt.timeIntervalSince(now) > 60 else {
                self.value = nil
                return nil
            }
            return value
        }

        func store(_ session: MobileMachineSession) {
            value = session
        }
    }

    private let session: URLSession
    private let authManager: AuthManager
    private let decoder: JSONDecoder
    private let encoder = JSONEncoder()
    private let now: () -> Date
    private let cache = SessionCache()

    @MainActor
    init(
        session: URLSession = .shared,
        authManager: AuthManager? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.session = session
        self.authManager = authManager ?? .shared
        self.now = now
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .millisecondsSince1970
    }

    func machineSession(
        teamID: String,
        identity: MobileMachineIdentity
    ) async throws -> MobileMachineSession {
        if let cached = await cache.current(
            teamID: teamID,
            machineID: identity.machineID,
            now: now()
        ) {
            return cached
        }

        var request = URLRequest(
            url: AuthEnvironment.apiBaseURL.appendingPathComponent("api/mobile/machine-session")
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "Bearer \(try await authManager.getAccessToken())",
            forHTTPHeaderField: "Authorization"
        )
        request.httpBody = try encoder.encode([
            "teamSlugOrId": teamID,
            "machineId": identity.machineID,
            "displayName": identity.displayName,
        ])

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200 ..< 300).contains(httpResponse.statusCode) else {
            throw NSError(domain: "cmux.mobile.machine-session", code: 1)
        }
        let machineSession = try decoder.decode(MobileMachineSession.self, from: data)
        await cache.store(machineSession)
        return machineSession
    }

    func publishHeartbeat(
        sessionToken: String,
        payload: MobileHeartbeatPayload
    ) async throws {
        var request = URLRequest(
            url: AuthEnvironment.apiBaseURL.appendingPathComponent("api/mobile/heartbeat")
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try encoder.encode(payload)
        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200 ..< 300).contains(httpResponse.statusCode) else {
            throw NSError(domain: "cmux.mobile.heartbeat", code: 1)
        }
    }

}
