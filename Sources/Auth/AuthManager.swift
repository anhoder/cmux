import AppKit
import Foundation
#if canImport(Security)
import Security
#endif

enum AuthManagerError: LocalizedError {
    case invalidCallback
    case missingAccessToken

    var errorDescription: String? {
        switch self {
        case .invalidCallback:
            return String(
                localized: "settings.account.error.invalidCallback",
                defaultValue: "The sign-in callback was invalid."
            )
        case .missingAccessToken:
            return String(
                localized: "settings.account.error.missingAccessToken",
                defaultValue: "Account access token is unavailable."
            )
        }
    }
}

protocol StackAuthTokenStoreProtocol: Sendable {
    func seed(accessToken: String, refreshToken: String) async
    func clear() async
    func currentAccessToken() async -> String?
    func currentRefreshToken() async -> String?
}

protocol AuthClientProtocol: Sendable {
    func currentUser() async throws -> CMUXAuthUser?
    func listTeams() async throws -> [AuthTeamSummary]
    func currentAccessToken() async throws -> String?
}

extension AuthClientProtocol {
    func currentAccessToken() async throws -> String? { nil }
}

@MainActor
final class AuthManager: ObservableObject {
    static let shared = AuthManager()

    @Published private(set) var isAuthenticated = false
    @Published private(set) var currentUser: CMUXAuthUser?
    @Published private(set) var availableTeams: [AuthTeamSummary] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isRestoringSession = false
    @Published var selectedTeamID: String? {
        didSet {
            guard selectedTeamID != oldValue else { return }
            settingsStore.selectedTeamID = selectedTeamID
        }
    }

    let requiresAuthenticationGate = false

    private let client: any AuthClientProtocol
    private let tokenStore: any StackAuthTokenStoreProtocol
    private let settingsStore: AuthSettingsStore
    private let urlOpener: (URL) -> Void

    init(
        client: (any AuthClientProtocol)? = nil,
        tokenStore: any StackAuthTokenStoreProtocol = KeychainStackTokenStore(),
        settingsStore: AuthSettingsStore = AuthSettingsStore(),
        urlOpener: ((URL) -> Void)? = nil
    ) {
        self.tokenStore = tokenStore
        self.settingsStore = settingsStore
        self.client = client ?? Self.makeDefaultClient(tokenStore: tokenStore)
        self.urlOpener = urlOpener ?? Self.defaultURLOpener
        self.currentUser = settingsStore.cachedUser()
        self.selectedTeamID = settingsStore.selectedTeamID
        self.isAuthenticated = self.currentUser != nil
        Task { [weak self] in
            await self?.restoreStoredSessionIfNeeded()
        }
    }

    func beginSignInInBrowser() {
        urlOpener(AuthEnvironment.signInURL())
    }

    func handleCallbackURL(_ url: URL) async throws {
        guard let payload = AuthCallbackRouter.callbackPayload(from: url) else {
            throw AuthManagerError.invalidCallback
        }

        isLoading = true
        defer { isLoading = false }

        await tokenStore.seed(
            accessToken: payload.accessToken,
            refreshToken: payload.refreshToken
        )
        try await refreshSession()
    }

    func signOut() async {
        await tokenStore.clear()
        availableTeams = []
        currentUser = nil
        isAuthenticated = false
        selectedTeamID = nil
        settingsStore.saveCachedUser(nil)
    }

    func getAccessToken() async throws -> String {
        if let accessToken = try await client.currentAccessToken(),
           !accessToken.isEmpty {
            return accessToken
        }
        if let cached = await tokenStore.currentAccessToken(),
           !cached.isEmpty {
            return cached
        }
        throw AuthManagerError.missingAccessToken
    }

    private func restoreStoredSessionIfNeeded() async {
        let hasAccessToken = await tokenStore.currentAccessToken() != nil
        let hasRefreshToken = await tokenStore.currentRefreshToken() != nil
        let hasTokens = hasAccessToken || hasRefreshToken
        guard hasTokens else {
            if currentUser == nil {
                isAuthenticated = false
            }
            return
        }

        isAuthenticated = currentUser != nil
        isRestoringSession = true
        defer { isRestoringSession = false }

        do {
            try await refreshSession()
        } catch {
            if currentUser == nil {
                isAuthenticated = false
            }
        }
    }

    private func refreshSession() async throws {
        let user = try await client.currentUser()
        let teams = try await client.listTeams()
        let hasRefreshToken = await tokenStore.currentRefreshToken() != nil
        currentUser = user
        settingsStore.saveCachedUser(user)
        availableTeams = teams
        isAuthenticated = user != nil || hasRefreshToken

        if let selectedTeamID,
           teams.contains(where: { $0.id == selectedTeamID }) {
            return
        }
        self.selectedTeamID = teams.first?.id
    }

    private static func makeDefaultClient(
        tokenStore: any StackAuthTokenStoreProtocol
    ) -> any AuthClientProtocol {
        UITestAuthClient.makeIfEnabled(tokenStore: tokenStore) ?? LiveAuthClient(tokenStore: tokenStore)
    }

    private static func defaultURLOpener(_ url: URL) {
        let environment = ProcessInfo.processInfo.environment
        if let capturePath = environment["CMUX_UI_TEST_CAPTURE_OPEN_URL_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !capturePath.isEmpty {
            try? FileManager.default.createDirectory(
                at: URL(fileURLWithPath: capturePath).deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? url.absoluteString.write(
                to: URL(fileURLWithPath: capturePath),
                atomically: true,
                encoding: .utf8
            )
            return
        }
        NSWorkspace.shared.open(url)
    }
}

private actor KeychainStackTokenStore: StackAuthTokenStoreProtocol {
    private static let accessTokenAccount = "cmux-auth-access-token"
    private static let refreshTokenAccount = "cmux-auth-refresh-token"
    private static let service = "com.cmuxterm.app.auth"

    func seed(accessToken: String, refreshToken: String) async {
        setKeychainValue(accessToken, account: Self.accessTokenAccount)
        setKeychainValue(refreshToken, account: Self.refreshTokenAccount)
    }

    func clear() async {
        deleteKeychainValue(account: Self.accessTokenAccount)
        deleteKeychainValue(account: Self.refreshTokenAccount)
    }

    func currentAccessToken() async -> String? {
        keychainValue(account: Self.accessTokenAccount)
    }

    func currentRefreshToken() async -> String? {
        keychainValue(account: Self.refreshTokenAccount)
    }

    private func keychainValue(account: String) -> String? {
#if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
#else
        return nil
#endif
    }

    private func setKeychainValue(_ value: String, account: String) {
#if canImport(Security)
        guard let data = value.data(using: .utf8) else { return }
        let lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
        ]
        let status = SecItemUpdate(lookup as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = lookup
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(insert as CFDictionary, nil)
        }
#endif
    }

    private func deleteKeychainValue(account: String) {
#if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
#endif
    }
}

private actor LiveAuthClient: AuthClientProtocol {
    private struct UserResponse: Decodable {
        let id: String
        let primaryEmail: String?
        let displayName: String?

        private enum CodingKeys: String, CodingKey {
            case id
            case primaryEmail = "primary_email"
            case displayName = "display_name"
        }
    }

    private struct TeamListResponse: Decodable {
        let items: [TeamResponse]
    }

    private struct TeamResponse: Decodable {
        let id: String
        let displayName: String

        private enum CodingKeys: String, CodingKey {
            case id
            case displayName = "display_name"
        }
    }

    private let tokenStore: any StackAuthTokenStoreProtocol
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let publishableClientKeyNotNecessarySentinel = "publishable-client-key-not-set"

    init(
        tokenStore: any StackAuthTokenStoreProtocol,
        session: URLSession = .shared
    ) {
        self.tokenStore = tokenStore
        self.session = session
    }

    func currentAccessToken() async throws -> String? {
        try await validAccessToken()
    }

    func currentUser() async throws -> CMUXAuthUser? {
        guard let accessToken = try await validAccessToken() else { return nil }
        var request = URLRequest(
            url: AuthEnvironment.stackBaseURL.appendingPathComponent("api/v1/users/me")
        )
        request.httpMethod = "GET"
        addStackHeaders(to: &request, accessToken: accessToken)
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { return nil }
        guard httpResponse.statusCode == 200 else { return nil }
        let payload = try decoder.decode(UserResponse.self, from: data)
        return CMUXAuthUser(
            id: payload.id,
            primaryEmail: payload.primaryEmail,
            displayName: payload.displayName
        )
    }

    func listTeams() async throws -> [AuthTeamSummary] {
        guard let accessToken = try await validAccessToken() else { return [] }
        var request = URLRequest(
            url: AuthEnvironment.stackBaseURL.appendingPathComponent("api/v1/teams")
                .appending(queryItems: [URLQueryItem(name: "user_id", value: "me")])
        )
        request.httpMethod = "GET"
        addStackHeaders(to: &request, accessToken: accessToken)
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            return []
        }
        let payload = try decoder.decode(TeamListResponse.self, from: data)
        return payload.items.map {
            AuthTeamSummary(id: $0.id, displayName: $0.displayName)
        }
    }

    private func validAccessToken() async throws -> String? {
        if let accessToken = await tokenStore.currentAccessToken(),
           Self.isTokenFreshEnough(accessToken) {
            return accessToken
        }

        guard let refreshToken = await tokenStore.currentRefreshToken(),
              !refreshToken.isEmpty else {
            return await tokenStore.currentAccessToken()
        }

        guard let refreshedToken = try await refreshAccessToken(refreshToken: refreshToken) else {
            return await tokenStore.currentAccessToken()
        }
        await tokenStore.seed(accessToken: refreshedToken, refreshToken: refreshToken)
        return refreshedToken
    }

    private func refreshAccessToken(refreshToken: String) async throws -> String? {
        var request = URLRequest(
            url: AuthEnvironment.stackBaseURL.appendingPathComponent("api/v1/auth/oauth/token")
        )
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(AuthEnvironment.stackProjectID, forHTTPHeaderField: "x-stack-project-id")
        request.setValue(
            AuthEnvironment.stackPublishableClientKey,
            forHTTPHeaderField: "x-stack-publishable-client-key"
        )
        let body = [
            "grant_type=refresh_token",
            "refresh_token=\(Self.formURLEncode(refreshToken))",
            "client_id=\(Self.formURLEncode(AuthEnvironment.stackProjectID))",
            "client_secret=\(Self.formURLEncode(AuthEnvironment.stackPublishableClientKey.isEmpty ? publishableClientKeyNotNecessarySentinel : AuthEnvironment.stackPublishableClientKey))",
        ].joined(separator: "&")
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json["access_token"] as? String
    }

    private func addStackHeaders(to request: inout URLRequest, accessToken: String) {
        request.setValue(accessToken, forHTTPHeaderField: "x-stack-access-token")
        request.setValue(AuthEnvironment.stackProjectID, forHTTPHeaderField: "x-stack-project-id")
        request.setValue(
            AuthEnvironment.stackPublishableClientKey,
            forHTTPHeaderField: "x-stack-publishable-client-key"
        )
    }

    private static func isTokenFreshEnough(_ token: String) -> Bool {
        guard let payload = decodeJWTPayload(token) else { return false }
        let expiresInMillis = (payload.exp * 1000) - (Date().timeIntervalSince1970 * 1000)
        let issuedMillisAgo = (Date().timeIntervalSince1970 * 1000) - (payload.iat * 1000)
        return expiresInMillis > 20_000 && issuedMillisAgo < 75_000
    }

    private static func decodeJWTPayload(_ token: String) -> (exp: TimeInterval, iat: TimeInterval)? {
        let segments = token.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        var base64 = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = json["exp"] as? TimeInterval,
              let iat = json["iat"] as? TimeInterval else {
            return nil
        }
        return (exp: exp, iat: iat)
    }

    private static func formURLEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

private struct UITestAuthClient: AuthClientProtocol {
    let tokenStore: any StackAuthTokenStoreProtocol
    let user: CMUXAuthUser
    let teams: [AuthTeamSummary]

    static func makeIfEnabled(
        tokenStore: any StackAuthTokenStoreProtocol
    ) -> Self? {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CMUX_UI_TEST_AUTH_STUB"] == "1" else {
            return nil
        }

        let user = CMUXAuthUser(
            id: environment["CMUX_UI_TEST_AUTH_USER_ID"] ?? "ui_test_user",
            primaryEmail: environment["CMUX_UI_TEST_AUTH_EMAIL"] ?? "uitest@cmux.dev",
            displayName: environment["CMUX_UI_TEST_AUTH_NAME"] ?? "UI Test"
        )
        let teams = [
            AuthTeamSummary(
                id: environment["CMUX_UI_TEST_AUTH_TEAM_ID"] ?? "team_alpha",
                displayName: environment["CMUX_UI_TEST_AUTH_TEAM_NAME"] ?? "Alpha"
            ),
        ]
        return Self(tokenStore: tokenStore, user: user, teams: teams)
    }

    func currentUser() async throws -> CMUXAuthUser? {
        let hasAccessToken = await tokenStore.currentAccessToken() != nil
        let hasRefreshToken = await tokenStore.currentRefreshToken() != nil
        return (hasAccessToken || hasRefreshToken) ? user : nil
    }

    func listTeams() async throws -> [AuthTeamSummary] {
        let hasAccessToken = await tokenStore.currentAccessToken() != nil
        let hasRefreshToken = await tokenStore.currentRefreshToken() != nil
        return (hasAccessToken || hasRefreshToken) ? teams : []
    }

    func currentAccessToken() async throws -> String? {
        await tokenStore.currentAccessToken()
    }
}

private extension URL {
    func appending(queryItems: [URLQueryItem]) -> URL {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
            return self
        }
        components.queryItems = (components.queryItems ?? []) + queryItems
        return components.url ?? self
    }
}
