import Foundation
import AVFoundation

/// UI and touch lifecycle live on the main queue. Only one /frame can be in flight.
final class SessionController: NSObject, URLSessionTaskDelegate {
    private(set) var connection: Connection?
    private(set) var lease: String?
    private var owner = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    private var http: URLSession!
    private var stream: NativeStream?
    private var diagnostics: ClientDiagnostics?
    private var queue = FrameQueue()
    private var active: [TouchContact] = []
    private var frameTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var recoveringInput = false
    private var resyncingInput = false
    private var inputEpoch = UUID()
    private var inputResyncTask: Task<Void, Never>?
    private var inputResyncFailure: (ConnectionFailure, [String: Double])?
    private var lastInputResync = Date.distantPast
    private var awaitingRecoveredMedia = false
    private var mediaStopTask: Task<Void, Never>?
    private var recoveryFields: [String: Double]?
    private var recoveryBeganUptime: TimeInterval?
    private let recoveryBudget: ConnectionRecoveryBudget
    private let displayReady: (AVSampleBufferDisplayLayer) -> Bool
    private var attemptedInputRecovery: Bool { recoveryBudget.used }
    private var hasBeenReady = false
    private var timer: Timer?
    private var lastVideo = -TimeInterval.infinity
    private var connectedAt = Date.distantPast
    private var lastStatus = Date.distantPast
    private var epoch = UUID()
    private weak var layer: AVSampleBufferDisplayLayer?
    private var receivedVideo = false
    private var reportedReady = false
    private var clientRectSource: String?
    private var mappingVerified: Bool { clientRectSource == "configured" }
    var isReady: Bool { reportedReady && lease != nil && !recoveringInput && !resyncingInput }
    var onState: ((String) -> Void)?
    var onReady: ((Bool) -> Void)?
    var onVideoSize: ((CGSize) -> Void)?
    var onClientRect: ((CGRect) -> Void)?
    var onDisconnected: ((String?) -> Void)?

    override convenience init() { self.init(configuration: .ephemeral) }
    init(configuration: URLSessionConfiguration,
         recoveryBudget: ConnectionRecoveryBudget = ConnectionRecoveryBudget(),
         displayReady: @escaping (AVSampleBufferDisplayLayer) -> Bool = SessionController.rendererReady) {
        self.recoveryBudget = recoveryBudget; self.displayReady = displayReady
        super.init()
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 5
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        http = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
    }
    static func rendererReady(_ layer: AVSampleBufferDisplayLayer) -> Bool {
        if #available(iOS 17.4, *) { return layer.isReadyForDisplay }
        return layer.sampleBufferRenderer.status == .rendering
    }
    func connect(_ connection: Connection, layer: AVSampleBufferDisplayLayer) {
        guard lease == nil, startTask == nil else { return }
        self.connection = connection; self.layer = layer
        recoveringInput = false; awaitingRecoveredMedia = false
        resyncingInput = false; inputEpoch = UUID(); inputResyncTask = nil; inputResyncFailure = nil
        recoveryBudget.reset(); hasBeenReady = false
        recoveryFields = nil; recoveryBeganUptime = nil
        let diagnostics = ClientDiagnostics()
        self.diagnostics = diagnostics
        owner = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let currentOwner = owner
        let current = UUID(); epoch = current
        onState?("正在连接 Mac…")
        let mediaBarrier = mediaStopTask
        startTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await mediaBarrier?.value
            guard current == self.epoch else { return }
            let requestStart = ProcessInfo.processInfo.systemUptime
            do {
                let reply = try await self.post("session", body: [:], connection: connection, lease: nil, owner: currentOwner)
                guard current == self.epoch, !Task.isCancelled else {
                    // An exit during /session must also release a late-granted lease.
                    if let lease = reply["lease"] as? String { self.sendStop(connection: connection, lease: lease, owner: currentOwner) }
                    return
                }
                guard let lease = reply["lease"] as? String, !lease.isEmpty else { throw SessionError.invalidResponse }
                self.lease = lease
                self.startTask = nil
                self.connectedAt = Date()
                self.lastVideo = -.infinity
                self.receivedVideo = false; self.reportedReady = false; self.clientRectSource = nil
                self.onState?("等待窗口画面…")
                self.startHeartbeat()
                self.startMedia(connection: connection, lease: lease, layer: layer, diagnostics: diagnostics, epoch: current)
            } catch {
                guard current == self.epoch else { return }
                self.startTask = nil
                let failure = ConnectionFailure(error, operation: .session,
                    elapsed: ProcessInfo.processInfo.systemUptime - requestStart, requestTimeout: Connection.requestTimeout)
                diagnostics.recordConnectionFailure(failure.diagnosticFields)
                self.disconnect(reason: .sessionRequestFailed, message: failure.message)
            }
        }
    }
    func submit(_ contacts: [TouchContact]) {
        guard lease != nil, !recoveringInput, !resyncingInput, !awaitingRecoveredMedia else { return }
        active = contacts.filter { $0.phase != 3 }.map { var c = $0; c.phase = 2; return c }
        guard queue.append(contacts) else {
            disconnect(reason: .inputBacklog, message: "触控传输积压，已释放全部触点。请重新连接。")
            return
        }
        diagnostics?.gauge("input_pending_frames", Double(queue.frames.count))
        diagnostics?.gauge("input_active_contacts", Double(active.count))
        pump()
    }
    func releaseTouches() {
        active.removeAll()
        guard lease != nil, !recoveringInput, !resyncingInput else { return }
        queue.releaseAll()
        pump()
    }
    func disconnect(reason: SessionEndReason? = nil, message: String? = nil) {
        let oldConnection = connection, oldLease = lease, oldOwner = owner
        var fields: [String: Double] = [
            "session_end_received_video": receivedVideo ? 1 : 0,
            "session_end_stream_healthy": stream?.isHealthy == true ? 1 : 0,
            "session_end_has_lease": lease == nil ? 0 : 1,
            "session_end_recovering_input": recoveringInput || resyncingInput ? 1 : 0,
            "session_end_attempted_input_recovery": attemptedInputRecovery ? 1 : 0,
            "session_end_active_contacts": Double(active.count),
            "session_end_pending_frames": Double(queue.frames.count)
        ]
        if receivedVideo { fields["session_end_video_idle_ms"] = (ProcessInfo.processInfo.systemUptime - lastVideo) * 1000 }
        if awaitingRecoveredMedia, let original = recoveryFields,
           reason != .requested, reason != .background, reason != .audioInterruption, message != nil {
            var failure = original
            failure["connection_failure_recovery_outcome"] = 3
            failure["connection_failure_recovery_elapsed_ms"] =
                (ProcessInfo.processInfo.systemUptime - (recoveryBeganUptime ?? ProcessInfo.processInfo.systemUptime)) * 1000
            diagnostics?.recordConnectionFailure(failure)
        }
        diagnostics?.recordSessionEnd(reason ?? (message == nil ? .requested : .unspecifiedFailure), fields: fields)
        epoch = UUID(); inputEpoch = UUID()
        resyncingInput = false; inputResyncTask = nil; inputResyncFailure = nil
        timer?.invalidate(); timer = nil
        // Do not cancel session acquisition: a late granted lease is explicitly released above.
        startTask = nil
        frameTask?.cancel(); frameTask = nil
        statusTask?.cancel(); statusTask = nil
        // Let bounded acquisition finish so any late-granted lease can be explicitly stopped.
        recoveryTask = nil; recoveringInput = false; awaitingRecoveredMedia = false
        recoveryFields = nil; recoveryBeganUptime = nil
        let finalState = message == nil ? "stopped" : "connection_failed"
        if stream != nil { retireMedia(reason: finalState) }
        else { diagnostics?.finish(finalState) }
        diagnostics = nil
        active.removeAll(); queue.clear()
        lease = nil; connection = nil
        receivedVideo = false; reportedReady = false
        onReady?(false)
        if let oldConnection, let oldLease { sendStop(connection: oldConnection, lease: oldLease, owner: oldOwner) }
        onDisconnected?(message)
    }
    private func startHeartbeat() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
        tick()
    }
    private func tick() {
        guard lease != nil, !recoveringInput else { return }
        let now = Date()
        // A static captured image need not produce changed video frames. Require
        // silence of both validated media kinds; first-video readiness stays separate.
        // Completely static sources without audio still need a capture heartbeat.
        let uptime = ProcessInfo.processInfo.systemUptime
        if receivedVideo && uptime - lastVideo > 1.2 && (stream?.mediaIdleInterval(at: uptime) ?? .infinity) > 1.2 {
            recoverMediaOrDisconnect(reason: .videoWatchdog, message: "影音串流已中断，触点已释放。请重新连接。")
            return
        }
        if !receivedVideo && now.timeIntervalSince(connectedAt) > 10 {
            disconnect(reason: .firstVideoTimeout, message: "未收到窗口画面，请确认 Mac 正在采集所选窗口。")
            return
        }
        if !resyncingInput, receivedVideo && !reportedReady, let layer {
            let ready = displayReady(layer)
            if ready && mappingVerified {
                reportedReady = true; hasBeenReady = true
                if awaitingRecoveredMedia {
                    awaitingRecoveredMedia = false
                    if var fields = recoveryFields {
                        fields["connection_failure_recovery_outcome"] = 2
                        fields["connection_failure_recovery_elapsed_ms"] =
                            (ProcessInfo.processInfo.systemUptime - (recoveryBeganUptime ?? ProcessInfo.processInfo.systemUptime)) * 1000
                        diagnostics?.recordConnectionFailure(fields)
                    }
                    recoveryFields = nil; recoveryBeganUptime = nil
                    diagnostics?.count("input_recovery_succeeded")
                    onState?("连接已恢复，请重新按下控件")
                } else { onState?("已连接") }
                onReady?(true)
            }
            else if ready {
                onState?(clientRectSource == "whole_window_unverified" ? "画面已连接 · 仅观看" : "画面已连接 · 等待触控区域")
            }
        }
        observeRecoveryStability()
        if resyncingInput {
            // A paused input path does not silence the independent media watchdog.
            // Reuse the existing status cadence for bounded retries, never a busy loop.
            if inputResyncTask == nil, now.timeIntervalSince(lastInputResync) >= 2,
               let connection, let lease, let pending = inputResyncFailure {
                resyncInput(connection: connection, lease: lease, failure: pending.0, fields: pending.1)
            }
            return
        }
        if queue.frames.isEmpty && frameTask == nil {
            _ = queue.append(active)
            pump()
        }
        if now.timeIntervalSince(lastStatus) >= 2 && statusTask == nil {
            lastStatus = now
            fetchStatus()
        }
    }
    private func pump() {
        guard !recoveringInput, !resyncingInput, frameTask == nil, let connection, let lease else { return }
        let contacts: [TouchContact]
        if let queued = queue.pop() { contacts = queued }
        else { return }
        let current = epoch, currentInput = inputEpoch, currentOwner = owner
        frameTask = Task { @MainActor [weak self] in
            guard let self, current == self.epoch, currentInput == self.inputEpoch else { return }
            let requestTimeout: TimeInterval = 0.65 // Host safety remains independent: it may already have revoked the owner.
            let requestStart = ProcessInfo.processInfo.systemUptime
            do {
                // Take at actual request construction, not when an async task was
                // scheduled: a pause/orientation change may have cleared it meanwhile.
                let encoded = try JSONEncoder().encode(FrameBody(contacts: contacts))
                var request = connection.request(path: "frame", owner: currentOwner, lease: lease, body: encoded)
                request.timeoutInterval = requestTimeout
                _ = try await self.perform(request)
                guard current == self.epoch, currentInput == self.inputEpoch else { return }
                self.diagnostics?.observe("frame_http_roundtrip_ms", (ProcessInfo.processInfo.systemUptime - requestStart) * 1000)
                self.frameTask = nil
                self.observeRecoveryStability(frame: true)
                self.pump()
            } catch {
                guard current == self.epoch, currentInput == self.inputEpoch else { return }
                self.frameTask = nil
                let failure = ConnectionFailure(error, operation: .frame,
                    elapsed: ProcessInfo.processInfo.systemUptime - requestStart, requestTimeout: requestTimeout)
                var failureFields = failure.diagnosticFields
                failureFields["connection_failure_received_video"] = self.receivedVideo ? 1 : 0
                if self.receivedVideo {
                    failureFields["connection_failure_video_idle_ms"] = (ProcessInfo.processInfo.systemUptime - self.lastVideo) * 1000
                }
                if failure.permitsInputLeaseRecovery && self.canResyncInput {
                    self.resyncInput(connection: connection, lease: lease, failure: failure, fields: failureFields)
                } else if failure.permitsInputLeaseRecovery && self.canRecoverInput {
                    self.recoverInput(connection: connection, lease: lease, failure: failure, fields: failureFields)
                } else {
                    failureFields["connection_failure_recovery_outcome"] = 0
                    self.diagnostics?.recordConnectionFailure(failureFields)
                    self.disconnect(reason: .frameRequestFailed, message: failure.message)
                }
            }
        }
    }
    private var canResyncInput: Bool {
        !recoveringInput && !resyncingInput && !awaitingRecoveredMedia && stream?.isHealthy == true
    }
    private func resyncInput(connection: Connection, lease oldLease: String,
                             failure: ConnectionFailure, fields: [String: Double]) {
        guard inputResyncTask == nil else { return }
        let current = epoch, currentOwner = owner
        if !resyncingInput {
            inputEpoch = UUID(); resyncingInput = true
            active.removeAll(); queue.clear(); reportedReady = false
            frameTask?.cancel(); frameTask = nil
            statusTask?.cancel(); statusTask = nil
            onReady?(false)
            inputResyncFailure = (failure, fields)
            diagnostics?.count("input_lease_resync_started")
        }
        let currentInput = inputEpoch
        lastInputResync = Date()
        onState?("触控短暂中断，正在同步；影音继续播放…")
        var pending = fields; pending["connection_failure_recovery_outcome"] = 1
        diagnostics?.recordConnectionFailure(pending)
        let began = ProcessInfo.processInfo.systemUptime
        inputResyncTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let config = self.http.configuration.copy() as! URLSessionConfiguration
            config.timeoutIntervalForRequest = 0.65; config.timeoutIntervalForResource = 0.65
            let resyncHTTP = URLSession(configuration: config, delegate: self, delegateQueue: .main)
            defer { resyncHTTP.finishTasksAndInvalidate() }
            do {
                var request = connection.request(path: "session", owner: currentOwner, lease: oldLease,
                    body: try JSONSerialization.data(withJSONObject: ["resume": true]))
                request.timeoutInterval = 0.65
                let result = try await self.perform(request, using: resyncHTTP)
                guard result["resumed"] as? Bool == true, let newLease = result["lease"] as? String,
                      !newLease.isEmpty, newLease != oldLease else { throw SessionError.invalidResponse }
                guard current == self.epoch else {
                    self.sendStop(connection: connection, lease: newLease, owner: currentOwner)
                    return
                }
                // A superseded input attempt must not stop its still-live media owner.
                guard currentInput == self.inputEpoch else { return }
                self.lease = newLease
                var confirm = connection.request(path: "frame", owner: currentOwner, lease: newLease,
                    body: try JSONEncoder().encode(FrameBody(contacts: [])))
                confirm.timeoutInterval = 0.65
                _ = try await self.perform(confirm, using: resyncHTTP)
                guard current == self.epoch, currentInput == self.inputEpoch else { return }
                let retiredHTTP = self.http
                self.http = URLSession(configuration: self.http.configuration.copy() as! URLSessionConfiguration,
                                       delegate: self, delegateQueue: .main)
                retiredHTTP?.finishTasksAndInvalidate()
                self.inputResyncTask = nil; self.resyncingInput = false; self.inputResyncFailure = nil
                var succeeded = fields; succeeded["connection_failure_recovery_outcome"] = 2
                succeeded["connection_failure_recovery_elapsed_ms"] = (ProcessInfo.processInfo.systemUptime - began) * 1000
                self.diagnostics?.recordConnectionFailure(succeeded)
                self.diagnostics?.count("input_lease_resync_succeeded")
                self.tick() // Real media/mapping readiness still gates UIKit input.
            } catch {
                guard current == self.epoch, currentInput == self.inputEpoch else { return }
                self.inputResyncTask = nil
                var failed = pending
                let nsError = error as NSError
                failed["connection_failure_recovery_error_code"] = Double(nsError.code)
                failed["connection_failure_recovery_url_error"] = nsError.domain == NSURLErrorDomain ? 1 : 0
                self.diagnostics?.recordConnectionFailure(failed)
                let missingOwner: Bool
                if case SessionError.http(409, "session_not_owned") = error { missingOwner = true }
                else { missingOwner = false }
                if missingOwner || self.stream?.isHealthy != true {
                    self.resyncingInput = false; self.inputResyncFailure = nil
                    if self.canRecoverInput {
                        self.recoverInput(connection: connection, lease: self.lease ?? oldLease, failure: failure, fields: fields)
                    } else { self.disconnect(reason: .inputRecoveryFailed, message: error.localizedDescription) }
                } else if nsError.domain != NSURLErrorDomain {
                    self.disconnect(reason: .inputRecoveryFailed, message: error.localizedDescription)
                } else {
                    // Transient control transport loss cannot itself kill healthy AV.
                    // Stay empty and retry one bounded sync on the existing 2s cadence.
                    self.onState?("影音继续播放 · 触控暂停，等待连接恢复…")
                }
            }
        }
    }
    private var canRecoverInput: Bool {
        !attemptedInputRecovery && !recoveringInput && !awaitingRecoveredMedia && layer != nil && hasBeenReady
    }
    private func observeRecoveryStability(frame: Bool = false, video: Bool = false) {
        if recoveryBudget.observe(ready: isReady && !awaitingRecoveredMedia, frame: frame, video: video) {
            diagnostics?.count("input_recovery_budget_replenished")
        }
    }
    private func recoverMediaOrDisconnect(reason: SessionEndReason, message: String) {
        guard canRecoverInput, let connection, let lease else {
            disconnect(reason: awaitingRecoveredMedia ? .inputRecoveryFailed : reason, message: message)
            return
        }
        let error = NSError(domain: "local.maciphonestream.client.mediaRecovery", code: reason.rawValue,
                            userInfo: [NSLocalizedDescriptionKey: message])
        let failure = ConnectionFailure(error, operation: .stream, elapsed: 0, requestTimeout: 0)
        var fields = failure.diagnosticFields
        fields["connection_failure_received_video"] = receivedVideo ? 1 : 0
        if receivedVideo { fields["connection_failure_video_idle_ms"] = (ProcessInfo.processInfo.systemUptime - lastVideo) * 1000 }
        recoverInput(connection: connection, lease: lease, failure: failure, fields: fields)
    }
    /// A stop barrier also covers a user disconnect followed immediately by connect.
    /// Old media must finish flushing the shared display layer before its replacement starts.
    private func retireMedia(reason: String) {
        guard let oldStream = stream else { return }
        stream = nil
        let previous = mediaStopTask
        mediaStopTask = Task { @MainActor in
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                oldStream.stop(reason: reason) { continuation.resume() }
            }
            await previous?.value
        }
    }
    private func startMedia(connection: Connection, lease: String, layer: AVSampleBufferDisplayLayer,
                            diagnostics: ClientDiagnostics, epoch current: UUID) {
        let stream = NativeStream(layer: layer, diagnostics: diagnostics)
        self.stream = stream
        stream.onVideo = { [weak self] size in
            guard let self, self.epoch == current else { return }
            self.lastVideo = ProcessInfo.processInfo.systemUptime; self.receivedVideo = true
            self.observeRecoveryStability(video: true)
            self.onVideoSize?(size)
        }
        stream.onAudioError = { [weak self] in
            guard let self, self.epoch == current else { return }
            self.onState?("画面已连接 · 音频不可用")
        }
        stream.onFailure = { [weak self] message in
            guard let self, self.epoch == current else { return }
            self.recoverMediaOrDisconnect(reason: .streamFailure, message: message)
        }
        stream.start(connection.request(path: "native/stream", owner: owner, lease: lease))
    }
    private func recoverInput(connection: Connection, lease oldLease: String,
                              failure: ConnectionFailure, fields: [String: Double]) {
        guard let layer else { disconnect(reason: .inputRecoveryFailed, message: failure.message); return }
        let oldOwner = owner
        let current = UUID(); epoch = current // Retire every old frame/status/media callback.
        inputEpoch = UUID(); resyncingInput = false; inputResyncTask = nil; inputResyncFailure = nil
        recoveryBudget.consume(); recoveringInput = true; awaitingRecoveredMedia = false
        active.removeAll(); queue.clear(); reportedReady = false
        timer?.invalidate(); timer = nil
        frameTask?.cancel(); frameTask = nil
        statusTask?.cancel(); statusTask = nil
        onReady?(false)
        onState?("连接短暂中断，正在重新连接…")
        var pending = fields
        pending["connection_failure_recovery_outcome"] = 1
        diagnostics?.recordConnectionFailure(pending)
        diagnostics?.gauge("input_pending_frames", 0)
        diagnostics?.gauge("input_active_contacts", 0)
        recoveryFields = fields; recoveryBeganUptime = ProcessInfo.processInfo.systemUptime
        retireMedia(reason: "recovering_connection")
        let mediaBarrier = mediaStopTask
        recoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await mediaBarrier?.value
            guard current == self.epoch else { return }
            // A fresh HTTP session avoids inheriting the failed pooled connection.
            // Every operation remains bounded; no touch POST is ever replayed.
            let config = self.http.configuration.copy() as! URLSessionConfiguration
            config.timeoutIntervalForRequest = 0.65
            config.timeoutIntervalForResource = 0.65
            let recoveryHTTP = URLSession(configuration: config, delegate: self, delegateQueue: .main)
            defer { recoveryHTTP.finishTasksAndInvalidate() }
            do {
                let stopBody = try JSONSerialization.data(withJSONObject: ["stop": true])
                var stop = connection.request(path: "reset", owner: oldOwner, lease: oldLease, body: stopBody)
                stop.timeoutInterval = 0.65
                // Timeout/409 does not mean released. The fresh /session below must
                // independently win ownership; controller_busy safely ends this attempt.
                _ = try? await self.perform(stop, using: recoveryHTTP)
                guard current == self.epoch else { return }
                let newOwner = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
                var claim = connection.request(path: "session", owner: newOwner, lease: nil,
                    body: try JSONSerialization.data(withJSONObject: [:]))
                claim.timeoutInterval = 0.65
                let reply = try await self.perform(claim, using: recoveryHTTP)
                guard let newLease = reply["lease"] as? String, !newLease.isEmpty else { throw SessionError.invalidResponse }
                guard current == self.epoch else {
                    self.sendStop(connection: connection, lease: newLease, owner: newOwner)
                    return
                }
                self.owner = newOwner; self.lease = newLease
                let freshDiagnostics = ClientDiagnostics()
                self.diagnostics = freshDiagnostics
                freshDiagnostics.recordConnectionFailure(pending)
                let empty = try JSONEncoder().encode(FrameBody(contacts: []))
                var confirm = connection.request(path: "frame", owner: newOwner, lease: newLease, body: empty)
                confirm.timeoutInterval = 0.65
                _ = try await self.perform(confirm, using: recoveryHTTP)
                guard current == self.epoch else { return }
                let replacementHTTP = URLSession(configuration: self.http.configuration.copy() as! URLSessionConfiguration,
                    delegate: self, delegateQueue: .main)
                let retiredHTTP = self.http
                self.http = replacementHTTP
                retiredHTTP?.finishTasksAndInvalidate()
                self.recoveryTask = nil; self.recoveringInput = false; self.awaitingRecoveredMedia = true
                self.connectedAt = Date(); self.lastVideo = -.infinity; self.lastStatus = .distantPast
                self.receivedVideo = false; self.clientRectSource = nil
                freshDiagnostics.count("input_recovery_reclaimed")
                self.startMedia(connection: connection, lease: newLease, layer: layer,
                                diagnostics: freshDiagnostics, epoch: current)
                // Empty heartbeats maintain the new owner while awaiting fresh video
                // and mapping; submit remains gated until actual rendering is ready.
                self.startHeartbeat()
            } catch {
                guard current == self.epoch else { return }
                self.recoveryTask = nil
                var failed = fields
                let error = error as NSError
                failed["connection_failure_recovery_outcome"] = 3
                failed["connection_failure_recovery_elapsed_ms"] =
                    (ProcessInfo.processInfo.systemUptime - (self.recoveryBeganUptime ?? ProcessInfo.processInfo.systemUptime)) * 1000
                failed["connection_failure_recovery_url_error"] = error.domain == NSURLErrorDomain ? 1 : 0
                failed["connection_failure_recovery_error_code"] = Double(error.code)
                self.diagnostics?.recordConnectionFailure(failed)
                self.diagnostics?.count("input_recovery_failed")
                self.disconnect(reason: .inputRecoveryFailed, message: error.localizedDescription)
            }
        }
    }
    private func fetchStatus() {
        guard let connection, let lease else { return }
        let current = epoch, currentInput = inputEpoch
        statusTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if current == self.epoch, currentInput == self.inputEpoch { self.statusTask = nil } }
            do {
                let result = try await self.perform(connection.request(path: "status", owner: self.owner, lease: lease))
                guard current == self.epoch, currentInput == self.inputEpoch, !self.recoveringInput, !self.resyncingInput, self.lease == lease else { return }
                if let native = result["native_video"] as? [String: Any],
                   let rect = native["client_rect_normalized"] as? [String: Double],
                   let x = rect["x"], let y = rect["y"], let w = rect["width"], let h = rect["height"],
                   x.isFinite, y.isFinite, w.isFinite, h.isFinite,
                   x >= 0, y >= 0, w > 0, h > 0, x + w <= 1, y + h <= 1 {
                    self.onClientRect?(CGRect(x: x, y: y, width: w, height: h))
                    self.clientRectSource = native["client_rect_source"] as? String
                }
            } catch { /* The heartbeat and video paths are authoritative for connection health. */ }
        }
    }
    private func sendStop(connection: Connection, lease: String, owner: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = try? await self.post("reset", body: ["stop": true], connection: connection, lease: lease, owner: owner)
        }
    }
    private func post(_ path: String, body: [String: Any], connection: Connection, lease: String?, owner: String) async throws -> [String: Any] {
        try await perform(connection.request(path: path, owner: owner, lease: lease, body: JSONSerialization.data(withJSONObject: body)))
    }
    private func perform(_ request: URLRequest, using session: URLSession? = nil) async throws -> [String: Any] {
        let (data, response) = try await (session ?? http!).data(for: request)
        guard data.count <= 128 * 1024, let response = response as? HTTPURLResponse else { throw SessionError.invalidResponse }
        let result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard response.statusCode == 200 else {
            throw SessionError.http(response.statusCode, result["error"] as? String ?? "request_failed")
        }
        return result
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    private struct FrameBody: Encodable {
        let contacts: [TouchContact]
    }
}
