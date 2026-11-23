import AVFoundation
import Darwin

/// Confirm callback-ledger overflow against the player clock only while the schedule is contiguous.
/// Value-only policy, so the measured decisions can be replayed without opening an audio device.
enum AudioOverflowPolicy {
    static let maximumFrames = 7_200

    static func clockReachedScheduledEnd(scheduledFrames: Int64, playerProgressFrames: Double?) -> Bool {
        guard let progress = playerProgressFrames, progress.isFinite, progress >= 0 else { return false }
        return progress >= Double(scheduledFrames)
    }

    static func shouldReset(callbackQueuedFrames: Int, incomingFrames: Int,
                            scheduledFrames: Int64, playerProgressFrames: Double?,
                            hasDiscontinuousSchedule: Bool) -> Bool {
        guard callbackQueuedFrames + incomingFrames > maximumFrames else { return false }
        // A gap, an unavailable clock, or progress beyond scheduled media invalidates
        // scheduled-minus-clock accounting. Preserve the previous bounded fallback.
        guard !hasDiscontinuousSchedule, let progress = playerProgressFrames,
              progress.isFinite, progress >= 0 else { return true }
        let remaining = Double(scheduledFrames) - progress
        guard remaining >= 0 else { return true }
        return remaining + Double(incomingFrames) > Double(maximumFrames)
    }
}

/// Receipt context uses two separate clock domains: local arrival uptime and source media PTS.
/// Values are materialized only for a diagnostic event, never for each normal audio packet.
struct AudioArrivalObservation {
    let uptimeSeconds: Double
    let sourceTimestampMicroseconds: UInt64
    let sourceGapMicroseconds: Double?
    let intervalSeconds: Double?
    let videoPacketsSincePreviousAudio: Int
    let latestVideoSourceMicroseconds: UInt64
    let packetFrames: Int

    var fields: [String: Double] {
        var result: [String: Double] = [
            "arrival_uptime_s": uptimeSeconds,
            "source_timestamp_us": Double(sourceTimestampMicroseconds),
            "video_latest_source_us": Double(latestVideoSourceMicroseconds),
            "video_packets_since_previous_audio": Double(videoPacketsSincePreviousAudio),
            "packet_frames": Double(packetFrames)
        ]
        if let sourceGapMicroseconds { result["source_gap_ms"] = sourceGapMicroseconds / 1000 }
        if let intervalSeconds { result["arrival_interval_ms"] = intervalSeconds * 1000 }
        return result
    }
}

/// Restored AVAudioEngine path from the verified video live-edge build.
/// Completion callbacks remain the ledger; a valid contiguous native clock vetoes false resets.
final class StreamAudio {
    private let diagnostics: ClientDiagnostics
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let lock = NSLock()
    private var queuedFrames = 0
    private var generation = 0
    // Once either ledger observes an exhausted schedule, this generation cannot use the clock veto.
    private var generationScheduledFrames: Int64 = 0
    private var generationRenderedFrames: Int64 = 0
    private var generationHadEmptyArrival = false
    private var generationClockReachedEnd = false
    private var started = false
    private var sessionActive = false
    private var playing = false
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!

    init(diagnostics: ClientDiagnostics) { self.diagnostics = diagnostics }

    /// GSA1 is validated as 48 kHz stereo float PCM by StreamParser. Prepare that
    /// existing format on the media owner queue before requesting any stream data.
    func prepare() throws {
        guard !started else { return }
        let startup = ProcessInfo.processInfo.systemUptime
        // Playback only: no microphone category, entitlement or permission.
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
        try AVAudioSession.sharedInstance().setActive(true)
        sessionActive = true
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        try engine.start()
        started = true
        diagnostics.observe("audio_engine_start_ms", (ProcessInfo.processInfo.systemUptime - startup) * 1000)
        diagnostics.gauge("audio_output_latency_ms", AVAudioSession.sharedInstance().outputLatency * 1000)
        diagnostics.gauge("audio_io_buffer_ms", AVAudioSession.sharedInstance().ioBufferDuration * 1000)
    }

    func enqueue(_ packet: StreamPacket, observation: AudioArrivalObservation) throws {
        let frames = packet.payload.count / 8
        guard frames <= 7_200 else { diagnostics.count("audio_drop_oversize_packets"); return }
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channels = buffer.floatChannelData else { throw MediaError.audioFormat }
        buffer.frameLength = AVAudioFrameCount(frames)
        packet.payload.withUnsafeBytes { raw in
            for frame in 0..<frames {
                for channel in 0..<2 {
                    let value = Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: (frame * 2 + channel) * 4, as: UInt32.self)))
                    channels[channel][frame] = value.isFinite ? max(-1, min(1, value)) : 0
                }
            }
        }
        try prepare()
        // Read the native clock before taking our bookkeeping lock. No player API is
        // called from the completion callback or while holding the callback's lock.
        let clockReadBegan = ProcessInfo.processInfo.systemUptime
        let nodeTime = playing ? player.lastRenderTime : nil
        let playerTime = nodeTime.flatMap { player.playerTime(forNodeTime: $0) }
        let hostNow = mach_absolute_time()
        let playerProgressFrames = playerTime.flatMap { time -> Double? in
            guard time.isSampleTimeValid, time.sampleRate > 0, time.sampleTime >= 0 else { return nil }
            return Double(time.sampleTime) * 48_000 / time.sampleRate
        }
        lock.lock()
        let previousFrames = queuedFrames
        let callbackOverflow = queuedFrames + frames > AudioOverflowPolicy.maximumFrames
        if previousFrames == 0 && playing { generationHadEmptyArrival = true }
        // Observe every packet, including those below the callback cap. Refilled data
        // must never make a previously exhausted player timeline appear contiguous again.
        if playing && AudioOverflowPolicy.clockReachedScheduledEnd(scheduledFrames: generationScheduledFrames,
                                                                  playerProgressFrames: playerProgressFrames) {
            generationClockReachedEnd = true
        }
        let overflow = AudioOverflowPolicy.shouldReset(callbackQueuedFrames: queuedFrames,
            incomingFrames: frames, scheduledFrames: generationScheduledFrames,
            playerProgressFrames: playerProgressFrames,
            hasDiscontinuousSchedule: generationHadEmptyArrival || generationClockReachedEnd)
        let clockGeneration = generation
        let clockScheduled = generationScheduledFrames
        let clockRendered = generationRenderedFrames
        let clockHadEmpty = generationHadEmptyArrival
        let clockReachedEnd = generationClockReachedEnd
        if overflow {
            generation += 1; queuedFrames = 0
            generationScheduledFrames = 0; generationRenderedFrames = 0; generationHadEmptyArrival = false
            generationClockReachedEnd = false
        }
        let current = generation
        queuedFrames += frames
        generationScheduledFrames += Int64(frames)
        lock.unlock()
        observeClock(playerTime: playerTime, nodeTime: nodeTime, hostNow: hostNow,
            generation: clockGeneration, scheduled: clockScheduled, rendered: clockRendered,
            queued: previousFrames, hadEmptyArrival: clockHadEmpty, clockReachedEnd: clockReachedEnd, overflow: overflow,
            readSpan: ProcessInfo.processInfo.systemUptime - clockReadBegan,
            emptyArrival: previousFrames == 0 && playing, observation: observation)
        if callbackOverflow && !overflow {
            diagnostics.count("audio_false_overflow_avoided")
            if let playerProgressFrames {
                diagnostics.observe("audio_false_overflow_native_pending_ms",
                    (Double(clockScheduled) - playerProgressFrames + Double(frames)) / 48)
            }
        }
        if previousFrames == 0 && playing { diagnostics.count("audio_empty_arrivals") }
        if overflow {
            diagnostics.count("audio_overflow_resets")
            diagnostics.observe("audio_overflow_discarded_ms", Double(previousFrames) / 48)
            player.stop(); playing = false
        }
        diagnostics.count("audio_scheduled_frames", by: Double(frames))
        let scheduleStarted = ProcessInfo.processInfo.systemUptime
        player.scheduleBuffer(buffer, completionCallbackType: .dataRendered) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            let matches = self.generation == current
            if matches {
                self.queuedFrames = max(0, self.queuedFrames - frames)
                self.generationRenderedFrames += Int64(frames)
            }
            let drained = matches && self.queuedFrames == 0
            self.lock.unlock()
            if matches { self.diagnostics.count("audio_rendered_frames", by: Double(frames)) }
            if drained { self.diagnostics.count("audio_queue_drained") }
        }
        diagnostics.observe("audio_player_schedule_ms", (ProcessInfo.processInfo.systemUptime - scheduleStarted) * 1000)
        lock.lock()
        let buffered = queuedFrames
        lock.unlock()
        diagnostics.observe("audio_queue_ms", Double(buffered) / 48)
        // Schedule before starting; retain the previously verified 40ms preroll.
        if !playing && buffered >= 1_920 { player.play(); playing = true; diagnostics.count("audio_player_starts") }
    }
    func stop() {
        lock.lock()
        generation += 1; queuedFrames = 0
        generationScheduledFrames = 0; generationRenderedFrames = 0; generationHadEmptyArrival = false
        generationClockReachedEnd = false
        lock.unlock()
        player.stop(); playing = false; engine.stop()
        // Activation can succeed even if engine.start() subsequently fails.
        if sessionActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            sessionActive = false
        }
    }
    private func observeClock(playerTime: AVAudioTime?, nodeTime: AVAudioTime?, hostNow: UInt64,
                              generation: Int, scheduled: Int64, rendered: Int64, queued: Int,
                              hadEmptyArrival: Bool, clockReachedEnd: Bool, overflow: Bool, readSpan: Double,
                              emptyArrival: Bool, observation: AudioArrivalObservation) {
        var values: [String: Double] = [
            "audio_clock_snapshot_uptime_s": ProcessInfo.processInfo.systemUptime,
            "audio_clock_generation": Double(generation),
            "audio_clock_was_playing": playing ? 1 : 0,
            "audio_clock_before_overflow": overflow ? 1 : 0,
            "audio_clock_generation_had_empty_arrival": hadEmptyArrival ? 1 : 0,
            "audio_clock_generation_reached_schedule_end": clockReachedEnd ? 1 : 0,
            "audio_clock_generation_scheduled_frames": Double(scheduled),
            "audio_clock_generation_callback_rendered_frames": Double(rendered),
            "audio_clock_callback_queued_frames": Double(queued),
            "audio_clock_accounting_difference_frames": Double(queued) - Double(scheduled - rendered),
            "audio_clock_read_span_ms": readSpan * 1000,
            "audio_player_clock_valid": 0
        ]
        if let nodeTime, nodeTime.isHostTimeValid, hostNow >= nodeTime.hostTime {
            values["audio_node_last_render_age_ms"] = AVAudioTime.seconds(forHostTime: hostNow - nodeTime.hostTime) * 1000
        }
        if let playerTime, playerTime.isSampleTimeValid, playerTime.sampleRate > 0, playerTime.sampleTime >= 0 {
            let progress = Double(playerTime.sampleTime) * 48_000 / playerTime.sampleRate
            let remaining = Double(scheduled) - progress
            let difference = Double(queued) - remaining
            values["audio_player_clock_valid"] = 1
            values["audio_player_clock_sample_time"] = Double(playerTime.sampleTime)
            values["audio_player_clock_sample_rate"] = playerTime.sampleRate
            values["audio_player_clock_progress_48k_frames"] = progress
            values["audio_scheduled_minus_player_clock_frames"] = remaining
            values["audio_callback_minus_clock_queue_frames"] = difference
            // A negative residual or an empty arrival invalidates the contiguous
            // schedule assumption; retain the signed value instead of hiding it.
            values["audio_clock_contiguous_generation"] = !hadEmptyArrival && !clockReachedEnd && remaining >= 0 ? 1 : 0
            diagnostics.observe("audio_scheduled_minus_player_clock_ms", remaining / 48)
            diagnostics.observe("audio_callback_minus_clock_queue_ms", difference / 48)
            if overflow {
                diagnostics.count("audio_overflow_clock_observations")
                diagnostics.observe("audio_overflow_callback_queue_ms", Double(queued) / 48)
                diagnostics.observe("audio_overflow_scheduled_minus_clock_ms", remaining / 48)
                diagnostics.observe("audio_overflow_callback_minus_clock_ms", difference / 48)
                if !hadEmptyArrival && !clockReachedEnd && remaining >= 0 {
                    diagnostics.count("audio_overflow_contiguous_clock_observations")
                    diagnostics.observe("audio_overflow_contiguous_scheduled_minus_clock_ms", remaining / 48)
                    diagnostics.observe("audio_overflow_contiguous_callback_minus_clock_ms", difference / 48)
                }
            }
        } else {
            values["audio_clock_contiguous_generation"] = 0
            diagnostics.count(playing ? "audio_player_clock_unavailable_while_playing" : "audio_player_clock_not_playing")
            if overflow { diagnostics.count("audio_overflow_clock_unavailable") }
        }
        if overflow {
            // Preserve the decisive observation across the next two-second file write.
            let overflowValues = values.map { ("audio_last_overflow_" + $0.key, $0.value) }
            for (key, value) in overflowValues { values[key] = value }
        }
        if emptyArrival || overflow {
            var event = observation.fields
            for (key, value) in values where !key.hasPrefix("audio_last_overflow_") { event[key] = value }
            if emptyArrival { diagnostics.recordAudioEvent(.emptyArrival, fields: event) }
            if overflow { diagnostics.recordAudioEvent(.overflow, fields: event) }
        }
        diagnostics.setGauges(values)
    }
}
