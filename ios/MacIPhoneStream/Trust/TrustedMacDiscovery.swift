import Foundation

struct DiscoveredMac {
    let name: String
    let domain: String
    let hostname: String
    let port: Int
    let advertisedHostID: String?
    var url: URL? {
        PairingInvitation.endpointURL(hostname: hostname, port: port)
    }
    func matches(_ host: TrustedMac) -> Bool {
        if let advertisedHostID { return advertisedHostID == host.hostID }
        return name == host.serviceName && domain == host.serviceDomain
    }
}

/// Bonjour names/TXT are discovery hints only. TLS always verifies the saved identity.
final class TrustedMacDiscovery: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    var onChange: (([DiscoveredMac]) -> Void)?
    var onError: ((String) -> Void)?
    private var browser: NetServiceBrowser?
    private var services: [NetService] = []
    private var resolved: [String: DiscoveredMac] = [:]
    func start() {
        stop()
        let browser = NetServiceBrowser(); self.browser = browser
        browser.delegate = self
        browser.searchForServices(ofType: DeviceTrustProtocol.serviceType, inDomain: "local.")
    }
    func stop() {
        browser?.stop(); browser?.delegate = nil; browser = nil
        for service in services { service.stop(); service.delegate = nil }
        services.removeAll(); resolved.removeAll()
    }
    private func key(_ service: NetService) -> String { service.name + "\n" + service.domain }
    private func publish() { onChange?(resolved.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) }
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        services.append(service); service.delegate = self
        service.resolve(withTimeout: 5)
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        services.removeAll { key($0) == key(service) }; resolved.removeValue(forKey: key(service)); publish()
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        onError?("无法发现 Mac。请确认已允许此 App 访问本地网络。")
    }
    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let hostname = sender.hostName else { return }
        let txt = sender.txtRecordData().map(NetService.dictionary(fromTXTRecord:)) ?? [:]
        let hostID = txt["host_id"].flatMap { String(data: $0, encoding: .utf8) }
        let candidate = DiscoveredMac(name: sender.name, domain: sender.domain, hostname: hostname,
                                      port: sender.port, advertisedHostID: hostID)
        guard candidate.url != nil else { return }
        resolved[key(sender)] = candidate; publish()
    }
}
