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

    /// The wall-clock time the track will finish, e.g. "ends 2:47 PM".
    ///
    /// Uses the user's locale and 12/24-hour setting via `.short`, rather than
    /// hard-coding a pattern.
    ///
    /// **The formatter is cached, and that is not a micro-optimisation.** This is
    /// called from the scrub bar's body, so it ran 30 times a second; building a
    /// `DateFormatter` each time went through `__CreateCFDateFormatter` into ICU's
    /// `udat_open` and accounted for essentially all of the panel's CPU use —
    /// about 12% while playing, found with `sample`. Cached, it is free.
    @MainActor
    static func endTime(remaining: TimeInterval, now: Date = Date(),
                        locale: Locale = .autoupdatingCurrent,
                        timeZone: TimeZone = .autoupdatingCurrent) -> String {
        let formatter = cachedFormatter(locale: locale, timeZone: timeZone)
        return "ends " + formatter.string(from: now.addingTimeInterval(max(0, remaining)))
    }

    /// Keyed by locale and time zone, so a test passing explicit ones does not
    /// poison the cache for the live ones.
    @MainActor private static var formatters: [String: DateFormatter] = [:]
    @MainActor private static var localeObserver: NSObjectProtocol?

    @MainActor
    private static func cachedFormatter(locale: Locale, timeZone: TimeZone) -> DateFormatter {
        // The 12/24-hour switch in System Settings changes the format without
        // changing the locale identifier, so the cache is cleared on the locale
        // notification rather than relying on the key alone.
        if localeObserver == nil {
            localeObserver = NotificationCenter.default.addObserver(
                forName: NSLocale.currentLocaleDidChangeNotification,
                object: nil,
                queue: .main
            ) { _ in
                MainActor.assumeIsolated { formatters.removeAll() }
            }
        }

        let key = "\(locale.identifier)|\(timeZone.identifier)"
        if let existing = formatters[key] { return existing }

        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        formatters[key] = formatter
        return formatter
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
