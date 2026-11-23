import Foundation
import AppKit
import ScreenCaptureKit
import VideoToolbox
import CoreGraphics
import AudioToolbox
import Darwin

// No display capture path exists in this executable. Window selection is mandatory.
struct CaptureError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

func diagnostic(_ event: String, _ fields: [String: Any] = [:]) {
    var value = fields
    value["event"] = event
    if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
        FileHandle.standardError.write(data + Data([10]))
    }
}

func rectJSON(_ r: CGRect) -> [String: Double] {
    ["x": r.origin.x, "y": r.origin.y, "width": r.width, "height": r.height]
}

func attachmentRect(_ value: Any?) -> CGRect? {
    if let dictionary = value as? NSDictionary {
        return CGRect(dictionaryRepresentation: dictionary)
    }
    if let value = value as? NSValue { return value.rectValue }
    return nil
}

// Whitelist color metadata only: never read pixel planes, dump all attachments,
// or change the input buffer while inspecting the first submitted frame.
func captureInputColorMetadata(_ sample: CMSampleBuffer, image: CVPixelBuffer) -> [String: Any] {
    func scalar(_ value: CFTypeRef?) -> Any {
        guard let value else { return NSNull() }
        if let string = value as? String { return string }
        if let number = value as? NSNumber, number.doubleValue.isFinite { return number }
        return ["unexpected_type_id": CFGetTypeID(value)]
    }
    let pixelFormat = CVPixelBufferGetPixelFormatType(image)
    let fourCC = (0..<4).map { UInt8(truncatingIfNeeded: pixelFormat >> (24 - $0 * 8)) }
    var attachments: [String: Any] = [:]
    for key in [kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey,
                kCVImageBufferYCbCrMatrixKey, kCVImageBufferGammaLevelKey] {
        attachments[key as String] = scalar(CVBufferCopyAttachment(image, key, nil))
    }
    var colorSpace: [String: Any] = ["present": false]
    if let value = CVBufferCopyAttachment(image, kCVImageBufferCGColorSpaceKey, nil) {
        colorSpace["present"] = true
        if CFGetTypeID(value) == CGColorSpace.typeID {
            let space = value as! CGColorSpace
            colorSpace["name"] = scalar(space.name)
        } else {
            colorSpace["unexpected_type_id"] = CFGetTypeID(value)
        }
    }
    let format = CMSampleBufferGetFormatDescription(sample)
    var extensions: [String: Any] = [:]
    for key in [kCMFormatDescriptionExtension_ColorPrimaries,
                kCMFormatDescriptionExtension_TransferFunction,
                kCMFormatDescriptionExtension_YCbCrMatrix,
                kCMFormatDescriptionExtension_FullRangeVideo] {
        extensions[key as String] = scalar(format.flatMap {
            CMFormatDescriptionGetExtension($0, extensionKey: key)
        })
    }
    return ["pixel_format_code": pixelFormat,
            "pixel_format": String(bytes: fourCC, encoding: .ascii) ?? "non_ascii",
            "image_buffer_attachments": attachments,
            "image_buffer_cg_color_space": colorSpace,
            "image_buffer_icc_profile_present": CVBufferHasAttachment(image, kCVImageBufferICCProfileKey),
            "source_format_present": format != nil,
            "source_format_extensions": extensions]
}

struct Options {
    var windowID: CGWindowID?
    var windowPID: pid_t?
    var fps = 30
    var width = 1280
    var bitrate = 6_000_000
    var audio = false
    var seconds = 0
    var metricsFile: String?
    var packetTrace = false
    var contentFingerprint = false
    var command = "capture"

    init(_ args: [String]) throws {
        var index = 0
        while index < args.count {
            let arg = args[index]
            if ["--list-windows", "--preflight", "--request-permission", "--help"].contains(arg) {
                command = arg
            } else if arg == "--audio" {
                audio = true
            } else if arg == "--packet-trace" {
                packetTrace = true
            } else if arg == "--content-fingerprint" {
                contentFingerprint = true
            } else if arg == "--metrics-file" {
                guard index + 1 < args.count, args[index + 1].hasPrefix("/"),
                      !args[index + 1].hasSuffix("/"), !args[index + 1].contains("\0") else {
                    throw CaptureError("--metrics-file requires an absolute file path")
                }
                metricsFile = args[index + 1]
                index += 1
            } else {
                guard index + 1 < args.count, let number = Int(args[index + 1]) else {
                    throw CaptureError("Expected integer after \(arg)")
                }
                switch arg {
                case "--window-id":
                    guard number > 0, number <= Int(UInt32.max) else { throw CaptureError("Invalid window ID") }
                    windowID = CGWindowID(number)
                case "--window-pid":
                    guard number > 0, number <= Int(Int32.max) else { throw CaptureError("Invalid window owner PID") }
                    windowPID = pid_t(number)
                case "--fps": fps = number
                case "--width": width = number
                case "--bitrate": bitrate = number
                case "--seconds": seconds = number
                default: throw CaptureError("Unknown option \(arg)")
                }
                index += 1
            }
            index += 1
        }
        guard fps == 30 || fps == 60 else { throw CaptureError("--fps must be 30 or 60") }
        guard width >= 320 && width <= 3840 else { throw CaptureError("--width must be 320...3840") }
        guard bitrate >= 250_000 && bitrate <= 160_000_000 else { throw CaptureError("--bitrate must be 250000...160000000") }
        guard seconds >= 0 && seconds <= 3600 else { throw CaptureError("--seconds must be 0...3600 (0 means unlimited)") }
        if command == "capture" && windowID == nil { throw CaptureError("--window-id is required; no desktop fallback") }
        if packetTrace && metricsFile == nil { throw CaptureError("--packet-trace requires --metrics-file") }
        if contentFingerprint && metricsFile == nil { throw CaptureError("--content-fingerprint requires --metrics-file") }
    }
}

// Diagnostic only: FNV-1a of a 64 x 36 grid over the central 80% of NV12 luma.
// A different hash proves sampled values changed; equality does not prove that
// the image is identical (unsampled changes and hash collisions remain possible).
// No pixel values, sample array, image, or buffer reference leave this function.
func contentFingerprint(_ image: CVPixelBuffer) -> (hash: UInt64?, error: String?) {
    let format = CVPixelBufferGetPixelFormatType(image)
    guard format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
          format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange else { return (nil, "format") }
    guard CVPixelBufferIsPlanar(image), CVPixelBufferGetPlaneCount(image) == 2 else { return (nil, "planes") }
    let width = CVPixelBufferGetWidthOfPlane(image, 0)
    let height = CVPixelBufferGetHeightOfPlane(image, 0)
    let stride = CVPixelBufferGetBytesPerRowOfPlane(image, 0)
    guard width >= 80, height >= 45, width == CVPixelBufferGetWidth(image),
          height == CVPixelBufferGetHeight(image), stride >= width,
          width <= Int.max / 128, height <= Int.max / 72,
          stride > 0, height <= Int.max / stride,
          CVPixelBufferGetDataSize(image) >= stride * height else { return (nil, "dimensions") }
    guard CVPixelBufferLockBaseAddress(image, .readOnly) == kCVReturnSuccess else { return (nil, "lock") }
    defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddressOfPlane(image, 0) else { return (nil, "base") }
    let bytes = base.assumingMemoryBound(to: UInt8.self)
    let left = width / 10, top = height / 10
    let spanX = width - 2 * left, spanY = height - 2 * top
    var hash: UInt64 = 14_695_981_039_346_656_037
    for row in 0..<36 {
        let y = top + (2 * row + 1) * spanY / 72
        for column in 0..<64 {
            let x = left + (2 * column + 1) * spanX / 128
            hash = (hash ^ UInt64(bytes[y * stride + x])) &* 1_099_511_628_211
        }
    }
    return (hash, nil)
}

// Optional numeric-only diagnostics. Except for explicit content-fingerprint sampling,
// the hot path only updates short locked counters and attachment metadata;
// JSON serialization and atomic 0600 file replacement run on a separate utility queue.
// No window identity, geometry, packet contents, addresses, or command line are stored.
final class CaptureMetrics: @unchecked Sendable {
    private struct PacketTrace {
        let sequence: UInt64
        let kind: UInt64
        let pts: UInt64
        let outputStart: UInt64
        let packetReady: UInt64
        let writeStart: UInt64
        let writeDone: UInt64
        let sourceCallbackSequence: UInt64?
        var numeric: [String: UInt64] {
            var result = ["sequence": sequence, "kind": kind, "source_timestamp_us": pts,
             "output_start_uptime_ns": outputStart, "packet_ready_uptime_ns": packetReady,
             "write_start_uptime_ns": writeStart, "write_done_uptime_ns": writeDone]
            if let sourceCallbackSequence { result["source_callback_sequence"] = sourceCallbackSequence }
            return result
        }
    }
    private struct SourceTrace {
        let sequence: UInt64
        let status: Int
        let pts: CMTime // Scalar timestamp only; never a retained sample or surface.
        let entry: UInt64
        var displayTime: UInt64?
        var dirtyRectCount: Int?
        var dirtyRectInvalidCount = 0
        var dirtyRectNonemptyCount = 0
        var dirtyRectAreaSum: Double = 0
        var contentHash: UInt64?
        var fingerprintCostNS: UInt64?
        var disposition = 0
        var wirePTS: Int64?
        var encodeSubmit: UInt64?
        var encodeCallback: UInt64?
        var callbackStatus: OSStatus?
        var callbackDropped: Bool?
        var numeric: [String: Any] {
            var result: [String: Any] = ["callback_sequence": sequence, "status": status,
                "pts_valid": pts.isNumeric ? 1 : 0, "raw_pts_value": pts.value,
                "raw_pts_timescale": pts.timescale, "raw_pts_epoch": pts.epoch,
                "callback_entry_uptime_ns": entry, "disposition": disposition]
            if let displayTime { result["display_time_mach_absolute"] = displayTime }
            if let contentHash { result["content_fingerprint_u64"] = contentHash }
            if let fingerprintCostNS { result["content_fingerprint_cost_ns"] = fingerprintCostNS }
            if let dirtyRectCount {
                result["dirty_rect_count"] = dirtyRectCount
                result["dirty_rect_invalid_count"] = dirtyRectInvalidCount
                result["dirty_rect_nonempty_count"] = dirtyRectNonemptyCount
                // Rectangles can overlap. This is deliberately not a union area
                // or proof that any of these pixels changed value.
                result["dirty_rect_area_sum_pixels"] = dirtyRectAreaSum
            }
            if let wirePTS { result["wire_pts_us"] = wirePTS }
            if let encodeSubmit { result["encode_submit_uptime_ns"] = encodeSubmit }
            if let encodeCallback { result["encode_callback_uptime_ns"] = encodeCallback }
            if let callbackStatus { result["encode_callback_status"] = callbackStatus }
            if let callbackDropped { result["encode_callback_dropped"] = callbackDropped ? 1 : 0 }
            return result
        }
    }
    static let packetTraceCapacity = 2048
    private let packetTraceEnabled: Bool
    private var packetTraces: [PacketTrace?]
    private var packetTraceSequence: UInt64 = 0
    private var packetTraceInvalid: UInt64 = 0
    private var sourceTraces: [SourceTrace?]
    private var sourceTraceSequence: UInt64 = 0
    private var sourceTraceUpdateMisses: UInt64 = 0
    final class Frame: @unchecked Sendable {
        let started = DispatchTime.now().uptimeNanoseconds
        let sourceSequence: UInt64?
        fileprivate var dropCounted = false // Protected by CaptureMetrics.lock.
        init(sourceSequence: UInt64? = nil) { self.sourceSequence = sourceSequence }
    }
    private struct Timing {
        var count: Double = 0
        var total: Double = 0
        var maximum: Double = 0
        var overFrame: Double = 0
        var over50ms: Double = 0
        mutating func add(_ milliseconds: Double) {
            count += 1; total += milliseconds; maximum = max(maximum, milliseconds)
            if milliseconds > 1000.0 / 60 { overFrame += 1 }
            if milliseconds > 50 { over50ms += 1 }
        }
    }
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "stream.capture.metrics", qos: .utility)
    private let path: String
    private let started = DispatchTime.now().uptimeNanoseconds
    private var timer: DispatchSourceTimer?
    private var values: [String: Double] = [:]
    private var timings: [String: Timing] = [:]
    private var lastScreenCallback: UInt64?
    private var lastCompletePTS: Double?
    private var lastCompleteCallback: UInt64?
    private var lastSnapshot: UInt64?
    private var sequence: Double = 0
    private var lastContentHash: UInt64?

    init(path: String, packetTrace: Bool = false) {
        self.path = path
        packetTraceEnabled = packetTrace
        packetTraces = packetTrace ? Array(repeating: nil, count: Self.packetTraceCapacity) : []
        sourceTraces = packetTrace ? Array(repeating: nil, count: Self.packetTraceCapacity) : []
        let counters = "screen_callbacks screen_invalid screen_missing_status screen_complete screen_idle screen_blank screen_suspended screen_started screen_stopped screen_unknown screen_missing_image screen_missing_encoder video_accepted video_busy_skipped video_stopping_skipped video_timestamp_skipped video_written idle_heartbeat_written encoder_submitted encoder_call_errors encoder_call_dropped encoder_callbacks encoder_callback_errors encoder_callback_dropped encoder_callback_missing_sample encoder_drops audio_callbacks audio_invalid audio_timestamp_skipped audio_empty audio_oversize audio_accepted audio_busy_skipped audio_stopping_skipped audio_written pipe_write_errors metrics_write_errors capture_ready stopped"
        for key in counters.split(separator: " ") { values[String(key)] = 0 }
        for key in ["screen_callback_gap", "screen_complete_callback_gap", "screen_complete_pts_gap", "encoder_call", "encoder_callback", "video_output_queue", "audio_output_queue", "video_busy", "video_pipe_write", "audio_pipe_write", "heartbeat_pipe_write"] {
            timings[key] = Timing()
        }
    }

    func increment(_ key: String, by amount: Double = 1) {
        lock.withLock { values[key, default: 0] += amount }
    }

    func observe(_ key: String, since start: UInt64) {
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        lock.withLock { timings[key, default: Timing()].add(elapsed) }
    }

    // Disabled tracing does not read the clock, inspect headers, or allocate a ring.
    func packetTraceTime() -> UInt64? {
        packetTraceEnabled ? DispatchTime.now().uptimeNanoseconds : nil
    }

    func recordPacket(_ packet: Data, outputStart: UInt64, packetReady: UInt64,
                      writeStart: UInt64, writeDone: UInt64, sourceCallbackSequence: UInt64? = nil) {
        guard packetTraceEnabled else { return }
        guard packet.count >= 24, outputStart <= packetReady, packetReady <= writeStart,
              writeStart <= writeDone else {
            lock.withLock { packetTraceInvalid += 1 }; return
        }
        // Read only the fixed wire header. Never retain packet data or payload bytes.
        let magic = packet.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let kind: UInt64
        switch magic {
        case 0x47535631: kind = 1 // GSV1
        case 0x47534131: kind = 2 // GSA1
        default: lock.withLock { packetTraceInvalid += 1 }; return
        }
        let pts = packet.dropFirst(8).prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        lock.withLock {
            let index = Int(packetTraceSequence % UInt64(Self.packetTraceCapacity))
            packetTraceSequence += 1
            packetTraces[index] = PacketTrace(sequence: packetTraceSequence, kind: kind, pts: pts,
                outputStart: outputStart, packetReady: packetReady, writeStart: writeStart, writeDone: writeDone,
                sourceCallbackSequence: sourceCallbackSequence)
        }
    }

    func sourceCallback(status: Int?, pts: CMTime, entry: UInt64, info: [SCStreamFrameInfo: Any]? = nil) -> UInt64? {
        guard packetTraceEnabled else { return nil }
        // Metadata only: no surface lock, pixel read, hash, or retained sample.
        // A complete frame, advancing display time, or nonempty dirty region is
        // not evidence of a distinct rendered frame or an input-to-display delay.
        var trace = SourceTrace(sequence: 0, status: status ?? -1, pts: pts, entry: entry)
        trace.displayTime = info?[.displayTime] as? UInt64
        if let rectangles = info?[.dirtyRects] as? [Any] {
            trace.dirtyRectCount = rectangles.count
            for value in rectangles {
                guard let rect = attachmentRect(value), rect.origin.x.isFinite, rect.origin.y.isFinite,
                      rect.width.isFinite, rect.height.isFinite, rect.width >= 0, rect.height >= 0 else {
                    trace.dirtyRectInvalidCount += 1; continue
                }
                if rect.width > 0 && rect.height > 0 {
                    trace.dirtyRectNonemptyCount += 1
                    trace.dirtyRectAreaSum += Double(rect.width * rect.height)
                }
            }
        }
        return lock.withLock {
            let index = Int(sourceTraceSequence % UInt64(Self.packetTraceCapacity))
            sourceTraceSequence += 1
            sourceTraces[index] = SourceTrace(sequence: sourceTraceSequence, status: trace.status, pts: trace.pts,
                entry: trace.entry, displayTime: trace.displayTime, dirtyRectCount: trace.dirtyRectCount,
                dirtyRectInvalidCount: trace.dirtyRectInvalidCount, dirtyRectNonemptyCount: trace.dirtyRectNonemptyCount,
                dirtyRectAreaSum: trace.dirtyRectAreaSum)
            return sourceTraceSequence
        }
    }

    func fingerprint(hash: UInt64?, error: String?, costNS: UInt64, sourceSequence: UInt64?) {
        lock.withLock {
            values["content_fingerprint_attempts", default: 0] += 1
            values["content_fingerprint_cost_total_ns", default: 0] += Double(costNS)
            values["content_fingerprint_cost_max_ns"] = max(values["content_fingerprint_cost_max_ns", default: 0], Double(costNS))
            if let error {
                values["content_fingerprint_errors", default: 0] += 1
                values["content_fingerprint_error_" + error, default: 0] += 1
            }
            if let hash {
                values["content_fingerprint_samples", default: 0] += 1
                // Comparisons are between successive successful samples, which
                // can span skipped/error callbacks. They are not engine FPS.
                if let previous = lastContentHash {
                    values[hash == previous ? "content_fingerprint_equal" : "content_fingerprint_changed", default: 0] += 1
                }
                lastContentHash = hash
            }
            if packetTraceEnabled, let sourceSequence { updateSourceLocked(sourceSequence) {
                $0.contentHash = hash; $0.fingerprintCostNS = costNS
            } }
        }
    }

    // Caller holds lock. An overwritten token must never mutate its replacement.
    private func updateSourceLocked(_ sequence: UInt64, _ update: (inout SourceTrace) -> Void) {
        guard sequence > 0 else { sourceTraceUpdateMisses += 1; return }
        let index = Int((sequence - 1) % UInt64(Self.packetTraceCapacity))
        guard var value = sourceTraces[index], value.sequence == sequence else {
            sourceTraceUpdateMisses += 1; return
        }
        update(&value)
        sourceTraces[index] = value
    }

    // 0=not admitted (e.g. idle), 1=submitted, 2=pending, 3=replaced,
    // 4=expired, 5=stopping, 6=invalid/missing input or rejected admission.
    func sourceDisposition(_ sequence: UInt64?, _ disposition: Int) {
        guard packetTraceEnabled, let sequence else { return }
        lock.withLock { updateSourceLocked(sequence) { $0.disposition = disposition } }
    }

    func sourceTraceSnapshot() -> [String: Any]? {
        guard packetTraceEnabled else { return nil }
        let (records, total, misses) = lock.withLock { () -> ([SourceTrace], UInt64, UInt64) in
            let count = Int(min(sourceTraceSequence, UInt64(Self.packetTraceCapacity)))
            let first = sourceTraceSequence - UInt64(count)
            return ((0..<count).compactMap { sourceTraces[Int((first + UInt64($0)) % UInt64(Self.packetTraceCapacity))] },
                    sourceTraceSequence, sourceTraceUpdateMisses)
        }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        var result: [String: Any] = ["schema_version": 2, "capacity": Self.packetTraceCapacity,
            "display_time_mach_timebase_numer": timebase.numer, "display_time_mach_timebase_denom": timebase.denom,
            "count": records.count, "total_callbacks": total, "update_misses": misses,
            "truncated": total > UInt64(Self.packetTraceCapacity) ? 1 : 0,
            "overwritten_callbacks": total - UInt64(records.count), "records": records.map { $0.numeric }]
        if let first = records.first, let last = records.last {
            result["first_callback_sequence"] = first.sequence; result["last_callback_sequence"] = last.sequence
            result["first_callback_entry_uptime_ns"] = first.entry; result["last_callback_entry_uptime_ns"] = last.entry
            result["first_raw_pts_value"] = first.pts.value; result["first_raw_pts_timescale"] = first.pts.timescale
            result["last_raw_pts_value"] = last.pts.value; result["last_raw_pts_timescale"] = last.pts.timescale
        }
        return result
    }

    func packetTraceSnapshot() -> [String: Any]? {
        guard packetTraceEnabled else { return nil }
        let (records, total, invalid) = lock.withLock { () -> ([PacketTrace], UInt64, UInt64) in
            let count = Int(min(packetTraceSequence, UInt64(Self.packetTraceCapacity)))
            let first = packetTraceSequence - UInt64(count)
            let records = (0..<count).compactMap { packetTraces[Int((first + UInt64($0)) % UInt64(Self.packetTraceCapacity))] }
            return (records, packetTraceSequence, packetTraceInvalid)
        }
        // Dictionary construction/JSON serialization occurs on the existing writer queue.
        var result: [String: Any] = ["schema_version": 1, "capacity": Self.packetTraceCapacity,
            "count": records.count, "total_records": total, "invalid_records": invalid,
            "truncated": total > UInt64(Self.packetTraceCapacity) ? 1 : 0,
            "overwritten_records": total - UInt64(records.count), "records": records.map { $0.numeric }]
        if let first = records.first, let last = records.last {
            result["first_sequence"] = first.sequence; result["last_sequence"] = last.sequence
            result["first_kind"] = first.kind; result["last_kind"] = last.kind
            result["first_source_timestamp_us"] = first.pts; result["last_source_timestamp_us"] = last.pts
        }
        for (kind, name) in [(UInt64(1), "video"), (UInt64(2), "audio")] {
            if let first = records.first(where: { $0.kind == kind }), let last = records.last(where: { $0.kind == kind }) {
                result[name + "_first_source_timestamp_us"] = first.pts
                result[name + "_last_source_timestamp_us"] = last.pts
                result[name + "_first_sequence"] = first.sequence
                result[name + "_last_sequence"] = last.sequence
            }
        }
        return result
    }

    func screen(valid: Bool, status: Int?, pts: CMTime) {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.withLock {
            values["screen_callbacks", default: 0] += 1
            if let previous = lastScreenCallback { timings["screen_callback_gap"]!.add(Double(now - previous) / 1_000_000) }
            lastScreenCallback = now
            if !valid { values["screen_invalid", default: 0] += 1 }
            let key: String
            switch status.flatMap(SCFrameStatus.init(rawValue:)) {
            case .complete: key = "screen_complete"
            case .idle: key = "screen_idle"
            case .blank: key = "screen_blank"
            case .suspended: key = "screen_suspended"
            case .started: key = "screen_started"
            case .stopped: key = "screen_stopped"
            default: key = status == nil ? "screen_missing_status" : "screen_unknown"
            }
            values[key, default: 0] += 1
            if status == SCFrameStatus.complete.rawValue {
                if let previous = lastCompleteCallback { timings["screen_complete_callback_gap"]!.add(Double(now - previous) / 1_000_000) }
                lastCompleteCallback = now
                if pts.isNumeric {
                    let seconds = CMTimeGetSeconds(pts)
                    if let previous = lastCompletePTS, seconds >= previous { timings["screen_complete_pts_gap"]!.add((seconds - previous) * 1000) }
                    lastCompletePTS = seconds
                }
            }
        }
    }

    func beginEncode(sourceSequence: UInt64? = nil, wirePTS: Int64? = nil) -> Frame {
        increment("encoder_submitted")
        let frame = Frame(sourceSequence: packetTraceEnabled ? sourceSequence : nil)
        if let sequence = frame.sourceSequence, let wirePTS {
            lock.withLock { updateSourceLocked(sequence) {
                $0.disposition = 1; $0.wirePTS = wirePTS; $0.encodeSubmit = frame.started
            } }
        }
        return frame
    }

    func encoderResult(_ frame: Frame, callback: Bool, status: OSStatus, flags: VTEncodeInfoFlags, hasSample: Bool = true) {
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = Double(now - frame.started) / 1_000_000
        lock.withLock {
            if packetTraceEnabled, callback, let sequence = frame.sourceSequence {
                updateSourceLocked(sequence) {
                    $0.encodeCallback = now; $0.callbackStatus = status; $0.callbackDropped = flags.contains(.frameDropped)
                }
            }
            let prefix = callback ? "encoder_callback" : "encoder_call"
            timings[prefix]!.add(elapsed)
            if callback { values["encoder_callbacks", default: 0] += 1 }
            if status != noErr { values[prefix + "_errors", default: 0] += 1 }
            if callback && !hasSample { values["encoder_callback_missing_sample", default: 0] += 1 }
            if flags.contains(.frameDropped) {
                values[prefix + "_dropped", default: 0] += 1
                if !frame.dropCounted { values["encoder_drops", default: 0] += 1; frame.dropCounted = true }
            }
        }
    }

    func snapshot(gauges: [String: Double] = [:]) -> [String: Double] {
        let now = DispatchTime.now().uptimeNanoseconds
        return lock.withLock {
            var result = values
            sequence += 1
            result["schema_version"] = 1
            result["snapshot_sequence"] = sequence
            result["elapsed_seconds"] = Double(now - started) / 1_000_000_000
            result["interval_seconds"] = Double(now - (lastSnapshot ?? started)) / 1_000_000_000
            lastSnapshot = now
            for (key, timing) in timings {
                result[key + "_count"] = timing.count
                result[key + "_total_ms"] = timing.total
                result[key + "_max_ms"] = timing.maximum
                result[key + "_mean_ms"] = timing.count > 0 ? timing.total / timing.count : 0
                result[key + "_over_16_667_ms"] = timing.overFrame
                result[key + "_over_50_ms"] = timing.over50ms
            }
            result.merge(gauges) { _, new in new }
            return result
        }
    }

    // Same-directory rename publishes complete JSON with private permissions from
    // its first byte. O_EXCL/O_NOFOLLOW prevents following a temporary-file symlink.
    static func writeSnapshot(_ value: [String: Any], to path: String) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) + Data([10])
        let temporary = path + "." + UUID().uuidString + ".tmp"
        let descriptor = Darwin.open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw CaptureError("Metrics create errno \(errno)") }
        defer { Darwin.close(descriptor); Darwin.unlink(temporary) }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else { throw CaptureError("Metrics permissions errno \(errno)") }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count > 0 { offset += count }
                else if count < 0 && errno == EINTR { continue }
                else { throw CaptureError("Metrics write errno \(errno)") }
            }
        }
        guard Darwin.rename(temporary, path) == 0 else { throw CaptureError("Metrics rename errno \(errno)") }
    }

    private func publish(gauges: [String: Double]) {
        var value: [String: Any] = snapshot(gauges: gauges)
        if let trace = packetTraceSnapshot() { value["packet_trace"] = trace }
        if let trace = sourceTraceSnapshot() { value["source_trace"] = trace }
        // Preserve all 64 hash bits; the ordinary counters use Double.
        if let hash = lock.withLock({ lastContentHash }) { value["content_fingerprint_last_u64"] = hash }
        do { try Self.writeSnapshot(value, to: path) }
        catch {
            let first = lock.withLock { () -> Bool in
                values["metrics_write_errors", default: 0] += 1
                return values["metrics_write_errors"] == 1
            }
            if first { diagnostic("metrics_write_failed") }
        }
    }

    func start(gauges: @escaping @Sendable () -> [String: Double]) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .seconds(2), leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.publish(gauges: gauges()) }
        self.timer = timer
        timer.resume()
    }

    func finish(gauges: [String: Double]) async {
        timer?.cancel(); timer = nil
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async {
                self.increment("stopped")
                self.publish(gauges: gauges)
                done.resume()
            }
        }
    }
}

func checked(_ result: OSStatus, _ operation: String) throws {
    if result != noErr { throw CaptureError("\(operation) failed (OSStatus \(result))") }
}

// Native receivers accept High with an encoder-selected level. Only the requested
// width and source size constrain dimensions; never upscale either source axis.
func outputDimensions(source: CGSize, maxWidth: Int) throws -> (Int, Int) {
    guard source.width.isFinite, source.height.isFinite, source.width >= 2, source.height >= 2 else {
        throw CaptureError("Window has invalid content geometry")
    }
    let width = min(maxWidth, Int(source.width)) / 2 * 2
    guard width >= 2 else { throw CaptureError("Output width is too small") }
    let height = min(Int(source.height) / 2 * 2,
        max(2, Int((Double(width) * source.height / source.width / 2).rounded()) * 2))
    return (width, height)
}

func appendBE<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    var big = value.bigEndian
    withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
}

func packetForIdleHeartbeat(uptimeMicroseconds: UInt64) -> Data {
    var packet = Data("GSH1".utf8)
    appendBE(UInt32(1), to: &packet)
    appendBE(uptimeMicroseconds, to: &packet)
    appendBE(UInt32(0), to: &packet)
    appendBE(UInt32(0), to: &packet)
    packet.append(0)
    return packet
}

func packetForSample(_ sample: CMSampleBuffer, width: Int, height: Int) throws -> Data {
    guard let block = CMSampleBufferGetDataBuffer(sample),
          let format = CMSampleBufferGetFormatDescription(sample) else { throw CaptureError("Missing encoded buffer/format") }
    let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[String: Any]]
    let isKeyframe = (attachments?.first?[kCMSampleAttachmentKey_NotSync as String] as? Bool) != true
    var payload = Data()
    var nalLengthBytes: Int32 = 0
    var parameterCount = 0
    try checked(CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0,
        parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &parameterCount,
        nalUnitHeaderLengthOut: &nalLengthBytes), "Read H264 format")
    if isKeyframe {
        for index in 0..<parameterCount {
            var pointer: UnsafePointer<UInt8>?
            var length = 0
            try checked(CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index,
                parameterSetPointerOut: &pointer, parameterSetSizeOut: &length, parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil), "Read H264 parameter set")
            guard let pointer, length > 0 else { throw CaptureError("Empty H264 parameter set") }
            payload.append(contentsOf: [0, 0, 0, 1])
            payload.append(pointer, count: length)
        }
    }
    guard [1, 2, 4].contains(nalLengthBytes) else { throw CaptureError("Invalid AVCC length field") }
    let length = CMBlockBufferGetDataLength(block)
    guard length > 0 && length <= 16 * 1024 * 1024 else { throw CaptureError("Invalid encoded sample size") }
    var avcc = Data(count: length)
    let status = avcc.withUnsafeMutableBytes { bytes in
        CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: bytes.baseAddress!)
    }
    try checked(status, "Copy encoded sample")
    var offset = 0
    while offset < avcc.count {
        guard offset + Int(nalLengthBytes) <= avcc.count else { throw CaptureError("Truncated AVCC length") }
        var size = 0
        for _ in 0..<nalLengthBytes { size = (size << 8) | Int(avcc[offset]); offset += 1 }
        guard size > 0 && size <= avcc.count - offset else { throw CaptureError("Truncated AVCC NAL") }
        payload.append(contentsOf: [0, 0, 0, 1])
        payload.append(avcc[offset..<offset + size])
        offset += size
    }
    let pts = CMTimeConvertScale(CMSampleBufferGetPresentationTimeStamp(sample), timescale: 1_000_000, method: .default)
    guard pts.isNumeric && pts.value >= 0 else { throw CaptureError("Invalid encoded timestamp") }
    var packet = Data("GSV1".utf8)
    appendBE(UInt32(payload.count), to: &packet)
    appendBE(UInt64(pts.value), to: &packet)
    appendBE(UInt32(width), to: &packet)
    appendBE(UInt32(height), to: &packet)
    packet.append(payload)
    return packet
}

// SCK's requested 48 kHz stereo PCM is checked, not merely relabeled. Preserve Float32
// sample bits while interleaving planar input; no extra audio converter or buffering.
func packetForAudioSample(_ sample: CMSampleBuffer, pts: CMTime) throws -> Data {
    guard let format = CMSampleBufferGetFormatDescription(sample),
          let pointer = CMAudioFormatDescriptionGetStreamBasicDescription(format) else {
        throw CaptureError("Audio format description missing")
    }
    let formatInfo = pointer.pointee
    guard formatInfo.mFormatID == kAudioFormatLinearPCM,
          formatInfo.mSampleRate == 48_000, formatInfo.mChannelsPerFrame == 2,
          formatInfo.mBitsPerChannel == 32,
          formatInfo.mFormatFlags & kAudioFormatFlagIsFloat != 0,
          formatInfo.mFormatFlags & kAudioFormatFlagIsBigEndian == 0 else {
        throw CaptureError("Audio must be Float32LE PCM 48000Hz stereo; received rate=\(formatInfo.mSampleRate) channels=\(formatInfo.mChannelsPerFrame) flags=\(formatInfo.mFormatFlags) bits=\(formatInfo.mBitsPerChannel)")
    }
    let frames = CMSampleBufferGetNumSamples(sample)
    guard frames > 0 && frames <= 4800 else { throw CaptureError("Audio chunk exceeds 100ms") }
    var payload = Data(count: frames * 2 * MemoryLayout<Float>.size)
    try sample.withAudioBufferList { buffers, _ in
        if buffers.count == 1 && buffers[0].mNumberChannels == 2 {
            guard let source = buffers[0].mData, Int(buffers[0].mDataByteSize) >= payload.count else {
                throw CaptureError("Truncated interleaved audio")
            }
            payload.withUnsafeMutableBytes { destination in
                destination.baseAddress!.copyMemory(from: source, byteCount: destination.count)
            }
        } else if buffers.count == 2 && buffers.allSatisfy({ $0.mNumberChannels == 1 }) {
            guard let left = buffers[0].mData, let right = buffers[1].mData,
                  Int(buffers[0].mDataByteSize) >= frames * 4,
                  Int(buffers[1].mDataByteSize) >= frames * 4 else {
                throw CaptureError("Truncated planar audio")
            }
            payload.withUnsafeMutableBytes { destination in
                // UInt32 copies preserve the Float32 representation without rounding.
                let output = destination.bindMemory(to: UInt32.self)
                for index in 0..<frames {
                    output[index * 2] = left.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self)
                    output[index * 2 + 1] = right.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self)
                }
            }
        } else { throw CaptureError("Unexpected audio buffer layout") }
    }
    guard pts.isNumeric && pts.value >= 0 else { throw CaptureError("Invalid audio timestamp") }
    var packet = Data("GSA1".utf8)
    appendBE(UInt32(payload.count), to: &packet)
    appendBE(UInt64(pts.value), to: &packet)
    appendBE(UInt32(48_000), to: &packet)
    appendBE(UInt32(2), to: &packet)
    packet.append(payload)
    return packet
}

// A replaceable raw-frame slot, never a FIFO. Owned by captureQueue in production.
struct LatestFrameSlot<Value> {
    private var pending: (value: Value, received: UInt64)?
    var currentValue: Value? { pending?.value }
    var count: Int { pending == nil ? 0 : 1 }
    mutating func replace(_ value: Value, received: UInt64) -> Bool {
        let replaced = pending != nil
        pending = (value, received)
        return replaced
    }
    mutating func take(now: UInt64, maximumAge: UInt64) -> (value: Value?, expired: Bool, received: UInt64?) {
        guard let next = pending else { return (nil, false, nil) }
        pending = nil
        guard now >= next.received, now - next.received <= maximumAge else { return (nil, true, next.received) }
        return (next.value, false, next.received)
    }
    mutating func clear() -> Bool {
        let hadValue = pending != nil
        pending = nil
        return hadValue
    }
}

// A synchronous encode failure and a late callback cannot release a newer frame.
final class VideoFrameTicket: @unchecked Sendable {
    private let lock = NSLock()
    private var phase = 0 // encoding, output, finished
    func beginOutput() -> Bool { lock.withLock {
        guard phase == 0 else { return false }; phase = 1; return true
    } }
    func finish(output: Bool) -> Bool { lock.withLock {
        guard phase == (output ? 1 : 0) else { return false }; phase = 2; return true
    } }
}

final class Capture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let state = NSLock()
    private let captureQueue = DispatchQueue(label: "stream.capture.frames", qos: .userInteractive)
    private let outputQueue = DispatchQueue(label: "stream.capture.pipe", qos: .userInteractive)
    private var busy = false
    private var busyStarted: UInt64?
    private struct PendingVideo {
        let sample: CMSampleBuffer
        let info: [SCStreamFrameInfo: Any]
        let sourceSequence: UInt64?
    }
    private var pendingVideo = LatestFrameSlot<PendingVideo>() // captureQueue only
    private var pendingVideoCount = 0 // state lock; diagnostics never reads the slot
    private var metrics: CaptureMetrics?
    private var fingerprintEnabled = false
    private var stopping = false
    private var starting = true
    private var forceKeyframe = true
    private var origin: CMTime?
    private var previousPTS: Int64 = -1
    private var lastForcedKeyframePTS: Int64 = -1_000_000
    private var framesEncoded: UInt64 = 0
    private var framesSkipped: UInt64 = 0
    private var audioChunks: UInt64 = 0
    private var audioSkipped: UInt64 = 0
    private var pendingAudioFrames = 0
    private var idleHeartbeatPending = false
    private var lastIdleHeartbeat = UInt64(0)
    private var lastGeometry: Data?
    private var compressor: VTCompressionSession?
    private var stream: SCStream?
    private var continuation: CheckedContinuation<Int32, Never>?
    private var signalSources: [DispatchSourceSignal] = []
    private var deadlineTimer: DispatchSourceTimer?
    private var stopCode: Int32 = 0
    private var stopReason = "requested"
    private var width = 0
    private var height = 0
    private var fps = 30
    private var hardwareVerifiedBy = "required_creation_specification"
    // Only the serial SCK capture queue reads/writes this one-shot input flag.
    private var emittedInputColor = false
    // The serial output queue owns this one-shot metadata diagnostic.
    private var emittedEncodedColor = false
    private let backgroundColor = CGColor(gray: 0, alpha: 1)

    private func isStopping() -> Bool { state.withLock { stopping } }
    private func releaseFrame(_ ticket: VideoFrameTicket, output: Bool = false) {
        guard ticket.finish(output: output) else { return }
        captureQueue.async {
            self.state.withLock {
                if let start = self.busyStarted { self.metrics?.observe("video_busy", since: start) }
                self.busyStarted = nil
                self.busy = false
            }
            guard !self.isStopping() else { self.clearPendingVideo(); return }
            let pendingSequence = self.pendingVideo.currentValue?.sourceSequence
            let next = self.pendingVideo.take(now: DispatchTime.now().uptimeNanoseconds,
                maximumAge: 1_000_000_000 / UInt64(self.fps))
            self.state.withLock { self.pendingVideoCount = 0 }
            if next.expired {
                self.metrics?.sourceDisposition(pendingSequence, 4)
                self.skipPendingVideo("video_pending_expired")
            }
            if let value = next.value, let received = next.received {
                self.submitVideo(value.sample, info: value.info, pendingSince: received, sourceSequence: value.sourceSequence)
            }
        }
    }

    private func skipPendingVideo(_ reason: String) {
        state.withLock { framesSkipped += 1 }
        metrics?.increment("video_busy_skipped")
        metrics?.increment(reason)
    }

    private func clearPendingVideo() {
        metrics?.sourceDisposition(pendingVideo.currentValue?.sourceSequence, 5)
        if pendingVideo.clear() { metrics?.increment("video_pending_stopping_skipped") }
        state.withLock { pendingVideoCount = 0 }
    }

    private func metricsGauges() -> [String: Double] {
        state.withLock {
            ["video_busy_now": busy ? 1 : 0,
             "video_pending_now": Double(pendingVideoCount),
             "video_busy_age_ms": busyStarted.map { Double(DispatchTime.now().uptimeNanoseconds - $0) / 1_000_000 } ?? 0,
             "pending_audio_frames": Double(pendingAudioFrames),
             "stopping_now": stopping ? 1 : 0]
        }
    }

    func requestKeyframe() { state.withLock { forceKeyframe = true } }

    func requestStop(_ reason: String, code: Int32 = 0) {
        let shouldStop = state.withLock { () -> Bool in
            guard !stopping else { return false }
            stopping = true; stopReason = reason; stopCode = code
            return !starting
        }
        captureQueue.async { self.clearPendingVideo() }
        guard shouldStop else { return }
        Task { await self.finish() }
    }

    private func setupEncoder(bitrate: Int) throws {
        let spec = [
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true
        ] as CFDictionary
        try checked(VTCompressionSessionCreate(allocator: kCFAllocatorDefault,
            width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
            encoderSpecification: spec, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &compressor), "Create hardware H264 encoder")
        guard let compressor else { throw CaptureError("No compression session") }
        let properties: [(CFString, CFTypeRef)] = [
            (kVTCompressionPropertyKey_RealTime, kCFBooleanTrue),
            (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse),
            (kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel),
            // SCK converts to limited-range BT.709 below. Carry that colorimetry
            // into the H.264 SPS so native receivers need not guess an SD space.
            (kVTCompressionPropertyKey_ColorPrimaries, kCMFormatDescriptionColorPrimaries_ITU_R_709_2),
            (kVTCompressionPropertyKey_TransferFunction, kCMFormatDescriptionTransferFunction_ITU_R_709_2),
            (kVTCompressionPropertyKey_YCbCrMatrix, kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2),
            (kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: fps)),
            (kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: bitrate)),
            // Zero matters: the one-in-flight gate must not need a future frame to flush.
            (kVTCompressionPropertyKey_MaxFrameDelayCount, NSNumber(value: 0))
        ]
        for (key, value) in properties {
            let result = VTSessionSetProperty(compressor, key: key, value: value)
            if key == kVTCompressionPropertyKey_MaxFrameDelayCount && result == kVTPropertyNotSupportedErr {
                diagnostic("optional_encoder_property_unsupported", ["property": key as String, "status": result])
                continue
            }
            try checked(result, "Set \(key)")
        }
        diagnostic("encoder_color_configured", ["primaries": "ITU_R_709_2", "transfer": "ITU_R_709_2",
            "matrix": "ITU_R_709_2", "pixel_format": "420v", "property_status": 0])
        try checked(VTCompressionSessionPrepareToEncodeFrames(compressor), "Prepare encoder")
        var hardware: Unmanaged<CFTypeRef>?
        let hardwareStatus = VTSessionCopyProperty(compressor, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
            allocator: kCFAllocatorDefault, valueOut: &hardware)
        let hardwareValue = hardware?.takeRetainedValue()
        if hardwareStatus == kVTPropertyNotSupportedErr {
            // RequireHardware=true is a creation-time guarantee: Apple documents
            // that VTCompressionSessionCreate fails if hardware cannot be used.
            // The low-latency encoder on this Mac does not list/implement this getter.
            diagnostic("hardware_verified_by_required_specification", ["query_status": hardwareStatus,
                "require_hardware": true, "low_latency_rate_control": true])
        } else {
            try checked(hardwareStatus, "Verify hardware encoder")
            guard (hardwareValue as? Bool) == true else { throw CaptureError("Hardware encoder not active") }
            hardwareVerifiedBy = "runtime_property"
        }
    }

    func run(window: SCWindow, options: Options) async throws -> Int32 {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let dimensions = try outputDimensions(source: CGSize(
            width: filter.contentRect.width * Double(filter.pointPixelScale),
            height: filter.contentRect.height * Double(filter.pointPixelScale)), maxWidth: options.width)
        width = dimensions.0; height = dimensions.1; fps = options.fps
        try setupEncoder(bitrate: options.bitrate)
        let config = SCStreamConfiguration()
        config.width = width; config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.colorSpaceName = CGColorSpace.itur_709
        config.colorMatrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2
        config.queueDepth = 3
        config.scalesToFit = true
        config.preservesAspectRatio = true
        config.ignoreShadowsSingleWindow = true
        config.ignoreGlobalClipSingleWindow = true
        config.showsCursor = false
        config.capturesAudio = options.audio
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        if #available(macOS 15.0, *) { config.captureMicrophone = false }
        config.includeChildWindows = false
        config.streamName = "Selected window stream"
        config.backgroundColor = backgroundColor
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        self.stream = stream
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        if options.audio { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: captureQueue) }
        // Nonblocking stdout allows SIGTERM to stop even if the transport stops draining.
        let flags = fcntl(STDOUT_FILENO, F_GETFL)
        guard flags >= 0, fcntl(STDOUT_FILENO, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw CaptureError("Could not set stdout nonblocking")
        }
        signal(SIGPIPE, SIG_IGN)
        metrics = options.metricsFile.map { CaptureMetrics(path: $0, packetTrace: options.packetTrace) }
        fingerprintEnabled = options.contentFingerprint
        metrics?.start { [weak self] in self?.metricsGauges() ?? [:] }
        // Register the continuation before starting, so an early delegate failure cannot be lost.
        return await withCheckedContinuation { pending in
            continuation = pending
            for number in [SIGTERM, SIGINT, SIGUSR1] {
                signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number, queue: .global(qos: .userInitiated))
                source.setEventHandler { [weak self] in
                    if number == SIGUSR1 { self?.requestKeyframe() }
                    else { self?.requestStop("signal_\(number)") }
                }
                source.resume(); signalSources.append(source)
            }
            if options.seconds > 0 {
                let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
                timer.schedule(deadline: .now() + .seconds(options.seconds))
                timer.setEventHandler { [weak self] in self?.requestStop("time_limit") }
                deadlineTimer = timer
                timer.resume()
            }
            Task {
                do {
                    try await stream.startCapture()
                    metrics?.increment("capture_ready")
                    let cancelled = state.withLock { starting = false; return stopping }
                    if cancelled { await finish(); return }
                    diagnostic("capture_ready", ["window_id": window.windowID,
                        "pid": window.owningApplication?.processID ?? 0, "width": width, "height": height,
                        "fps": fps, "bitrate": options.bitrate, "hardware": true, "profile": "H264_High_AutoLevel",
                        "hardware_verified_by": hardwareVerifiedBy,
                        "low_latency_rate_control": true,
                        "source_rect_points": rectJSON(filter.contentRect),
                        "window_frame_points": rectJSON(window.frame), "point_pixel_scale": filter.pointPixelScale,
                        "crop": "whole_window_without_shadow", "client_area_crop": false,
                        "title_bar": "included_if_part_of_window", "audio": options.audio,
                        "audio_format": "Float32LE_interleaved", "audio_rate": 48000, "audio_channels": 2,
                        "audio_scope": "selected_window_application", "microphone": false])
                } catch {
                    diagnostic("error", ["message": "Capture startup: \(error)"])
                    let cancelled = state.withLock { starting = false; return stopping }
                    if cancelled { await finish() }
                    else { requestStop("startup_failed", code: 1) }
                }
            }
        }
    }

    private func finish() async {
        // Stop capture before invalidating the encoder; queue synchronization excludes encode/invalidate races.
        if let stream { try? await stream.stopCapture() }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            captureQueue.async {
                self.clearPendingVideo()
                if let compressor = self.compressor { VTCompressionSessionInvalidate(compressor) }
                self.compressor = nil
                self.outputQueue.async {
                    // Output completions enqueue their releases onto captureQueue.
                    // Drain those before publishing the stopped snapshot.
                    self.captureQueue.async { done.resume() }
                }
            }
        }
        let result = state.withLock { (stopReason, stopCode, framesEncoded, framesSkipped, audioChunks, audioSkipped) }
        await metrics?.finish(gauges: metricsGauges())
        diagnostic("stopped", ["reason": result.0, "frames_encoded": result.2, "frames_skipped": result.3,
            "audio_chunks": result.4, "audio_chunks_skipped": result.5])
        for source in signalSources { source.cancel() }
        signalSources.removeAll()
        deadlineTimer?.cancel()
        deadlineTimer = nil
        continuation?.resume(returning: result.1)
        continuation = nil
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        diagnostic("error", ["message": "Capture stopped: \(error)"])
        requestStop("capture_error", code: 1)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio { handleAudio(sampleBuffer); return }
        guard type == .screen else { return }
        let callbackEntry = metrics?.packetTraceTime() // Before attachment parsing; nil/clock-free when disabled.
        let valid = sampleBuffer.isValid
        let attachments = valid ? CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]] : nil
        let info = attachments?.first
        let rawStatus = info?[.status] as? Int
        var sourceSequence: UInt64?
        if let metrics {
            let sourcePTS = valid ? CMSampleBufferGetPresentationTimeStamp(sampleBuffer) : .invalid
            metrics.screen(valid: valid, status: rawStatus, pts: sourcePTS)
            if let callbackEntry { sourceSequence = metrics.sourceCallback(status: rawStatus, pts: sourcePTS, entry: callbackEntry, info: info) }
        }
        guard valid, let info else { return }
        if rawStatus == SCFrameStatus.idle.rawValue {
            sendIdleHeartbeat()
            return
        }
        guard rawStatus == SCFrameStatus.complete.rawValue else { return }
        if fingerprintEnabled {
            let started = DispatchTime.now().uptimeNanoseconds
            let result = sampleBuffer.imageBuffer.map(contentFingerprint) ?? (hash: nil, error: "missing_image")
            metrics?.fingerprint(hash: result.hash, error: result.error,
                costNS: DispatchTime.now().uptimeNanoseconds - started, sourceSequence: sourceSequence)
        }
        let received = DispatchTime.now().uptimeNanoseconds
        guard !isStopping() else { metrics?.sourceDisposition(sourceSequence, 5); metrics?.increment("video_stopping_skipped"); return }
        if state.withLock({ busy }) {
            let replacedSequence = pendingVideo.currentValue?.sourceSequence
            if pendingVideo.replace(PendingVideo(sample: sampleBuffer, info: info, sourceSequence: sourceSequence), received: received) {
                metrics?.sourceDisposition(replacedSequence, 3)
                skipPendingVideo("video_pending_replaced")
            }
            metrics?.sourceDisposition(sourceSequence, 2)
            state.withLock { pendingVideoCount = 1 }
            metrics?.increment("video_pending_offered")
            return
        }
        submitVideo(sampleBuffer, info: info, sourceSequence: sourceSequence)
    }

    private func sendIdleHeartbeat() {
        let now = DispatchTime.now().uptimeNanoseconds
        let reserved = state.withLock { () -> Bool in
            // Report confirmed source idleness after the first usable video
            // frame, without holding an SCK surface or queueing repeated work.
            guard !stopping, framesEncoded > 0, !busy, !idleHeartbeatPending,
                  now - lastIdleHeartbeat >= 400_000_000 else { return false }
            idleHeartbeatPending = true
            lastIdleHeartbeat = now
            return true
        }
        guard reserved else { return }
        outputQueue.async {
            defer { self.state.withLock { self.idleHeartbeatPending = false } }
            guard self.state.withLock({ !self.stopping && !self.busy }) else { return }
            do {
                let packet = packetForIdleHeartbeat(uptimeMicroseconds: now / 1_000)
                _ = try self.writePacket(packet, metric: "heartbeat_pipe_write")
                self.metrics?.increment("idle_heartbeat_written")
            } catch {
                if !self.isStopping() {
                    diagnostic("error", ["message": String(describing: error)])
                    self.requestStop("output_error", code: 1)
                }
            }
        }
    }

    // All admissions, including completion-driven ones, run on captureQueue.
    private func submitVideo(_ sampleBuffer: CMSampleBuffer, info: [SCStreamFrameInfo: Any], pendingSince: UInt64? = nil,
                             sourceSequence: UInt64? = nil) {
        if let pendingSince {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now >= pendingSince, now - pendingSince <= 1_000_000_000 / UInt64(fps) else {
                metrics?.sourceDisposition(sourceSequence, 4); skipPendingVideo("video_pending_expired"); return
            }
            metrics?.observe("video_pending_wait", since: pendingSince)
            metrics?.increment("video_pending_submitted")
        }
        guard let image = sampleBuffer.imageBuffer else { metrics?.sourceDisposition(sourceSequence, 6); metrics?.increment("screen_missing_image"); return }
        guard let compressor else { metrics?.sourceDisposition(sourceSequence, 6); metrics?.increment("screen_missing_encoder"); return }
        let accepted = state.withLock { () -> Bool in
            guard !stopping else { metrics?.increment("video_stopping_skipped"); return false }
            guard !busy else { framesSkipped += 1; metrics?.increment("video_busy_skipped"); return false }
            busy = true
            busyStarted = metrics.map { _ in DispatchTime.now().uptimeNanoseconds }
            metrics?.increment("video_accepted")
            return true
        }
        guard accepted else { metrics?.sourceDisposition(sourceSequence, 6); return }
        let ticket = VideoFrameTicket()
        emitGeometry(info)
        guard var pts = relativeTimestamp(sampleBuffer) else { metrics?.sourceDisposition(sourceSequence, 6); metrics?.increment("video_timestamp_skipped"); releaseFrame(ticket); return }
        if pts.value <= previousPTS { pts = CMTime(value: previousPTS + 1, timescale: 1_000_000) }
        previousPTS = pts.value
        let shouldForce = state.withLock { () -> Bool in
            // Low-latency rate control has an infinite GOP. Explicitly request an
            // IDR at least every second as well as at startup and on SIGUSR1/drop.
            let value = forceKeyframe || pts.value - lastForcedKeyframePTS >= 1_000_000
            forceKeyframe = false
            if value { lastForcedKeyframePTS = pts.value }
            return value
        }
        let properties = shouldForce ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        var flags = VTEncodeInfoFlags()
        let inputColor = emittedInputColor ? nil : captureInputColorMetadata(sampleBuffer, image: image)
        let encodeTiming = metrics?.beginEncode(sourceSequence: sourceSequence, wirePTS: pts.value)
        let status = VTCompressionSessionEncodeFrame(compressor, imageBuffer: image, presentationTimeStamp: pts,
            duration: CMTime(value: 1, timescale: CMTimeScale(fps)), frameProperties: properties, infoFlagsOut: &flags) {
                [weak self] status, flags, sample in
                guard let self else { return }
                if let encodeTiming { self.metrics?.encoderResult(encodeTiming, callback: true, status: status, flags: flags, hasSample: sample != nil) }
                guard status == noErr, !flags.contains(.frameDropped), let sample else {
                    if status != noErr {
                        diagnostic("error", ["message": "Encoder output failed: \(status)"])
                        self.requestStop("encode_error", code: 1)
                    } else { self.requestKeyframe() }
                    self.releaseFrame(ticket)
                    return
                }
                guard ticket.beginOutput() else { return }
                let queuedAt = self.metrics.map { _ in DispatchTime.now().uptimeNanoseconds }
                self.outputQueue.async {
                    let outputStarted = self.metrics?.packetTraceTime()
                    if let queuedAt { self.metrics?.observe("video_output_queue", since: queuedAt) }
                    defer { self.releaseFrame(ticket, output: true) }
                    guard !self.isStopping() else { return }
                    do {
                        if !self.emittedEncodedColor, let format = CMSampleBufferGetFormatDescription(sample) {
                            var color: [String: Any] = [:]
                            for key in [kCMFormatDescriptionExtension_ColorPrimaries,
                                        kCMFormatDescriptionExtension_TransferFunction,
                                        kCMFormatDescriptionExtension_YCbCrMatrix,
                                        kCMFormatDescriptionExtension_FullRangeVideo] {
                                color[key as String] = CMFormatDescriptionGetExtension(format, extensionKey: key) ?? NSNull()
                            }
                            var parameterSets: [String] = []
                            for index in 0..<2 {
                                var pointer: UnsafePointer<UInt8>?
                                var count = 0
                                try checked(CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format,
                                    parameterSetIndex: index, parameterSetPointerOut: &pointer,
                                    parameterSetSizeOut: &count, parameterSetCountOut: nil,
                                    nalUnitHeaderLengthOut: nil), "Read encoded color parameter sets")
                                if let pointer {
                                    parameterSets.append(Data(bytes: pointer, count: count).map { String(format: "%02x", $0) }.joined())
                                }
                            }
                            color["h264_parameter_sets_hex"] = parameterSets
                            diagnostic("encoded_color_format", color)
                            self.emittedEncodedColor = true
                        }
                        let packet = try packetForSample(sample, width: self.width, height: self.height)
                        let packetReady = self.metrics?.packetTraceTime()
                        let written = try self.writePacket(packet, metric: "video_pipe_write")
                        if let outputStarted, let packetReady, let written {
                            self.metrics?.recordPacket(packet, outputStart: outputStarted, packetReady: packetReady,
                                writeStart: written.start, writeDone: written.done, sourceCallbackSequence: sourceSequence)
                        }
                        self.state.withLock { self.framesEncoded += 1 }
                        self.metrics?.increment("video_written")
                    } catch {
                        if !self.isStopping() {
                            diagnostic("error", ["message": "\(error)"])
                            self.requestStop("output_error", code: 1)
                        }
                    }
                }
            }
        if let encodeTiming { metrics?.encoderResult(encodeTiming, callback: false, status: status, flags: flags) }
        if var color = inputColor {
            emittedInputColor = true
            color["encode_call_status"] = status
            color["encode_call_frame_dropped"] = flags.contains(.frameDropped)
            diagnostic("capture_input_color", color)
        }
        if status != noErr {
            diagnostic("error", ["message": "Encode failed: \(status)"])
            requestStop("encode_error", code: 1)
            releaseFrame(ticket)
        } else if flags.contains(.frameDropped) { requestKeyframe(); releaseFrame(ticket) }
    }

    // Both SCK output types use captureQueue, therefore share one clock origin.
    private func relativeTimestamp(_ sample: CMSampleBuffer) -> CMTime? {
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        guard time.isNumeric else { return nil }
        if origin == nil { origin = time }
        let result = CMTimeConvertScale(CMTimeSubtract(time, origin!), timescale: 1_000_000, method: .default)
        // A leading audio sample can predate the first delivered video frame. Skip that
        // one sample instead of shifting only one media timeline.
        return result.value >= 0 ? result : nil
    }

    private func handleAudio(_ sample: CMSampleBuffer) {
        metrics?.increment("audio_callbacks")
        guard sample.isValid, sample.dataReadiness == .ready else { metrics?.increment("audio_invalid"); return }
        guard let pts = relativeTimestamp(sample) else { metrics?.increment("audio_timestamp_skipped"); return }
        let frames = CMSampleBufferGetNumSamples(sample)
        guard frames > 0 else { metrics?.increment("audio_empty"); return }
        guard frames <= 4800 else {
            metrics?.increment("audio_oversize")
            diagnostic("error", ["message": "Audio chunk exceeds the 100ms output bound"])
            requestStop("audio_format_error", code: 1)
            return
        }
        let accepted = state.withLock { () -> Bool in
            guard !stopping else { metrics?.increment("audio_stopping_skipped"); return false }
            // Keep at most 100ms of pending PCM. Incoming audio is skipped under
            // backpressure; video access units are never evicted from the pipe queue.
            guard pendingAudioFrames + frames <= 4800 else { audioSkipped += 1; metrics?.increment("audio_busy_skipped"); return false }
            pendingAudioFrames += frames
            metrics?.increment("audio_accepted")
            return true
        }
        guard accepted else { return }
        let queuedAt = metrics.map { _ in DispatchTime.now().uptimeNanoseconds }
        outputQueue.async {
            let outputStarted = self.metrics?.packetTraceTime()
            if let queuedAt { self.metrics?.observe("audio_output_queue", since: queuedAt) }
            defer { self.state.withLock { self.pendingAudioFrames -= frames } }
            guard !self.isStopping() else { return }
            do {
                let packet = try packetForAudioSample(sample, pts: pts)
                let packetReady = self.metrics?.packetTraceTime()
                let written = try self.writePacket(packet, metric: "audio_pipe_write")
                if let outputStarted, let packetReady, let written {
                    self.metrics?.recordPacket(packet, outputStart: outputStarted, packetReady: packetReady,
                        writeStart: written.start, writeDone: written.done)
                }
                self.state.withLock { self.audioChunks += 1 }
                self.metrics?.increment("audio_written")
            } catch {
                if !self.isStopping() {
                    diagnostic("error", ["message": "\(error)"])
                    self.requestStop("audio_error", code: 1)
                }
            }
        }
    }

    private func emitGeometry(_ info: [SCStreamFrameInfo: Any]) {
        var value: [String: Any] = ["width": width, "height": height,
            "content_scale": info[.contentScale] as? Double ?? 1,
            "scale_factor": info[.scaleFactor] as? Double ?? 1,
            "content_rect_units": "surface_points", "screen_rect_units": "screen_points",
            "crop": "whole_window_without_shadow", "client_area_crop": false,
            "title_bar": "included_if_part_of_window"]
        if let rect = attachmentRect(info[.contentRect]) { value["content_rect"] = rectJSON(rect) }
        if let rect = attachmentRect(info[.screenRect]) { value["screen_rect"] = rectJSON(rect) }
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), data != lastGeometry {
            lastGeometry = data
            diagnostic("frame_geometry", value)
        }
    }

    private func writePacket(_ packet: Data, metric: String) throws -> (start: UInt64, done: UInt64)? {
        let traceStarted = metrics?.packetTraceTime()
        // Never drop a partially-written access unit. A stalled pipe terminates this stream;
        // the transport must start a new decoder session when it restarts the helper.
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        let started = metrics.map { _ in DispatchTime.now().uptimeNanoseconds }
        var succeeded = false
        defer {
            if let started { metrics?.observe(metric, since: started) }
            if !succeeded { metrics?.increment("pipe_write_errors") }
        }
        try packet.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                if isStopping() { throw CaptureError("Stopping") }
                if DispatchTime.now().uptimeNanoseconds >= deadline { throw CaptureError("stdout stalled for 2 seconds") }
                let count = Darwin.write(STDOUT_FILENO, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count > 0 { offset += count; continue }
                if count < 0 && errno == EINTR { continue }
                guard count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) else {
                    throw CaptureError("stdout closed (errno \(errno))")
                }
                var descriptor = pollfd(fd: STDOUT_FILENO, events: Int16(POLLOUT), revents: 0)
                metrics?.increment(metric + "_backpressure_waits")
                _ = poll(&descriptor, 1, 50)
            }
        }
        succeeded = true
        return traceStarted.map { ($0, DispatchTime.now().uptimeNanoseconds) }
    }
}

#if !CAPTURE_OFFLINE_TEST
@main struct StreamCapture {
    @MainActor
    static func main() async {
        do {
            // Window-only SCContentFilter needs a WindowServer/AppKit context even
            // when the helper is launched from a pipe rather than LaunchServices.
            NSApplication.shared.setActivationPolicy(.prohibited)
            let options = try Options(Array(CommandLine.arguments.dropFirst()))
            if options.command == "--help" {
                print("StreamCapture --window-id N [--window-pid N] [--fps 30|60] [--width 320...3840] [--bitrate 250000...160000000] [--audio] [--seconds 0...3600] [--metrics-file /absolute/path.json] [--packet-trace] [--content-fingerprint]\nCommands: --list-windows | --preflight | --request-permission\nCapture stdout: GSV1 Annex-B H264 High, optional GSA1 Float32LE stereo 48kHz PCM, and throttled GSH1 source-idle heartbeats. Diagnostics: JSONL stderr; optional numeric metrics file every 2s (0600). --packet-trace requires --metrics-file and adds a 2048-record numeric output timing ring. --content-fingerprint requires --metrics-file and reads only a central NV12 luma sample grid; equal hashes do not prove equal images or game FPS. SIGUSR1: next IDR. SIGTERM: stop.")
                return
            }
            if options.command == "--preflight" || options.command == "--request-permission" {
                let granted = options.command == "--request-permission" ? CGRequestScreenCaptureAccess() : CGPreflightScreenCaptureAccess()
                print(granted ? "{\"screen_recording\":true}" : "{\"screen_recording\":false}")
                Darwin.exit(granted ? 0 : 77)
            }
            guard CGPreflightScreenCaptureAccess() else {
                throw CaptureError("Screen Recording permission missing; use --request-permission explicitly, then restart the helper after approval")
            }
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            if options.command == "--list-windows" {
                let windows: [[String: Any]] = content.windows.filter { $0.windowLayer == 0 }.map { window in
                    ["window_id": window.windowID, "pid": window.owningApplication?.processID ?? 0,
                     "application": window.owningApplication?.applicationName ?? "",
                     "bundle_id": window.owningApplication?.bundleIdentifier ?? "",
                     "title": window.title ?? "", "on_screen": window.isOnScreen,
                     "frame_points": rectJSON(window.frame)]
                }
                let data = try JSONSerialization.data(withJSONObject: windows, options: [.sortedKeys])
                FileHandle.standardOutput.write(data + Data([10]))
                return
            }
            guard let window = content.windows.first(where: { $0.windowID == options.windowID }) else {
                throw CaptureError("Selected window is unavailable; refusing to capture any other window or display")
            }
            guard let owner = window.owningApplication, window.windowLayer == 0 else {
                throw CaptureError("Selected ID is not a normal application window")
            }
            if let expectedPID = options.windowPID, expectedPID != owner.processID {
                throw CaptureError("The selected window changed owners. Select a window again.")
            }
            let capture = Capture()
            let code = try await capture.run(window: window, options: options)
            Darwin.exit(code)
        } catch {
            diagnostic("error", ["message": "\(error)"])
            Darwin.exit(1)
        }
    }
}
#endif
