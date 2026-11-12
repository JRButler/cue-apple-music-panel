//
//  MusicBridge.swift
//  Cue
//
//  §3.1: the ONLY type in Cue that sends Apple Events. Everything else goes
//  through this async API.
//
//  NSAppleScript is main-thread-only and not Sendable, so the whole type is
//  main-actor isolated. Every script is kept small enough that a call returns
//  well inside a frame; `measureFetchLatency` exists to keep us honest about that.
//

import AppKit
import Foundation
import OSLog

@MainActor
final class MusicBridge {

    static let musicBundleID = "com.apple.Music"

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "nz.slstudio.Cue",
                                category: "MusicBridge")

    /// Compiled once at init and reused (§3.1).
    private var compiled: [MusicScript: NSAppleScript] = [:]
    /// Scripts that failed to compile, with the reason. Empty is the happy path.
    private(set) var compilationFailures: [MusicScript: String] = [:]

    /// Counts calls the §3.1 guard refused. Any non-zero value means we correctly
    /// declined to send an event that would have launched Music.
    private(set) var guardedCallCount = 0

    init() {
        for script in MusicScript.allCases {
            let instance = NSAppleScript(source: script.source)
            var error: NSDictionary?
            if instance?.compileAndReturnError(&error) == true, let instance {
                compiled[script] = instance
            } else {
                let detail = (error?[NSAppleScript.errorMessage] as? String) ?? "unknown error"
                compilationFailures[script] = detail
                logger.error("Failed to compile \(script.rawValue, privacy: .public): \(detail, privacy: .public)")
            }
        }
    }

    // MARK: - Running-app guard (§3.1)

    /// True when Music is already running. Checked before *every* call, because
    /// sending `tell application "Music"` to a dead app launches it, and §1 says
    /// we never do that as a side effect.
    var isMusicRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.musicBundleID).isEmpty
    }

    // MARK: - Permission

    /// Asks whether we may drive Music.
    ///
    /// With `askIfNeeded: false` this is silent and distinguishes "never asked"
    /// (-1744) from "refused" (-1743) — something sending a probe event cannot do,
    /// since that would itself trigger the prompt.
    func automationPermission(askIfNeeded: Bool = false) -> AutomationPermission {
        guard isMusicRunning else { return .musicNotRunning }

        let target = NSAppleEventDescriptor(bundleIdentifier: Self.musicBundleID)
        guard let addressDesc = target.aeDesc else { return .unknown(OSStatus(-1)) }

        let status = AEDeterminePermissionToAutomateTarget(
            addressDesc,
            typeWildCard,
            typeWildCard,
            askIfNeeded
        )

        switch status {
        case noErr:
            return .granted
        case OSStatus(errAEEventNotPermitted):
            return .denied
        case OSStatus(errAEEventWouldRequireUserConsent):
            return .notDetermined
        case OSStatus(procNotFound):
            return .musicNotRunning
        default:
            return .unknown(status)
        }
    }

    /// §5: opens the pane where the user can grant us access.
    func openAutomationSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
        NSWorkspace.shared.open(url)
    }

    /// The one place in Cue allowed to launch Music (§5, the "Open Music" button).
    func launchMusicDeliberately() async throws {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.musicBundleID) else {
            throw MusicBridgeError.musicNotRunning
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
    }

    // MARK: - Reads

    // MARK: - Record keys
    //
    // Four-char codes from the macOS 27.0.1 scripting definition, built from
    // their text form rather than hex so a typo cannot pass silently.
    //
    // Note `pnam` appears in BOTH records: in the application record it is the
    // app's own name ("Music"), in the track record it is the track title.
    // Always read it from the right one.

    private enum AppKey {
        static let playerState = AEKeyword(fourChar: "pPlS")
        static let volume = AEKeyword(fourChar: "pVol")
        static let mute = AEKeyword(fourChar: "pMut")
        static let shuffleEnabled = AEKeyword(fourChar: "pShE")
        static let songRepeat = AEKeyword(fourChar: "pRpt")
    }

    private enum TrackKey {
        static let name = AEKeyword(fourChar: "pnam")
        static let artist = AEKeyword(fourChar: "pArt")
        static let album = AEKeyword(fourChar: "pAlb")
        static let duration = AEKeyword(fourChar: "pDur")
        static let persistentID = AEKeyword(fourChar: "pPIS")
        static let favorited = AEKeyword(fourChar: "pLov")
    }

    /// `missing value`, which is how Music reports a genuinely absent field.
    private static let missingValueType = AEKeyword(fourChar: "msng")

    // MARK: - Reads

    /// Everything the 1 Hz tick needs, minus the track: two references, ~16.7 ms.
    ///
    /// Returns the application state and the position together. The track record
    /// is deliberately excluded — it only changes when the track changes, which
    /// arrives as a notification (§3.2).
    func fetchAppState() async throws -> MusicState {
        let list = try run(.fetchAppState)
        guard list.numberOfItems == 2, let appRecord = list.atIndex(1) else {
            throw MusicBridgeError.malformedResult(
                "fetchAppState returned \(list.numberOfItems) elements, expected 2"
            )
        }
        let rawPosition = list.atIndex(2)?.doubleValue ?? -1
        return Self.appState(from: appRecord, position: rawPosition, track: nil)
    }

    /// §3.3's full sync. Three references (~25 ms), driven by notifications and
    /// explicit user action, never by the 1 Hz timer.
    func fetchState() async throws -> MusicState {
        let list = try run(.fetchState)

        guard list.numberOfItems == 3 else {
            throw MusicBridgeError.malformedResult(
                "fetchState returned \(list.numberOfItems) elements, expected 3"
            )
        }

        guard let appRecord = list.atIndex(1) else {
            throw MusicBridgeError.malformedResult("fetchState returned no application record")
        }

        let rawPosition = list.atIndex(2)?.doubleValue ?? -1
        let trackRecord = list.atIndex(3).flatMap { Self.isPresent($0) ? $0 : nil }
        return Self.appState(
            from: appRecord,
            position: rawPosition,
            track: trackRecord.flatMap(Self.track(from:))
        )
    }

    /// One place that turns an application `properties` record into a state, so
    /// the tick and the full sync cannot drift apart in how they read it.
    private static func appState(
        from appRecord: NSAppleEventDescriptor,
        position rawPosition: Double,
        track: TrackInfo?
    ) -> MusicState {
        MusicState(
            playerState: PlayerState(enumCode: enumCode(appRecord, AppKey.playerState)),
            position: rawPosition >= 0 ? rawPosition : nil,
            volume: max(0, min(100, integer(appRecord, AppKey.volume) ?? 0)),
            isMuted: flag(appRecord, AppKey.mute) ?? false,
            isShuffling: flag(appRecord, AppKey.shuffleEnabled) ?? false,
            repeatMode: RepeatMode(enumCode: enumCode(appRecord, AppKey.songRepeat)),
            track: track
        )
    }

    /// Music's own mute state (`pMut`), which arrives free in the application
    /// record. §4.6's mute button is M2; this is here so it need not be re-read.
    // MARK: - Record parsing
    //
    // Each accessor matches the descriptor type observed with `--dump-records`:
    // utxt → stringValue, enum → enumCodeValue, long → int32Value,
    // doub → doubleValue, true/fals → booleanValue. They fall back rather than
    // trap, because a field Music stops sending should degrade one value, not
    // take down the whole sync.

    /// Returns nil when the record is present but hollow.
    ///
    /// After the last track of an album finishes, Music keeps answering
    /// `current track` with a record whose every field is empty rather than
    /// erroring. Building a TrackInfo from it gave the panel a track with no
    /// title, no artwork and no duration — which rendered as a blank panel with
    /// an indeterminate scrub bar instead of §5's "nothing queued" state.
    private static func track(from record: NSAppleEventDescriptor) -> TrackInfo? {
        let duration = number(record, TrackKey.duration) ?? -1
        let name = text(record, TrackKey.name) ?? ""
        let persistentID = text(record, TrackKey.persistentID) ?? ""
        let artist = text(record, TrackKey.artist) ?? ""

        if name.isEmpty, persistentID.isEmpty, artist.isEmpty, duration <= 0 {
            return nil
        }

        return TrackInfo(
            persistentID: persistentID,
            name: name,
            artist: artist,
            album: text(record, TrackKey.album) ?? "",
            duration: duration > 0 ? duration : 0,
            isFavourite: flag(record, TrackKey.favorited) ?? false
        )
    }

    /// False for a `missing value` descriptor, which is not the same as absent.
    private static func isPresent(_ descriptor: NSAppleEventDescriptor) -> Bool {
        AEKeyword(descriptor.descriptorType) != missingValueType
    }

    private static func field(_ record: NSAppleEventDescriptor, _ key: AEKeyword) -> NSAppleEventDescriptor? {
        guard let value = record.forKeyword(key), isPresent(value) else { return nil }
        return value
    }

    private static func text(_ record: NSAppleEventDescriptor, _ key: AEKeyword) -> String? {
        field(record, key)?.stringValue
    }

    private static func number(_ record: NSAppleEventDescriptor, _ key: AEKeyword) -> Double? {
        field(record, key)?.doubleValue
    }

    private static func integer(_ record: NSAppleEventDescriptor, _ key: AEKeyword) -> Int? {
        field(record, key).map { Int($0.int32Value) }
    }

    private static func flag(_ record: NSAppleEventDescriptor, _ key: AEKeyword) -> Bool? {
        field(record, key)?.booleanValue
    }

    /// Enum fields arrive as `enum`, read through `enumCodeValue`. Zero means
    /// absent, and every `init(enumCode:)` maps that to its own default.
    private static func enumCode(_ record: NSAppleEventDescriptor, _ key: AEKeyword) -> OSType {
        field(record, key)?.enumCodeValue ?? 0
    }

    // MARK: - Commands

    func playPause() async throws {
        _ = try run(.playPause)
    }

    /// Starts playback outright. Needed when nothing is queued, where
    /// `playpause` has no current track to toggle and does nothing.
    func play() async throws {
        _ = try run(.play)
    }

    func next() async throws {
        _ = try run(.nextTrack)
    }

    func previous() async throws {
        _ = try run(.previousTrack)
    }

    /// §4.2: exactly one of these per drag, sent on release.
    func seek(to seconds: TimeInterval) async throws {
        _ = try run(.seek, arguments: [NSAppleEventDescriptor(double: max(0, seconds))])
    }

    /// §4.3's artwork bytes, or nil when the track carries none.
    ///
    /// Called on track change only, never from the 1 Hz tick — it is the one
    /// script here that moves a non-trivial payload, and §4.3 says so explicitly.
    func fetchArtwork() async throws -> Data? {
        let descriptor = try run(.fetchArtwork)
        guard Self.isPresent(descriptor) else { return nil }
        let data = descriptor.data

        // Music sometimes answers with a token payload rather than an image —
        // a 4-byte reply was observed moments after it relaunched, while it was
        // presumably still warming up. Nothing that small can be an image, and
        // passing it on as artwork led to a failed decode being cached as
        // "this track has no artwork". Treat it as absent.
        guard data.count >= Self.minimumPlausibleArtworkBytes else {
            if !data.isEmpty {
                logger.notice("Discarding \(data.count, privacy: .public)-byte artwork reply as implausible")
            }
            return nil
        }
        return data
    }

    /// Smaller than any real encoded image; large enough to reject tokens.
    private static let minimumPlausibleArtworkBytes = 128

    /// §4.6. Music's own output level, 0–100, not the system volume.
    func setVolume(_ volume: Int) async throws {
        let clamped = min(max(0, volume), 100)
        _ = try run(.setVolume, arguments: [NSAppleEventDescriptor(int32: Int32(clamped))])
    }

    /// §4.6's mute, restoring the previous level being the caller's job.
    func setMuted(_ muted: Bool) async throws {
        _ = try run(.setMute, arguments: [NSAppleEventDescriptor(boolean: muted)])
    }

    // MARK: - §4.5

    func setShuffle(_ enabled: Bool) async throws {
        _ = try run(.setShuffle, arguments: [NSAppleEventDescriptor(boolean: enabled)])
    }

    func setRepeat(_ mode: RepeatMode) async throws {
        _ = try run(.setRepeat, arguments: [NSAppleEventDescriptor(string: mode.rawValue)])
    }

    func setFavourite(_ favourite: Bool) async throws {
        _ = try run(.setFavourite, arguments: [NSAppleEventDescriptor(boolean: favourite)])
    }

    // MARK: - M0 diagnostics

    /// Answers §4.5's open question against the running app.
    /// Returns the reply for `favorited` and for the older `loved`.
    func probeFavouriteProperty() async throws -> (favorited: String, loved: String) {
        let list = try run(.probeFavourite)
        guard list.numberOfItems == 2 else {
            throw MusicBridgeError.malformedResult("favourite probe returned \(list.numberOfItems) fields")
        }
        return (list.atIndex(1)?.stringValue ?? "", list.atIndex(2)?.stringValue ?? "")
    }

    struct LatencyReport: Sendable {
        var samples: Int
        var minMS: Double
        var medianMS: Double
        var p95MS: Double
        var maxMS: Double

        var summary: String {
            String(
                format: "n=%d  min %.1f ms  median %.1f ms  p95 %.1f ms  max %.1f ms",
                samples, minMS, medianMS, p95MS, maxMS
            )
        }
    }

    /// M0 acceptance criterion: measured `fetchState()` latency, recorded in CLAUDE.md.
    /// Uses a monotonic clock so a wall-clock adjustment cannot skew a sample.
    func measureFetchLatency(samples: Int = 100) async throws -> LatencyReport {
        guard samples > 0 else { throw MusicBridgeError.malformedResult("sample count must be positive") }

        var timings: [Double] = []
        timings.reserveCapacity(samples)

        for _ in 0 ..< samples {
            let start = ContinuousClock.now
            _ = try await fetchState()
            let elapsed = ContinuousClock.now - start
            timings.append(Double(elapsed.components.attoseconds) / 1e15
                + Double(elapsed.components.seconds) * 1000)
        }

        timings.sort()
        func percentile(_ p: Double) -> Double {
            let index = min(timings.count - 1, max(0, Int((p * Double(timings.count - 1)).rounded())))
            return timings[index]
        }

        return LatencyReport(
            samples: timings.count,
            minMS: timings[0],
            medianMS: percentile(0.5),
            p95MS: percentile(0.95),
            maxMS: timings[timings.count - 1]
        )
    }

    /// M0 only: compiles an arbitrary source and times it, so `fetchState`
    /// variants can be compared head to head. Lives here rather than in the
    /// benchmark harness so §3.1's rule holds — this stays the only type that
    /// sends Apple Events. Goes away with the spike.
    func benchmarkAdHoc(source: String, samples: Int) throws -> LatencyReport {
        guard isMusicRunning else { throw MusicBridgeError.musicNotRunning }

        let instance = NSAppleScript(source: source)
        var compileError: NSDictionary?
        guard instance?.compileAndReturnError(&compileError) == true, let instance else {
            throw MusicBridgeError.compilationFailed(
                (compileError?[NSAppleScript.errorMessage] as? String) ?? "unknown error"
            )
        }

        var timings: [Double] = []
        timings.reserveCapacity(samples)

        for _ in 0 ..< samples {
            var runError: NSDictionary?
            let start = ContinuousClock.now
            _ = instance.executeAndReturnError(&runError)
            let elapsed = ContinuousClock.now - start
            if let runError { throw Self.mapError(runError) }
            timings.append(Double(elapsed.components.seconds) * 1000
                + Double(elapsed.components.attoseconds) / 1e15)
        }

        timings.sort()
        func percentile(_ fraction: Double) -> Double {
            timings[min(timings.count - 1, max(0, Int((fraction * Double(timings.count - 1)).rounded())))]
        }

        return LatencyReport(
            samples: timings.count,
            minMS: timings[0],
            medianMS: percentile(0.5),
            p95MS: percentile(0.95),
            maxMS: timings[timings.count - 1]
        )
    }

    /// M1 scaffolding: runs an ad-hoc source and returns the raw descriptor, so
    /// the shape of a `properties` record can be inspected before a parser is
    /// written against it. Guessing at four-char codes and descriptor types is
    /// how you get a parser that silently returns zeroes.
    func rawDescriptor(source: String) throws -> NSAppleEventDescriptor {
        guard isMusicRunning else { throw MusicBridgeError.musicNotRunning }

        let instance = NSAppleScript(source: source)
        var compileError: NSDictionary?
        guard instance?.compileAndReturnError(&compileError) == true, let instance else {
            throw MusicBridgeError.compilationFailed(
                (compileError?[NSAppleScript.errorMessage] as? String) ?? "unknown error"
            )
        }
        var runError: NSDictionary?
        let result = instance.executeAndReturnError(&runError)
        if let runError { throw Self.mapError(runError) }
        return result
    }

    // MARK: - Execution

    /// Runs a compiled script, applying the §3.1 guard and the §3.1 error mapping.
    @discardableResult
    private func run(_ script: MusicScript, arguments: [NSAppleEventDescriptor] = []) throws -> NSAppleEventDescriptor {
        // The guard comes first, before anything that could send an event.
        guard isMusicRunning else {
            guardedCallCount += 1
            logger.debug("Guarded \(script.rawValue, privacy: .public): Music is not running")
            throw MusicBridgeError.musicNotRunning
        }

        guard let instance = compiled[script] else {
            throw MusicBridgeError.compilationFailed(
                compilationFailures[script] ?? "\(script.rawValue) was never compiled"
            )
        }

        var error: NSDictionary?
        let result: NSAppleEventDescriptor?

        if let handler = script.handlerName {
            result = instance.executeAppleEvent(
                Self.subroutineEvent(handler: handler, arguments: arguments),
                error: &error
            )
        } else {
            result = instance.executeAndReturnError(&error)
        }

        if let error {
            throw Self.mapError(error)
        }
        guard let result else {
            throw MusicBridgeError.malformedResult("\(script.rawValue) returned no descriptor and no error")
        }
        return result
    }

    /// Builds the `ascr`/`psbr` event that calls a handler inside a compiled
    /// script, which is how `seek(to:)` passes its argument without recompiling.
    private static func subroutineEvent(
        handler: String,
        arguments: [NSAppleEventDescriptor]
    ) -> NSAppleEventDescriptor {
        // Four-char codes spelled out so this file needs no Carbon import.
        let kAppleScriptSuite = AEEventClass(0x6173_6372)    // 'ascr'
        let kSubroutineEvent = AEEventID(0x7073_6272)        // 'psbr'
        let keySubroutineName = AEKeyword(0x736E_616D)       // 'snam'
        let keyDirectObjectCode = AEKeyword(0x2D2D_2D2D)     // '----'

        let event = NSAppleEventDescriptor(
            eventClass: kAppleScriptSuite,
            eventID: kSubroutineEvent,
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )

        // AppleScript matches the handler name case-insensitively only if it is
        // supplied lower case here; MusicScript.handlerName already guarantees that.
        event.setDescriptor(NSAppleEventDescriptor(string: handler), forKeyword: keySubroutineName)

        let argumentList = NSAppleEventDescriptor.list()
        for (offset, argument) in arguments.enumerated() {
            argumentList.insert(argument, at: offset + 1)
        }
        event.setDescriptor(argumentList, forKeyword: keyDirectObjectCode)

        return event
    }

    /// §3.1's error table. Not private so M0 can verify every row of it
    /// without having to provoke each condition for real.
    static func mapError(_ error: NSDictionary) -> MusicBridgeError {
        let code = (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
        let message = (error[NSAppleScript.errorMessage] as? String) ?? "unknown error"

        switch code {
        case Int(errAEEventNotPermitted), Int(errAEEventWouldRequireUserConsent):
            // -1743 refused; -1744 means consent was never granted. Both are the
            // same thing for the UI: §5's "needs permission" state.
            return .automationDenied
        case Int(procNotFound):
            // -600: Music went away between the guard and the send.
            return .musicNotRunning
        case Int(connectionInvalid):
            // -609 is NOT "Music is gone". The app keeps running and keeps
            // playing; it is the Apple Event connection that has gone stale,
            // which happens across a sleep/wake cycle. Conflating the two made
            // the panel declare "Music isn't open" over a live player, and —
            // because that state stopped the poll — it never recovered.
            return .connectionLost
        case Int(errAETimeout):
            // -1712: our `with timeout` elapsed. Distinct from a script fault,
            // and the state a pending permission prompt produces.
            return .timedOut
        default:
            return .scriptError(code: code, message: message)
        }
    }
}
