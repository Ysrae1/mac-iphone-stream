import Foundation

struct Connection {
    static let requestTimeout: TimeInterval = 5
    let baseURL: URL
    let token: String
    let origin: String
    enum Invalid: Error, LocalizedError {
        case address, token
        var errorDescription: String? {
            switch self {
            case .address: return "请粘贴 Mac 提供的局域网连接链接（http://IP:端口/#token=…）。"
            case .token: return "链接缺少有效会话令牌，请从 Mac 重新复制完整链接。"
            }
        }
    }
    init(text: String) throws {
        guard var c = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              c.scheme?.lowercased() == "http", let host = c.host, let port = c.port,
              (1...65535).contains(port), c.user == nil, c.password == nil,
              c.query == nil, c.path == "" || c.path == "/", Self.isLANIPv4(host) else { throw Invalid.address }
        let fragment = URLComponents(string: "?" + (c.fragment ?? ""))
        let tokens = fragment?.queryItems?.filter { $0.name == "token" } ?? []
        guard tokens.count == 1, let token = tokens.first?.value, (16...256).contains(token.utf8.count),
              token.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else { throw Invalid.token }
        c.fragment = nil; c.path = ""
        guard let url = c.url else { throw Invalid.address }
        self.baseURL = url; self.token = token; self.origin = "http://\(host):\(port)"
    }
    private static func isLANIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        let values = parts.compactMap { s -> Int? in
            guard !s.isEmpty, s.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(s), (0...255).contains(n), String(n) == s else { return nil }
            return n
        }
        guard values.count == 4 else { return false }
        return values[0] == 10 || (values[0] == 172 && (16...31).contains(values[1])) ||
            (values[0] == 192 && values[1] == 168) || (values[0] == 169 && values[1] == 254) || values[0] == 127
    }
    func request(path: String, owner: String, lease: String?, body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.timeoutInterval = Self.requestTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.setValue(token, forHTTPHeaderField: "X-Session-Token")
        request.setValue(owner, forHTTPHeaderField: "X-Controller-Id")
        if let lease { request.setValue(lease, forHTTPHeaderField: "X-Session-Lease") }
        if let body {
            request.httpMethod = "POST"; request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }
}

/// Fixed operation codes and numeric error fields only; never serialize a URL,
/// request headers, or NSError.userInfo into the diagnostic snapshot.
struct ConnectionFailure {
    enum Operation: Int { case session = 1, frame = 2, stream = 3 }
    let operation: Operation
    let error: NSError
    private let lostOwnership: Bool
    let elapsed: TimeInterval
    let requestTimeout: TimeInterval

    init(_ error: Error, operation: Operation, elapsed: TimeInterval, requestTimeout: TimeInterval) {
        self.error = error as NSError
        if case SessionError.http(409, "session_not_owned") = error { lostOwnership = true }
        else { lostOwnership = false }
        self.operation = operation
        self.elapsed = elapsed
        self.requestTimeout = requestTimeout
    }
    var isTimeout: Bool { error.domain == NSURLErrorDomain && error.code == NSURLErrorTimedOut }
    // Both failures leave a POST's delivery ambiguous (Apple QA1941). This
    // permits fresh ownership plus empty confirmation, never replay of that POST.
    var permitsInputLeaseRecovery: Bool {
        operation == .frame && (lostOwnership || (error.domain == NSURLErrorDomain &&
        (error.code == NSURLErrorTimedOut || error.code == NSURLErrorNetworkConnectionLost)))
    }
    var diagnosticFields: [String: Double] {
        ["connection_failure_operation": Double(operation.rawValue),
         "connection_failure_url_error": error.domain == NSURLErrorDomain ? 1 : 0,
         "connection_failure_code": Double(error.code),
         "connection_failure_timeout": isTimeout ? 1 : 0,
         "connection_failure_elapsed_ms": elapsed * 1000,
         "connection_failure_request_timeout_ms": requestTimeout * 1000]
    }
    var message: String {
        if isTimeout {
            switch operation {
            case .session: return "连接 Mac 超时，请确认主机仍在等待连接。"
            case .frame: return "触控请求超时，触点已释放。请重新连接。"
            case .stream: return "影音串流接收超时，触点已释放。请重新连接。"
            }
        }
        if operation == .frame { return "触控连接已中断，触点已释放。\n\(error.localizedDescription)" }
        return error.localizedDescription
    }
}

/// Stable numeric codes for LastSessionEnd.json; never infer a cause from UI text.
enum SessionEndReason: Int {
    case requested = 1, background = 2, audioInterruption = 3, transportFailure = 4
    case videoWatchdog = 10, firstVideoTimeout = 11, inputBacklog = 12
    case sessionRequestFailed = 13, frameRequestFailed = 14, streamFailure = 15
    case inputRecoveryFailed = 16, unspecifiedFailure = 99
}

enum SessionError: Error, LocalizedError {
    case invalidResponse, http(Int, String)
    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Mac 返回的数据无效。"
        case .http(409, "controller_busy"): return "已有另一台设备正在控制，请先在那台设备退出。"
        case .http(403, _), .http(410, _): return "会话链接已失效，请从 Mac 复制新的完整链接。"
        case .http(let status, let code): return "连接失败（HTTP \(status)，\(code)）。"
        }
    }
}

/// One automatic attempt per consecutive failure episode. Only observed, rendered
/// readiness plus continuous successful input/video earns another attempt.
final class ConnectionRecoveryBudget {
    private let clock: () -> TimeInterval
    private(set) var used = false
    private var stableSince: TimeInterval?
    private var lastFrame: TimeInterval?
    private var lastVideo: TimeInterval?
    private var previousObservation: TimeInterval?
    init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) { self.clock = clock }
    func reset() { used = false; clearObservations() }
    func consume() { used = true; clearObservations() }
    private func clearObservations() {
        stableSince = nil; lastFrame = nil; lastVideo = nil; previousObservation = nil
    }
    @discardableResult
    func observe(ready: Bool, frame: Bool = false, video: Bool = false) -> Bool {
        let now = clock()
        guard now.isFinite else { clearObservations(); return false }
        if previousObservation.map({ now < $0 }) == true { clearObservations() }
        let frameGap = lastFrame.map { now - $0 > 0.8 } ?? true
        let videoGap = lastVideo.map { now - $0 > 1.2 } ?? true
        if !ready || frameGap || videoGap { stableSince = nil }
        previousObservation = now
        if frame { lastFrame = now }
        if video { lastVideo = now }
        guard ready, let lastFrame, let lastVideo,
              now - lastFrame <= 0.8, now - lastVideo <= 1.2 else { stableSince = nil; return false }
        if stableSince == nil { stableSince = now }
        guard used, now - (stableSince ?? now) >= 30 else { return false }
        used = false
        return true
    }
}
