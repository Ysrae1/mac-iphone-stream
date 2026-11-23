import AVFoundation
import UIKit

/// Serial stream delegate queue owns this object. Video renderer supports background enqueue on iOS 17+.
final class NativeMedia {
    let renderer: AVSampleBufferVideoRenderer
    private let audio: StreamAudio
    private let diagnostics: ClientDiagnostics
    private var previousAudioEndUs: UInt64?
    private var previousAudioArrivalUptime: Double?
    private var videoPacketsSincePreviousAudio = 0
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private var timeline = PlaybackTimeline()
    private var timelineStarted = false
    private var backpressuredFrames = 0
    private var sps: Data?, pps: Data?, format: CMVideoFormatDescription?
    private var awaitingIDR = true
    private var size = CGSize.zero
    private var latestVideoTime: UInt64 = 0
    private(set) var videoFrames = 0
    var onVideo: ((CGSize) -> Void)?
    var onAudioError: (() -> Void)?
    private var audioFailed = false
    private var previousVideoSourceUs: UInt64?
    private var previousVideoArrivalUptime: Double?
    private var videoMetricsBaseline: (total: Int, dropped: Int, corrupted: Int)?
    private var lastVideoMetricsUptime: Double = 0
    private let metricsLock = NSLock()
    private var videoMetricsPending = false

    init(layer: AVSampleBufferDisplayLayer, diagnostics: ClientDiagnostics) {
        self.diagnostics = diagnostics
        audio = StreamAudio(diagnostics: diagnostics)
        renderer = layer.sampleBufferRenderer
        synchronizer.addRenderer(renderer)
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
    }
    func prepareAudio() {
        guard !audioFailed else { return }
        do { try audio.prepare() } catch { failAudio() }
    }
    private func resetVideo() {
        diagnostics.count("video_timeline_resets")
        // A flush invalidates H.264 references: resume only from a complete IDR.
        renderer.flush()
        awaitingIDR = true
        backpressuredFrames = 0
        synchronizer.setRate(0, time: .invalid)
        timelineStarted = false
        timeline.reset()
    }
    func consume(_ packet: StreamPacket) throws {
        if packet.kind == .audio {
            let arrivalUptime = ProcessInfo.processInfo.systemUptime
            let observation = AudioArrivalObservation(
                uptimeSeconds: arrivalUptime,
                sourceTimestampMicroseconds: packet.timestampMicroseconds,
                sourceGapMicroseconds: previousAudioEndUs.map { Double(packet.timestampMicroseconds) - Double($0) },
                intervalSeconds: previousAudioArrivalUptime.map { arrivalUptime - $0 },
                videoPacketsSincePreviousAudio: videoPacketsSincePreviousAudio,
                latestVideoSourceMicroseconds: latestVideoTime,
                packetFrames: packet.payload.count / 8)
            previousAudioArrivalUptime = arrivalUptime
            videoPacketsSincePreviousAudio = 0
            diagnostics.count("audio_received_packets")
            if let end = previousAudioEndUs {
                let gap = Double(packet.timestampMicroseconds) - Double(end)
                if gap > 1000 {
                    diagnostics.observe("audio_source_gap_ms", gap / 1000)
                    diagnostics.recordAudioEvent(.sourceGap, fields: observation.fields)
                }
                else if gap < -1000 { diagnostics.count("audio_source_reordered_packets") }
            }
            previousAudioEndUs = packet.timestampMicroseconds + UInt64(packet.payload.count / 8) * 1_000_000 / 48_000
            guard !audioFailed else { diagnostics.count("audio_drop_failed_packets"); return }
            // Keep the previously verified AVAudioEngine path independent of video clock corrections.
            if latestVideoTime > packet.timestampMicroseconds + 250_000 { diagnostics.count("audio_drop_behind_video_packets"); return }
            do { try audio.enqueue(packet, observation: observation) } catch { failAudio() }
            return
        }
        // All differences stay within their own clock domain. Batched packets can
        // have near-zero arrival intervals; this is not a pure network measurement.
        let videoArrivalUptime = ProcessInfo.processInfo.systemUptime
        if let previous = previousVideoArrivalUptime {
            let interval = (videoArrivalUptime - previous) * 1000
            diagnostics.observe("video_arrival_interval_ms", interval)
            if interval > 50 { diagnostics.count("video_arrival_intervals_over_50ms") }
        }
        if let previous = previousVideoSourceUs {
            if packet.timestampMicroseconds >= previous {
                let interval = Double(packet.timestampMicroseconds - previous) / 1000
                diagnostics.observe("video_source_interval_ms", interval)
                if interval > 50 { diagnostics.count("video_source_intervals_over_50ms") }
            } else { diagnostics.count("video_source_reordered_packets") }
        }
        previousVideoSourceUs = packet.timestampMicroseconds
        previousVideoArrivalUptime = videoArrivalUptime
        videoPacketsSincePreviousAudio += 1
        diagnostics.count("video_received_packets")
        let units = try AnnexB.units(packet.payload)
        var changed = false
        for unit in units {
            switch unit[unit.startIndex] & 0x1f {
            case 7: if sps != unit { sps = unit; changed = true }
            case 8: if pps != unit { pps = unit; changed = true }
            default: break
            }
        }
        let idr = units.contains { $0[$0.startIndex] & 0x1f == 5 }
        if changed {
            diagnostics.count("video_format_changes")
            format = nil; awaitingIDR = true
            resetVideo()
        }
        if format == nil, let sps, let pps { format = try makeFormat(sps: sps, pps: pps) }
        guard let format else { return }
        if awaitingIDR && !idr { diagnostics.count("video_wait_idr_drops"); return }
        let slices = units.filter { [1, 5, 6].contains(Int($0[$0.startIndex] & 0x1f)) }
        guard slices.contains(where: { [1, 5].contains(Int($0[$0.startIndex] & 0x1f)) }) else { return }
        guard renderer.status != .failed else { throw MediaError.videoDecoder }
        // Apple permits enqueue while readiness is false. A short burst is normal,
        // not a decoder failure; bound it to six frames before flushing the GOP.
        // Never drop one reference frame and continue decoding its dependents.
        if renderer.isReadyForMoreMediaData { backpressuredFrames = 0 }
        else { backpressuredFrames += 1; diagnostics.count("video_backpressured_frames") }
        if backpressuredFrames > 6 {
            diagnostics.count("video_backpressure_resets")
            resetVideo()
            guard idr else { return }
        }
        let sample = try makeSample(AnnexB.avcc(slices), format: format, timestamp: packet.timestampMicroseconds, idr: idr)
        if timelineStarted {
            let sourceTime = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            let observed = CMTimeGetSeconds(synchronizer.currentTime())
            let hostTime = CMClockGetTime(CMClockGetHostTimeClock())
            let hostSeconds = CMTimeGetSeconds(hostTime)
            diagnostics.observe("video_pts_ahead_of_timeline_ms", (sourceTime - observed) * 1000)
            if sourceTime < observed {
                diagnostics.count("video_arrived_past_playhead_frames")
                diagnostics.observe("video_arrival_lateness_ms", (observed - sourceTime) * 1000)
            }
            let before = timeline.effectiveTime(observed: observed, hostTime: hostSeconds)
            if let target = timeline.correction(for: sourceTime, observed: observed, hostTime: hostSeconds) {
                // An old first frame must not permanently anchor playback behind live media.
                // Move presentation time forward, retaining every encoded reference frame.
                // Never flush the decoder or mark dependent P frames DisplayImmediately.
                synchronizer.setRate(1, time: CMTime(seconds: target, preferredTimescale: 1_000_000), atHostTime: hostTime)
                diagnostics.count("video_live_edge_corrections")
                diagnostics.observe("video_live_edge_advance_ms", (target - before) * 1000)
            }
            diagnostics.observe("video_pts_ahead_of_requested_timeline_ms",
                (sourceTime - timeline.effectiveTime(observed: observed, hostTime: hostSeconds)) * 1000)
        }
        let enqueuedAt = ProcessInfo.processInfo.systemUptime
        renderer.enqueue(sample)
        diagnostics.observe("video_renderer_enqueue_ms", (ProcessInfo.processInfo.systemUptime - enqueuedAt) * 1000)
        sampleVideoPerformance()
        if !timelineStarted {
            // Preserve source cadence across network bursts. DisplayImmediately
            // would replace queued frames regardless of their source timestamps.
            let hostNow = CMClockGetTime(CMClockGetHostTimeClock())
            let hostStart = CMTimeAdd(hostNow, CMTime(seconds: PlaybackTimeline.prerollSeconds, preferredTimescale: 1_000_000))
            synchronizer.setRate(1, time: CMSampleBufferGetPresentationTimeStamp(sample), atHostTime: hostStart)
            timeline.anchor(sourceTime: CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)) - PlaybackTimeline.prerollSeconds,
                            hostTime: CMTimeGetSeconds(hostNow))
            timelineStarted = true
        }
        awaitingIDR = false
        latestVideoTime = packet.timestampMicroseconds
        videoFrames += 1
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        guard dimensions.width > 0, dimensions.height > 0,
              UInt32(dimensions.width) == packet.a, UInt32(dimensions.height) == packet.b else { throw StreamProtocolError.invalidVideo }
        let next = CGSize(width: Int(packet.a), height: Int(packet.b))
        size = next
        onVideo?(next)
    }
    func stop() {
        audio.stop()
        synchronizer.setRate(0, time: .invalid)
        renderer.flush(removingDisplayedImage: true, completionHandler: nil)
        synchronizer.removeRenderer(renderer, at: .invalid, completionHandler: nil)
    }
    private func failAudio() {
        audioFailed = true
        diagnostics.count("audio_playback_failures")
        audio.stop()
        onAudioError?()
    }
    private func sampleVideoPerformance() {
        guard #available(iOS 17.4, macCatalyst 17.4, *) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastVideoMetricsUptime >= 2 else { return }
        metricsLock.lock()
        guard !videoMetricsPending else { metricsLock.unlock(); return }
        videoMetricsPending = true
        metricsLock.unlock()
        lastVideoMetricsUptime = now
        renderer.loadVideoPerformanceMetrics { [self] metrics in
            defer { metricsLock.lock(); videoMetricsPending = false; metricsLock.unlock() }
            guard let metrics else { diagnostics.count("video_renderer_metrics_unavailable"); return }
            let metricsUptime = ProcessInfo.processInfo.systemUptime
            // The display layer survives reconnects, so absolute renderer counters
            // must not be divided by this NativeMedia session's received count.
            // This baseline intentionally excludes frames before the first callback.
            let current = (total: metrics.totalNumberOfFrames,
                           dropped: metrics.numberOfDroppedFrames,
                           corrupted: metrics.numberOfCorruptedFrames)
            if let baseline = videoMetricsBaseline,
               current.total < baseline.total || current.dropped < baseline.dropped || current.corrupted < baseline.corrupted {
                videoMetricsBaseline = nil
                diagnostics.count("video_renderer_metrics_counter_discontinuities")
            }
            if videoMetricsBaseline == nil {
                videoMetricsBaseline = current
                diagnostics.gauge("video_renderer_baseline_uptime_s", metricsUptime)
            }
            if let baseline = videoMetricsBaseline {
                diagnostics.gauge("video_renderer_since_baseline_total_frames", Double(current.total - baseline.total))
                diagnostics.gauge("video_renderer_since_baseline_dropped_frames", Double(current.dropped - baseline.dropped))
                diagnostics.gauge("video_renderer_since_baseline_corrupted_frames", Double(current.corrupted - baseline.corrupted))
            }
            diagnostics.gauge("video_renderer_metrics_uptime_s", metricsUptime)
            diagnostics.gauge("video_renderer_total_frames", Double(metrics.totalNumberOfFrames))
            diagnostics.gauge("video_renderer_dropped_frames", Double(metrics.numberOfDroppedFrames))
            diagnostics.gauge("video_renderer_corrupted_frames", Double(metrics.numberOfCorruptedFrames))
            diagnostics.gauge("video_renderer_optimized_compositing_frames", Double(metrics.numberOfFramesDisplayedUsingOptimizedCompositing))
            diagnostics.gauge("video_renderer_accumulated_frame_delay_ms", metrics.totalAccumulatedFrameDelay * 1000)
            diagnostics.count("video_renderer_metrics_snapshots")
        }
    }
    private func makeFormat(sps: Data, pps: Data) throws -> CMVideoFormatDescription {
        var result: CMFormatDescription?
        let status = sps.withUnsafeBytes { s in
            pps.withUnsafeBytes { p in
                let pointers = [s.bindMemory(to: UInt8.self).baseAddress!, p.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = [sps.count, pps.count]
                return pointers.withUnsafeBufferPointer { ptr in
                    sizes.withUnsafeBufferPointer { len in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault,
                            parameterSetCount: 2, parameterSetPointers: ptr.baseAddress!,
                            parameterSetSizes: len.baseAddress!, nalUnitHeaderLength: 4, formatDescriptionOut: &result)
                    }
                }
            }
        }
        guard status == noErr, let result else { throw MediaError.videoFormat }
        // Diagnostic labels are not CoreMedia extension keys. Use the SDK constants:
        // the three color keys and GammaLevel have CVImageBuffer-prefixed values.
        let colorKeys: [(String, CFString)] = [
            ("ColorPrimaries", kCMFormatDescriptionExtension_ColorPrimaries),
            ("TransferFunction", kCMFormatDescriptionExtension_TransferFunction),
            ("YCbCrMatrix", kCMFormatDescriptionExtension_YCbCrMatrix),
            ("FullRangeVideo", kCMFormatDescriptionExtension_FullRangeVideo),
            ("GammaLevel", kCMFormatDescriptionExtension_GammaLevel),
            ("BitsPerComponent", kCMFormatDescriptionExtension_BitsPerComponent)
        ]
        var colorFields: [String: String] = [:]
        for (label, key) in colorKeys {
            colorFields[label] = CMFormatDescriptionGetExtension(result, extensionKey: key)
                .map { String(describing: $0) } ?? "absent"
        }
        diagnostics.setVideoFormat(colorFields)
        return result
    }
    private func makeSample(_ data: Data, format: CMVideoFormatDescription, timestamp: UInt64, idr: Bool) throws -> CMSampleBuffer {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: data.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: data.count, flags: 0, blockBufferOut: &block) == noErr, let block else { throw MediaError.videoBuffer }
        let copied = data.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count) }
        guard copied == noErr else { throw MediaError.videoBuffer }
        var timing = CMSampleTimingInfo(duration: .invalid,
            presentationTimeStamp: CMTime(value: Int64(clamping: timestamp), timescale: 1_000_000), decodeTimeStamp: .invalid)
        var length = data.count, sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &length, sampleBufferOut: &sample) == noErr, let sample else { throw MediaError.videoBuffer }
        if let array = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(array, 0), to: CFMutableDictionary.self)
            if !idr { CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()) }
        }
        return sample
    }
}

enum MediaError: Error, LocalizedError {
    case videoFormat, videoBuffer, videoDecoder, audioFormat
    var errorDescription: String? {
        switch self {
        case .audioFormat: return "音频格式无法播放。"
        default: return "视频解码失败，已释放触控，请重新连接。"
        }
    }
}
