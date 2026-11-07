//
//  PlaybackClock.swift
//  Cue
//
//  §3.3's position interpolation. The scrub bar renders *this*, not the polled
//  value, which is what lets a 1 Hz poll drive a bar that moves at display
//  refresh rate.
//
//  Pure logic, no Apple Events, no timers of its own. It is handed samples and
//  asked what the position is now, so it can be tested without Music running.
//

import Foundation

@MainActor
@Observable
final class PlaybackClock {

    /// §3.3: beyond this gap between polled and interpolated position, snap
    /// rather than ease. Also §4.2's accuracy requirement — never drift further
    /// from Music than this.
    static let snapThreshold: TimeInterval = 0.5

    /// How quickly an eased correction is absorbed. A correction of less than
    /// `snapThreshold` is spread over roughly this long, so the bar never jumps
    /// visibly for ordinary jitter.
    static let easeDuration: TimeInterval = 0.4

    /// The last position Music reported, and when we learned it.
    private var anchorPosition: TimeInterval = 0
    private var anchorInstant: ContinuousClock.Instant = .now
    /// Whether the position should be advancing with time.
    private var isAdvancing = false

    /// A correction being eased in, rather than snapped.
    private var pendingCorrection: TimeInterval = 0
    private var correctionInstant: ContinuousClock.Instant = .now

    /// Set while the user is dragging. §4.2: suppress clock updates during a
    /// drag so the thumb does not jump out from under the pointer.
    var isSuppressed = false

    /// Track length, used only to clamp. Zero means unknown (a stream).
    var duration: TimeInterval = 0

    // MARK: - Input

    /// Whether any sample has been seen yet. The first one always snaps.
    private var hasAnchor = false

    /// Accepts a fresh sample from Music.
    ///
    /// `isAdvancing` comes from the player state, not from whether the position
    /// changed: a paused player still reports a position, it just does not move.
    func sync(position: TimeInterval, isAdvancing advancing: Bool, at instant: ContinuousClock.Instant = .now) {
        guard !isSuppressed else { return }

        let projected = rawPosition(at: instant)
        let delta = position - projected

        // Consolidate first. Any correction still in flight is folded into the
        // anchor before a new one is considered — otherwise assigning a second
        // correction would discard however much of the first had been applied,
        // and the bar would quietly lose that adjustment.
        anchorPosition = projected
        anchorInstant = instant
        pendingCorrection = 0

        let stateChanged = advancing != isAdvancing
        if !hasAnchor || stateChanged || abs(delta) >= Self.snapThreshold {
            // Snap: first sample, the player started or stopped under us, or the
            // drift is past §3.3's threshold.
            anchorPosition = position
        } else {
            // Ease: absorb a small difference over easeDuration, so ordinary
            // jitter never shows as a jump.
            pendingCorrection = delta
            correctionInstant = instant
        }

        isAdvancing = advancing
        hasAnchor = true
    }

    /// Called when playback starts, stops or pauses, so the clock stops
    /// advancing immediately rather than at the next poll.
    func setAdvancing(_ advancing: Bool, position: TimeInterval? = nil, at instant: ContinuousClock.Instant = .now) {
        anchorPosition = position ?? rawPosition(at: instant)
        anchorInstant = instant
        pendingCorrection = 0
        isAdvancing = advancing
    }

    /// Moves the clock immediately, for an optimistic update after a seek.
    func jump(to position: TimeInterval, at instant: ContinuousClock.Instant = .now) {
        anchorPosition = position
        anchorInstant = instant
        pendingCorrection = 0
    }

    func reset() {
        anchorPosition = 0
        anchorInstant = .now
        pendingCorrection = 0
        isAdvancing = false
        hasAnchor = false
        duration = 0
    }

    // MARK: - Output

    /// The position to render right now, clamped to the track.
    func position(at instant: ContinuousClock.Instant = .now) -> TimeInterval {
        let value = rawPosition(at: instant)
        guard duration > 0 else { return max(0, value) }
        return min(max(0, value), duration)
    }

    /// Seconds left, or nil when the duration is unknown (§4.2's stream case).
    func remaining(at instant: ContinuousClock.Instant = .now) -> TimeInterval? {
        guard duration > 0 else { return nil }
        return max(0, duration - position(at: instant))
    }

    /// Fraction through the track, 0...1, or nil when the duration is unknown.
    func progress(at instant: ContinuousClock.Instant = .now) -> Double? {
        guard duration > 0 else { return nil }
        return min(max(0, position(at: instant) / duration), 1)
    }

    /// Position before clamping, including any easing in flight.
    private func rawPosition(at instant: ContinuousClock.Instant) -> TimeInterval {
        var value = anchorPosition
        if isAdvancing {
            value += Self.seconds(from: anchorInstant, to: instant)
        }
        if pendingCorrection != 0 {
            let elapsed = Self.seconds(from: correctionInstant, to: instant)
            if elapsed >= Self.easeDuration {
                // Fully applied. It stays folded in here rather than being
                // written back, because `rawPosition` must stay side-effect
                // free — `sync` is what consolidates it into the anchor.
                value += pendingCorrection
            } else {
                value += pendingCorrection * (elapsed / Self.easeDuration)
            }
        }
        return value
    }

    private static func seconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> TimeInterval {
        let elapsed = end - start
        return TimeInterval(elapsed.components.seconds)
            + TimeInterval(elapsed.components.attoseconds) / 1e18
    }
}
