#if canImport(TailscaleKit)
import Foundation
import TailscaleKit

/// Manages a TailscaleKit node for cmux peer discovery and connectivity.
/// Used by both macOS (daemon bridge) and iOS (server scanner).
final class TailscaleNodeManager: @unchecked Sendable {
    static let hostnamePrefix = "cmux-"
    static let wsPort = 52100

    private(set) var node: TailscaleNode?
    private(set) var localAPI: LocalAPIClient?
    private var busProcessor: MessageProcessor?

    private let stateDir: String
    private let hostname: String
    private let authKey: String?
    private let ephemeral: Bool

    var onBrowseToURL: ((String) -> Void)?
    var onStateChange: ((Ipn.State) -> Void)?

    init(machineID: String, stateDir: String, authKey: String? = nil, ephemeral: Bool = false) {
        self.hostname = "\(Self.hostnamePrefix)\(machineID)"
        self.stateDir = stateDir
        self.authKey = authKey
        self.ephemeral = ephemeral
    }

    func start() async throws {
        let config = Configuration(
            hostName: hostname,
            path: stateDir,
            authKey: authKey,
            controlURL: kDefaultControlURL,
            ephemeral: ephemeral
        )

        let tsNode = try TailscaleNode(config: config, logger: nil)
        self.node = tsNode
        try await tsNode.up()

        let api = LocalAPIClient(localNode: tsNode, logger: nil)
        self.localAPI = api
    }

    func stop() async {
        busProcessor?.cancel()
        busProcessor = nil
        if let node {
            try? await node.close()
        }
        node = nil
        localAPI = nil
    }

    /// Returns the tailnet IP addresses of this node.
    func addresses() async throws -> IPAddresses {
        guard let node else { throw TailscaleError.badInterfaceHandle }
        return try await node.addrs()
    }

    /// Returns all peers on the tailnet whose hostname starts with "cmux-".
    func discoverCmuxPeers() async throws -> [CmuxPeer] {
        guard let localAPI else { throw TailscaleError.badInterfaceHandle }
        let status = try await localAPI.backendStatus()
        guard let peers = status.Peer else { return [] }

        return peers.values.compactMap { peer in
            guard peer.HostName.hasPrefix(Self.hostnamePrefix) else { return nil }
            let ip = peer.TailscaleIPs?.first
            guard let ip else { return nil }
            return CmuxPeer(
                hostname: peer.HostName,
                tailscaleIP: ip,
                online: peer.Online,
                dnsName: peer.DNSName
            )
        }
    }

    struct CmuxPeer: Sendable {
        let hostname: String
        let tailscaleIP: String
        let online: Bool
        let dnsName: String
    }
}
#endif
