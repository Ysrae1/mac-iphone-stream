import Foundation

@main enum PlaybackTimelineTests {
    static func main() {
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message); checks += 1
        }
        func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.000_001 }
        var timeline = PlaybackTimeline()
        timeline.anchor(sourceTime: 10, hostTime: 100)
        // Replay the measured stale-first-frame condition: 750ms future PTS.
        let corrected = timeline.correction(for: 10.75, observed: 10, hostTime: 100)
        check(corrected.map { near($0, 10.71) } == true, "750ms old anchor must advance to 40ms lead")
        // setRate updates asynchronously. Same receive burst must not repeat the correction.
        check(timeline.correction(for: 10.75, observed: 10, hostTime: 100) == nil, "pending correction must be respected")
        check(near(timeline.effectiveTime(observed: 10, hostTime: 100.02), 10.73), "requested clock advances at natural rate")
        // Normal 50fps source stays at 40ms lead for two minutes, without sawtooth resets.
        for frame in 1...6000 {
            let elapsed = Double(frame) / 50
            check(timeline.correction(for: 10.75 + elapsed, observed: 10.71 + elapsed, hostTime: 100 + elapsed) == nil,
                  "steady source cadence must not cause repeated correction")
        }
        check(timeline.correction(for: 10, observed: 12, hostTime: 100) == nil, "late packets must never rewind the clock")
        timeline.reset()
        check(near(timeline.effectiveTime(observed: 2, hostTime: 200), 2), "reconnect must forget previous anchor")
        timeline.anchor(sourceTime: 2, hostTime: 200)
        check(timeline.correction(for: 2.079, observed: 2, hostTime: 200) == nil, "ordinary arrival jitter within two prerolls is unchanged")
        check(timeline.correction(for: 2.081, observed: 2, hostTime: 200) != nil, "excess queue lead is bounded")
        print("PlaybackTimeline: \(checks) assertions passed")
    }
}
