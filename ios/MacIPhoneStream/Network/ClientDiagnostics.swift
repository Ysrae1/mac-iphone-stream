import Foundation
import Darwin

enum AudioDiagnosticEvent: Int {
    case emptyArrival = 1
    case sourceGap = 2
    case overflow = 3
}

/// Numeric, per-session diagnostics only. File I/O never runs on the URLSession or audio callback queue.
final class ClientDiagnostics {
    // Shared across connection instances, so an old session's queued work cannot
    // replace the newest failure after a reconnect.
    private static let failureWriter = DispatchQueue(label: "local.maciphonestream.client.last-failure", qos: .utility)
    private static var newestFailureSessionUptime = -Double.infinity // failureWriter only
    private static var newestFailureUptime = -Double.infinity // failureWriter only
    private static var newestEndedSessionUptime = -Double.infinity // failureWriter only
    private static let failureFields: Set<String> = [
        "connection_failure_operation", "connection_failure_url_error", "connection_failure_code",
        "connection_failure_timeout", "connection_failure_elapsed_ms", "connection_failure_request_timeout_ms",
        "connection_failure_received_video", "connection_failure_video_idle_ms", "connection_failure_receive_idle_ms",
        "connection_failure_recovery_outcome", "connection_failure_recovery_elapsed_ms",
        "connection_failure_recovery_url_error", "connection_failure_recovery_error_code"
    ]
    private static let sessionEndFields: Set<String> = [
        "session_end_received_video", "session_end_video_idle_ms", "session_end_stream_healthy",
        "session_end_has_lease", "session_end_recovering_input", "session_end_attempted_input_recovery",
        "session_end_active_contacts", "session_end_pending_frames"
    ]
    private let lock = NSLock()
    private var counters: [String: Double] = [:]
    private var gauges: [String: Double] = [:]
    private var samples: [String: [String: Double]] = [:]
    private var recentAudioEvents: [[String: Double]] = []
    private var audioEventSequence: UInt64 = 0
    private var recentAVPathEvents: [[String: Double]] = []
    private var avPathEventSequence: UInt64 = 0
    private var sourcePTS: [String: Double] = [:]
    private var receivedAVPackets: Double = 0
    private var failureRecord: [String: Double] = [:]
    private var videoFormat: [String: String] = [:]
    private var state = "running"
    private var recordedSessionEnd = false
    private let started = ProcessInfo.processInfo.systemUptime
    private let writer = DispatchQueue(label: "local.maciphonestream.client.diagnostics", qos: .utility)
    private let cacheDirectory: URL?
    private var timer: DispatchSourceTimer?

    init(cacheDirectory: URL? = nil, startsTimer: Bool = true) {
        self.cacheDirectory = cacheDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        guard startsTimer else { return }
        let timer = DispatchSource.makeTimerSource(queue: writer)
        timer.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.writeSnapshot() }
        self.timer = timer
        timer.resume()
    }
    func count(_ key: String, by value: Double = 1) {
        guard value.isFinite else { return }
        lock.lock()
        let total = counters[key, default: 0] + value
        if total.isFinite { counters[key] = total }
        lock.unlock()
    }
    func gauge(_ key: String, _ value: Double) {
        guard value.isFinite else { return }
        lock.lock(); gauges[key] = value; lock.unlock()
    }
    /// Format labels only; no image data, connection identifiers, or payloads.
    func setVideoFormat(_ values: [String: String]) {
        lock.lock(); videoFormat = values; lock.unlock()
    }
    /// Keep one multi-field clock observation coherent in the periodic JSON snapshot.
    func setGauges(_ values: [String: Double]) {
        lock.lock()
        for (key, value) in values where value.isFinite { gauges[key] = value }
        lock.unlock()
    }
    /// Retain the most recent failure independently of reconnecting snapshots.
    /// Only fixed numeric fields are accepted; NSError metadata and request data
    /// must never enter this archive. Completion runs on the archive writer.
    func recordConnectionFailure(_ fields: [String: Double], completion: (() -> Void)? = nil) {
        var record = fields.filter { Self.failureFields.contains($0.key) && $0.value.isFinite }
        guard !record.isEmpty else { completion?(); return }
        lock.lock()
        // Controller termination is a synchronous barrier. A later stream
        // completion (including cancellation/-1004) cannot replace its cause.
        guard !recordedSessionEnd else { lock.unlock(); completion?(); return }
        failureRecord.merge(record) { _, new in new }
        record = failureRecord
        gauges.merge(record) { _, new in new }
        let now = ProcessInfo.processInfo.systemUptime
        lock.unlock()
        record["schema"] = 1
        record["failure_uptime_s"] = now
        record["session_started_uptime_s"] = started
        let snapshot = record
        let cache = cacheDirectory, sessionStart = started
        Self.failureWriter.async {
            defer { completion?() }
            guard let cache, sessionStart > Self.newestFailureSessionUptime ||
                    (sessionStart == Self.newestFailureSessionUptime && now >= Self.newestFailureUptime) else { return }
            Self.newestFailureSessionUptime = sessionStart
            Self.newestFailureUptime = now
            Self.writeJSON(snapshot, in: cache, named: "LastConnectionFailure.json")
        }
    }
    /// An explicit controller end, independent of any previous HTTP failure.
    /// The session clock joins this record to NativeStreamDiagnostics and the
    /// optional LastConnectionFailure without storing identifiers or UI text.
    func recordSessionEnd(_ reason: SessionEndReason, fields: [String: Double], completion: (() -> Void)? = nil) {
        var record = fields.filter { Self.sessionEndFields.contains($0.key) && $0.value.isFinite }
        record["session_end_reason"] = Double(reason.rawValue)
        lock.lock()
        guard !recordedSessionEnd else { lock.unlock(); completion?(); return }
        recordedSessionEnd = true
        gauges.merge(record) { _, new in new }
        lock.unlock()
        record["schema"] = 1
        record["end_uptime_s"] = ProcessInfo.processInfo.systemUptime
        record["session_started_uptime_s"] = started
        let snapshot = record, sessionStart = started, cache = cacheDirectory
        Self.failureWriter.async {
            defer { completion?() }
            guard sessionStart >= Self.newestEndedSessionUptime, let cache else { return }
            Self.newestEndedSessionUptime = sessionStart
            Self.writeJSON(snapshot, in: cache, named: "LastSessionEnd.json")
        }
    }
    func observe(_ key: String, _ value: Double) {
        guard value.isFinite else { return }
        lock.lock()
        var item = samples[key] ?? ["count": 0, "sum": 0, "max": value, "latest": value]
        item["count", default: 0] += 1
        if item["sum_overflow"] == nil {
            let sum = item["sum", default: 0] + value
            if sum.isFinite { item["sum"] = sum }
            else { item.removeValue(forKey: "sum"); item["sum_overflow"] = 1 }
        }
        item["max"] = max(item["max"] ?? value, value)
        item["latest"] = value
        samples[key] = item
        lock.unlock()
    }
    /// Bounded numeric history. No file I/O or player API runs on this path.
    func recordAudioEvent(_ kind: AudioDiagnosticEvent, fields: [String: Double]) {
        var event = fields.filter { $0.value.isFinite }
        event["event_uptime_s"] = ProcessInfo.processInfo.systemUptime
        event["kind"] = Double(kind.rawValue)
        lock.lock()
        audioEventSequence += 1
        event["sequence"] = Double(audioEventSequence)
        recentAudioEvents.append(event)
        if recentAudioEvents.count > 32 { recentAudioEvents.removeFirst(recentAudioEvents.count - 32) }
        lock.unlock()
    }
    /// Only anomalous callback/consume spans, with adjacent source-PTS anchors.
    /// This uses the existing periodic writer; no per-packet disk I/O is added.
    func recordAVPathEvent(_ fields: [String: Double]) {
        let allowed: Set<String> = ["stage", "packet_kind", "source_timestamp_us",
            "first_packet_kind", "first_source_timestamp_us", "previous_source_timestamp_us",
            "begin_uptime_s", "end_uptime_s", "previous_begin_uptime_s", "previous_end_uptime_s",
            "callback_begin_uptime_s", "callback_ms", "consume_ms", "packet_interval_ms",
            "bytes", "packets", "buffered_before", "buffered_after"]
        var event = fields.filter { allowed.contains($0.key) && $0.value.isFinite }
        lock.lock()
        avPathEventSequence += 1
        event["sequence"] = Double(avPathEventSequence)
        recentAVPathEvents.append(event)
        if recentAVPathEvents.count > 64 { recentAVPathEvents.removeFirst(recentAVPathEvents.count - 64) }
        lock.unlock()
    }
    /// Complete parsed packets only. Four PTS bounds and one count, not a packet log.
    func recordAVPacket(kind: Int, sourceTimestamp: UInt64) {
        guard kind == 1 || kind == 2 else { return }
        let prefix = kind == 1 ? "video" : "audio"
        let pts = Double(sourceTimestamp)
        lock.lock()
        receivedAVPackets += 1
        if sourcePTS[prefix + "_first_us"] == nil { sourcePTS[prefix + "_first_us"] = pts }
        sourcePTS[prefix + "_last_us"] = pts
        lock.unlock()
    }
    func finish(_ reason: String, completion: (() -> Void)? = nil) {
        lock.lock(); state = reason; lock.unlock()
        writer.async { [self] in
            timer?.cancel(); timer = nil
            writeSnapshot(preserveAVPath: true)
            completion?()
        }
    }
    private func writeSnapshot(preserveAVPath: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let snapshot: [String: Any] = [
            "schema": 1, "state": state,
            "clock": "local ProcessInfo.systemUptime seconds",
            "started_uptime_s": started, "snapshot_uptime_s": now, "elapsed_s": now - started,
            "counters": counters, "gauges": gauges, "samples": samples,
            "audio_recent_events": recentAudioEvents,
            "audio_event_sequence": Double(audioEventSequence),
            "av_path_recent_events": recentAVPathEvents,
            "av_path_event_sequence": Double(avPathEventSequence),
            "av_path_received_packets": receivedAVPackets, "av_path_source_pts": sourcePTS,
            "video_format": videoFormat,
            "notes": [
                "frame_http_roundtrip_ms is client HTTP request/response time, not input-to-photon latency",
                "receive_callback_ms includes synchronous parser/media work, not URLSession internal buffering",
                "av_path_recent_events: stage 5=URLSession delegate entry/end, stage 6=complete packet media consume entry/end; only >=50ms gaps/work, latest 64 numeric events",
                "source_timestamp_us + packet_kind (1 video, 2 audio) join host and client events within ONE capture session; compare local durations, never subtract host and phone uptime",
                "a callback's first/last PTS belongs to complete parsed packets, possibly begun in an earlier callback; zero packets has no PTS anchor and buffered_before/after preserves that distinction",
                "absence of host anomalies is evidence only if capture/send PTS coverage includes the client interval and the bounded event sequence has not overwritten that interval; send completion does not mean phone receipt",
                "audio_source_gap_ms compares consecutive received source PTS and PCM frame duration",
                "audio_recent_events retains the latest 32 numeric events: kind 1=empty arrival, 2=source PTS gap, 3=overflow before stop; sequence counts all recorded events",
                "event_uptime_s and arrival_uptime_s use this client process clock; source_timestamp_us and video_latest_source_us use capture media PTS; do not subtract these clock domains or directly subtract client and host uptimes",
                "arrival_interval_ms and video_packets_since_previous_audio describe client media-consume entry times, including upstream receive and parser scheduling; they are not isolated network transit time or per-URLSession callback work",
                "empty-arrival and overflow events preserve the existing pre-stop clock validity and contiguity flags; absent clock fields are unavailable, not zero",
                "audio_queue_drained counts rendered node buffers reaching zero, not proof of audible silence",
                "audio_clock fields are sampled before the incoming buffer and before any overflow stop; the ledger resets at every stop generation",
                "audio_player_clock_valid=0 means no usable player sample time; ignore retained clock-value gauges in that snapshot",
                "audio_scheduled_minus_player_clock is a signed schedule residual at lastRenderTime, not acoustic latency; gaps can invalidate its queue interpretation",
                "audio_clock_contiguous_generation=0 marks an empty arrival or clock beyond scheduled data; compare raw totals without treating the residual as an exact queue",
                "audio_node_last_render_age_ms and audio_clock_read_span_ms describe timing skew; callback and render-clock reads are not simultaneous hardware observations",
                "video_pts_ahead_of_timeline_ms compares received PTS to actual local render timeline before correction, not one-way network latency",
                "video_pts_ahead_of_requested_timeline_ms includes the predicted asynchronous timebase correction; it is not displayed-frame latency",
                "video_live_edge_advance_ms measures forward presentation-clock corrections without flushing H264 references",
                "video_renderer gauges are raw cumulative Apple renderer snapshots; compare snapshots and account for renderer resets",
                "video_renderer_dropped_frames includes pre-decode drops and missed display deadlines, not network packet loss",
                "video_arrived_past_playhead_frames counts samples whose PTS was already behind the actual render clock on receipt"
            ]
        ]
        lock.unlock()
        guard let cache = cacheDirectory else { return }
        Self.writeJSON(snapshot, in: cache, named: "NativeStreamDiagnostics.json")
        if preserveAVPath && receivedMedia(in: snapshot) {
            let keys = ["schema", "started_uptime_s", "snapshot_uptime_s", "elapsed_s",
                        "av_path_recent_events", "av_path_event_sequence", "counters", "samples",
                        "av_path_received_packets", "av_path_source_pts"]
            var archive = snapshot.filter { keys.contains($0.key) }
            archive["session_started_uptime_s"] = started
            let captured = archive
            Self.failureWriter.async {
                Self.preserveMediaSession(captured, in: cache)
            }
        }
    }
    private func receivedMedia(in snapshot: [String: Any]) -> Bool {
        let count = snapshot["av_path_received_packets"] as? Double ?? 0
        let pts = snapshot["av_path_source_pts"] as? [String: Double] ?? [:]
        return count > 0 && !pts.isEmpty
    }
    /// Called only on failureWriter. Read at most four bounded records from disk
    /// so late per-session writers merge by session start instead of arrival order.
    private static func preserveMediaSession(_ archive: [String: Any], in cache: URL) {
        let url = cache.appendingPathComponent("AVPathSessions.json")
        var records: [[String: Any]] = []
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attributes[.size] as? NSNumber, size.intValue <= 512 * 1024,
           let data = try? Data(contentsOf: url),
           let saved = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let sessions = saved["sessions"] as? [[String: Any]], sessions.count <= 4 {
            records = sessions
        }
        records.append(archive)
        var byStart: [Double: [String: Any]] = [:]
        for item in records {
            guard let start = item["started_uptime_s"] as? Double, start.isFinite,
                  let captured = item["snapshot_uptime_s"] as? Double, captured.isFinite,
                  let finite = finiteNumericObject(item) as? [String: Any] else { continue }
            if let old = byStart[start], (old["snapshot_uptime_s"] as? Double ?? 0) > captured { continue }
            byStart[start] = finite
        }
        let latest = byStart.keys.sorted().suffix(4).compactMap { byStart[$0] }
        guard let newest = latest.last else { return }
        writeJSON(["schema": 1, "sessions": latest], in: cache, named: "AVPathSessions.json")
        writeJSON(newest, in: cache, named: "LastAVPathSession.json")
    }
    /// Archives contain dictionaries/arrays of finite numbers only. In
    /// particular, a nonfinite accumulated sample cannot invalidate the file.
    private static func finiteNumericObject(_ value: Any) -> Any? {
        if let number = value as? NSNumber { return number.doubleValue.isFinite ? number : nil }
        if let dictionary = value as? [String: Any] {
            return dictionary.compactMapValues { finiteNumericObject($0) }
        }
        if let array = value as? [Any] { return array.compactMap { finiteNumericObject($0) } }
        return nil
    }
    private static func writeJSON(_ snapshot: [String: Any], in cache: URL, named name: String) {
        guard JSONSerialization.isValidJSONObject(snapshot),
              let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let target = cache.appendingPathComponent(name).path
        let temporary = target + "." + UUID().uuidString + ".tmp"
        let fd = Darwin.open(temporary, O_WRONLY | O_CREAT | O_TRUNC, mode_t(0o600))
        guard fd >= 0 else { return }
        _ = Darwin.fchmod(fd, mode_t(0o600))
        let success = data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            var offset = 0
            while offset < raw.count {
                let result = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                if result < 0 && errno == EINTR { continue }
                guard result > 0 else { return false }
                offset += result
            }
            return true
        }
        Darwin.close(fd)
        if !success || Darwin.rename(temporary, target) != 0 { _ = Darwin.unlink(temporary) }
    }
}
