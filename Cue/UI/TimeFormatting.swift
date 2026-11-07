//
//  TimeFormatting.swift
//  Cue
//
//  §4.2's labels. Pure functions so they can be checked numerically.
//

import Foundation

enum TimeFormatting {

    /// `m:ss`, or `h:mm:ss` when the **track** is an hour or longer.
    ///
    /// The width is chosen by the track, not by the current position, so the
    /// label does not change shape as a long track plays past the hour mark and
    /// shove the scrub bar sideways.
    static func position(_ seconds: TimeInterval, trackDuration: TimeInterval) -> String {
        clock(seconds, includeHours: trackDuration >= 3600)
    }

    /// `-m:ss`, matching `position`'s width.
    static func remaining(_ seconds: TimeInterval, trackDuration: TimeInterval) -> String {
        "-" + clock(seconds, includeHours: trackDuration >= 3600)
    }

    /// The track length, for the §4.2 toggle and the tooltip.
    static func total(_ seconds: TimeInterval) -> String {
        clock(seconds, includeHours: seconds >= 3600)
    }

    /// The wall-clock time the track will finish, e.g. "ends 2:47 pm".
    ///
    /// Uses the user's locale and 12/24-hour setting via `.short`, rather than
    /// hard-coding a pattern.
    static func endTime(remaining: TimeInterval, now: Date = Date(),
                        locale: Locale = .autoupdatingCurrent,
                        timeZone: TimeZone = .autoupdatingCurrent) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return "ends " + formatter.string(from: now.addingTimeInterval(max(0, remaining)))
    }

    /// Rounds toward zero, so a label never shows a second the player has not
    /// reached. Negative input clamps to zero rather than rendering "-0:-3".
    private static func clock(_ seconds: TimeInterval, includeHours: Bool) -> String {
        let whole = Int(max(0, seconds.rounded(.down)))
        let hours = whole / 3600
        let minutes = (whole % 3600) / 60
        let secs = whole % 60

        if includeHours || hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}
