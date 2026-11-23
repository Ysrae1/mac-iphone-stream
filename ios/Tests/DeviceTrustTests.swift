import Foundation
import CryptoKit

@main struct DeviceTrustTests {
    static func main() throws {
        var checks = 0
        func check(_ value: Bool, _ label: String) { precondition(value, label); checks += 1 }
        check(DeviceTrustProtocol.pairingDeviceName("  我的 iPhone \n") == "我的 iPhone", "device name trims boundary whitespace")
        check(DeviceTrustProtocol.pairingDeviceName(String(repeating: "名", count: 64)) != nil, "64-character device name")
        for invalid in ["", "  \n", String(repeating: "名", count: 65), "bad\nname", "bad\u{0000}name"] {
            check(DeviceTrustProtocol.pairingDeviceName(invalid) == nil, "invalid device name denied")
        }
        let key = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32))
        let publicKey = key.publicKey.x963Representation.base64EncodedString()
        let hostID = String(repeating: "a", count: 64)
        let deviceID = DeviceTrustProtocol.fingerprint(key.publicKey.x963Representation)
        let pairID = String(repeating: "b", count: 32)
        let challengeID = String(repeating: "c", count: 64)
        let nonce = Data(repeating: 1, count: 32).base64EncodedString()
        let serverNonce = Data(repeating: 2, count: 32).base64EncodedString()
        let pairMessage = DeviceTrustProtocol.pairingMessage(hostID: hostID, pairID: pairID, publicKey: publicKey, nonce: nonce)
        check(String(data: pairMessage, encoding: .utf8) == "GS-PAIR-1\n\(hostID)\n\(pairID)\n\(publicKey)\n\(nonce)", "pair transcript")
        let proof = try key.signature(for: pairMessage)
        check(key.publicKey.isValidSignature(proof, for: pairMessage), "P256 proof")
        check(!key.publicKey.isValidSignature(proof, for: pairMessage + Data([0])), "mutated proof")
        let decodedProof = try P256.Signing.ECDSASignature(derRepresentation: proof.derRepresentation)
        check(key.publicKey.isValidSignature(decodedProof, for: pairMessage), "DER interoperability")
        let code = DeviceTrustProtocol.pairingCode(hostID: hostID, pairID: pairID, publicKey: publicKey, nonce: nonce, serverNonce: serverNonce)
        check(code.count == 6 && code.allSatisfy(\.isNumber), "SAS six digits")
        check(code != DeviceTrustProtocol.pairingCode(hostID: hostID, pairID: pairID, publicKey: publicKey, nonce: nonce, serverNonce: nonce), "SAS nonce bound")
        let expiry = 1_800_000_000.0
        let message = Data("GS-COMMAND-1\n\(hostID)\n\(deviceID)\nstart\n\(challengeID)\n1800000000".utf8)
        try DeviceTrustProtocol.validateChallenge(message, hostID: hostID, deviceID: deviceID, operation: "start", challengeID: challengeID, expiresAt: expiry); checks += 1
        let mutations: [(Data,String,String,String,String,Double)] = [
            (message, String(repeating:"b",count:64), deviceID, "start", challengeID, expiry),
            (message, hostID, hostID, "start", challengeID, expiry),
            (message, hostID, deviceID, "status", challengeID, expiry),
            (message, hostID, deviceID, "start", hostID, expiry),
            (message, hostID, deviceID, "start", challengeID, expiry+1),
            (message, hostID, deviceID, "start", challengeID, expiry+0.5),
            (message, hostID, deviceID, "shell", challengeID, expiry),
            (message+Data([10]), hostID, deviceID, "start", challengeID, expiry),
            (message, hostID, deviceID, "start", challengeID, .infinity),
            (message, hostID, deviceID, "start", challengeID, .nan)
        ]
        for item in mutations {
            do {
                try DeviceTrustProtocol.validateChallenge(item.0, hostID:item.1, deviceID:item.2, operation:item.3, challengeID:item.4, expiresAt:item.5)
                fatalError("accepted mutated binding")
            } catch { checks += 1 }
        }
        check(DeviceTrustProtocol.validFingerprint(hostID), "fingerprint accepted")
        for bad in ["", "a", String(repeating:"A", count:64), String(repeating:"g", count:64), hostID+"\n"] {
            check(!DeviceTrustProtocol.validFingerprint(bad), "fingerprint rejected")
        }
        let vector: [String: Any] = ["host_id":hostID, "device_id":deviceID, "public_key":publicKey,
            "pair_id":pairID,"nonce":nonce,"server_nonce":serverNonce,"code":code,
            "pair_message":pairMessage.base64EncodedString(),"signature":proof.derRepresentation.base64EncodedString()]
        if CommandLine.arguments.count > 1 {
            try JSONSerialization.data(withJSONObject:vector,options:[.sortedKeys,.prettyPrinted]).write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
        }
        print("Device trust: \(checks) offline checks passed; no Keychain writes, network or device operations.")
    }
}
