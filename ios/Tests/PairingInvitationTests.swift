import Foundation

@main struct PairingInvitationTests {
    static func main() throws {
        var checks = 0
        let hostID = String(repeating: "a", count: 64)
        let metadata = "#gs-pair=1&host_id=\(hostID)&service=My%20Mac&domain=local."
        func check(_ condition: Bool, _ label: String) {
            precondition(condition, label); checks += 1
        }
        for hostname in ["mac.local", "mac.local.", "MY-MAC.local", "10.0.0.8", "172.16.0.2", "172.31.255.5", "192.168.1.9", "169.254.5.6"] {
            let invite = try PairingInvitation(text: " https://\(hostname):8443/\(metadata) \n")
            check(invite.hostID == hostID && invite.endpointURL.port == 8443, "identity and port")
            check(invite.serviceName == "My Mac" && invite.serviceDomain == "local.", "discovery hints")
            check(invite.endpointURL.fragment == nil && invite.endpointURL.query == nil, "stored endpoint contains no invitation metadata")
        }
        let chinese = try PairingInvitation(text: "https://mac.local:8443/#gs-pair=1&host_id=\(hostID)&service=%E6%B5%8B%E8%AF%95%E4%B8%B2%E6%B5%81%E4%B8%BB%E6%9C%BA&domain=local.")
        check(chinese.serviceName == "测试串流主机", "UTF8 service name")
        for badHost in ["example.com", "localhost", "127.0.0.1", "0.0.0.0", "8.8.8.8", "172.15.0.1", "172.32.0.1", "192.169.0.1", "192.168.01.1", "256.1.1.1", "mac..local", "-mac.local", "mac-.local", ".local", "mac.local..", "[::1]", "[fe80::1]"] {
            check(!PairingInvitation.isLocalHost(badHost), "reject nonlocal or malformed host")
        }
        let valid = "https://mac.local:8443/\(metadata)"
        let invalid = [
            valid.replacingOccurrences(of: "https://", with: "http://"),
            valid.replacingOccurrences(of: "mac.local:8443", with: "mac.local"),
            valid.replacingOccurrences(of: ":8443", with: ":0"),
            valid.replacingOccurrences(of: ":8443", with: ":65536"),
            valid.replacingOccurrences(of: "mac.local", with: "user@mac.local"),
            valid.replacingOccurrences(of: "mac.local", with: "user:pass@mac.local"),
            valid.replacingOccurrences(of: "/#", with: "/v1/info#"),
            valid.replacingOccurrences(of: "/#", with: "/?token=abc#"),
            valid.replacingOccurrences(of: "gs-pair=1", with: "gs-pair=2"),
            valid + "&token=legacy-token", valid + "&service=other", valid + "&host_id=" + hostID,
            valid.replacingOccurrences(of: "&domain=local.", with: ""),
            valid.replacingOccurrences(of: "domain=local.", with: "domain=example.com"),
            valid.replacingOccurrences(of: "service=My%20Mac", with: "service="),
            valid.replacingOccurrences(of: "service=My%20Mac", with: "service=bad%0Aname"),
            valid.replacingOccurrences(of: hostID, with: hostID.uppercased()),
            valid.replacingOccurrences(of: hostID, with: String(hostID.dropLast())),
            valid.replacingOccurrences(of: "gs-pair=1", with: "gs-pair=1%26other=2"),
            "http://192.168.1.1:8787/#token=abcdefghijklmnop"
        ]
        for text in invalid {
            do { _ = try PairingInvitation(text: text); fatalError("accepted invalid invitation") }
            catch { checks += 1 }
        }
        let oldJSON = Data("{\"hostID\":\"\(hostID)\",\"deviceID\":\"saved-device\",\"name\":\"Saved Mac\",\"serviceName\":\"Saved Mac\",\"serviceDomain\":\"local.\"}".utf8)
        let oldHost = try JSONDecoder().decode(TrustedMac.self, from: oldJSON)
        check(oldHost.endpointURL == nil && oldHost.savedCandidate == nil, "old Keychain record remains decodable")
        let invite = try PairingInvitation(text: valid)
        let updated = oldHost.withEndpoint(invite.candidate)
        check(updated.hostID == oldHost.hostID && updated.deviceID == oldHost.deviceID, "endpoint update preserves device identity")
        let renamed = oldHost.withEndpoint(invite.candidate, name: "Current computer name")
        check(renamed.name == "Current computer name" && renamed.hostID == oldHost.hostID && renamed.deviceID == oldHost.deviceID,
              "verified name update preserves both certificate identities")
        check(updated.name == oldHost.name, "unverified discovery name never replaces the saved display name")
        check(updated.savedCandidate?.url == invite.endpointURL, "saved endpoint validates and reconstructs")
        check(try JSONDecoder().decode(TrustedMac.self, from: JSONEncoder().encode(updated)) == updated, "new Keychain metadata roundtrip")
        for endpoint in ["http://mac.local:8443", "https://example.com:8443", "https://127.0.0.1:8443", "https://mac.local:8443/#token=abc", "https://mac.local:8443/v1/info", "https://mac.local:8443?x=y"] {
            let invalidSaved = TrustedMac(hostID: hostID, deviceID: oldHost.deviceID, name: oldHost.name,
                serviceName: oldHost.serviceName, serviceDomain: oldHost.serviceDomain, endpointURL: endpoint)
            check(invalidSaved.savedCandidate == nil, "saved endpoint never bypasses local HTTPS policy")
        }
        let sameNameOtherID = DiscoveredMac(name: oldHost.serviceName, domain: oldHost.serviceDomain,
            hostname: "other.local", port: 8443, advertisedHostID: String(repeating: "b", count: 64))
        check(!sameNameOtherID.matches(oldHost), "advertised identity mismatch cannot match by display name")
        let sameIDNewName = DiscoveredMac(name: "Renamed", domain: "local.", hostname: "renamed.local", port: 8443, advertisedHostID: hostID)
        check(sameIDNewName.matches(oldHost), "saved identity survives name changes")
        print("Pairing invitation: \(checks) offline checks passed; no network or Keychain operations.")
    }
}
