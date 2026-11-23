import Foundation
import CoreMedia
import AudioToolbox
import ScreenCaptureKit
import VideoToolbox

private final class RawFrameProbe {
    let pts: Int64
    init(_ pts: Int64) { self.pts = pts }
}

private func checkLatestPending() {
    let interval: UInt64 = 1_000_000_000 / 60
    var slot = LatestFrameSlot<RawFrameProbe>()
    var first: RawFrameProbe? = RawFrameProbe(17_000)
    weak let firstLifetime = first
    precondition(!slot.replace(first!, received: 17_000_000) && slot.count == 1)
    first = nil
    precondition(firstLifetime != nil, "Pending raw sample must be retained")
    precondition(slot.replace(RawFrameProbe(34_000), received: 34_000_000))
    precondition(firstLifetime == nil, "Replaced raw sample must release immediately")
    let latest = slot.take(now: 38_000_000, maximumAge: interval)
    precondition(latest.value?.pts == 34_000 && latest.received == 34_000_000 && !latest.expired)
    precondition(slot.count == 0, "Take must empty the slot; source PTS must be preserved")

    // During a 155ms encoder stall only the newest raw sample survives.
    for ms in stride(from: 40, through: 140, by: 20) {
        _ = slot.replace(RawFrameProbe(Int64(ms) * 1000), received: UInt64(ms) * 1_000_000)
        precondition(slot.count == 1)
    }
    precondition(slot.take(now: 155_000_000, maximumAge: interval).value?.pts == 140_000)
    _ = slot.replace(RawFrameProbe(160_000), received: 160_000_000)
    let expired = slot.take(now: 160_000_000 + interval + 1, maximumAge: interval)
    precondition(expired.expired && expired.value == nil && slot.count == 0)
    _ = slot.replace(RawFrameProbe(180_000), received: 180_000_000)
    precondition(slot.take(now: 180_000_000 + interval, maximumAge: interval).value != nil)

    var stopped: RawFrameProbe? = RawFrameProbe(200_000)
    weak let stoppedLifetime = stopped
    _ = slot.replace(stopped!, received: 200_000_000)
    stopped = nil
    precondition(slot.clear() && stoppedLifetime == nil && slot.count == 0)
    precondition(!slot.clear() && slot.take(now: 300_000_000, maximumAge: interval).value == nil)

    let synchronousFailure = VideoFrameTicket()
    precondition(synchronousFailure.finish(output: false))
    precondition(!synchronousFailure.finish(output: false) && !synchronousFailure.beginOutput(),
        "A late callback must not enqueue output or release a newer frame")
    let success = VideoFrameTicket()
    precondition(success.beginOutput() && !success.beginOutput())
    precondition(!success.finish(output: false), "Encode return cannot release an output still being written")
    precondition(success.finish(output: true) && !success.finish(output: true))
    let beforeCallback = VideoFrameTicket()
    precondition(!beforeCallback.finish(output: true) && beforeCallback.beginOutput())
    precondition(beforeCallback.finish(output: true))
}

private func checkSourceTrace(directory: URL) async throws {
    let path = directory.appendingPathComponent("source-trace.json").path
    let disabled = CaptureMetrics(path: path)
    precondition(disabled.sourceCallback(status: 0, pts: .zero, entry: 1) == nil)
    disabled.sourceDisposition(1, 3)
    precondition(disabled.sourceTraceSnapshot() == nil && disabled.packetTraceTime() == nil)
    let disabledFrame = disabled.beginEncode(sourceSequence: 1, wirePTS: 1)
    precondition(disabledFrame.sourceSequence == nil)

    let traced = CaptureMetrics(path: path, packetTrace: true)
    let raw = CMTime(value: 9_123_456_789, timescale: 60_000)
    let complete = traced.sourceCallback(status: SCFrameStatus.complete.rawValue, pts: raw, entry: 100)!
    let idle = traced.sourceCallback(status: SCFrameStatus.idle.rawValue, pts: raw, entry: 200)!
    let invalid = traced.sourceCallback(status: nil, pts: .invalid, entry: 300)!
    precondition(complete == 1 && idle == 2 && invalid == 3)
    traced.sourceDisposition(complete, 2)
    let frame = traced.beginEncode(sourceSequence: complete, wirePTS: 987654)
    traced.encoderResult(frame, callback: false, status: noErr, flags: [])
    traced.encoderResult(frame, callback: true, status: noErr, flags: [])
    var rows = traced.sourceTraceSnapshot()!["records"] as! [[String: Any]]
    precondition((rows[0]["raw_pts_value"] as! Int64) == raw.value && (rows[0]["raw_pts_timescale"] as! Int32) == raw.timescale)
    precondition((rows[0]["wire_pts_us"] as! Int64) == 987654 && (rows[0]["disposition"] as! Int) == 1)
    precondition((rows[0]["callback_entry_uptime_ns"] as! UInt64) == 100)
    precondition((rows[0]["encode_submit_uptime_ns"] as! UInt64) == frame.started)
    precondition((rows[0]["encode_callback_uptime_ns"] as! UInt64) >= frame.started)
    precondition((rows[1]["status"] as! Int) == SCFrameStatus.idle.rawValue && rows[1]["wire_pts_us"] == nil)
    precondition((rows[2]["pts_valid"] as! Int) == 0 && (rows[2]["status"] as! Int) == -1)

    // Source identity is carried by the same replaceable slot used in capture.
    var pending = LatestFrameSlot<UInt64>()
    _ = pending.replace(idle, received: 200)
    traced.sourceDisposition(idle, 2)
    let victim = pending.currentValue
    _ = pending.replace(invalid, received: 300)
    traced.sourceDisposition(victim, 3)
    traced.sourceDisposition(invalid, 2)
    let expired = pending.currentValue
    precondition(pending.take(now: 400, maximumAge: 50).expired)
    traced.sourceDisposition(expired, 4)
    let stopped = traced.sourceCallback(status: 0, pts: .zero, entry: 400)!
    _ = pending.replace(stopped, received: 400)
    traced.sourceDisposition(pending.currentValue, 5)
    _ = pending.clear()
    rows = traced.sourceTraceSnapshot()!["records"] as! [[String: Any]]
    precondition((rows[1]["disposition"] as! Int) == 3 && (rows[2]["disposition"] as! Int) == 4)
    precondition((rows[3]["disposition"] as! Int) == 5 && rows[1]["encode_submit_uptime_ns"] == nil)

    var packet = Data()
    appendBE(UInt32(0x47535631), to: &packet); appendBE(UInt32(4), to: &packet)
    appendBE(UInt64(987654), to: &packet); appendBE(UInt32(100), to: &packet); appendBE(UInt32(100), to: &packet)
    packet.append(contentsOf: [0, 0, 1, 0x65])
    traced.recordPacket(packet, outputStart: frame.started, packetReady: frame.started + 1,
        writeStart: frame.started + 2, writeDone: frame.started + 3, sourceCallbackSequence: complete)
    let packets = traced.packetTraceSnapshot()!["records"] as! [[String: UInt64]]
    precondition(packets[0]["source_callback_sequence"] == complete && packets[0]["source_timestamp_us"] == 987654)

    for index in 0..<CaptureMetrics.packetTraceCapacity {
        _ = traced.sourceCallback(status: index % 2, pts: CMTime(value: Int64(index), timescale: 600), entry: UInt64(500 + index))
    }
    traced.sourceDisposition(complete, 3) // A late update cannot corrupt a reused slot.
    let bounded = traced.sourceTraceSnapshot()!
    rows = bounded["records"] as! [[String: Any]]
    precondition(rows.count == 2048 && (bounded["truncated"] as! Int) == 1)
    precondition((bounded["first_callback_sequence"] as! UInt64) == 5 && (bounded["last_callback_sequence"] as! UInt64) == 2052)
    precondition((bounded["overwritten_callbacks"] as! UInt64) == 4 && (bounded["update_misses"] as! UInt64) == 1)
    precondition(rows.allSatisfy { ($0["disposition"] as! Int) == 0 })
    precondition(!FileManager.default.fileExists(atPath: path))
    await traced.finish(gauges: [:])
    let published = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any]
    precondition((published["source_trace"] as! [String: Any])["records"] is [[String: NSNumber]])
    precondition(published["packet_trace"] != nil)
    try FileManager.default.removeItem(atPath: path)
}

private func checkPacketTrace(directory: URL) async throws {
    func packet(kind: UInt32 = 0x47534131, pts: UInt64) -> Data {
        var data = Data()
        appendBE(kind, to: &data); appendBE(UInt32(4), to: &data); appendBE(pts, to: &data)
        appendBE(UInt32(48000), to: &data); appendBE(UInt32(2), to: &data)
        data.append(contentsOf: [0xde, 0xad, 0xbe, 0xef])
        return data
    }
    let path = directory.appendingPathComponent("trace.json").path
    let disabled = CaptureMetrics(path: path)
    disabled.recordPacket(packet(pts: 123), outputStart: 1, packetReady: 2, writeStart: 3, writeDone: 4)
    precondition(disabled.packetTraceTime() == nil && disabled.packetTraceSnapshot() == nil)
    precondition(!FileManager.default.fileExists(atPath: path), "Recording must never write on the hot path")

    let header = CaptureMetrics(path: path, packetTrace: true)
    let widePTS: UInt64 = 1_234_567_890_123
    header.recordPacket(packet(pts: widePTS), outputStart: 100, packetReady: 101, writeStart: 102, writeDone: 103)
    header.recordPacket(packet(kind: 0x47535631, pts: 0), outputStart: 103, packetReady: 103, writeStart: 103, writeDone: 103)
    header.recordPacket(Data(), outputStart: 0, packetReady: 0, writeStart: 0, writeDone: 0)
    header.recordPacket(packet(kind: 0, pts: 7), outputStart: 0, packetReady: 0, writeStart: 0, writeDone: 0)
    header.recordPacket(packet(pts: 7), outputStart: 4, packetReady: 3, writeStart: 5, writeDone: 6)
    let headerSnapshot = header.packetTraceSnapshot()!
    let headerRows = headerSnapshot["records"] as! [[String: UInt64]]
    precondition(headerRows.count == 2 && headerRows[0]["source_timestamp_us"] == widePTS)
    precondition(headerRows[0]["kind"] == 2 && headerRows[1]["kind"] == 1 && headerRows[1]["source_timestamp_us"] == 0)
    precondition((headerSnapshot["invalid_records"] as! UInt64) == 3)
    precondition((headerSnapshot["truncated"] as! Int) == 0)
    precondition(Set(headerRows[0].keys) == Set(["sequence", "kind", "source_timestamp_us", "output_start_uptime_ns",
        "packet_ready_uptime_ns", "write_start_uptime_ns", "write_done_uptime_ns"]), "Only numeric timing/header fields may be retained")

    let traced = CaptureMetrics(path: path, packetTrace: true)
    let empty = traced.packetTraceSnapshot()!
    precondition((empty["count"] as! Int) == 0 && empty["first_sequence"] == nil)
    for index in 0..<(CaptureMetrics.packetTraceCapacity + 2) {
        let time = UInt64(index) * 10 + 100_000_000_000_000
        traced.recordPacket(packet(kind: index % 2 == 0 ? 0x47535631 : 0x47534131, pts: UInt64(index)),
            outputStart: time, packetReady: time + 1, writeStart: time + 2, writeDone: time + 3)
    }
    let full = traced.packetTraceSnapshot()!
    let rows = full["records"] as! [[String: UInt64]]
    precondition(rows.count == 2048 && rows.first?["sequence"] == 3 && rows.last?["sequence"] == 2050)
    precondition(rows.first?["source_timestamp_us"] == 2 && rows.last?["source_timestamp_us"] == 2049)
    precondition((full["truncated"] as! Int) == 1 && (full["overwritten_records"] as! UInt64) == 2)
    precondition((full["video_first_sequence"] as! UInt64) == 3 && (full["audio_first_sequence"] as! UInt64) == 4)
    precondition((full["video_last_source_timestamp_us"] as! UInt64) == 2048 && (full["audio_last_source_timestamp_us"] as! UInt64) == 2049)
    precondition(!FileManager.default.fileExists(atPath: path), "Snapshots do not publish until the writer runs")
    await traced.finish(gauges: [:])
    let published = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any]
    let publishedTrace = published["packet_trace"] as! [String: Any]
    precondition((publishedTrace["records"] as! [[String: NSNumber]]).count == 2048)
    precondition((publishedTrace["last_sequence"] as! NSNumber).uint64Value == 2050)
    let fileMode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as! NSNumber
    precondition(fileMode.intValue == 0o600)
    try FileManager.default.removeItem(atPath: path)
}

// Pure synthetic PCM / packet-format checks. Never enumerates or captures windows.
func makeAudio(planar: Bool, rate: Double = 48_000) throws -> CMSampleBuffer {
    var formatInfo = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | (planar ? kAudioFormatFlagIsNonInterleaved : 0),
        mBytesPerPacket: planar ? 4 : 8, mFramesPerPacket: 1, mBytesPerFrame: planar ? 4 : 8,
        mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
    var format: CMAudioFormatDescription?
    try checked(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &formatInfo,
        layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
        formatDescriptionOut: &format), "test audio format")
    var sample: CMSampleBuffer?
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(rate)),
        presentationTimeStamp: CMTime(value: 12000, timescale: 1_000_000), decodeTimeStamp: .invalid)
    try checked(CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: true,
        makeDataReadyCallback: nil, refcon: nil, formatDescription: format, sampleCount: 3,
        sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0,
        sampleSizeArray: nil, sampleBufferOut: &sample), "test audio sample")
    let values: [[Float]] = planar ? [[0.25, -0.5, 1], [-0.25, 0.5, -1]] : [[0.25, -0.25, -0.5, 0.5, 1, -1]]
    let list = AudioBufferList.allocate(maximumBuffers: values.count)
    list.count = values.count
    defer { list.unsafeMutablePointer.deallocate() }
    var storage: [UnsafeMutableRawPointer] = []
    defer { storage.forEach { $0.deallocate() } }
    for (index, samples) in values.enumerated() {
        let bytes = samples.count * 4
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 16)
        samples.withUnsafeBytes { pointer.copyMemory(from: $0.baseAddress!, byteCount: bytes) }
        storage.append(pointer)
        list[index] = AudioBuffer(mNumberChannels: planar ? 1 : 2, mDataByteSize: UInt32(bytes), mData: pointer)
    }
    try checked(CMSampleBufferSetDataBufferFromAudioBufferList(sample!, blockBufferAllocator: kCFAllocatorDefault,
        blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: list.unsafePointer), "test audio data")
    return sample!
}

@main struct CaptureOfflineTests {
    static func main() async throws {
        checkLatestPending()
        let timestamp = CMTime(value: 12000, timescale: 1_000_000)
        let planar = try packetForAudioSample(makeAudio(planar: true), pts: timestamp)
        let interleaved = try packetForAudioSample(makeAudio(planar: false), pts: timestamp)
        precondition(planar == interleaved, "Planar/interleaved output mismatch")
        precondition(planar.count == 48 && String(data: planar.prefix(4), encoding: .utf8) == "GSA1")
        func be(_ range: Range<Int>) -> UInt64 { planar[range].reduce(0) { ($0 << 8) | UInt64($1) } }
        precondition(be(4..<8) == 24 && be(8..<16) == 12000 && be(16..<20) == 48000 && be(20..<24) == 2)
        let values = planar.dropFirst(24).withUnsafeBytes { $0.bindMemory(to: Float.self).map { $0 } }
        precondition(values == [0.25, -0.25, -0.5, 0.5, 1, -1], "Channel ordering / signed PCM damaged")
        do {
            _ = try packetForAudioSample(makeAudio(planar: true, rate: 44100), pts: timestamp)
            throw CaptureError("Unsupported PCM rate was relabeled")
        } catch let error as CaptureError {
            precondition(error.description.hasPrefix("Audio must be Float32LE"))
        }
        let full = try outputDimensions(source: CGSize(width: 2622, height: 1206), maxWidth: 3840)
        precondition(full == (2622, 1206), "Native source resolution must not shrink for a codec level")
        let small = try outputDimensions(source: CGSize(width: 1352, height: 878), maxWidth: 3840)
        precondition(small == (1352, 878), "Source content must not be upscaled")
        let reduced = try outputDimensions(source: CGSize(width: 2622, height: 1206), maxWidth: 1280)
        precondition(reduced.0 == 1280 && reduced.1 % 2 == 0)
        precondition(abs(Double(reduced.1) - 1280 * 1206 / 2622) <= 1)
        let heartbeat = packetForIdleHeartbeat(uptimeMicroseconds: 0x0102030405060708)
        precondition(heartbeat == Data([
            0x47, 0x53, 0x48, 0x31, 0, 0, 0, 1, 1, 2, 3, 4, 5, 6, 7, 8,
            0, 0, 0, 0, 0, 0, 0, 0, 0
        ]), "GSH1 heartbeat has an exact 24-byte header and one-byte sentinel")
        let boundToPID = try Options(["--window-id", "123", "--window-pid", "456"])
        precondition(boundToPID.windowID == 123 && boundToPID.windowPID == 456)
        let options = try Options(["--window-id", "123", "--audio", "--seconds", "5", "--width", "2622", "--fps", "60"])
        precondition(options.audio && options.seconds == 5 && options.windowID == 123 && options.width == 2622 && options.fps == 60)
        precondition(options.bitrate == 6_000_000, "Default bitrate must remain the comparison baseline")
        for bitrate in [250_000, 40_000_000, 80_000_000, 80_000_001, 160_000_000] {
            let quality = try Options(["--window-id", "123", "--bitrate", String(bitrate)])
            precondition(quality.bitrate == bitrate)
        }
        for bitrate in [249_999, 160_000_001] {
            do {
                _ = try Options(["--window-id", "123", "--bitrate", String(bitrate)])
                throw CaptureError("Bitrate boundary not enforced")
            } catch let error as CaptureError {
                precondition(error.description == "--bitrate must be 250000...160000000")
            }
        }
        precondition(options.metricsFile == nil, "Metrics must be opt-in")
        precondition(!options.packetTrace, "Packet tracing must be opt-in")
        let measured = try Options(["--window-id", "123", "--metrics-file", "/tmp/capture-metrics.json"])
        precondition(measured.metricsFile == "/tmp/capture-metrics.json")
        let traceOptions = try Options(["--window-id", "123", "--packet-trace", "--metrics-file", "/tmp/capture-metrics.json"])
        precondition(traceOptions.packetTrace)
        do {
            _ = try Options(["--window-id", "123", "--packet-trace"])
            throw CaptureError("Packet tracing silently accepted without a metrics destination")
        } catch let error as CaptureError {
            precondition(error.description == "--packet-trace requires --metrics-file")
        }
        for badPath in ["relative.json", "/tmp/", ""] {
            do {
                _ = try Options(["--window-id", "123", "--metrics-file", badPath])
                throw CaptureError("Invalid metrics path accepted")
            } catch let error as CaptureError {
                precondition(error.description == "--metrics-file requires an absolute file path")
            }
        }
        let testDirectory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
            .appendingPathComponent("metrics-test-" + UUID().uuidString)
        let files = FileManager.default
        try files.createDirectory(at: testDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: testDirectory) }
        try await checkPacketTrace(directory: testDirectory)
        try await checkSourceTrace(directory: testDirectory)
        let destination = testDirectory.appendingPathComponent("metrics.json")
        let sentinel = testDirectory.appendingPathComponent("sentinel")
        try Data("unchanged".utf8).write(to: sentinel)
        try files.createSymbolicLink(at: destination, withDestinationURL: sentinel)
        let metrics = CaptureMetrics(path: destination.path)
        metrics.screen(valid: true, status: SCFrameStatus.idle.rawValue, pts: .invalid)
        metrics.screen(valid: true, status: SCFrameStatus.complete.rawValue, pts: .zero)
        metrics.screen(valid: true, status: SCFrameStatus.complete.rawValue, pts: CMTime(value: 1, timescale: 60))
        let frame = metrics.beginEncode()
        metrics.encoderResult(frame, callback: false, status: noErr, flags: .frameDropped)
        metrics.encoderResult(frame, callback: true, status: noErr, flags: .frameDropped, hasSample: false)
        let snapshot = metrics.snapshot()
        precondition(snapshot["screen_callbacks"] == 3 && snapshot["screen_complete"] == 2 && snapshot["screen_idle"] == 1)
        precondition(snapshot["screen_complete_pts_gap_count"] == 1)
        precondition(abs(snapshot["screen_complete_pts_gap_mean_ms"]! - 1000.0 / 60) < 0.001)
        precondition(snapshot["encoder_drops"] == 1 && snapshot["encoder_call_dropped"] == 1 && snapshot["encoder_callback_dropped"] == 1)
        try CaptureMetrics.writeSnapshot(snapshot, to: destination.path)
        let preservedSentinel = try Data(contentsOf: sentinel)
        precondition(preservedSentinel == Data("unchanged".utf8), "Atomic replacement must not follow existing symlink")
        let attributes = try files.attributesOfItem(atPath: destination.path)
        precondition((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        metrics.start { ["pending_audio_frames": 0] }
        try await Task.sleep(nanoseconds: 2_200_000_000)
        await metrics.finish(gauges: ["video_busy_now": 0])
        let published = try JSONSerialization.jsonObject(with: Data(contentsOf: destination)) as! [String: NSNumber]
        precondition(published["stopped"] == 1 && published["snapshot_sequence"]!.intValue >= 4)
        precondition(published["elapsed_seconds"]!.doubleValue >= 2)
        precondition(published.values.allSatisfy { $0.doubleValue.isFinite })
        let remaining = try files.contentsOfDirectory(atPath: testDirectory.path).sorted()
        precondition(remaining == ["metrics.json", "sentinel"], "Temporary metrics file leaked")
        print("PASS GSH1 heartbeat framing and window-owner CLI; opt-in packet trace/header-only PTS/kind/time boundaries/2048-ring order and coverage/truncation/no hot-path file/JSON publication; latest-only raw slot/retention/replacement/155ms stall/age bound/stop cleanup/PTS preservation/late and duplicate callbacks/output completion; synthetic PCM/framing/dimensions/CLI; opt-in metrics status counts, PTS gaps, deduplicated encoder drops, numeric JSON, 2s timer/final flush, atomic symlink replacement and 0600 permissions")
    }
}
