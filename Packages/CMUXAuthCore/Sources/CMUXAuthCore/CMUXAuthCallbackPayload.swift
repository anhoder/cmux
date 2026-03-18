import Foundation

public struct CMUXAuthCallbackPayload: Equatable, Sendable {
    public let refreshToken: String
    public let accessToken: String

    public init(refreshToken: String, accessToken: String) {
        self.refreshToken = refreshToken
        self.accessToken = accessToken
    }
}
