import Foundation
import CryptoKit
import Security

/// Persistent app-only identity. No SSH keys, system settings or media credentials.
struct TrustedMac: Codable, Equatable {
    let hostID: String
    let deviceID: String
    let name: String
    let serviceName: String
    let serviceDomain: String
    /// An optional reachability hint, never an alternative to the saved TLS pin.
    let endpointURL: String?

    init(hostID: String, deviceID: String, name: String, serviceName: String, serviceDomain: String,
         endpointURL: String? = nil) {
        self.hostID = hostID; self.deviceID = deviceID; self.name = name
        self.serviceName = serviceName; self.serviceDomain = serviceDomain; self.endpointURL = endpointURL
    }


}

enum DeviceTrustError: Error, LocalizedError {
    case keychain(OSStatus), invalidResponse, identityChanged, unavailable, denied, expired, invalidDeviceName
    case remote(String)
    var errorDescription: String? {
        switch self {
        case .keychain: return "无法读取本机设备密钥。请解锁 iPhone 后重试。"
        case .invalidResponse: return "Mac 返回的配对数据无效。"
        case .identityChanged: return "Mac 的设备身份与已保存的信任不一致，已停止连接。请在 Mac 核对后重新配对。"
        case .unavailable: return "没有发现可用的 Mac。请打开 Mac 串流主机并保持设备在同一局域网。"
        case .denied: return "Mac 已拒绝此次配对。"
        case .expired: return "此次配对或启动等待已到期，请重试。"
        case .invalidDeviceName: return "请输入 1–64 个字符的设备名称。"
        case .remote(let message): return message
        }
    }
}

final class DeviceTrustStore {
    private let service = "local.maciphonestream.client.device-trust.v1"
    private func read(_ account: String) throws -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw DeviceTrustError.keychain(status) }
        return data
    }
    private func write(_ data: Data, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account]
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let result = SecItemAdd(attributes as CFDictionary, nil)
            guard result == errSecSuccess else { throw DeviceTrustError.keychain(result) }
        } else if status != errSecSuccess { throw DeviceTrustError.keychain(status) }
    }
    func identity() throws -> P256.Signing.PrivateKey {
        if let data = try read("device-key") { return try P256.Signing.PrivateKey(rawRepresentation: data) }
        let key = P256.Signing.PrivateKey()
        try write(key.rawRepresentation, account: "device-key")
        return key
    }
    func hosts() throws -> [TrustedMac] {
        guard let data = try read("trusted-hosts") else { return [] }
        return try JSONDecoder().decode([TrustedMac].self, from: data)
    }
    func save(_ host: TrustedMac) throws {
        var hosts = try hosts().filter { $0.hostID != host.hostID }
        hosts.append(host)
        try write(JSONEncoder().encode(hosts), account: "trusted-hosts")
    }
    func forget(_ hostID: String) throws {
        try write(JSONEncoder().encode(try hosts().filter { $0.hostID != hostID }), account: "trusted-hosts")
    }
}

enum DeviceTrustProtocol {
    static let serviceType = "_miph-stream._tcp."
    static func pairingDeviceName(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...64).contains(value.unicodeScalars.count),
              value.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return value
    }
    static func fingerprint(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func pairingMessage(hostID: String, pairID: String, publicKey: String, nonce: String) -> Data {
        Data("GS-PAIR-1\n\(hostID)\n\(pairID)\n\(publicKey)\n\(nonce)".utf8)
    }
    static func pairingCode(hostID: String, pairID: String, publicKey: String, nonce: String, serverNonce: String) -> String {
        let hash = SHA256.hash(data: Data("GS-SAS-1\n\(hostID)\n\(pairID)\n\(publicKey)\n\(nonce)\n\(serverNonce)".utf8))
        let value = hash.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return String(format: "%06llu", value % 1_000_000)
    }
    static func validateChallenge(_ message: Data, hostID: String, deviceID: String, operation: String,
                                  challengeID: String, expiresAt: TimeInterval) throws {
        guard validFingerprint(hostID), validFingerprint(deviceID), validFingerprint(challengeID),
              ["start", "status"].contains(operation), expiresAt.isFinite, expiresAt > 0,
              expiresAt < 10_000_000_000, expiresAt.rounded(.down) == expiresAt else {
            throw DeviceTrustError.invalidResponse
        }
        let expected = Data("GS-COMMAND-1\n\(hostID)\n\(deviceID)\n\(operation)\n\(challengeID)\n\(Int64(expiresAt))".utf8)
        guard message == expected else { throw DeviceTrustError.invalidResponse }
    }
    static func randomNonce() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let result = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard result == errSecSuccess else { throw DeviceTrustError.keychain(result) }
        return Data(bytes).base64EncodedString()
    }
    static func validFingerprint(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
