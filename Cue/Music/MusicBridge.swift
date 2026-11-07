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

    /// Field order of `MusicScript.fetchState`'s returned list. Must stay in step
    /// with the `return {...}` line in that script.
    private enum StateField: Int, CaseIterable {
        case playerState = 1
        case position
        case volume
        case shuffle
        case repeatMode
        case persistentID
        case name
        case artist
        case album
        case duration
    }

    /// One batched sample of everything the panel polls (§3.1).
    func fetchState() async throws -> MusicState {
        let list = try run(.fetchState)

        guard list.numberOfItems == StateField.allCases.count else {
            throw MusicBridgeError.malformedResult(
                "fetchState returned \(list.numberOfItems) fields, expected \(StateField.allCases.count)"
            )
        }

        func text(_ field: StateField) -> String {
            list.atIndex(field.rawValue)?.stringValue ?? ""
        }
        func number(_ field: StateField) -> Double {
            list.atIndex(field.rawValue)?.doubleValue ?? -1
        }
        func flag(_ field: StateField) -> Bool {
            list.atIndex(field.rawValue)?.booleanValue ?? false
        }

        let rawPosition = number(.position)
        let rawDuration = number(.duration)
        let persistentID = text(.persistentID)
        let name = text(.name)

        // The script sends -1 for "no current track", so an empty id AND an empty
        // name is the only reliable test: streams can have a name but no id.
        let track: TrackInfo? = (persistentID.isEmpty && name.isEmpty)
            ? nil
            : TrackInfo(
                persistentID: persistentID,
                name: name,
                artist: text(.artist),
                album: text(.album),
                duration: rawDuration > 0 ? rawDuration : 0
            )

        return MusicState(
            playerState: PlayerState(appleScriptText: text(.playerState)),
            position: rawPosition >= 0 ? rawPosition : nil,
            volume: max(0, Int(number(.volume))),
            isShuffling: flag(.shuffle),
            repeatMode: RepeatMode(appleScriptText: text(.repeatMode)),
            track: track
        )
    }

    // MARK: - Commands

    func playPause() async throws {
        _ = try run(.playPause)
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
        case Int(procNotFound), Int(connectionInvalid):
            // -600 / -609: Music went away between the guard and the send.
            return .musicNotRunning
        case Int(errAETimeout):
            // -1712: our `with timeout` elapsed. Distinct from a script fault,
            // and the state a pending permission prompt produces.
            return .timedOut
        default:
            return .scriptError(code: code, message: message)
        }
    }
}
