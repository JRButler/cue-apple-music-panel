//
//  MusicTypes.swift
//  Cue
//
//  Value types shared across the Music bridge. Nothing here sends Apple Events.
//

import Foundation

// MARK: - Player state

/// Mirrors Music's `ePlS` enumeration (see the app's scripting definition).
enum PlayerState: String, Sendable, CaseIterable {
    case stopped
    case playing
    case paused
    case fastForwarding
    case rewinding
    case unknown

    /// Music returns these via `player state as text`.
    init(appleScriptText raw: String) {
        switch raw.lowercased() {
        case "stopped": self = .stopped
        case "playing": self = .playing
        case "paused": self = .paused
        case "fast forwarding", "fastforwarding": self = .fastForwarding
        case "rewinding": self = .rewinding
        default: self = .unknown
        }
    }

    /// True whenever the position is advancing, so the clock should run.
    var isAdvancing: Bool {
        switch self {
        case .playing, .fastForwarding, .rewinding: true
        case .stopped, .paused, .unknown: false
        }
    }
}

// MARK: - Repeat

/// Mirrors Music's `eRpt` enumeration: off / one / all.
enum RepeatMode: String, Sendable, CaseIterable {
    case off
    case one
    case all

    init(appleScriptText raw: String) {
        switch raw.lowercased() {
        case "one": self = .one
        case "all": self = .all
        default: self = .off
        }
    }

    /// §4.5 cycles off → all → one.
    var next: RepeatMode {
        switch self {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }
}

// MARK: - Track

struct TrackInfo: Sendable, Equatable, Identifiable {
    /// `persistent ID of current track`, inherited from Music's `item` class.
    /// Empty for some streamed catalogue tracks, so never assume it is unique.
    var persistentID: String
    var name: String
    var artist: String
    var album: String
    /// Seconds. Zero when Music reports no duration, which happens on streams.
    var duration: TimeInterval

    var id: String { persistentID.isEmpty ? "\(name)\u{1F}\(artist)\u{1F}\(album)" : persistentID }

    /// §4.2: a track with no duration gets an indeterminate bar and no seeking.
    var isSeekable: Bool { duration > 0 }
}

// MARK: - Snapshot

/// One `fetchState()` sample. Deliberately has no timestamp: whoever receives it
/// stamps it, so `PlaybackClock` interpolates from the moment of receipt (M1).
struct MusicState: Sendable, Equatable {
    var playerState: PlayerState
    /// Seconds into the track. Nil when Music reports no position, e.g. stopped.
    var position: TimeInterval?
    /// Music's own output level, 0–100. Not the system volume.
    var volume: Int
    var isShuffling: Bool
    var repeatMode: RepeatMode
    var track: TrackInfo?

    static let idle = MusicState(
        playerState: .stopped,
        position: nil,
        volume: 0,
        isShuffling: false,
        repeatMode: .off,
        track: nil
    )
}

// MARK: - Permission

/// Result of asking whether we may drive Music, without necessarily prompting.
enum AutomationPermission: Sendable, Equatable {
    /// We may send events.
    case granted
    /// The user said no, or an MDM profile forbids it. Needs System Settings.
    case denied
    /// Never asked. Sending an event, or probing with `askIfNeeded: true`, prompts.
    case notDetermined
    /// Music is not running, so there is nothing to ask about.
    case musicNotRunning
    case unknown(OSStatus)

    var isUsable: Bool { self == .granted }
}

// MARK: - Errors

enum MusicBridgeError: Error, Sendable, Equatable {
    /// The §3.1 guard tripped: Music is not running and we refused to launch it.
    case musicNotRunning
    /// -1743. The user must grant Automation access in System Settings.
    case automationDenied
    /// -1712. Music did not answer inside the script's `with timeout`. Seen when
    /// Music is busy, and whenever an Automation prompt is waiting to be answered.
    case timedOut
    case scriptError(code: Int, message: String)
    case malformedResult(String)
    case compilationFailed(String)
}

extension MusicBridgeError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .musicNotRunning:
            "Music isn't open."
        case .automationDenied:
            "Cue needs permission to control Music."
        case .timedOut:
            "Music didn't answer in time."
        case let .scriptError(code, message):
            "Music returned error \(code): \(message)"
        case let .malformedResult(detail):
            "Unexpected reply from Music: \(detail)"
        case let .compilationFailed(detail):
            "A script failed to compile: \(detail)"
        }
    }
}
