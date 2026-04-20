import Foundation

enum VMClientError: Error, CustomStringConvertible {
    case notSignedIn
    case httpStatus(Int, String)
    case malformedResponse(String)

    var description: String {
        switch self {
        case .notSignedIn:
            return "Not signed in. Run `cmux auth login` first."
        case .httpStatus(let code, let body):
            return "HTTP \(code): \(body)"
        case .malformedResponse(let message):
            return "Malformed response: \(message)"
        }
    }
}

struct VMSummary {
    let id: String
    let provider: String
    let image: String
    let createdAt: Int64
}

struct VMExecResult {
    let exitCode: Int
    let stdout: String
    let stderr: String
}

/// Talks to the manaflow cloud VM backend at `/api/vm/*`. Stack Auth tokens come from
/// `AuthManager.shared`; the HTTP base URL from `AuthEnvironment.vmAPIBaseURL`.
///
/// All methods are `async throws` and run off the main actor.
actor VMClient {
    static let shared = VMClient()

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func list() async throws -> [VMSummary] {
        let (data, http) = try await request("GET", path: "/api/vm")
        try ensureOK(http, data: data)
        let obj = try decodeJSONObject(data)
        guard let items = obj["vms"] as? [[String: Any]] else {
            throw VMClientError.malformedResponse("missing `vms` array")
        }
        return items.compactMap { dict -> VMSummary? in
            guard let id = dict["id"] as? String,
                  let provider = dict["provider"] as? String,
                  let image = dict["image"] as? String
            else { return nil }
            let createdAt = (dict["createdAt"] as? Int64)
                ?? Int64((dict["createdAt"] as? Double) ?? 0)
            return VMSummary(id: id, provider: provider, image: image, createdAt: createdAt)
        }
    }

    func create(image: String? = nil, provider: String? = nil) async throws -> VMSummary {
        var body: [String: Any] = [:]
        if let image { body["image"] = image }
        if let provider { body["provider"] = provider }
        let (data, http) = try await request("POST", path: "/api/vm", jsonBody: body)
        try ensureOK(http, data: data)
        let obj = try decodeJSONObject(data)
        guard let id = obj["id"] as? String,
              let providerValue = obj["provider"] as? String,
              let imageValue = obj["image"] as? String
        else {
            throw VMClientError.malformedResponse("missing id/provider/image on POST /api/vm response")
        }
        return VMSummary(id: id, provider: providerValue, image: imageValue, createdAt: Int64(Date().timeIntervalSince1970 * 1000))
    }

    func destroy(id: String) async throws {
        let (data, http) = try await request("DELETE", path: "/api/vm/\(id)")
        try ensureOK(http, data: data)
    }

    func exec(id: String, command: String, timeoutMs: Int = 30_000) async throws -> VMExecResult {
        let body: [String: Any] = ["command": command, "timeoutMs": timeoutMs]
        let (data, http) = try await request(
            "POST",
            path: "/api/vm/\(id)/exec",
            jsonBody: body
        )
        try ensureOK(http, data: data)
        let obj = try decodeJSONObject(data)
        let exitCode = (obj["exitCode"] as? Int) ?? ((obj["exitCode"] as? Double).map(Int.init) ?? -1)
        let stdout = (obj["stdout"] as? String) ?? ""
        let stderr = (obj["stderr"] as? String) ?? ""
        return VMExecResult(exitCode: exitCode, stdout: stdout, stderr: stderr)
    }

    // MARK: - HTTP

    private func request(
        _ method: String,
        path: String,
        jsonBody: [String: Any]? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        let tokens: (accessToken: String, refreshToken: String)
        do {
            tokens = try await AuthManager.shared.currentTokens()
        } catch {
            throw VMClientError.notSignedIn
        }

        guard var url = URLComponents(url: AuthEnvironment.vmAPIBaseURL, resolvingAgainstBaseURL: false) else {
            throw VMClientError.malformedResponse("bad vmAPIBaseURL")
        }
        url.path = (url.path.hasSuffix("/") ? String(url.path.dropLast()) : url.path) + path
        guard let resolved = url.url else {
            throw VMClientError.malformedResponse("could not build URL for \(path)")
        }

        var req = URLRequest(url: resolved)
        req.httpMethod = method
        req.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(tokens.refreshToken, forHTTPHeaderField: "X-Stack-Refresh-Token")
        if let jsonBody {
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.httpBody = try JSONSerialization.data(withJSONObject: jsonBody, options: [])
        }

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw VMClientError.malformedResponse("non-HTTP response")
        }
        return (data, http)
    }

    private func ensureOK(_ http: HTTPURLResponse, data: Data) throws {
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            throw VMClientError.httpStatus(http.statusCode, body)
        }
    }

    private func decodeJSONObject(_ data: Data) throws -> [String: Any] {
        let parsed = try JSONSerialization.jsonObject(with: data, options: [])
        guard let obj = parsed as? [String: Any] else {
            throw VMClientError.malformedResponse("expected JSON object, got \(type(of: parsed))")
        }
        return obj
    }
}
