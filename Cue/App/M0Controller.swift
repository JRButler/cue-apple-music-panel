//
//  M0Controller.swift
//  Cue
//
//  Wires MusicBridge to MusicEventSource for the M0 bridge spike and records
//  what the milestone asks us to measure.
//
//  This is NOT §3.3's PlayerModel. It holds no interpolated position, does no
//  1 Hz polling and owns no UI state; it exists to exercise the bridge and
//  collect numbers. PlayerModel and PlaybackClock arrive in M1 and this type
//  goes away with the debug window.
//

import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class M0Controller {

    let log: EventLog
    let bridge: MusicBridge

    private let events: MusicEventSource

    // Observed state, for the debug window to render.
    var isMusicRunning = false
    var permission: AutomationPermission = .notDetermined
    var lastState: MusicState?
    var lastError: String?
    var latency: MusicBridge.LatencyReport?
    var favouriteProbe: String?

    /// Worst notification-to-state-logged interval seen, which is the figure
    /// M0's "track changes are logged within 200 ms" criterion is judged on.
    var worstResyncMS: Double?
    var playerInfoCount: Int { events.playerInfoCount }
    var observedPayloadKeys: [String] { events.observedPlayerInfoKeys.sorted() }
    var lastPayload: PlayerInfoPayload?

    init(log: EventLog = EventLog(), bridge: MusicBridge = MusicBridge(), events: MusicEventSource = MusicEventSource()) {
        self.log = log
        self.bridge = bridge
        self.events = events
    }

    // MARK: - Lifecycle

    func start() {
        log.append(.lifecycle, "Cue M0 starting — pid \(ProcessInfo.processInfo.processIdentifier)")
        if let url = log.logFileURL {
            log.append(.lifecycle, "Logging to \(url.path)")
        }

        for (script, reason) in bridge.compilationFailures.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            log.append(.failure, "Script \(script.rawValue) failed to compile: \(reason)")
        }
        if bridge.compilationFailures.isEmpty {
            log.append(.lifecycle, "All \(MusicScript.allCases.count) scripts compiled")
        }

        events.start(handlers: .init(
            playerInfo: { [weak self] payload in
                self?.handlePlayerInfo(payload)
            },
            musicLaunched: { [weak self] in
                guard let self else { return }
                log.append(.notification, "NSWorkspace: Music launched")
                Task { await self.resync(reason: "music launched") }
            },
            musicTerminated: { [weak self] in
                guard let self else { return }
                log.append(.notification, "NSWorkspace: Music terminated")
                refreshEnvironment()
                lastState = nil
            }
        ))
        log.append(.lifecycle, "Observing \(MusicEventSource.playerInfoNotification.rawValue) and NSWorkspace launch/terminate")

        refreshEnvironment()
    }

    func stop() {
        events.stop()
    }

    /// Re-reads the two things that gate every call: is Music up, and may we talk to it.
    func refreshEnvironment() {
        let wasRunning = isMusicRunning
        isMusicRunning = bridge.isMusicRunning
        permission = bridge.automationPermission(askIfNeeded: false)

        if wasRunning != isMusicRunning {
            log.append(.lifecycle, "Music running: \(isMusicRunning)")
        }
        log.append(.lifecycle, "Automation permission: \(describe(permission))")
    }

    // MARK: - Notifications

    private func handlePlayerInfo(_ payload: PlayerInfoPayload) {
        let arrived = ContinuousClock.now
        lastPayload = payload
        log.appendBlock(
            .notification,
            title: "playerInfo #\(events.playerInfoCount) received",
            body: payload.fullDescription
        )
        Task { await resync(reason: "playerInfo", since: arrived) }
    }

    // MARK: - Reads

    func resync(reason: String, since: ContinuousClock.Instant? = nil) async {
        do {
            let state = try await bridge.fetchState()
            lastState = state
            lastError = nil

            var line = "state after \(reason): \(describe(state))"
            if let since {
                let elapsedMS = Self.milliseconds(since: since)
                worstResyncMS = max(worstResyncMS ?? 0, elapsedMS)
                line += String(format: "  (+%.1f ms from notification)", elapsedMS)
            }
            log.append(.bridge, line)
        } catch {
            handle(error, while: reason)
        }
    }

    // MARK: - Commands

    func playPause() async {
        await command("playpause") { try await self.bridge.playPause() }
    }

    func next() async {
        await command("next track") { try await self.bridge.next() }
    }

    func previous() async {
        await command("previous track") { try await self.bridge.previous() }
    }

    /// Seeks relative to the last known position, which is enough to prove
    /// `seek(to:)` works without M1's scrub bar.
    func seek(by delta: TimeInterval) async {
        guard let position = lastState?.position else {
            log.append(.failure, "seek skipped: no known position")
            return
        }
        let target = max(0, position + delta)
        await command(String(format: "seek to %.1f s", target)) {
            try await self.bridge.seek(to: target)
        }
    }

    private func command(_ label: String, _ body: @escaping () async throws -> Void) async {
        do {
            let start = ContinuousClock.now
            try await body()
            log.append(.bridge, String(format: "%@ sent in %.1f ms", label, Self.milliseconds(since: start)))
            // Commands have no reply, so read back to confirm Music acted on it.
            await resync(reason: label)
        } catch {
            handle(error, while: label)
        }
    }

    /// Absolute seek, for restoring state after a diagnostic.
    func seek(to position: TimeInterval) async {
        await command(String(format: "seek to %.2f s", position)) {
            try await self.bridge.seek(to: position)
        }
    }

    // MARK: - Measurements

    func measureLatency(samples: Int = 100) async {
        log.append(.measurement, "Measuring fetchState() latency over \(samples) samples…")
        do {
            let report = try await bridge.measureFetchLatency(samples: samples)
            latency = report
            log.append(.measurement, "fetchState() latency: \(report.summary)")
        } catch {
            handle(error, while: "latency measurement")
        }
    }

    func probeFavourite() async {
        do {
            let (favorited, loved) = try await bridge.probeFavouriteProperty()
            favouriteProbe = "favorited → \(favorited)   |   loved → \(loved)"
            log.append(.measurement, "Favourite property probe: \(favouriteProbe!)")
        } catch {
            handle(error, while: "favourite probe")
        }
    }

    /// §5: the one sanctioned launch, behind an explicit button.
    func openMusic() async {
        do {
            try await bridge.launchMusicDeliberately()
            log.append(.lifecycle, "Launched Music deliberately (user action)")
        } catch {
            handle(error, while: "open Music")
        }
    }

    func openAutomationSettings() {
        bridge.openAutomationSettings()
        log.append(.lifecycle, "Opened System Settings → Privacy & Security → Automation")
    }

    /// Proof for M0's "Music is never launched by Cue": the count of calls the
    /// §3.1 guard refused rather than sending.
    var guardedCallCount: Int { bridge.guardedCallCount }

    // MARK: - Helpers

    private func handle(_ error: Error, while action: String) {
        let described = (error as? MusicBridgeError)?.localizedDescription ?? error.localizedDescription
        lastError = described
        log.append(.failure, "\(action) failed: \(described)")

        if let bridgeError = error as? MusicBridgeError {
            switch bridgeError {
            case .musicNotRunning, .automationDenied:
                refreshEnvironment()
            default:
                break
            }
        }
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1e15
    }

    private func describe(_ permission: AutomationPermission) -> String {
        switch permission {
        case .granted: "granted"
        case .denied: "DENIED — needs System Settings"
        case .notDetermined: "not yet determined (first event will prompt)"
        case .musicNotRunning: "n/a, Music not running"
        case let .unknown(status): "unknown (OSStatus \(status))"
        }
    }

    private func describe(_ state: MusicState) -> String {
        var parts: [String] = [state.playerState.rawValue]
        if let position = state.position {
            parts.append(String(format: "pos %.2fs", position))
        } else {
            parts.append("pos —")
        }
        if let track = state.track {
            parts.append("\"\(track.name)\" / \(track.artist)")
            parts.append(track.duration > 0 ? String(format: "dur %.1fs", track.duration) : "dur unknown")
            parts.append("pid \(track.persistentID.isEmpty ? "—" : track.persistentID)")
        } else {
            parts.append("no track")
        }
        parts.append("vol \(state.volume)")
        parts.append("shuffle \(state.isShuffling)")
        parts.append("repeat \(state.repeatMode.rawValue)")
        return parts.joined(separator: "  ")
    }
}
