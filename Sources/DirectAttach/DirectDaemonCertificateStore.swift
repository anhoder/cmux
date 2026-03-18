import CryptoKit
import Foundation

struct MobileDirectDaemonMaterial: Equatable, Sendable {
    let certPath: String
    let keyPath: String
    let ticketSecret: String
    let pin: String
    let hosts: [String]
}

final class DirectDaemonCertificateStore {
    private struct Metadata: Codable {
        let hosts: [String]
    }

    func ensureMaterial(baseDirectory: URL, hosts: [String]) throws -> MobileDirectDaemonMaterial {
        try FileManager.default.createDirectory(
            at: baseDirectory,
            withIntermediateDirectories: true
        )

        let certURL = baseDirectory.appendingPathComponent("server.crt", isDirectory: false)
        let keyURL = baseDirectory.appendingPathComponent("server.key", isDirectory: false)
        let metadataURL = baseDirectory.appendingPathComponent("metadata.json", isDirectory: false)
        let ticketSecretURL = baseDirectory.appendingPathComponent("ticket-secret.txt", isDirectory: false)

        let existingMetadata = loadMetadata(from: metadataURL)
        let needsNewCertificate = !FileManager.default.fileExists(atPath: certURL.path) ||
            !FileManager.default.fileExists(atPath: keyURL.path) ||
            existingMetadata?.hosts != hosts

        if needsNewCertificate {
            try generateSelfSignedCertificate(
                commonName: hosts.first ?? "cmux-direct-daemon",
                certURL: certURL,
                keyURL: keyURL
            )
            let metadata = Metadata(hosts: hosts)
            let metadataData = try JSONEncoder().encode(metadata)
            try metadataData.write(to: metadataURL, options: .atomic)
        }

        let ticketSecret = try existingTicketSecret(from: ticketSecretURL) ?? {
            let generated = Self.randomHex(byteCount: 32)
            try generated.write(
                to: ticketSecretURL,
                atomically: true,
                encoding: .utf8
            )
            return generated
        }()

        let certPEM = try String(contentsOf: certURL, encoding: .utf8)
        return MobileDirectDaemonMaterial(
            certPath: certURL.path,
            keyPath: keyURL.path,
            ticketSecret: ticketSecret,
            pin: try certificatePin(fromPEM: certPEM),
            hosts: hosts
        )
    }

    private func loadMetadata(from url: URL) -> Metadata? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Metadata.self, from: data)
    }

    private func existingTicketSecret(from url: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let secret = try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return secret.isEmpty ? nil : secret
    }

    private func generateSelfSignedCertificate(
        commonName: String,
        certURL: URL,
        keyURL: URL
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = [
            "req",
            "-x509",
            "-nodes",
            "-newkey",
            "rsa:2048",
            "-sha256",
            "-days",
            "365",
            "-subj",
            "/CN=\(commonName)/O=cmux Mobile Direct",
            "-keyout",
            keyURL.path,
            "-out",
            certURL.path,
        ]
        let stderrPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: stderrData, encoding: .utf8) ?? "openssl failed"
            throw NSError(
                domain: "cmux.auth.direct-daemon",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
    }

    private func certificatePin(fromPEM pem: String) throws -> String {
        let lines = pem
            .components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") && !$0.isEmpty }
            .joined()
        guard let derData = Data(base64Encoded: lines) else {
            throw NSError(
                domain: "cmux.auth.direct-daemon",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "invalid certificate data"]
            )
        }
        let digest = SHA256.hash(data: derData)
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func randomHex(byteCount: Int) -> String {
        let bytes = (0 ..< byteCount).map { _ in UInt8.random(in: 0 ... 255) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
