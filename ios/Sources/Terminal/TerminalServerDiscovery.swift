import Combine
import Foundation

protocol TerminalServerDiscovering {
    var hostsPublisher: AnyPublisher<[TerminalHost], Never> { get }
}

/// Discovers cmux desktop instances by probing known hosts on their WebSocket port.
final class TailscaleServerDiscovery: TerminalServerDiscovering {
    let hostsPublisher: AnyPublisher<[TerminalHost], Never>

    private let subject = CurrentValueSubject<[TerminalHost], Never>([])
    private var probeTimer: DispatchSourceTimer?
    private var knownHosts: [TerminalHost] = []

    @MainActor
    convenience init() {
        // In DEBUG, auto-probe common local ports for cmuxd-remote
        #if DEBUG
        // Read the WS secret: device reads from app bundle, simulator from host filesystem
        let hostSecret: String = {
            // Device: embedded by reload.sh
            if let bundlePath = Bundle.main.path(forResource: "mobile-ws-secret", ofType: nil),
               let s = try? String(contentsOfFile: bundlePath, encoding: .utf8)
                   .trimmingCharacters(in: .whitespacesAndNewlines),
               !s.isEmpty {
                return s
            }
            // Simulator: shared filesystem with host Mac
            let home = ProcessInfo.processInfo.environment["SIMULATOR_HOST_HOME"]
                ?? ProcessInfo.processInfo.environment["HOME"]
                ?? NSHomeDirectory()
            let secretPath = "\(home)/Library/Application Support/cmux/mobile-ws-secret"
            return (try? String(contentsOfFile: secretPath, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
        }()

        // Determine hostname: device uses relay host (Tailscale IP), simulator uses localhost
        let probeHostname: String = {
            #if targetEnvironment(simulator)
            return "127.0.0.1"
            #else
            if let path = Bundle.main.path(forResource: "debug-relay-host", ofType: nil),
               let host = try? String(contentsOfFile: path, encoding: .utf8)
                   .trimmingCharacters(in: .whitespacesAndNewlines),
               !host.isEmpty {
                return host
            }
            return "127.0.0.1"
            #endif
        }()

        var debugHosts: [TerminalHost] = []
        var seenPorts: Set<Int> = []

        ScannerLog.shared.log("discovery.init hostname=\(probeHostname) secret=\(hostSecret.isEmpty ? "empty" : "\(hostSecret.prefix(8))...")")

        // Check for embedded port from tagged build
        if let bundlePath = Bundle.main.path(forResource: "debug-ws-port", ofType: nil),
           let portStr = try? String(contentsOfFile: bundlePath, encoding: .utf8)
               .trimmingCharacters(in: .whitespacesAndNewlines),
           let port = Int(portStr) {
            seenPorts.insert(port)
            ScannerLog.shared.log("discovery.port embedded=\(port)")
            debugHosts.append(TerminalHost(
                stableID: "\(probeHostname)-\(port)",
                name: probeHostname == "127.0.0.1" ? "Local Dev (:\(port))" : "\(probeHostname) (:\(port))",
                hostname: probeHostname, port: 22, username: "cmux",
                symbolName: "desktopcomputer", palette: .sky,
                source: .discovered, transportPreference: .remoteDaemon,
                wsPort: port, wsSecret: hostSecret
            ))
        } else {
            ScannerLog.shared.log("discovery.port not_embedded")
        }

        ScannerLog.shared.log("discovery.hosts count=\(debugHosts.count)")
        self.init(existingHosts: debugHosts)
        #else
        // Load persisted hosts from GRDB snapshot store for production discovery
        do {
            let store = try TerminalCacheRepository(database: AppDatabase.live())
            let snapshot = store.load()
            let savedHosts = snapshot.hosts.filter { $0.wsPort != nil }
            self.init(existingHosts: savedHosts)
        } catch {
            self.init(existingHosts: [])
        }
        #endif
    }

    init(existingHosts: [TerminalHost]) {
        self.hostsPublisher = subject.eraseToAnyPublisher()
        self.knownHosts = existingHosts
        if !existingHosts.isEmpty {
            probeHosts(existingHosts)
        }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 5, repeating: 30)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.probeHosts(self.knownHosts)
        }
        timer.resume()
        self.probeTimer = timer
    }

    deinit {
        probeTimer?.cancel()
    }

    func addHost(_ host: TerminalHost) {
        if !knownHosts.contains(where: { $0.stableID == host.stableID }) {
            knownHosts.append(host)
        }
        probeHosts(knownHosts)
    }

    private func probeHosts(_ hosts: [TerminalHost]) {
        let hostsToProbe = hosts.filter { $0.wsPort != nil }
        guard !hostsToProbe.isEmpty else { return }

        ScannerLog.shared.log("discovery.probe starting count=\(hostsToProbe.count)")

        DispatchQueue.global(qos: .utility).async { [weak self] in
            var onlineHosts: [TerminalHost] = []
            let lock = NSLock()
            let group = DispatchGroup()

            for host in hostsToProbe {
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    defer { group.leave() }
                    var probed = host
                    let port = host.wsPort ?? 52100
                    let ok = Self.probeHost(hostname: host.hostname, port: port, secret: host.wsSecret ?? "")
                    ScannerLog.shared.log("discovery.probe \(host.hostname):\(port) result=\(ok ? "online" : "offline")")
                    if ok {
                        probed.machineStatus = .online
                        lock.lock()
                        onlineHosts.append(probed)
                        lock.unlock()
                    }
                }
            }

            group.wait()
            ScannerLog.shared.log("discovery.probe.done online=\(onlineHosts.count)/\(hostsToProbe.count)")
            DispatchQueue.main.async { self?.subject.send(onlineHosts) }
        }
    }

    private static func probeHost(hostname: String, port: Int, secret: String) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        // Connect
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        inet_pton(AF_INET, hostname, &addr.sin_addr)
        let addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let connectResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(fd, sockaddrPtr, addrLen)
            }
        }
        guard connectResult == 0 else { return false }

        // WebSocket upgrade
        let req = "GET / HTTP/1.1\r\nHost: \(hostname):\(port)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGVzdA==\r\nSec-WebSocket-Version: 13\r\n\r\n"
        _ = req.data(using: .utf8)?.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = read(fd, &buf, buf.count)
        let response = n > 0 ? String(bytes: buf[0..<n], encoding: .utf8) ?? "" : ""
        let success = response.contains("101")
        TerminalSidebarStore.debugLog("probe \(hostname):\(port) connect=OK ws_upgrade=\(success) response_len=\(n)")
        guard success else { return false }
        return true
    }
}
