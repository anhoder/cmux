import CryptoKit
import Darwin
import Foundation

struct MobileDirectConnectInfo: Equatable, Sendable {
    let directPort: Int
    let directTLSPins: [String]
    let ticketSecret: String
}

struct MobileDirectDaemonHosts: Equatable, Sendable {
    let machineID: String
    let hostname: String
    let tailscaleHostname: String?
    let tailscaleIPs: [String]
}

struct MobileDirectDaemonProcessHandle: Sendable {
    let processIdentifier: Int32
    let waitUntilReady: @Sendable () async throws -> Void
    let terminate: @Sendable () -> Void
}

final class MobileDirectDaemonManager {
    private struct ActiveState {
        let handle: MobileDirectDaemonProcessHandle
        let info: MobileDirectConnectInfo
        let machineID: String
        let hosts: [String]
        let binaryPath: String
    }

    private let resolveBinaryPath: () -> String?
    private let getApplicationSupportDirectory: () -> URL
    private let allocatePort: () -> Int
    private let ensureMaterial: (URL, [String]) throws -> MobileDirectDaemonMaterial
    private let spawn: (String, [String]) throws -> MobileDirectDaemonProcessHandle

    private var activeState: ActiveState?

    init(
        resolveBinaryPath: (() -> String?)? = nil,
        getApplicationSupportDirectory: @escaping () -> URL = {
            try! FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("cmux", isDirectory: true)
        },
        allocatePort: (() -> Int)? = nil,
        ensureMaterial: @escaping (URL, [String]) throws -> MobileDirectDaemonMaterial = { baseDirectory, hosts in
            try DirectDaemonCertificateStore().ensureMaterial(baseDirectory: baseDirectory, hosts: hosts)
        },
        spawn: ((String, [String]) throws -> MobileDirectDaemonProcessHandle)? = nil
    ) {
        self.resolveBinaryPath = resolveBinaryPath ?? Self.defaultBinaryPath
        self.getApplicationSupportDirectory = getApplicationSupportDirectory
        self.allocatePort = allocatePort ?? Self.allocateFreePort
        self.ensureMaterial = ensureMaterial
        self.spawn = spawn ?? Self.spawnProcess
    }

    func ensureConnection(hosts: MobileDirectDaemonHosts) async throws -> MobileDirectConnectInfo {
        let binaryPath = try resolvedBinaryPath()
        let normalizedHosts = Self.normalizeHosts([
            hosts.machineID,
            hosts.hostname,
            hosts.tailscaleHostname,
        ] + hosts.tailscaleIPs)

        if let activeState,
           activeState.machineID == hosts.machineID,
           activeState.binaryPath == binaryPath,
           activeState.hosts == normalizedHosts,
           Self.isProcessRunning(activeState.handle.processIdentifier) {
            return activeState.info
        }

        shutdown()

        let baseDirectory = getApplicationSupportDirectory()
            .appendingPathComponent("mobile-direct-daemon", isDirectory: true)
            .appendingPathComponent(Self.machineDirectoryName(for: hosts.machineID), isDirectory: true)
        let material = try ensureMaterial(baseDirectory, normalizedHosts)
        let port = allocatePort()
        let arguments = [
            "serve",
            "--tls",
            "--listen",
            "0.0.0.0:\(port)",
            "--server-id",
            hosts.machineID,
            "--ticket-secret",
            material.ticketSecret,
            "--cert-file",
            material.certPath,
            "--key-file",
            material.keyPath,
        ]

        let handle = try spawn(binaryPath, arguments)
        try await handle.waitUntilReady()
        let info = MobileDirectConnectInfo(
            directPort: port,
            directTLSPins: [material.pin],
            ticketSecret: material.ticketSecret
        )
        activeState = ActiveState(
            handle: handle,
            info: info,
            machineID: hosts.machineID,
            hosts: normalizedHosts,
            binaryPath: binaryPath
        )
        return info
    }

    func shutdown() {
        guard let activeState else { return }
        self.activeState = nil
        activeState.handle.terminate()
    }

    private func resolvedBinaryPath() throws -> String {
        guard let path = resolveBinaryPath(), !path.isEmpty else {
            throw NSError(
                domain: "cmux.auth.direct-daemon",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "cmuxd-remote binary not found"]
            )
        }
        return path
    }

    private static func normalizeHosts(_ values: [String?]) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for value in values {
            guard let trimmed = value?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
                  !trimmed.isEmpty else {
                continue
            }
            let normalized = trimmed.replacingOccurrences(of: #"\.+$"#, with: "", options: .regularExpression)
            guard !normalized.isEmpty, !seen.contains(normalized) else { continue }
            seen.insert(normalized)
            result.append(normalized)
        }
        return result
    }

    private static func machineDirectoryName(for machineID: String) -> String {
        let digest = SHA256.hash(data: Data(machineID.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func defaultBinaryPath() -> String? {
        let environment = ProcessInfo.processInfo.environment
        let candidates: [String?] = [
            environment["CMUX_REMOTE_DAEMON_BINARY"],
            Bundle.main.resourceURL?
                .appendingPathComponent("bin", isDirectory: true)
                .appendingPathComponent("cmuxd-remote", isDirectory: false)
                .path,
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".cmux/bin/cmuxd-remote-current", isDirectory: false)
                .path,
        ]
        return candidates.compactMap { path in
            guard let path, FileManager.default.isExecutableFile(atPath: path) else {
                return nil
            }
            return path
        }.first
    }

    private static func allocateFreePort() -> Int {
        let listener = try? SocketListener()
        defer { listener?.invalidate() }
        return listener?.port ?? 9443
    }

    private static func isProcessRunning(_ processIdentifier: Int32) -> Bool {
        guard processIdentifier > 0 else { return false }
        if kill(processIdentifier, 0) == 0 {
            return true
        }
        return errno == EPERM
    }

    private static func spawnProcess(
        binary: String,
        arguments: [String]
    ) throws -> MobileDirectDaemonProcessHandle {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments

        let stderrPipe = Pipe()
        process.standardInput = nil
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe

        let readiness = ProcessReadiness()
        let parser = ReadyLineParser(readiness: readiness)
        process.terminationHandler = { process in
            parser.finish(
                error: NSError(
                    domain: "cmux.auth.direct-daemon",
                    code: Int(process.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: "cmuxd-remote exited before becoming ready"]
                )
            )
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                parser.finish(error: nil)
                return
            }
            parser.consume(data)
        }

        try process.run()

        return MobileDirectDaemonProcessHandle(
            processIdentifier: process.processIdentifier,
            waitUntilReady: {
                try await readiness.wait()
            },
            terminate: {
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                if process.isRunning {
                    process.terminate()
                }
            }
        )
    }
}

private final class ReadyLineParser: @unchecked Sendable {
    private var buffer = Data()
    private let readiness: ProcessReadiness

    init(readiness: ProcessReadiness) {
        self.readiness = readiness
    }

    func consume(_ data: Data) {
        buffer.append(data)
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.prefix(upTo: newlineIndex)
            buffer.removeSubrange(...newlineIndex)
            let line = String(decoding: lineData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("READY") {
                finish(error: nil)
                return
            }
            NSLog("mobile-direct-daemon %@", line)
        }
    }

    func finish(error: Error?) {
        Task {
            await readiness.resolve(error: error)
        }
    }
}

private actor ProcessReadiness {
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?

    func wait() async throws {
        if let result {
            return try result.get()
        }

        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resolve(error: Error?) {
        guard result == nil else { return }
        let nextResult: Result<Void, Error> = {
            if let error {
                return .failure(error)
            }
            return .success(())
        }()
        result = nextResult
        continuation?.resume(with: nextResult)
        continuation = nil
    }
}

private final class SocketListener {
    private let socketDescriptor: Int32
    let port: Int

    init() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw POSIXError(.EIO)
        }

        var value: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &value, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0).bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_ANY.bigEndian)

        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(descriptor)
            throw POSIXError(.EADDRINUSE)
        }

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard nameResult == 0 else {
            close(descriptor)
            throw POSIXError(.EIO)
        }
        self.socketDescriptor = descriptor
        self.port = Int(UInt16(bigEndian: boundAddress.sin_port))
    }

    func invalidate() {
        Darwin.close(socketDescriptor)
    }
}
