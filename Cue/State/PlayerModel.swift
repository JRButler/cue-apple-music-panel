//
//  PlayerModel.swift
//  Cue
//
//  §3.3's single source of truth. Owns the poll timer, the clock, and the
//  connection state the panel renders.
//
//  The read strategy is §7.1's decision, and the split is load-bearing:
//
//    fetchPosition()  one Apple Event  ~8.3 ms   on the 1 Hz timer
//    fetchState()     three events     ~25 ms    on notification or user action
//
//  Adding a field to the timer path costs ~8.3 ms of blocked main thread every
//  second. If volume or shuffle need to track changes made inside Music more
//  closely, add a slow secondary timer — do not widen the hot path.
//

import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class PlayerModel {

    /// What the panel should be showing (§5's state table).
    enum Connection: Sendable, Equatable {
        case musicNotRunning
        case automationDenied
        case connected
        /// Music is up and permitted, but something else went wrong.
        case failed(String)
    }

    // MARK: - Observed state

    private(set) var connection: Connection = .musicNotRunning
    private(set) var playerState: PlayerState = .stopped
    private(set) var track: TrackInfo?
    private(set) var volume: Int = 0
    private(set) var isShuffling = false
    private(set) var repeatMode: RepeatMode = .off

    /// The interpolated clock the scrub bar renders.
    let clock = PlaybackClock()

    /// §4.2: whether the right-hand label shows remaining or total time.
    /// Persisted, because the spec asks for the choice to stick.
    var showsTotalTime: Bool {
        didSet { UserDefaults.standard.set(showsTotalTime, forKey: Self.showsTotalTimeKey) }
    }

    /// True while the panel is hidden, which stops polling entirely (§3.3).
    private(set) var isPanelVisible = false

    // MARK: - Dependencies

    private let bridge: MusicBridge
    private let events: MusicEventSource
    private var pollTask: Task<Void, Never>?

    private static let showsTotalTimeKey = "ScrubBarShowsTotalTime"

    init(bridge: MusicBridge = MusicBridge(), events: MusicEventSource = MusicEventSource()) {
        self.bridge = bridge
        self.events = events
        self.showsTotalTime = UserDefaults.standard.bool(forKey: Self.showsTotalTimeKey)
    }

    // MARK: - Lifecycle

    func start() {
        events.start(handlers: .init(
            playerInfo: { [weak self] payload in self?.handle(payload) },
            musicLaunched: { [weak self] in
                guard let self else { return }
                Task { await self.resync() }
            },
            musicTerminated: { [weak self] in
                guard let self else { return }
                connection = .musicNotRunning
                track = nil
                playerState = .stopped
                clock.reset()
                stopPolling()
            }
        ))
        Task { await resync() }
    }

    func stop() {
        events.stop()
        stopPolling()
    }

    /// §3.3: while the panel is hidden, stop polling entirely.
    func setPanelVisible(_ visible: Bool) {
        guard isPanelVisible != visible else { return }
        isPanelVisible = visible
        if visible {
            Task { await resync() }
        } else {
            stopPolling()
        }
    }

    // MARK: - Syncing

    /// The full three-event sync. Not on the timer.
    func resync() async {
        guard bridge.isMusicRunning else {
            connection = .musicNotRunning
            track = nil
            playerState = .stopped
            clock.reset()
            stopPolling()
            return
        }

        do {
            let state = try await bridge.fetchState()
            apply(state)
            connection = .connected
        } catch MusicBridgeError.automationDenied {
            connection = .automationDenied
            stopPolling()
        } catch MusicBridgeError.musicNotRunning {
            connection = .musicNotRunning
            stopPolling()
        } catch {
            let described = (error as? MusicBridgeError)?.localizedDescription ?? error.localizedDescription
            connection = .failed(described)
        }
    }

    private func apply(_ state: MusicState) {
        let trackChanged = state.track?.id != track?.id

        playerState = state.playerState
        track = state.track
        volume = state.volume
        isShuffling = state.isShuffling
        repeatMode = state.repeatMode

        clock.duration = state.track?.duration ?? 0
        if let position = state.position {
            if trackChanged {
                clock.jump(to: position)
                clock.setAdvancing(state.playerState.isAdvancing, position: position)
            } else {
                clock.sync(position: position, isAdvancing: state.playerState.isAdvancing)
            }
        } else {
            clock.setAdvancing(false, position: 0)
        }

        updatePolling()
    }

    /// §3.2's payload arrives before any round trip, so the panel can repaint
    /// immediately. The authoritative sync follows ~25 ms behind.
    private func handle(_ payload: PlayerInfoPayload) {
        // Optimistic: title and state now, precise duration from the sync.
        playerState = payload.playerState
        clock.setAdvancing(payload.playerState.isAdvancing)
        if let name = payload.trackName, name != track?.name {
            track = TrackInfo(
                persistentID: payload.persistentID ?? "",
                name: name,
                artist: payload.artist ?? "",
                album: payload.album ?? "",
                // Rounded to the second in the payload; the sync corrects it.
                duration: payload.duration ?? 0,
                isFavourite: track?.isFavourite ?? false
            )
            clock.duration = payload.duration ?? 0
            clock.jump(to: 0)
        }
        updatePolling()
        Task { await resync() }
    }

    // MARK: - Polling (§3.3)

    private func updatePolling() {
        let shouldPoll = isPanelVisible && playerState.isAdvancing && connection == .connected
        shouldPoll ? startPolling() : stopPolling()
    }

    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                await tick()
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// One hot-path read. Only `player position` — see the note at the top.
    private func tick() async {
        // §4.2: a drag owns the position until it is committed.
        guard !clock.isSuppressed else { return }
        do {
            if let position = try await bridge.fetchPosition() {
                clock.sync(position: position, isAdvancing: playerState.isAdvancing)
            }
        } catch MusicBridgeError.musicNotRunning {
            connection = .musicNotRunning
            stopPolling()
        } catch MusicBridgeError.automationDenied {
            connection = .automationDenied
            stopPolling()
        } catch {
            // A single dropped tick is not worth surfacing; the clock carries on
            // and the next tick or notification corrects it.
        }
    }

    // MARK: - Commands

    /// §4.2: exactly one `set player position` per drag, on release.
    func commitSeek(to position: TimeInterval) async {
        clock.jump(to: position)
        do {
            try await bridge.seek(to: position)
        } catch {
            // The seek failed, so the optimistic jump was a lie. Re-read.
            await resync()
        }
    }

    /// Called as a drag begins and ends (§4.2's suppression rule).
    func setScrubbing(_ scrubbing: Bool) {
        clock.isSuppressed = scrubbing
    }

    func openMusic() async {
        do {
            try await bridge.launchMusicDeliberately()
        } catch {
            connection = .failed((error as? MusicBridgeError)?.localizedDescription ?? "\(error)")
        }
    }

    func openAutomationSettings() {
        bridge.openAutomationSettings()
    }

    /// Brings Music forward (§4.3's artwork click, and §4.8's escape hatches).
    func activateMusic() {
        NSRunningApplication
            .runningApplications(withBundleIdentifier: MusicBridge.musicBundleID)
            .first?
            .activate()
    }
}
