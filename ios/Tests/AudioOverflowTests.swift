import Foundation

@main enum AudioOverflowTests {
    static func main() {
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message); checks += 1
        }
        func resets(_ queued: Int = 6720, incoming: Int = 960, scheduled: Int64 = 96000,
                    progress: Double?, gap: Bool = false) -> Bool {
            AudioOverflowPolicy.shouldReset(callbackQueuedFrames: queued, incomingFrames: incoming,
                scheduledFrames: scheduled, playerProgressFrames: progress, hasDiscontinuousSchedule: gap)
        }
        // Measured three contiguous overflow observations: residuals 121.333, 125.333, 140 ms.
        // Callback queue was 140 ms and the incoming PCM packet was 20 ms in each case.
        check(!resets(progress: 96000 - 5824), "121.333 + 20 ms must not stop audible playback")
        check(!resets(progress: 96000 - 6016), "125.333 + 20 ms must not stop audible playback")
        check(resets(progress: 96000 - 6720), "140 + 20 ms is a real overflow and keeps the old reset")
        check(!resets(progress: 96000 - 6240), "exactly 150 ms remains within the unchanged cap")
        check(resets(progress: 96000 - 6241), "one frame above the cap must still reset")
        // Retained event 59 has a gap in this generation: raw residual 80 ms is not a valid queue.
        check(resets(scheduled: 111360, progress: 107520, gap: true), "never use a discontinuous residual")
        // Retained event 43: clock has advanced through a long empty period.
        check(resets(scheduled: 93120, progress: 112640, gap: true), "negative residual is not an empty queue proof")
        check(resets(scheduled: 93120, progress: 112640), "unobserved clock discontinuity also preserves fallback")
        check(resets(progress: nil), "startup or unavailable clock preserves the existing bound")
        check(resets(progress: .nan), "nonfinite clock cannot exempt overflow")
        check(resets(progress: .infinity), "infinite clock cannot exempt overflow")
        check(resets(progress: -1), "negative clock cannot exempt overflow")
        check(!resets(5760, progress: nil), "below-threshold packets retain old behavior")
        check(!resets(5760, progress: 0), "native clock never creates a new reset below old threshold")
        check(!resets(0, incoming: 1920, scheduled: 0, progress: nil), "40 ms preroll is unchanged")
        // A delayed completion can leave a nonempty callback ledger after the player drains.
        // Latch this below the threshold; later burst arrivals cannot restore clock validity.
        var clockReachedEnd = AudioOverflowPolicy.clockReachedScheduledEnd(scheduledFrames: 96000,
                                                                           playerProgressFrames: 96480)
        check(clockReachedEnd && !resets(960, scheduled: 96000, progress: 96480, gap: clockReachedEnd),
              "exhaustion below the callback cap is remembered without introducing a reset")
        clockReachedEnd = clockReachedEnd || AudioOverflowPolicy.clockReachedScheduledEnd(scheduledFrames: 102720,
                                                                                          playerProgressFrames: 96480)
        check(resets(scheduled: 102720, progress: 96480, gap: clockReachedEnd),
              "a positive residual after refill cannot exempt the same exhausted generation")
        check(AudioOverflowPolicy.clockReachedScheduledEnd(scheduledFrames: 96000, playerProgressFrames: 96000),
              "an exactly exhausted schedule conservatively disqualifies the clock")
        print("AudioOverflow: \(checks) assertions passed")
    }
}
