import Foundation
import AVFoundation

// The real controller runs against URLProtocol and fake media: no sockets, device,
// renderer success, or input injection is claimed by these checks.
final class NativeStream {
    static var instances: [NativeStream] = []
    static var emitVideoOnStart = true
    static var holdStops = false
    static var pendingStops: [() -> Void] = []
    let layer: AVSampleBufferDisplayLayer
    private var videoHandler: ((CGSize) -> Void)?
    private var lastMediaUptime: TimeInterval?
    var onVideo: ((CGSize) -> Void)? {
        get { { [weak self] size in
            self?.recordMediaActivity(); self?.videoHandler?(size)
        } }
        set { videoHandler = newValue }
    }
    func recordMediaActivity() { if isHealthy { lastMediaUptime = ProcessInfo.processInfo.systemUptime } }
    func mediaIdleInterval(at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> TimeInterval? {
        guard isHealthy, let lastMediaUptime else { return nil }
        return max(0, uptime - lastMediaUptime)
    }
    var onAudioError: (() -> Void)?
    var onFailure: ((String) -> Void)?
    var isHealthy = true
    var starts = 0
    init(layer: AVSampleBufferDisplayLayer, diagnostics: ClientDiagnostics) {
        self.layer = layer; Self.instances.append(self)
    }
    func start(_ request: URLRequest) { starts += 1; if Self.emitVideoOnStart { onVideo?(CGSize(width: 1280, height: 720)) } }
    func stop(reason: String = "stopped", completion: (() -> Void)? = nil) {
        isHealthy = false
        guard let completion else { return }
        if Self.holdStops { Self.pendingStops.append(completion) }
        else { DispatchQueue.main.async(execute: completion) }
    }
    static func releaseStops() {
        holdStops = false
        let pending = pendingStops; pendingStops = []
        pending.forEach { $0() }
    }
}
final class ClientDiagnostics {
    static var failures: [[String: Double]] = []
    static var ends: [SessionEndReason] = []
    static var counters: [String: Double] = [:]
    func count(_ key: String, by value: Double = 1) { Self.counters[key, default: 0] += value }
    func gauge(_ key: String, _ value: Double) {}
    func observe(_ key: String, _ value: Double) {}
    func finish(_ reason: String) {}
    func recordConnectionFailure(_ fields: [String: Double]) { Self.failures.append(fields) }
    func recordSessionEnd(_ reason: SessionEndReason, fields: [String: Double]) { Self.ends.append(reason) }
}
final class RecoveryProtocol: URLProtocol {
    struct Record {
        let request: URLRequest
        let body: [String: Any]
        var path: String { request.url!.lastPathComponent }
        var lease: String? { request.value(forHTTPHeaderField: "X-Session-Lease") }
        var owner: String? { request.value(forHTTPHeaderField: "X-Controller-Id") }
    }
    static let lock = NSLock()
    static var records: [Record] = []
    static var frameError = 0
    static var oldStopError = 0
    static var reclaimError = 0
    static var confirmationError = 0
    static var holdReclaim = false
    static var heldReclaim: (() -> Void)?
    static var resumeError = 409
    static var resumeCount = 0
    static var holdResume = false
    static var heldResume: (() -> Void)?
    static var sessionCount = 0
    static var onReclaim: (() -> Void)?
    static var holdFrames = false
    static var heldFrames: [() -> Void] = []
    static func reset() {
        lock.lock(); defer { lock.unlock() }
        records = []; frameError = 0; oldStopError = 0; reclaimError = 0
        confirmationError = 0; holdReclaim = false; heldReclaim = nil
        sessionCount = 0; onReclaim = nil
        resumeError = 409; resumeCount = 0; holdResume = false; heldResume = nil
        holdFrames = false; heldFrames = []
    }
    static func arm(_ code: Int) { lock.lock(); frameError = code; lock.unlock() }
    static func snapshot() -> [Record] { lock.lock(); defer { lock.unlock() }; return records }
    static func releaseReclaim() {
        lock.lock(); let reply = heldReclaim; heldReclaim = nil; lock.unlock(); reply?()
    }
    static func releaseResume() {
        lock.lock(); let reply = heldResume; heldResume = nil; lock.unlock(); reply?()
    }
    static func releaseFrames() {
        lock.lock(); let replies = heldFrames; heldFrames = []; holdFrames = false; lock.unlock()
        replies.forEach { $0() }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let record = Record(request: request, body: Self.body(request))
        Self.lock.lock()
        Self.records.append(record)
        let isResume = record.path == "session" && record.body["resume"] as? Bool == true
        if isResume { Self.resumeCount += 1 }
        else if record.path == "session" { Self.sessionCount += 1 }
        let resumeNumber = Self.resumeCount, resumeError = Self.resumeError, holdResume = Self.holdResume
        let sessionNumber = Self.sessionCount
        let frameError = record.path == "frame" ? Self.frameError : 0
        if frameError != 0 { Self.frameError = 0 }
        let stopError = Self.oldStopError, reclaimError = Self.reclaimError
        let confirmError = Self.confirmationError, hold = Self.holdReclaim
        let onReclaim = Self.onReclaim
        let holdFrames = Self.holdFrames
        Self.lock.unlock()
        if frameError != 0 { fail(frameError); return }
        if record.path == "reset", record.lease == "lease-1", stopError != 0 { fail(stopError); return }
        if isResume {
            let reply = { [self] in
                if resumeError != 0 { fail(resumeError) }
                else {
                    let result: [String: Any] = ["lease": "resume-\(resumeNumber)", "resumed": true]
                    respond(result)
                }
            }
            if holdResume { Self.lock.lock(); Self.heldResume = reply; Self.lock.unlock(); return }
            reply()
        } else if record.path == "session" {
            let reply = { [self] in
                if sessionNumber > 1 && reclaimError != 0 { fail(reclaimError, name: "controller_busy") }
                else {
                    let result: [String: Any] = ["lease": "lease-\(sessionNumber)"]
                    respond(result)
                }
            }
            if sessionNumber > 1 {
                if let onReclaim { DispatchQueue.main.async(execute: onReclaim) }
                if hold { Self.lock.lock(); Self.heldReclaim = reply; Self.lock.unlock(); return }
            }
            reply()
        } else if record.path == "frame", record.lease != "lease-1", confirmError != 0 { fail(confirmError) }
        else if record.path == "frame", holdFrames {
            Self.lock.lock(); Self.heldFrames.append { [self] in respond([:]) }; Self.lock.unlock()
        } else if record.path == "status" {
            respond(["native_video": ["client_rect_source": "configured",
                "client_rect_normalized": ["x": 0.0, "y": 0.0, "width": 1.0, "height": 1.0]]])
        } else { respond([:]) }
    }
    override func stopLoading() {}
    func fail(_ code: Int, name: String = "session_not_owned") {
        if code < 0 { client?.urlProtocol(self, didFailWithError: URLError(URLError.Code(rawValue: code))) }
        else { respond(["error": name], status: code) }
    }
    func respond(_ object: [String: Any], status: Int = 200) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: object))
        client?.urlProtocolDidFinishLoading(self)
    }
    static func body(_ request: URLRequest) -> [String: Any] {
        if let data = request.httpBody { return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:] }
        guard let stream = request.httpBodyStream else { return [:] }
        stream.open(); defer { stream.close() }
        var data = Data(), bytes = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&bytes, maxLength: bytes.count)
            if n <= 0 { break }; data.append(contentsOf: bytes.prefix(n))
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}

#if !MOTION_FRAME_TESTS
@main
#endif
struct InputRecoveryTests {
    static var checks = 0
    static var layers: [AVSampleBufferDisplayLayer] = []
    static func check(_ value: @autoclosure () -> Bool, _ name: String) {
        guard value() else { fatalError("FAIL: \(name)") }; checks += 1
    }
    @MainActor static func pause(_ seconds: Double = 0.04) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
    @MainActor static func until(_ name: String, _ predicate: () -> Bool) async {
        for _ in 0..<250 {
            if predicate() { return }; await pause(0.01)
        }
        fatalError("Timed out: \(name)")
    }
    static func connection() throws -> Connection {
        try Connection(text: "http://127.0.0.1:12345/#token=synthetic_token_12345")
    }
    final class DisplayGate { var ready = true }
    @MainActor static func controller(recoveryBudget: ConnectionRecoveryBudget = ConnectionRecoveryBudget(),
                                      ready: Bool = false, initialReady: Bool = true, emitVideo: Bool = true) async throws -> SessionController {
        RecoveryProtocol.reset(); NativeStream.releaseStops(); NativeStream.instances = []; NativeStream.emitVideoOnStart = emitVideo
        ClientDiagnostics.failures = []; ClientDiagnostics.ends = []; ClientDiagnostics.counters = [:]
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [RecoveryProtocol.self]
        let gate = DisplayGate(); gate.ready = initialReady
        let result = SessionController(configuration: config, recoveryBudget: recoveryBudget,
            displayReady: { _ in gate.ready })
        let layer = AVSampleBufferDisplayLayer(); layers.append(layer)
        result.connect(try connection(), layer: layer)
        await until("initial mapping") { RecoveryProtocol.snapshot().contains { $0.path == "status" } }
        await pause()
        if initialReady { await until("injected initial display readiness") { result.isReady } }
        gate.ready = ready
        return result
    }
    static func sessions() -> [RecoveryProtocol.Record] { RecoveryProtocol.snapshot().filter { $0.path == "session" && $0.body["resume"] as? Bool != true } }
    static func frames(_ lease: String) -> [RecoveryProtocol.Record] {
        RecoveryProtocol.snapshot().filter { $0.path == "frame" && $0.lease == lease }
    }
    @MainActor static func end(_ controller: SessionController) async {
        controller.disconnect(); NativeStream.releaseStops(); RecoveryProtocol.releaseReclaim(); RecoveryProtocol.releaseResume(); await pause(0.08)
    }
    final class Clock { var now: TimeInterval = 0 }
    static func stable(_ budget: ConnectionRecoveryBudget, _ clock: Clock, seconds: Double,
                       ready: Bool = true, frame: Bool = true, video: Bool = true) -> Int {
        var replenishments = 0
        for _ in 0..<Int((seconds * 10).rounded()) {
            clock.now += 0.1
            if budget.observe(ready: ready, frame: frame, video: video) { replenishments += 1 }
        }
        return replenishments
    }
    static func checkBudget() {
        let clock = Clock(), budget = ConnectionRecoveryBudget(clock: { clock.now })
        check(!budget.used, "new interaction has one recovery available")
        budget.consume()
        check(budget.used, "recovery consumes the budget")
        _ = budget.observe(ready: true, frame: true, video: true)
        check(stable(budget, clock, seconds: 29.9) == 0 && budget.used, "less than thirty stable seconds cannot replenish")
        check(stable(budget, clock, seconds: 0.3) == 1 && !budget.used, "thirty continuous healthy seconds replenish once")
        budget.consume(); clock.now += 87
        check(!budget.observe(ready: true) && budget.used, "eighty-seven seconds merely waiting cannot replenish")
        check(stable(budget, clock, seconds: 31, ready: false) == 0 && budget.used, "unready frames and video cannot replenish")
        check(stable(budget, clock, seconds: 31, video: false) == 0 && budget.used, "successful frames alone cannot replenish")
        check(stable(budget, clock, seconds: 31, frame: false) == 0 && budget.used, "fresh video alone cannot replenish")
        budget.reset(); budget.consume()
        _ = budget.observe(ready: true, frame: true, video: true)
        check(stable(budget, clock, seconds: 20) == 0, "partial healthy window is insufficient")
        clock.now += 0.9
        _ = budget.observe(ready: true, frame: true, video: true)
        check(stable(budget, clock, seconds: 10.5) == 0 && budget.used, "frame freshness gap restarts the stable window even when both recover")
        check(stable(budget, clock, seconds: 20) == 1 && !budget.used, "a full healthy window after the gap restores one attempt")
        budget.consume()
        _ = budget.observe(ready: true, frame: true, video: true)
        _ = stable(budget, clock, seconds: 20)
        _ = stable(budget, clock, seconds: 1.3, video: false)
        _ = budget.observe(ready: true, frame: true, video: true)
        check(stable(budget, clock, seconds: 10) == 0 && budget.used, "video freshness gap restarts the window while frames continue")
        budget.reset()
        check(!budget.used, "explicit new user interaction resets the budget")
    }
    @MainActor static func checkInputResync() async throws {
        let budget = ConnectionRecoveryBudget()
        let live = try await controller(recoveryBudget: budget, ready: true)
        let media = NativeStream.instances[0], originalOwner = sessions()[0].owner
        RecoveryProtocol.resumeError = 0
        for (index, code) in [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, 409].enumerated() {
            media.onVideo?(CGSize(width: 1280, height: 720))
            RecoveryProtocol.arm(code)
            let expected = "resume-\(index + 1)"
            await until("same-media input lease synchronization") { live.lease == expected && live.isReady }
            check(NativeStream.instances.count == 1 && media.isHealthy && sessions().count == 1, "input loss never restarts healthy media")
            check(!budget.used, "input lease sync does not consume whole-session recovery budget")
            check(frames(expected).allSatisfy { ($0.body["contacts"] as? [Any])?.isEmpty == true }, "lease confirmation never replays old touches")
        }
        let resumes = RecoveryProtocol.snapshot().filter { $0.body["resume"] as? Bool == true }
        check(resumes.count == 3 && resumes.allSatisfy { $0.owner == originalOwner }, "each independent input fault resumes the same owner")
        check(RecoveryProtocol.snapshot().filter { $0.path == "reset" }.isEmpty, "successful input recovery never stops media owner")
        await end(live)

        let beginning = try await controller(initialReady: false, emitVideo: false)
        RecoveryProtocol.resumeError = 0; RecoveryProtocol.arm(409)
        await until("input resume before phone's first video") { beginning.lease == "resume-1" }
        check(NativeStream.instances.count == 1 && !beginning.isReady && ClientDiagnostics.ends.isEmpty,
              "host-live media permits safe resume before client first frame, without declaring ready")
        await end(beginning)

        let held = try await controller(ready: true)
        RecoveryProtocol.resumeError = 0; RecoveryProtocol.holdResume = true; RecoveryProtocol.arm(NSURLErrorTimedOut)
        await until("resume held before empty confirmation") { RecoveryProtocol.heldResume != nil }
        held.submit([TouchContact(id: 90, phase: 1, x: 0.5, y: 0.5)])
        check(!held.isReady, "input remains paused while lease synchronization is pending")
        RecoveryProtocol.releaseResume()
        await until("empty confirmation") { held.lease == "resume-1" && held.isReady }
        check(frames("resume-1").allSatisfy { ($0.body["contacts"] as? [Any])?.isEmpty == true }, "pending UIKit input is not replayed")
        await end(held)

        for reason in [SessionEndReason.requested, .background, .audioInterruption] {
            let exiting = try await controller(ready: true)
            RecoveryProtocol.resumeError = 0; RecoveryProtocol.holdResume = true; RecoveryProtocol.arm(NSURLErrorTimedOut)
            await until("held resume before explicit exit") { RecoveryProtocol.heldResume != nil }
            exiting.disconnect(reason: reason); RecoveryProtocol.releaseResume()
            await until("late resumed lease cleanup") { RecoveryProtocol.snapshot().contains { $0.path == "reset" && $0.lease == "resume-1" } }
            check(exiting.lease == nil && frames("resume-1").isEmpty, "explicit exit cannot be revived by a late input lease")
            check(ClientDiagnostics.ends == [reason], "input sync preserves explicit exit reason")
            await end(exiting)
        }

        let upgrading = try await controller(ready: true); let old = NativeStream.instances[0]
        RecoveryProtocol.resumeError = 0; RecoveryProtocol.holdResume = true; RecoveryProtocol.arm(NSURLErrorTimedOut)
        await until("input resume before media failure") { RecoveryProtocol.heldResume != nil }
        old.isHealthy = false; old.onFailure?("synthetic media EOF")
        await until("one full reconnect after actual media failure") { upgrading.lease == "lease-2" && NativeStream.instances.count == 2 }
        RecoveryProtocol.releaseResume(); await pause()
        check(upgrading.lease == "lease-2" && sessions().count == 2, "late input response cannot overwrite upgraded full session")
        let cleanup = RecoveryProtocol.snapshot().filter { $0.path == "reset" && $0.lease == "resume-1" }
        check(cleanup.allSatisfy { $0.owner != sessions()[1].owner }, "late lease cleanup never targets replacement controller")
        await end(upgrading)

        let transportPause = try await controller(ready: true)
        let continuingMedia = NativeStream.instances[0]
        RecoveryProtocol.resumeError = NSURLErrorTimedOut; RecoveryProtocol.arm(NSURLErrorTimedOut)
        await until("transient control sync timeout") { RecoveryProtocol.resumeCount == 1 }
        await pause()
        check(transportPause.lease == "lease-1" && !transportPause.isReady && continuingMedia.isHealthy,
              "control transport timeout keeps healthy media and input paused")
        check(ClientDiagnostics.ends.isEmpty && sessions().count == 1, "control timeout alone does not disconnect owner")
        RecoveryProtocol.resumeError = 0
        for _ in 0..<24 {
            continuingMedia.onVideo?(CGSize(width: 1280, height: 720)); await pause(0.1)
            if transportPause.lease == "resume-2" { break }
        }
        await until("bounded status-cadence input retry") { transportPause.lease == "resume-2" && transportPause.isReady }
        check(NativeStream.instances.count == 1 && RecoveryProtocol.resumeCount == 2,
              "recovered control path resumes without busy retry or media restart")
        await end(transportPause)

        let watchdog = try await controller(ready: true)
        RecoveryProtocol.resumeError = 0; RecoveryProtocol.holdResume = true; RecoveryProtocol.arm(NSURLErrorTimedOut)
        await until("watchdog input sync held") { RecoveryProtocol.heldResume != nil }
        await until("real video watchdog remains active during input sync") { watchdog.lease == "lease-2" }
        check(sessions().count == 2, "input suspension cannot hide a true video outage")
        await end(watchdog)
    }
    @MainActor static func main() async throws {
        checkBudget()
        try await checkInputResync()
        for code in [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, 409] {
            let controller = try await controller(); let oldMedia = NativeStream.instances[0]
            controller.onReady = { ready in
                if !ready { controller.submit([TouchContact(id: 42, phase: 2, x: 0.7, y: 0.5)]) }
            }
            RecoveryProtocol.arm(code) // The next empty heartbeat fails; no renderer is forged.
            await until("new empty confirmation and media") { NativeStream.instances.count == 2 && controller.lease == "lease-2" }
            await pause()
            check(!oldMedia.isHealthy && NativeStream.instances[1].starts == 1, "old media is stopped before a new stream starts")
            check(sessions().count == 2 && sessions()[0].owner != sessions()[1].owner, "reclaim uses one fresh controller identity")
            let stops = RecoveryProtocol.snapshot().filter { $0.path == "reset" }
            check(stops.count == 1 && stops[0].body["stop"] as? Bool == true && stops[0].lease == "lease-1", "old lease only receives a bounded stop")
            check(!frames("lease-2").isEmpty && frames("lease-2").allSatisfy { ($0.body["contacts"] as? [Any])?.isEmpty == true }, "new owner receives empty confirmation and no replayed touch")
            controller.submit([TouchContact(id: 99, phase: 1, x: 0.5, y: 0.5)])
            await pause()
            check(frames("lease-2").allSatisfy { ($0.body["contacts"] as? [Any])?.isEmpty == true }, "fresh user input is gated until media and mapping readiness")
            check(!controller.isReady, "unrendered display cannot be declared ready")
            check(ClientDiagnostics.ends.isEmpty && ClientDiagnostics.counters["input_recovery_reclaimed"] == 1, "reclaimed is recorded separately from rendered recovery")
            check(ClientDiagnostics.failures.last?["connection_failure_recovery_outcome"] == 1, "reclaimed is not mislabeled fully recovered")
            check(stops.allSatisfy { $0.request.timeoutInterval == 0.65 } && frames("lease-2").allSatisfy { $0.request.timeoutInterval == 0.65 }, "650ms request bounds remain")
            oldMedia.onFailure?("late old stream failure"); oldMedia.onVideo?(CGSize(width: 1, height: 1))
            check(controller.lease == "lease-2" && ClientDiagnostics.ends.isEmpty, "old stream callbacks cannot alter the new session")
            RecoveryProtocol.arm(NSURLErrorTimedOut)
            await until("one recovery budget exhausted") { controller.lease == nil }
            check(sessions().count == 2, "internal reclaim does not reset the one-shot recovery budget")
            check(ClientDiagnostics.ends == [.frameRequestFailed], "second failure ends without another reclaim")
            await end(controller)
        }
        for stopError in [409, NSURLErrorTimedOut] {
            let controller = try await controller(); RecoveryProtocol.oldStopError = stopError
            RecoveryProtocol.arm(NSURLErrorTimedOut)
            await until("reclaim despite expired or ambiguous old stop") { controller.lease == "lease-2" && NativeStream.instances.count == 2 }
            check(sessions().count == 2, "old stop failure does not authorize takeover and still uses session admission")
            check(frames("lease-2").first.map { ($0.body["contacts"] as? [Any])?.isEmpty == true } == true, "old stop failure cannot replay input")
            await end(controller)
        }
        for failure in [409, NSURLErrorTimedOut] {
            let controller = try await controller(); RecoveryProtocol.reclaimError = failure
            RecoveryProtocol.arm(NSURLErrorTimedOut)
            await until("reclaim refusal") { ClientDiagnostics.ends.contains(.inputRecoveryFailed) }
            check(controller.lease == nil && sessions().count == 2, "busy or unreachable host cannot be forcefully claimed")
            check(frames("lease-2").isEmpty && NativeStream.instances.count == 1, "failed admission cannot send input or start media")
            await end(controller)
        }
        let unconfirmed = try await controller(); RecoveryProtocol.confirmationError = 409
        RecoveryProtocol.arm(NSURLErrorNetworkConnectionLost)
        await until("empty confirmation failure") { ClientDiagnostics.ends.contains(.inputRecoveryFailed) }
        check(unconfirmed.lease == nil && NativeStream.instances.count == 1, "failed empty confirmation never starts recovered media")
        await until("failed claimed lease released") { RecoveryProtocol.snapshot().contains { $0.path == "reset" && $0.lease == "lease-2" } }
        check(RecoveryProtocol.snapshot().filter { $0.path == "reset" && $0.lease == "lease-2" }.allSatisfy { $0.body["stop"] as? Bool == true }, "failed confirmation releases the newly claimed lease")
        await end(unconfirmed)

        let delayed = try await controller(); NativeStream.holdStops = true; RecoveryProtocol.arm(NSURLErrorTimedOut)
        await until("old stop pending") { !NativeStream.pendingStops.isEmpty }
        await pause(1.35)
        check(ClientDiagnostics.ends.isEmpty && sessions().count == 1, "old 1.2s video watchdog cannot kill an in-progress recovery")
        NativeStream.releaseStops()
        await until("delayed stop completion then reclaim") { delayed.lease == "lease-2" && NativeStream.instances.count == 2 }
        check(ClientDiagnostics.ends.isEmpty, "waiting for actual old media stop does not double-disconnect")
        await end(delayed)

        for reason in [SessionEndReason.requested, .background, .audioInterruption] {
            let exiting = try await controller(); RecoveryProtocol.holdReclaim = true; RecoveryProtocol.arm(NSURLErrorTimedOut)
            await until("held new claim") { RecoveryProtocol.heldReclaim != nil }
            exiting.disconnect(reason: reason)
            RecoveryProtocol.releaseReclaim()
            await until("late lease stopped") { RecoveryProtocol.snapshot().contains { $0.path == "reset" && $0.lease == "lease-2" } }
            check(exiting.lease == nil && NativeStream.instances.count == 1, "explicit exit cannot be revived by late claim response")
            check(frames("lease-2").isEmpty, "late claim cleanup does not send confirmation or input")
            check(ClientDiagnostics.ends == [reason], "explicit exit preserves its end reason")
            await end(exiting)
        }
        let replaced = try await controller(); let oldMedia = NativeStream.instances[0]
        NativeStream.holdStops = true; RecoveryProtocol.arm(NSURLErrorTimedOut)
        await until("stop pending before user reconnect") { !NativeStream.pendingStops.isEmpty }
        replaced.disconnect()
        let newLayer = AVSampleBufferDisplayLayer(); layers.append(newLayer)
        replaced.connect(try connection(), layer: newLayer)
        NativeStream.releaseStops()
        await until("explicit new connection") { replaced.lease == "lease-2" && NativeStream.instances.count == 2 }
        oldMedia.onFailure?("late prior failure")
        await pause()
        check(sessions().count == 2 && replaced.lease == "lease-2", "late stop completion cannot start a duplicate reclaim over a user connection")
        check(ClientDiagnostics.ends == [.requested], "old callbacks do not end explicitly reconnected session")
        await end(replaced)
        // These branches explicitly inject readiness and a fake monotonic clock.
        // They validate policy and transitions, not real renderer or network quality.
        let stableClock = Clock(), renewableBudget = ConnectionRecoveryBudget(clock: { stableClock.now })
        let renewable = try await controller(recoveryBudget: renewableBudget, ready: true)
        RecoveryProtocol.arm(NSURLErrorTimedOut)
        await until("first recovery reaches injected readiness") { renewable.lease == "lease-2" && renewable.isReady }
        check(renewableBudget.used, "first automatic recovery consumes shared budget")
        _ = renewableBudget.observe(ready: true, frame: true, video: true)
        check(stable(renewableBudget, stableClock, seconds: 87) == 1 && !renewableBudget.used,
              "eighty-seven seconds of explicit continuous healthy events restore exactly one attempt")
        RecoveryProtocol.arm(NSURLErrorTimedOut)
        await until("later independent failure recovers") { renewable.lease == "lease-3" && renewable.isReady }
        check(sessions().count == 3 && renewableBudget.used && ClientDiagnostics.ends.isEmpty,
              "a later independent failure can reclaim after a stable interval")
        RecoveryProtocol.arm(NSURLErrorTimedOut)
        await until("rapid third failure stops") { renewable.lease == nil }
        check(sessions().count == 3, "rapid repeated failures do not create a reconnect loop")
        await end(renewable)

        let streamFailed = try await controller(ready: true)
        let failedMedia = NativeStream.instances[0]
        failedMedia.isHealthy = false; failedMedia.onFailure?("synthetic transport EOF")
        await until("stream failure recovery") { streamFailed.lease == "lease-2" && streamFailed.isReady }
        check(sessions().count == 2 && ClientDiagnostics.ends.isEmpty, "established media failure shares full recovery")
        check(frames("lease-2").allSatisfy { ($0.body["contacts"] as? [Any])?.isEmpty == true }, "media-triggered recovery confirms empty input")
        await end(streamFailed)

        let audioOnly = try await controller(initialReady: false, emitVideo: false)
        let audioOnlyMedia = NativeStream.instances[0]
        for _ in 0..<105 {
            audioOnlyMedia.recordMediaActivity(); await pause(0.1)
            if audioOnly.lease == nil { break }
        }
        check(audioOnly.lease == nil && ClientDiagnostics.ends.contains(.firstVideoTimeout),
              "continuous audio cannot bypass the ten-second first-video requirement")
        await end(audioOnly)

        let staticVideo = try await controller(ready: true)
        let staticMedia = NativeStream.instances[0]
        for _ in 0..<16 { staticMedia.recordMediaActivity(); await pause(0.1) }
        check(staticVideo.lease == "lease-1" && staticVideo.isReady && sessions().count == 1,
              "static video with continuing valid audio survives the 1.2-second watchdog")
        await until("complete media silence still recovers") { staticVideo.lease == "lease-2" }
        staticMedia.recordMediaActivity()
        check(NativeStream.instances[1].mediaIdleInterval() != nil && !staticMedia.isHealthy,
              "retired stream activity cannot revive the old epoch")
        await end(staticVideo)

        let watchdog = try await controller(ready: true)
        await until("video watchdog recovery") { watchdog.lease == "lease-2" && watchdog.isReady }
        check(sessions().count == 2 && ClientDiagnostics.ends.isEmpty, "established video watchdog shares recovery instead of disconnecting")
        await end(watchdog)

        let startupFailure = try await controller(initialReady: false)
        NativeStream.instances[0].isHealthy = false
        NativeStream.instances[0].onFailure?("synthetic first stream failure")
        await until("startup stream failure remains terminal") { startupFailure.lease == nil }
        check(sessions().count == 1 && ClientDiagnostics.ends == [.streamFailure], "never-ready media failure does not auto-loop")
        await end(startupFailure)
        print("Passed \(checks) reclaim and stable-budget checks (offline URLProtocol, fake clock and injected readiness; no device or sockets).")
    }
}
