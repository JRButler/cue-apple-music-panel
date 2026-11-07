//
//  M1FormatTests.swift
//  Cue
//
//  Numeric checks for §4.2's labels, run with `--test-clock`.
//

import Foundation

@MainActor
struct M1FormatTests {

    static func runAll() -> [M1ClockTests.Result] {
        var results: [M1ClockTests.Result] = []

        // m:ss for an ordinary track.
        results.append(expect("position 0:00", TimeFormatting.position(0, trackDuration: 200), "0:00"))
        results.append(expect("position pads seconds", TimeFormatting.position(62, trackDuration: 200), "1:02"))
        results.append(expect("position rounds down", TimeFormatting.position(61.9, trackDuration: 200), "1:01"))
        results.append(expect("remaining is signed", TimeFormatting.remaining(133, trackDuration: 200), "-2:13"))

        // §4.2: h:mm:ss only when the TRACK is an hour or longer, so the label
        // does not change width mid-track.
        //
        // The exception below is defensive, not the rule: a position beyond the
        // track length cannot occur, because PlaybackClock clamps to duration.
        // If it somehow did, showing hours beats rendering "61:40".
        results.append(expect("position beyond a short track still renders sanely (unreachable; clamped)",
                              TimeFormatting.position(3700, trackDuration: 200), "1:01:40"))
        results.append(expect("long track uses h:mm:ss from the start",
                              TimeFormatting.position(5, trackDuration: 4000), "0:00:05"))
        results.append(expect("long track remaining uses h:mm:ss",
                              TimeFormatting.remaining(3661, trackDuration: 4000), "-1:01:01"))
        results.append(expect("exactly one hour counts as long",
                              TimeFormatting.position(5, trackDuration: 3600), "0:00:05"))

        results.append(expect("total of a short track", TimeFormatting.total(200), "3:20"))
        results.append(expect("total of a long track", TimeFormatting.total(4000), "1:06:40"))

        // Negative input must not produce nonsense.
        results.append(expect("negative clamps to zero", TimeFormatting.position(-5, trackDuration: 200), "0:00"))

        // End time, pinned to a fixed clock and locale so it is deterministic.
        var calendar = Calendar(identifier: .gregorian)
        let zone = TimeZone(identifier: "Pacific/Auckland")!
        calendar.timeZone = zone
        let fixed = calendar.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 14, minute: 30))!

        let twelveHour = TimeFormatting.endTime(
            remaining: 17 * 60, now: fixed, locale: Locale(identifier: "en_NZ"), timeZone: zone
        )
        results.append(M1ClockTests.Result(
            name: "end time, 12-hour locale",
            passed: twelveHour.hasPrefix("ends ") && twelveHour.contains("2:47"),
            detail: "\(twelveHour) — expected to contain 2:47"
        ))

        let twentyFourHour = TimeFormatting.endTime(
            remaining: 17 * 60, now: fixed, locale: Locale(identifier: "en_GB"), timeZone: zone
        )
        results.append(M1ClockTests.Result(
            name: "end time, 24-hour locale",
            passed: twentyFourHour.contains("14:47"),
            detail: "\(twentyFourHour) — expected to contain 14:47"
        ))

        // Rolling past midnight must not wrap to a negative or to the previous day.
        let nearMidnight = calendar.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 23, minute: 50))!
        let overMidnight = TimeFormatting.endTime(
            remaining: 20 * 60, now: nearMidnight, locale: Locale(identifier: "en_GB"), timeZone: zone
        )
        results.append(M1ClockTests.Result(
            name: "end time rolls past midnight",
            passed: overMidnight.contains("00:10"),
            detail: "\(overMidnight) — expected to contain 00:10"
        ))

        return results
    }

    private static func expect(_ name: String, _ actual: String, _ expected: String) -> M1ClockTests.Result {
        M1ClockTests.Result(
            name: name,
            passed: actual == expected,
            detail: actual == expected ? "\"\(actual)\"" : "got \"\(actual)\", expected \"\(expected)\""
        )
    }
}
