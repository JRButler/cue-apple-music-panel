//
//  M0Benchmark.swift
//  Cue
//
//  M0 diagnostic. The first `fetchState()` measurement came in at ~90 ms median,
//  ten times §3.1's budget, on the main thread, once a second. This exists to
//  find out where that time goes before M1 builds a scrub bar on top of it.
//
//  The hypothesis under test: one `NSAppleScript` execution is not one Apple
//  Event. Each property reference in the script is its own round trip to Music,
//  so a ten-field read costs ten events. If that is right, the per-event floor
//  times the field count should account for the whole 90 ms, and the fix is to
//  ask for a record of properties in a single reference rather than field by
//  field.
//
//  Deleted with the spike.
//

import Foundation

@MainActor
struct M0Benchmark {

    struct Variant: Sendable {
        let name: String
        /// What this variant is meant to tell us.
        let rationale: String
        /// How many Apple Event round trips this ought to cost, if the
        /// one-reference-one-event hypothesis holds.
        let expectedEvents: Int
        let source: String
    }

    static let variants: [Variant] = [
        Variant(
            name: "no-event-baseline",
            rationale: "A tell block that reads nothing. Isolates AppleScript's own overhead from the round trip.",
            expectedEvents: 0,
            source: """
            with timeout of 2 seconds
                tell application id "com.apple.Music" to return 1
            end timeout
            """
        ),
        Variant(
            name: "one-reference",
            rationale: "A single property. The per-event floor.",
            expectedEvents: 1,
            source: """
            with timeout of 2 seconds
                tell application id "com.apple.Music" to return player position
            end timeout
            """
        ),
        Variant(
            name: "ten-references",
            rationale: "What fetchState does today.",
            expectedEvents: 10,
            source: """
            with timeout of 2 seconds
                tell application id "com.apple.Music"
                    set ps to (player state as text)
                    set vol to sound volume
                    set shf to shuffle enabled
                    set rpt to (song repeat as text)
                    set pos to player position
                    tell current track
                        set pid to (persistent ID as text)
                        set tnm to (name as text)
                        set tar to (artist as text)
                        set tal to (album as text)
                        set tdu to duration
                    end tell
                    return {ps, pos, vol, shf, rpt, pid, tnm, tar, tal, tdu}
                end tell
            end timeout
            """
        ),
        Variant(
            name: "track-properties",
            rationale: "`properties of current track`: the whole track record in one reference.",
            expectedEvents: 1,
            source: """
            with timeout of 2 seconds
                tell application id "com.apple.Music" to return properties of current track
            end timeout
            """
        ),
        Variant(
            name: "app-properties",
            rationale: "`properties` on the application. Undeclared in the sdef, but pALL is standard — does it answer anyway?",
            expectedEvents: 1,
            source: """
            with timeout of 2 seconds
                tell application id "com.apple.Music" to return properties
            end timeout
            """
        ),
        Variant(
            name: "POLL-position-only",
            rationale: "PROPOSED 1 Hz hot path: position alone, with everything else driven by notifications.",
            expectedEvents: 1,
            source: """
            with timeout of 2 seconds
                tell application id "com.apple.Music" to return player position
            end timeout
            """
        ),
        Variant(
            name: "POLL-position-and-state",
            rationale: "PROPOSED 1 Hz hot path plus player state, in case notifications prove unreliable.",
            expectedEvents: 2,
            source: """
            with timeout of 2 seconds
                tell application id "com.apple.Music"
                    set a to player position
                    set b to (player state as text)
                    return {a, b}
                end tell
            end timeout
            """
        ),
        Variant(
            name: "SYNC-full-via-records",
            rationale: "PROPOSED on-notification read: track record in one reference, five app fields separately.",
            expectedEvents: 6,
            source: """
            with timeout of 2 seconds
                tell application id "com.apple.Music"
                    set ps to (player state as text)
                    set vol to sound volume
                    set shf to shuffle enabled
                    set rpt to (song repeat as text)
                    set pos to player position
                    set tp to {}
                    try
                        set tp to properties of current track
                    end try
                    return {ps, pos, vol, shf, rpt, tp}
                end tell
            end timeout
            """
        ),
    ]
}
