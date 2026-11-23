import Foundation
import AVFoundation

final class NativeStream: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate {
    private let queue = OperationQueue()
    private var session: URLSession!
    private var task: URLSessionDataTask?
    private var parser = StreamParser()
    private let media: NativeMedia
    private let diagnostics: ClientDiagnostics
    private var previousReceiveTime: Double?
    private var previousReceiveEnd: Double?
    private var previousMedia: [String: (pts: UInt64, began: Double, ended: Double)] = [:]
    private var requestStarted: Double?
    private let requestTimeout: TimeInterval = 8
    private let stateLock = NSLock()
    private var failureState = false
    private var stopRequested = false
    private var lastMediaUptime: TimeInterval?
    private var failed: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return failureState }
        set { stateLock.lock(); failureState = newValue; stateLock.unlock() }
    }
    var isHealthy: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return !failureState && !stopRequested
    }
    /// Accepted media starts the liveness clock. A validated capture-idle record
    /// can refresh it while the source is static.
    func mediaIdleInterval(at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> TimeInterval? {
        stateLock.lock(); defer { stateLock.unlock() }
        guard !failureState, !stopRequested, let lastMediaUptime else { return nil }
        return max(0, uptime - lastMediaUptime)
    }
    var onFailure: ((String) -> Void)?
    var onVideo: ((CGSize) -> Void)?
    var onAudioError: (() -> Void)?

    init(layer: AVSampleBufferDisplayLayer, diagnostics: ClientDiagnostics,
         configuration: URLSessionConfiguration = .ephemeral) {
        self.diagnostics = diagnostics
        media = NativeMedia(layer: layer, diagnostics: diagnostics)
        super.init()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInteractive
        media.onVideo = { [weak self] size in DispatchQueue.main.async { self?.onVideo?(size) } }
        media.onAudioError = { [weak self] in DispatchQueue.main.async { self?.onAudioError?() } }
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = 60 * 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }
    func start(_ request: URLRequest) {
        var request = request
        request.timeoutInterval = requestTimeout
        let preparedRequest = request
        queue.addOperation { [self] in
            stateLock.lock()
            let mayPrepare = !stopRequested && !failureState
            stateLock.unlock()
            guard mayPrepare else { return }
            media.prepareAudio()
            // stop() can arrive during the synchronous engine preparation. It must
            // prevent a late request, while media teardown stays on this same queue.
            stateLock.lock()
            defer { stateLock.unlock() }
            guard !stopRequested && !failureState else { return }
            requestStarted = ProcessInfo.processInfo.systemUptime
            task = session.dataTask(with: preparedRequest)
            task?.resume()
        }
    }
    func stop(reason: String = "stopped", completion: (() -> Void)? = nil) {
        stateLock.lock()
        stopRequested = true
        let taskToCancel = task
        stateLock.unlock()
        taskToCancel?.cancel()
        session.invalidateAndCancel()
        queue.addOperation { [self] in
            // fail() already finalized the original cause; cancellation must not overwrite it.
            if !failed {
                failed = true; media.stop(); diagnostics.finish(reason)
            }
            if let completion { DispatchQueue.main.async(execute: completion) }
        }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.mimeType == "application/octet-stream" else {
            completionHandler(.cancel)
            fail("无法打开原生串流（HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)）。")
            return
        }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // Timestamp before the state lock: actual URLSession delegate entry.
        let began = ProcessInfo.processInfo.systemUptime
        guard !failed else { return }
        let previousBegan = previousReceiveTime, previousEnd = previousReceiveEnd
        let bufferedBefore = parser.bufferedBytes
        if let previousReceiveTime { diagnostics.observe("receive_callback_interval_ms", (began - previousReceiveTime) * 1000) }
        previousReceiveTime = began
        diagnostics.observe("receive_callback_bytes", Double(data.count))
        var packets = 0
        var sawHeartbeat = false
        var firstPacket: (kind: Double, pts: Double)?, lastPacket: (kind: Double, pts: Double)?
        defer {
            let ended = ProcessInfo.processInfo.systemUptime
            let workMS = (ended - began) * 1000
            let intervalMS = previousBegan.map { (began - $0) * 1000 } ?? 0
            diagnostics.observe("receive_callback_ms", workMS)
            diagnostics.observe("receive_callback_packets", Double(packets))
            if (packets > 0 || !sawHeartbeat) && (intervalMS >= 50 || workMS >= 50) {
                var fields: [String: Double] = ["stage": 5, "begin_uptime_s": began,
                    "end_uptime_s": ended, "callback_ms": workMS, "packet_interval_ms": intervalMS,
                    "bytes": Double(data.count), "packets": Double(packets),
                    "buffered_before": Double(bufferedBefore), "buffered_after": Double(parser.bufferedBytes)]
                if let previousBegan { fields["previous_begin_uptime_s"] = previousBegan }
                if let previousEnd { fields["previous_end_uptime_s"] = previousEnd }
                if let firstPacket {
                    fields["first_packet_kind"] = firstPacket.kind
                    fields["first_source_timestamp_us"] = firstPacket.pts
                }
                if let lastPacket {
                    fields["packet_kind"] = lastPacket.kind
                    fields["source_timestamp_us"] = lastPacket.pts
                }
                diagnostics.recordAVPathEvent(fields)
            }
            previousReceiveEnd = ended
        }
        do {
            try parser.append(data) { packet in
                if packet.kind == .heartbeat {
                    sawHeartbeat = true
                    recordMediaActivity(allowsInitial: false)
                    return
                }
                packets += 1
                diagnostics.recordAVPacket(kind: packet.kind == .video ? 1 : 2, sourceTimestamp: packet.timestampMicroseconds)
                // Retain numeric anchors only; do not keep packet payloads in diagnostics.
                let anchor = (kind: packet.kind == .video ? 1.0 : 2.0, pts: Double(packet.timestampMicroseconds))
                if firstPacket == nil { firstPacket = anchor }
                lastPacket = anchor
                let started = ProcessInfo.processInfo.systemUptime
                let previous = previousMedia[packet.kind.rawValue]
                defer {
                    let ended = ProcessInfo.processInfo.systemUptime
                    let workMS = (ended - started) * 1000
                    let intervalMS = previous.map { (started - $0.began) * 1000 } ?? 0
                    diagnostics.observe(packet.kind == .video ? "video_consume_ms" : "audio_consume_ms", workMS)
                    if intervalMS >= 50 || workMS >= 50 {
                        var fields: [String: Double] = ["stage": 6,
                            "packet_kind": packet.kind == .video ? 1 : 2,
                            "source_timestamp_us": Double(packet.timestampMicroseconds),
                            "begin_uptime_s": started, "end_uptime_s": ended,
                            "callback_begin_uptime_s": began, "consume_ms": workMS,
                            "packet_interval_ms": intervalMS]
                        if let previous {
                            fields["previous_source_timestamp_us"] = Double(previous.pts)
                            fields["previous_begin_uptime_s"] = previous.began
                            fields["previous_end_uptime_s"] = previous.ended
                        }
                        diagnostics.recordAVPathEvent(fields)
                    }
                    previousMedia[packet.kind.rawValue] = (packet.timestampMicroseconds, started, ended)
                }
                try media.consume(packet)
                recordMediaActivity(allowsInitial: true)
            }
        } catch { fail(error.localizedDescription) }
    }

    private func recordMediaActivity(allowsInitial: Bool) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !failureState, !stopRequested, allowsInitial || lastMediaUptime != nil else { return }
        lastMediaUptime = ProcessInfo.processInfo.systemUptime
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !failed else { return }
        if let error {
            let nsError = error as NSError
            guard nsError.domain != NSURLErrorDomain || nsError.code != NSURLErrorCancelled else { return }
            let now = ProcessInfo.processInfo.systemUptime
            let failure = ConnectionFailure(error, operation: .stream,
                elapsed: now - (requestStarted ?? now), requestTimeout: requestTimeout)
            var fields = failure.diagnosticFields
            fields["connection_failure_receive_idle_ms"] = (now - (previousReceiveTime ?? requestStarted ?? now)) * 1000
            diagnostics.recordConnectionFailure(fields)
            // A partial packet at transport failure is an effect, not the failure's cause.
            fail(failure.message)
            return
        }
        do { try parser.finish() } catch { fail(error.localizedDescription); return }
        fail("串流已结束，触控已释放。")
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Never forward a LAN session credential to a redirected endpoint.
        completionHandler(nil)
        fail("主机返回了意外重定向。")
    }
    private func fail(_ message: String) {
        guard !failed else { return }
        failed = true
        task?.cancel()
        media.stop()
        diagnostics.finish("stream_failed")
        DispatchQueue.main.async { [weak self] in self?.onFailure?(message) }
    }
}
