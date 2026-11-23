import Foundation

/// Source PTS and local host time stay in separate domains. Never estimates network latency.
struct PlaybackTimeline {
    static let prerollSeconds = 0.040
    static let maximumLeadSeconds = prerollSeconds * 2
    private var requestedSourceTime: Double?
    private var requestedHostTime: Double = 0

    mutating func reset() { requestedSourceTime = nil }

    // AVSampleBufferRenderSynchronizer applies timebase changes asynchronously.
    // Include the latest requested anchor so a receive burst cannot reapply an old correction.
    func effectiveTime(observed: Double, hostTime: Double) -> Double {
        let requested = requestedSourceTime.map { $0 + max(0, hostTime - requestedHostTime) }
        return max(observed.isFinite ? observed : 0, requested ?? 0)
    }

    mutating func anchor(sourceTime: Double, hostTime: Double) {
        requestedSourceTime = sourceTime
        requestedHostTime = hostTime
    }

    mutating func correction(for sourceTime: Double, observed: Double, hostTime: Double) -> Double? {
        let now = effectiveTime(observed: observed, hostTime: hostTime)
        guard sourceTime - now > Self.maximumLeadSeconds else { return nil }
        let target = max(0, sourceTime - Self.prerollSeconds)
        anchor(sourceTime: target, hostTime: hostTime)
        return target
    }
}
