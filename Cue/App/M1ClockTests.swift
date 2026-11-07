//
//  M1ClockTests.swift
//  Cue
//
//  Numeric checks for PlaybackClock, run headlessly with `--test-clock`.
//
//  M1's acceptance criterion is that the scrub bar "moves smoothly and stays
//  within 0.5 s of Music". The bar renders the clock, so that is a property of
//  this class and can be proved with arithmetic instead of judged by eye. Every
//  case injects its own instants, so nothing here depends on wall-clock timing
//  or on Music running.
//

import Foundation

@MainActor
struct M1ClockTests {

    struct Result: Sendable {
        var name: String
        var passed: Bool
        var detail: String
    }

    static func runAll() -> [Result] {
        [
            advancesWithTime(),
            doesNotAdvanceWhilePaused(),
            snapsOnLargeDrift(),
            easesSmallDrift(),
            consecutiveCorrectionsAreNotLost(),
            ignoresSyncWhileSuppressed(),
            clampsToTrack(),
            reportsUnknownDuration(),
            staysWithinToleranceOverAMinute(),
        ]
    }

    // MARK: - Cases

    private static func advancesWithTime() -> Result {
        let clock = PlaybackClock()
        let base = ContinuousClock.now
        clock.duration = 300
        clock.sync(position: 10, isAdvancing: true, at: base)

        let after = clock.position(at: base.advanced(by: .seconds(1)))
        return check("advances with time", after, expected: 11, tolerance: 0.001)
    }

    private static func doesNotAdvanceWhilePaused() -> Result {
        let clock = PlaybackClock()
        let base = ContinuousClock.now
        clock.duration = 300
        clock.sync(position: 42, isAdvancing: false, at: base)

        let after = clock.position(at: base.advanced(by: .seconds(5)))
        return check("holds position while paused", after, expected: 42, tolerance: 0.001)
    }

    private static func snapsOnLargeDrift() -> Result {
        let clock = PlaybackClock()
        let base = ContinuousClock.now
        clock.duration = 300
        clock.sync(position: 10, isAdvancing: true, at: base)

        // A second later Music says 30 — someone seeked. Past the 0.5 s
        // threshold, so this must snap, not ease.
        let t1 = base.advanced(by: .seconds(1))
        clock.sync(position: 30, isAdvancing: true, at: t1)

        let immediately = clock.position(at: t1)
        return check("snaps past the 0.5 s threshold", immediately, expected: 30, tolerance: 0.001)
    }

    private static func easesSmallDrift() -> Result {
        let clock = PlaybackClock()
        let base = ContinuousClock.now
        clock.duration = 300
        clock.sync(position: 10, isAdvancing: true, at: base)

        // Music reports 11.2 when we projected 11.0: a 0.2 s correction, under
        // the threshold, so it should be absorbed gradually rather than jumped.
        let t1 = base.advanced(by: .seconds(1))
        clock.sync(position: 11.2, isAdvancing: true, at: t1)

        let atOnce = clock.position(at: t1)
        guard abs(atOnce - 11.0) < 0.001 else {
            return Result(name: "eases drift under the threshold", passed: false,
                          detail: String(format: "jumped immediately to %.4f, expected to stay at 11.0", atOnce))
        }

        // Half way through the ease, half the correction should be in.
        let half = t1.advanced(by: .milliseconds(Int(PlaybackClock.easeDuration * 500)))
        let midway = clock.position(at: half)
        let expectedMid = 11.0 + PlaybackClock.easeDuration / 2 + 0.1
        guard abs(midway - expectedMid) < 0.02 else {
            return Result(name: "eases drift under the threshold", passed: false,
                          detail: String(format: "midway %.4f, expected ~%.4f", midway, expectedMid))
        }

        // Once the ease completes the full correction is applied.
        let done = t1.advanced(by: .milliseconds(Int(PlaybackClock.easeDuration * 1000) + 10))
        let settled = clock.position(at: done)
        let expectedEnd = 11.2 + PlaybackClock.easeDuration + 0.01
        return check("eases drift under the threshold", settled, expected: expectedEnd, tolerance: 0.05)
    }

    /// The bug this guards: a second eased correction used to overwrite the
    /// first, discarding however much of it had been applied.
    private static func consecutiveCorrectionsAreNotLost() -> Result {
        let clock = PlaybackClock()
        let base = ContinuousClock.now
        clock.duration = 300
        clock.sync(position: 10, isAdvancing: true, at: base)

        // Two 0.2 s corrections, a second apart. Both must land.
        let t1 = base.advanced(by: .seconds(1))
        clock.sync(position: 11.2, isAdvancing: true, at: t1)
        let t2 = base.advanced(by: .seconds(2))
        clock.sync(position: 12.4, isAdvancing: true, at: t2)

        // Well after both eases, the clock should read the second sample plus
        // elapsed time: 12.4 + 2 s.
        let later = t2.advanced(by: .seconds(2))
        let value = clock.position(at: later)
        return check("consecutive corrections both land", value, expected: 14.4, tolerance: 0.05)
    }

    private static func ignoresSyncWhileSuppressed() -> Result {
        let clock = PlaybackClock()
        let base = ContinuousClock.now
        clock.duration = 300
        clock.sync(position: 10, isAdvancing: false, at: base)

        // §4.2: while dragging, Music's reports must not move the thumb.
        clock.isSuppressed = true
        clock.sync(position: 200, isAdvancing: false, at: base.advanced(by: .seconds(1)))

        let value = clock.position(at: base.advanced(by: .seconds(1)))
        return check("ignores syncs while dragging", value, expected: 10, tolerance: 0.001)
    }

    private static func clampsToTrack() -> Result {
        let clock = PlaybackClock()
        let base = ContinuousClock.now
        clock.duration = 20
        clock.sync(position: 19, isAdvancing: true, at: base)

        // Ten seconds past the end of a 20 s track.
        let over = clock.position(at: base.advanced(by: .seconds(10)))
        guard abs(over - 20) < 0.001 else {
            return Result(name: "clamps to the track", passed: false,
                          detail: String(format: "ran to %.4f on a 20 s track", over))
        }

        clock.jump(to: -5, at: base)
        let under = clock.position(at: base)
        return check("clamps to the track", under, expected: 0, tolerance: 0.001)
    }

    private static func reportsUnknownDuration() -> Result {
        let clock = PlaybackClock()
        clock.duration = 0
        clock.sync(position: 30, isAdvancing: true)

        // §4.2's stream case: no duration means no remaining and no progress,
        // which is what drives the indeterminate bar and disables seeking.
        let noRemaining = clock.remaining() == nil
        let noProgress = clock.progress() == nil
        return Result(
            name: "reports nil remaining/progress with no duration",
            passed: noRemaining && noProgress,
            detail: noRemaining && noProgress
                ? "both nil, as §4.2 needs"
                : "remaining=\(String(describing: clock.remaining())) progress=\(String(describing: clock.progress()))"
        )
    }

    /// The acceptance criterion itself: does the rendered position stay inside
    /// 0.5 s of Music's *actual* position?
    ///
    /// The first version of this test fed the clock the exact truth at each poll
    /// and then asked whether it had the truth — which it always did, reporting a
    /// 0.0000 s error and proving nothing. The error this needs to model is
    /// staleness: a sample read at time T describes Music as it was at
    /// T - callLatency, and the timer that asked for it fired late.
    private static func staysWithinToleranceOverAMinute() -> Result {
        let clock = PlaybackClock()
        let base = ContinuousClock.now
        clock.duration = 600

        // Music's true position, playing from 0 at `base`.
        func truth(_ elapsed: TimeInterval) -> TimeInterval { elapsed }

        // M0 measured fetchPosition at ~8.3 ms, so a sample is that stale.
        let callLatency: TimeInterval = 0.0083

        clock.sync(position: truth(0), isAdvancing: true, at: base)

        var worst: TimeInterval = 0
        var worstAt: TimeInterval = 0

        for second in 1 ... 60 {
            // Deterministic timer slop, 0–40 ms, as a 1 Hz timer on a busy main
            // thread would drift.
            let slop = Double((second * 17) % 41) / 1000
            let arrivalElapsed = Double(second) + slop
            let arrival = base.advanced(by: .milliseconds(Int(arrivalElapsed * 1000)))

            // The value Music reported describes a moment already past.
            clock.sync(position: truth(arrivalElapsed - callLatency), isAdvancing: true, at: arrival)

            // Sample the rendered value across the whole gap to the next poll,
            // not just at one convenient instant.
            for step in 0 ... 10 {
                let offset = Double(step) / 10.0
                let renderElapsed = arrivalElapsed + offset
                guard renderElapsed < 61 else { break }
                let rendered = clock.position(at: base.advanced(by: .milliseconds(Int(renderElapsed * 1000))))
                let error = abs(rendered - truth(renderElapsed))
                if error > worst {
                    worst = error
                    worstAt = renderElapsed
                }
            }
        }

        let passed = worst < PlaybackClock.snapThreshold
        return Result(
            name: "stays within 0.5 s of Music over 60 polls",
            passed: passed,
            detail: String(format: "worst error %.4f s at t=%.1f s, against a %.1f s tolerance "
                           + "(models %.1f ms call staleness + timer slop)",
                           worst, worstAt, PlaybackClock.snapThreshold, callLatency * 1000)
        )
    }

    // MARK: - Helper

    private static func check(_ name: String, _ actual: TimeInterval,
                              expected: TimeInterval, tolerance: TimeInterval) -> Result {
        let delta = abs(actual - expected)
        return Result(
            name: name,
            passed: delta <= tolerance,
            detail: String(format: "got %.4f, expected %.4f (±%.3f)", actual, expected, tolerance)
        )
    }
}
