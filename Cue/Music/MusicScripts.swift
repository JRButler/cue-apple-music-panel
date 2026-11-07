//
//  MusicScripts.swift
//  Cue
//
//  AppleScript sources, compiled once by MusicBridge and reused.
//
//  Every script addresses Music by bundle id rather than by name, so a localised
//  or renamed Music.app still resolves. Compiling a `tell application id` block
//  reads the target's scripting definition but does not launch it; only sending
//  the event would, which is what MusicBridge's running-app guard prevents.
//
//  Property and enumeration names below were taken from the macOS 27.0.1
//  scripting definition (`sdef /System/Applications/Music.app`).
//
//  EVERY script sets an explicit `with timeout`. This is not belt-and-braces.
//  The Apple Event default is two minutes, and NSAppleScript blocks the thread
//  it runs on — which per §3.1 is always the main thread. One stalled event,
//  whether because Music is busy or because a permission prompt is sitting
//  unanswered, would otherwise freeze the panel for two minutes. Measured
//  during M0: an unanswered Automation prompt does exactly that.
//

import Foundation

enum MusicScript: String, CaseIterable, Sendable {
    /// One batched read of every polled field (§3.1: never one call per property).
    case fetchState
    case playPause
    case nextTrack
    case previousTrack
    /// Takes one argument, so it is invoked as a subroutine rather than recompiled.
    case seek
    /// M0 only: confirms the favourite property name at runtime.
    case probeFavourite

    /// The subroutine to call, for scripts that take arguments.
    /// AppleScript requires the name in the event to be lower case.
    var handlerName: String? {
        switch self {
        case .seek: "seekto"
        default: nil
        }
    }

    var source: String {
        switch self {
        case .fetchState: Self.fetchStateSource
        case .playPause: Self.playPauseSource
        case .nextTrack: Self.nextTrackSource
        case .previousTrack: Self.previousTrackSource
        case .seek: Self.seekSource
        case .probeFavourite: Self.probeFavouriteSource
        }
    }
}

// MARK: - Sources

extension MusicScript {

    /// Returns a flat, fixed-order list rather than a record.
    ///
    /// A record with custom keys comes back wrapped in a `usrf` key/value list that
    /// has to be walked pairwise; a list is indexable directly. The point of §3.1 —
    /// one round trip for every field — is unaffected. The order here must match
    /// `MusicBridge.StateField`.
    ///
    /// Note which reads are wrapped in `try` and which are not. This is load-bearing.
    ///
    /// `player state` is read first and deliberately left unprotected, as a canary.
    /// If we are not permitted to drive Music, every read fails, and wrapping them
    /// all would turn that into a well-formed list of empty values — a silent lie
    /// that looks like a stopped player and hides §5's "automation denied" state.
    /// Leaving the first reads bare lets the error reach `MusicBridge.mapError`.
    /// Volume, shuffle and repeat are the same: Music always has those, so a
    /// failure there is systemic and should propagate.
    ///
    /// Only genuinely absent things get a `try`: `player position` is `missing
    /// value` when stopped, `current track` errors when nothing is queued, and
    /// `duration` is absent on some streams (§4.2's indeterminate-bar case).
    ///
    /// Two seconds, because this runs at 1 Hz: a read that takes longer than that
    /// has already missed its slot, and the clock in §3.3 will interpolate over it.
    static let fetchStateSource = """
    with timeout of 2 seconds
        tell application id "com.apple.Music"
            -- Canary: unprotected on purpose. See the note above.
            set ps to (player state as text)
            set vol to sound volume
            set shf to shuffle enabled
            set rpt to (song repeat as text)

            set pos to -1
            try
                set pos to player position
                if pos is missing value then set pos to -1
            end try

            set pid to ""
            set tnm to ""
            set tar to ""
            set tal to ""
            set tdu to -1
            try
                tell current track
                    set pid to (persistent ID as text)
                    set tnm to (name as text)
                    set tar to (artist as text)
                    set tal to (album as text)
                    try
                        set tdu to duration
                        if tdu is missing value then set tdu to -1
                    end try
                end tell
            end try

            return {ps, pos, vol, shf, rpt, pid, tnm, tar, tal, tdu}
        end tell
    end timeout
    """

    static let playPauseSource = """
    with timeout of 5 seconds
        tell application id "com.apple.Music" to playpause
    end timeout
    """

    static let nextTrackSource = """
    with timeout of 5 seconds
        tell application id "com.apple.Music" to next track
    end timeout
    """

    /// §4.4: Music's own `previous track` already restarts the track when more
    /// than a few seconds in, so we do not second-guess it.
    static let previousTrackSource = """
    with timeout of 5 seconds
        tell application id "com.apple.Music" to previous track
    end timeout
    """

    /// Invoked via `MusicBridge.call(_:argument:)`, which sends a subroutine event.
    /// Compiling once and passing the position as an argument avoids recompiling a
    /// script per seek, which would defeat §3.1's compile-once rule.
    static let seekSource = """
    on seekto(p)
        with timeout of 5 seconds
            tell application id "com.apple.Music" to set player position to p
        end timeout
    end seekto
    """

    /// M0's open question from §4.5: is the property `favorited` or the older `loved`?
    ///
    /// The macOS 27.0.1 scripting definition has `favorited` (code `pLov`) on
    /// `track` and no `loved` at all, but the dictionary is not the whole story,
    /// so this asks the running app for both and reports what each answers.
    ///
    /// Probing both in one script is safe: AppleScript does not resolve property
    /// names at compile time. `get flurgle42 of current track` compiles happily,
    /// so an absent term surfaces as a runtime error the `on error` blocks catch,
    /// not as a compile failure that would take the whole script down.
    static let probeFavouriteSource = """
    with timeout of 5 seconds
        tell application id "com.apple.Music"
            set favResult to "unavailable"
            set lovedResult to "unavailable"
            try
                set favResult to ((favorited of current track) as text)
            on error errMsg number errNum
                set favResult to "error " & errNum & ": " & errMsg
            end try
            try
                set lovedResult to ((loved of current track) as text)
            on error errMsg number errNum
                set lovedResult to "error " & errNum & ": " & errMsg
            end try
            return {favResult, lovedResult}
        end tell
    end timeout
    """
}
