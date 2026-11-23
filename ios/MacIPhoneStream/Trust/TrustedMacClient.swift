import Foundation
import CryptoKit
import Security

/// TOFU is allowed only for an explicit pairing operation. Once observed, even the
/// initial pairing connection is pinned; ordinary requests never accept a new key.
private final class TrustedMacTLS: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    private let lock = NSLock()
    private var expected: String?
    private let permitsFirstIdentity: Bool
    private var mismatch = false
    init(expected: String?, permitsFirstIdentity: Bool) {
        self.expected = expected; self.permitsFirstIdentity = permitsFirstIdentity
    }
    var fingerprint: String? { lock.lock(); defer { lock.unlock() }; return expected }
    var identityMismatch: Bool { lock.lock(); defer { lock.unlock() }; return mismatch }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        let observed = DeviceTrustProtocol.fingerprint(SecCertificateCopyData(leaf) as Data)
        lock.lock()
        if expected == nil && permitsFirstIdentity { expected = observed }
        let accepted = expected == observed
        if !accepted { mismatch = true }
        lock.unlock()
        completionHandler(accepted ? .useCredential : .cancelAuthenticationChallenge,
                          accepted ? URLCredential(trust: trust) : nil)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

struct TrustedPairing {
    let pairID: String
    let pollToken: String
    let code: String
    let expiresAt: TimeInterval
    let hostID: String
    let hostName: String
}

final class TrustedMacClient {
    private let baseURL: URL
    private let verifier: TrustedMacTLS
    private let session: URLSession
    private let identity: P256.Signing.PrivateKey
    private(set) var pairing: TrustedPairing?
    /// Populated only by the TLS-pinned /info response, never a Bonjour hint.
    private(set) var verifiedHostName: String?
    init(candidate: DiscoveredMac, host: TrustedMac?, identity: P256.Signing.PrivateKey,
         pairing: Bool = false, expectedHostID: String? = nil) throws {
        guard let url = candidate.url, host != nil || pairing else { throw DeviceTrustError.unavailable }
        if let expectedHostID {
            guard DeviceTrustProtocol.validFingerprint(expectedHostID),
                  host == nil || host?.hostID == expectedHostID else { throw DeviceTrustError.identityChanged }
        }
        baseURL = url; self.identity = identity
        let expected = host?.hostID ?? expectedHostID
        verifier = TrustedMacTLS(expected: expected, permitsFirstIdentity: pairing && expected == nil)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8; configuration.timeoutIntervalForResource = 12
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        session = URLSession(configuration: configuration, delegate: verifier, delegateQueue: nil)
    }
    func cancel() { session.invalidateAndCancel() }
    private func request(_ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let body {
            request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        do {
            // Async transfers need their explicit task delegate for certificate
            // authentication; relying on the session delegate skips our pin callback.
            let (bytes, response) = try await session.bytes(for: request, delegate: verifier)
            guard let http = response as? HTTPURLResponse,
                  http.expectedContentLength <= 65536 else { throw DeviceTrustError.invalidResponse }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 65536 else { throw DeviceTrustError.invalidResponse }
                data.append(byte)
            }
            let object = try JSONSerialization.jsonObject(with: data)
            guard let result = object as? [String: Any] else { throw DeviceTrustError.invalidResponse }
            guard (200..<300).contains(http.statusCode) else {
                if http.statusCode == 429 {
                    throw DeviceTrustError.remote("请求过于频繁，请稍后重试。Mac 上已经开始的启动流程不会被中断。")
                }
                let code = result["error"] as? String ?? "request_failed"
                let messages = ["pairing_closed": "请先在 Mac 主机点“配对新 iPhone”，再试一次。",
                                "unknown_device": "Mac 已撤销此设备的信任。请重新配对。",
                                "device_revoked": "Mac 已撤销此设备的信任。请重新配对。",
                                "untrusted_device": "Mac 已撤销此设备的信任。请忘记此 Mac 后重新配对。",
                                "pairing_rate_limited": "配对尝试过多，请在 Mac 重新开启配对后再试。",
                                "challenge_expired": "设备认证已到期，请重试。",
                                "busy": "Mac 正在处理启动，请稍后重试。"]
                throw DeviceTrustError.remote(messages[code] ?? "Mac 未能完成请求（\(http.statusCode)）。")
            }
            return result
        } catch {
            if verifier.identityMismatch { throw DeviceTrustError.identityChanged }
            throw error
        }
    }
    private func hostInfo() async throws -> [String: Any] {
        let info = try await request("v1/info")
        guard let hostID = info["host_id"] as? String, DeviceTrustProtocol.validFingerprint(hostID),
              hostID == verifier.fingerprint, (info["protocol"] as? Int) == 1,
              let name = info["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.utf8.count <= 128 else { throw DeviceTrustError.identityChanged }
        verifiedHostName = name
        return info
    }
    /// Reachability and pinned identity only; this never requests a stream.
    func verifyHostIdentity() async throws -> String {
        let info = try await hostInfo()
        return info["name"] as! String
    }
    func beginPairing(deviceName: String) async throws -> TrustedPairing {
        guard let deviceName = DeviceTrustProtocol.pairingDeviceName(deviceName) else {
            throw DeviceTrustError.invalidDeviceName
        }
        let info = try await hostInfo()
        guard let hostID = info["host_id"] as? String, let name = info["name"] as? String else {
            throw DeviceTrustError.invalidResponse
        }
        guard info["pairing_open"] as? Bool == true else {
            throw DeviceTrustError.remote("请先在 Mac 主机点“配对新 iPhone”，再试一次。")
        }
        let publicKey = identity.publicKey.x963Representation.base64EncodedString()
        let nonce = try DeviceTrustProtocol.randomNonce()
        let commitment = DeviceTrustProtocol.fingerprint(Data("GS-PAIR-COMMIT-1\n\(publicKey)\n\(nonce)".utf8))
        let begin = try await request("v1/pair/begin", body: ["commitment": commitment])
        guard let pairID = begin["pair_id"] as? String, (16...128).contains(pairID.utf8.count),
              let hostCommitment = begin["host_commitment"] as? String,
              DeviceTrustProtocol.validFingerprint(hostCommitment) else { throw DeviceTrustError.invalidResponse }
        let message = DeviceTrustProtocol.pairingMessage(hostID: hostID, pairID: pairID, publicKey: publicKey, nonce: nonce)
        let signature = try identity.signature(for: message).derRepresentation.base64EncodedString()
        let response = try await request("v1/pair", body: ["host_id": hostID, "pair_id": pairID,
            "name": deviceName, "public_key": publicKey, "nonce": nonce, "signature": signature])
        guard response["pair_id"] as? String == pairID, let serverNonce = response["server_nonce"] as? String,
              Data(base64Encoded: serverNonce)?.count == 32,
              DeviceTrustProtocol.fingerprint(Data("GS-HOST-COMMIT-1\n\(hostID)\n\(pairID)\n\(serverNonce)".utf8)) == hostCommitment,
              let token = response["poll_token"] as? String, (16...256).contains(token.utf8.count),
              let expires = response["expires_at"] as? Double, expires > Date().timeIntervalSince1970,
              expires < Date().timeIntervalSince1970 + 301 else { throw DeviceTrustError.invalidResponse }
        let code = DeviceTrustProtocol.pairingCode(hostID: hostID, pairID: pairID, publicKey: publicKey,
                                                  nonce: nonce, serverNonce: serverNonce)
        guard response["code"] as? String == code else { throw DeviceTrustError.identityChanged }
        let pairing = TrustedPairing(pairID: pairID, pollToken: token, code: code,
                                     expiresAt: expires, hostID: hostID, hostName: name)
        self.pairing = pairing
        return pairing
    }
    func pollPairing(_ pairing: TrustedPairing) async throws -> String? {
        guard Date().timeIntervalSince1970 < pairing.expiresAt else { throw DeviceTrustError.expired }
        let response = try await request("v1/pair/status", body: ["pair_id": pairing.pairID, "poll_token": pairing.pollToken])
        switch response["status"] as? String {
        case "pending": return nil
        case "denied": throw DeviceTrustError.denied
        case "expired": throw DeviceTrustError.expired
        case "approved":
            guard response["host_id"] as? String == pairing.hostID,
                  let deviceID = response["device_id"] as? String,
                  DeviceTrustProtocol.validFingerprint(deviceID),
                  deviceID == DeviceTrustProtocol.fingerprint(identity.publicKey.x963Representation) else { throw DeviceTrustError.invalidResponse }
            return deviceID
        default: throw DeviceTrustError.invalidResponse
        }
    }
    func command(_ operation: String, host: TrustedMac) async throws -> [String: Any] {
        guard ["start", "status"].contains(operation) else { throw DeviceTrustError.invalidResponse }
        let challenge = try await request("v1/challenge", body: ["device_id": host.deviceID, "operation": operation])
        guard let id = challenge["challenge_id"] as? String, (16...128).contains(id.utf8.count),
              let encoded = challenge["message"] as? String, let message = Data(base64Encoded: encoded),
              message.count <= 2048,
              let expires = challenge["expires_at"] as? Double,
              expires > Date().timeIntervalSince1970, expires < Date().timeIntervalSince1970 + 61 else {
            throw DeviceTrustError.invalidResponse
        }
        try DeviceTrustProtocol.validateChallenge(message, hostID: host.hostID, deviceID: host.deviceID,
                                                  operation: operation, challengeID: id, expiresAt: expires)
        let signature = try identity.signature(for: message).derRepresentation.base64EncodedString()
        return try await request("v1/command", body: ["device_id": host.deviceID, "challenge_id": id, "signature": signature])
    }
}
