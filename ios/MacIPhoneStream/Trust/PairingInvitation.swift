import Foundation

/// Public host identity and a local HTTPS endpoint. This is not a stream token
/// and does not grant permission to start a stream or approve a device.
struct PairingInvitation: Equatable {
    let endpointURL: URL
    let hostID: String
    let serviceName: String
    let serviceDomain: String

    enum Invalid: Error, LocalizedError {
        case address, identity, metadata
        var errorDescription: String? {
            switch self {
            case .address: return "请粘贴 Mac 主机提供的完整配对地址。无需开始串流。"
            case .identity: return "配对地址缺少有效主机身份，请从 Mac 重新复制。"
            case .metadata: return "配对地址格式无效，请从 Mac 重新复制。"
            }
        }
    }

    init(text: String) throws {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count <= 2048,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let parts = URLComponents(string: value),
              parts.scheme?.lowercased() == "https", parts.user == nil, parts.password == nil,
              parts.query == nil, parts.path.isEmpty || parts.path == "/",
              let hostname = parts.host, let port = parts.port,
              let endpoint = Self.endpointURL(hostname: hostname, port: port),
              let encodedFragment = parts.percentEncodedFragment,
              let items = URLComponents(string: "?" + encodedFragment)?.queryItems else {
            throw Invalid.address
        }
        let names = items.map(\.name)
        guard items.count == 4, Set(names) == Set(["gs-pair", "host_id", "service", "domain"]),
              Set(names).count == names.count,
              let version = items.first(where: { $0.name == "gs-pair" })?.value, version == "1" else {
            throw Invalid.metadata
        }
        guard let hostID = items.first(where: { $0.name == "host_id" })?.value,
              DeviceTrustProtocol.validFingerprint(hostID) else { throw Invalid.identity }
        guard let name = items.first(where: { $0.name == "service" })?.value,
              !name.isEmpty, name.utf8.count <= 128,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let domain = items.first(where: { $0.name == "domain" })?.value, domain == "local." else {
            throw Invalid.metadata
        }
        endpointURL = endpoint
        self.hostID = hostID
        serviceName = name
        serviceDomain = domain
    }

    var candidate: DiscoveredMac {
        DiscoveredMac(name: serviceName, domain: serviceDomain,
                      hostname: endpointURL.host!, port: endpointURL.port!, advertisedHostID: hostID)
    }

    /// A saved endpoint is revalidated on use; it never bypasses the TLS identity pin.
    static func endpointURL(hostname: String, port: Int) -> URL? {
        guard (1...65535).contains(port), isLocalHost(hostname) else { return nil }
        var parts = URLComponents()
        parts.scheme = "https"; parts.host = hostname.lowercased(); parts.port = port
        return parts.url
    }

    static func isLocalHost(_ hostname: String) -> Bool {
        let host = hostname.lowercased()
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        if labels.count == 4 {
            let octets = labels.compactMap { label -> Int? in
                guard !label.isEmpty, label.utf8.allSatisfy({ (48...57).contains($0) }),
                      let number = Int(label), (0...255).contains(number), String(number) == label else { return nil }
                return number
            }
            if octets.count == 4 {
                return octets[0] == 10 || (octets[0] == 172 && (16...31).contains(octets[1])) ||
                    (octets[0] == 192 && octets[1] == 168) || (octets[0] == 169 && octets[1] == 254)
            }
        }
        let name = host.hasSuffix(".") ? String(host.dropLast()) : host
        guard name.utf8.count <= 253, name.hasSuffix(".local") else { return false }
        let localLabels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard localLabels.count >= 2 else { return false }
        return localLabels.allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-" &&
                label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }
    }
}

/// Saved reachability hints retain the existing host identity.
extension TrustedMac {
    var savedCandidate: DiscoveredMac? {
        guard let endpointURL, let parts = URLComponents(string: endpointURL),
              parts.scheme?.lowercased() == "https", parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, parts.path.isEmpty || parts.path == "/",
              let hostname = parts.host, let port = parts.port,
              PairingInvitation.endpointURL(hostname: hostname, port: port) != nil else { return nil }
        return DiscoveredMac(name: serviceName, domain: serviceDomain, hostname: hostname,
                             port: port, advertisedHostID: hostID)
    }

    func withEndpoint(_ candidate: DiscoveredMac, name: String? = nil) -> TrustedMac {
        TrustedMac(hostID: hostID, deviceID: deviceID, name: name ?? self.name,
                   serviceName: candidate.name, serviceDomain: candidate.domain,
                   endpointURL: candidate.url?.absoluteString ?? endpointURL)
    }
}
