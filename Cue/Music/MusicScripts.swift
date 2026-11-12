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
    /// §3.3's 1 Hz hot path: the application `properties` record plus
    /// `player position`. Two references, ~16.7 ms.
    case fetchAppState
    /// §3.3's full sync, off the timer. Three references, ~25 ms.
    case fetchState
    case playPause
    case nextTrack
    case previousTrack
    /// Takes one argument, so it is invoked as a subroutine rather than recompiled.
    case seek
    /// §4.3's artwork, fetched on track change only — never on the poll.
    case fetchArtwork
    /// §4.6, both argument-taking.
    case setVolume
    case setMute
    /// §4.5, all argument-taking.
    case setShuffle
    case setRepeat
    case setFavourite
    /// M0 only: confirms the favourite property name at runtime.
    case probeFavourite

    /// The subroutine to call, for scripts that take arguments.
    /// AppleScript requires the name in the event to be lower case.
    var handlerName: String? {
        switch self {
        case .seek: "seekto"
        case .setVolume: "setvolume"
        case .setMute: "setmute"
        case .setShuffle: "setshuffle"
        case .setRepeat: "setrepeat"
        case .setFavourite: "setfavourite"
        default: nil
        }
    }

    var source: String {
        switch self {
        case .fetchAppState: Self.fetchAppStateSource
        case .fetchState: Self.fetchStateSource
        case .playPause: Self.playPauseSource
        case .nextTrack: Self.nextTrackSource
        case .previousTrack: Self.previousTrackSource
        case .seek: Self.seekSource
        case .fetchArtwork: Self.fetchArtworkSource
        case .setVolume: Self.setVolumeSource
        case .setMute: Self.setMuteSource
        case .setShuffle: Self.setShuffleSource
        case .setRepeat: Self.setRepeatSource
        case .setFavourite: Self.setFavouriteSource
        case .probeFavourite: Self.probeFavouriteSource
        }
    }
}

// MARK: - Sources

extension MusicScript {

    /// §3.3's hot path. Two references, deliberately — see the note below.
    ///
    /// It was one (`player position` alone, ~8.3 ms) until §4.6's acceptance
    /// criterion forced the issue: "a change made in Music is reflected within
    /// 1 s". Music posts no notification when its volume, shuffle or repeat
    /// change, so the only way to notice is to look, and looking has to happen
    /// at least once a second to meet that.
    ///
    /// The application `properties` record costs the same single event as
    /// reading `sound volume` alone, and carries volume, mute, shuffle, repeat
    /// and player state together — so the fix is one extra reference for all of
    /// them, not one per field. `player position` stays separate because it is
    /// not in that record (see the full sync below).
    ///
    /// Two seconds, because this runs at 1 Hz: a read slower than that has
    /// already missed its slot, and PlaybackClock interpolates over the gap.
    static let fetchAppStateSource = """
    with timeout of 2 seconds
        tell application id "com.apple.Music"
            set appProps to properties
            set pos to player position
            if pos is missing value then set pos to -1
            return {appProps, pos}
        end tell
    end timeout
    """

    /// The full sync: three references, returned as a three-element list.
    ///
    /// M0 measured one property reference as one ~8.3 ms Apple Event, so the
    /// shape of this script is its cost. `properties` returns an entire record
    /// for a single reference, which is what makes this 3 events rather than the
    /// 10 it started as. Measured with `--bench`; see §6.1.
    ///
    /// It has to be three, not two, because **`player position` is not in the
    /// application `properties` record** — that record has 16 fields and neither
    /// `pPos` nor `pTrk` is among them. Verified with `--dump-records`.
    ///
    /// `properties of current track` raises -1728 when nothing is queued rather
    /// than returning an empty record, so it needs its own `try`. The other two
    /// are unprotected on purpose: see the canary note in §3.1 — wrapping them
    /// would turn a refused connection into a plausible-looking stopped player.
    static let fetchStateSource = """
    with timeout of 5 seconds
        tell application id "com.apple.Music"
            set appProps to properties
            set pos to player position
            if pos is missing value then set pos to -1
            set trackProps to missing value
            try
                set trackProps to properties of current track
            end try
            return {appProps, pos, trackProps}
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

    /// §4.3's artwork.
    ///
    /// `raw data` (`pRaw`), not `data` (`pPCT`): the latter is typed `picture`,
    /// while the former hands back the original bytes, which `NSImage` decodes
    /// directly. `artworks` is the plural form of the element.
    ///
    /// Returns `missing value` rather than erroring when a track carries no art,
    /// which some streamed catalogue tracks do — §4.3's placeholder case. Ten
    /// seconds, because this moves real bytes, unlike every other script here.
    static let fetchArtworkSource = """
    with timeout of 10 seconds
        tell application id "com.apple.Music"
            set artData to missing value
            try
                tell current track
                    if (count of artworks) > 0 then
                        set artData to raw data of artwork 1
                    end if
                end tell
            end try
            return artData
        end tell
    end timeout
    """

    /// §4.6. Clamped here as well as in Swift: Music silently ignores an
    /// out-of-range value rather than complaining, which would look like the
    /// slider having no effect.
    static let setVolumeSource = """
    on setvolume(v)
        with timeout of 5 seconds
            tell application id "com.apple.Music"
                if v < 0 then set v to 0
                if v > 100 then set v to 100
                set sound volume to (v as integer)
            end tell
        end timeout
    end setvolume
    """

    /// §4.6's mute, which is Music's own `mute` rather than system audio.
    static let setMuteSource = """
    on setmute(m)
        with timeout of 5 seconds
            tell application id "com.apple.Music" to set mute to m
        end timeout
    end setmute
    """

    /// §4.5's shuffle.
    ///
    /// Music applies these writes asynchronously: reading the property back in
    /// the same script returns the OLD value, which made an early probe look
    /// like the write had silently failed. Do not verify a write by reading it
    /// immediately — update optimistically and let the next tick confirm.
    static let setShuffleSource = """
    on setshuffle(enabled)
        with timeout of 5 seconds
            tell application id "com.apple.Music" to set shuffle enabled to enabled
        end timeout
    end setshuffle
    """

    /// §4.5's repeat. The `eRpt` values are enum constants, not strings, so the
    /// mode arrives as text and is mapped here.
    static let setRepeatSource = """
    on setrepeat(mode)
        with timeout of 5 seconds
            tell application id "com.apple.Music"
                if mode is "one" then
                    set song repeat to one
                else if mode is "all" then
                    set song repeat to all
                else
                    set song repeat to off
                end if
            end tell
        end timeout
    end setrepeat
    """

    /// §4.5's favourite — `favorited`, confirmed writable in M3.
    static let setFavouriteSource = """
    on setfavourite(flag)
        with timeout of 5 seconds
            tell application id "com.apple.Music" to set favorited of current track to flag
        end timeout
    end setfavourite
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
