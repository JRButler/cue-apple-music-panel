//
//  PlayerModel.swift
//  Cue
//
//  §3.3's single source of truth. Owns the poll timer, the clock, and the
//  connection state the panel renders.
//
//  The read strategy is §7.1's decision, and the split is load-bearing:
//
//    fetchAppState()  two events    ~16.7 ms  on the 1 Hz timer
//    fetchState()     three events  ~25 ms    on notification or user action
//
//  The timer path was one event until §4.6's "reflected within 1 s" criterion
//  forced a second: Music posts no notification when its own volume changes, so
//  the only way to notice is to look. The second reference is the whole
//  application `properties` record, which carries volume, mute, shuffle, repeat
//  and player state for that one event — so it is one reference for all of them,
//  not one each. Keep it that way: a per-field read here costs ~8.3 ms of
//  blocked main thread every second.
//

import AppKit
import Foundation
import Observation
import OSLog

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

    private(set) var connection: Connection = .musicNotRunning {
        didSet {
            guard oldValue != connection else { return }
            logger.notice("connection: \(String(describing: oldValue), privacy: .public) -> \(String(describing: self.connection), privacy: .public)")
            connection == .connected ? stopRecovery() : startRecovery()
        }
    }
    private(set) var playerState: PlayerState = .stopped
    private(set) var track: TrackInfo?
    private(set) var volume: Int = 0
    private(set) var isMuted = false
    private(set) var isShuffling = false
    private(set) var repeatMode: RepeatMode = .off

    /// §4.3's artwork for the current track, or nil for the placeholder case.
    private(set) var artwork: NSImage?

    /// The interpolated clock. Read by the scrub bar for its animation targets,
    /// and still the authority on "where are we" for seeks and labels.
    let clock = PlaybackClock()

    /// How far ahead the scrub bar should animate on each sync. One poll
    /// interval, so the thumb arrives just as the next sync re-targets it.
    var animationLookahead: TimeInterval { Self.pollInterval }

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

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "nz.slstudio.Cue",
                                category: "PlayerModel")

    /// §4.3: the last 20 tracks, so flicking back and forth does not re-fetch.
    private let artworkCache = ArtworkCache()
    /// Cancels an in-flight fetch when the track changes again first.
    private var artworkTask: Task<Void, Never>?
    /// The track whose artwork is shown or being fetched. Compared against
    /// rather than against `track`, which the notification path updates
    /// optimistically and so cannot be used to detect a change.
    private var artworkKey: String?
    /// The track the clock was last anchored for. Same reasoning as
    /// `artworkKey`: comparing against `track` cannot detect a change the
    /// notification path has already applied.
    private var appliedTrackKey: String?

    /// Retries while anything other than `.connected`. See `startRecovery`.
    private var recoveryTask: Task<Void, Never>?

    /// How often to retry while disconnected. Slow enough to be free, often
    /// enough that the panel is never wrong for long.
    private static let recoveryInterval: TimeInterval = 3

    /// §4.6: a drag owns the volume until released, so a sync must not fight it.
    private var isAdjustingVolume = false
    private var lastVolumeSend: ContinuousClock.Instant?
    private var pendingVolumeSend: Task<Void, Never>?

    /// Every seek this session. §4.2 requires exactly one per drag, and the only
    /// way to know is to count them — so each is logged and tallied.
    private(set) var seekCount = 0

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
            },
            systemDidWake: { [weak self] in
                guard let self else { return }
                // Do not trust the pre-sleep state: re-read everything.
                Task { await self.resync() }
            }
        ))
        Task {
            await resync()
            // `connection` starts as .musicNotRunning, and a property
            // initialiser does not fire didSet — so if this first sync also
            // fails, the value never *changes* and recovery would never start.
            // Launching with Music closed is exactly that case.
            if connection != .connected { startRecovery() }
        }
    }

    func stop() {
        events.stop()
        stopPolling()
        stopRecovery()
        artworkTask?.cancel()
        pendingVolumeSend?.cancel()
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

    // MARK: - Recovery
    //
    // No connection state is terminal. This is the bug that put "Music isn't
    // open" over a live player for hours: a transient failure set the state,
    // the state stopped the poll — because `updatePolling` requires
    // `.connected` — and the poll was the only thing that could have noticed
    // Music was fine. Recovery then depended entirely on a notification, and
    // mid-track with nothing changing, none arrives.

    private func startRecovery() {
        guard recoveryTask == nil else { return }
        logger.notice("recovery: retrying every \(Self.recoveryInterval, privacy: .public)s")
        recoveryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.recoveryInterval))
                guard !Task.isCancelled, let self else { return }
                await resync()
            }
        }
    }

    private func stopRecovery() {
        guard recoveryTask != nil else { return }
        recoveryTask?.cancel()
        recoveryTask = nil
        logger.notice("recovery: stopped, connected")
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
            stopPolling()
        }
    }

    private func apply(_ state: MusicState) {
        // Keyed against what was last applied, not against `track`: the
        // notification path sets `track` optimistically, so comparing with it
        // always reports "unchanged". Same trap that stopped the artwork
        // loading.
        let trackChanged = state.track?.id != appliedTrackKey
        appliedTrackKey = state.track?.id

        playerState = state.playerState
        track = state.track
        // §4.6: "read the volume on each sync" — except while the user is
        // dragging it, when their hand is the authority, not Music.
        if !isAdjustingVolume {
            volume = state.volume
            musicReportsMuted = state.isMuted
            isMuted = isEffectivelyMuted
        }
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

        // Unconditional: `loadArtwork` decides for itself whether this is a
        // track it has already fetched. Gating here on a comparison against
        // `track` was the bug — the notification path sets `track` optimistically
        // before this runs, so by now it always matches and the artwork never
        // loaded. The text kept pace; the artwork did not.
        loadArtwork(for: state.track)

        updatePolling()
    }

    // MARK: - Artwork (§4.3)

    /// Fetched on track change only, never from the tick.
    ///
    /// A cache hit paints immediately; a miss goes to Music once. Tracks with no
    /// artwork are cached as such, so the placeholder case does not re-ask on
    /// every track change back to the same song.
    private func loadArtwork(for track: TrackInfo?) {
        guard let track else {
            artworkTask?.cancel()
            artworkTask = nil
            artworkKey = nil
            artwork = nil
            return
        }

        // Already showing, or already fetching, this track's art.
        guard track.artworkKey != artworkKey else { return }

        artworkTask?.cancel()
        artworkTask = nil
        artworkKey = track.artworkKey

        if let cached = artworkCache.lookup(track.artworkKey) {
            artwork = cached
            logger.notice("artwork cache hit for \(track.artworkKey, privacy: .public)")
            return
        }

        // Clear rather than leave the previous track's art showing.
        artwork = nil

        artworkTask = Task { [weak self] in
            guard let self else { return }
            let started = ContinuousClock.now
            do {
                let data = try await bridge.fetchArtwork()
                guard !Task.isCancelled else { return }

                let image = data.flatMap { NSImage(data: $0) }

                // Bytes that arrived but will not decode are a FAILURE, not a
                // track without artwork. Caching the difference wrongly is what
                // left the placeholder showing indefinitely after Music
                // relaunched: one bad reply was remembered as "this track has
                // none" and never retried. Clear the key so the next sync tries
                // again, and cache nothing.
                if data != nil, image == nil {
                    logger.notice("artwork failed to decode; will retry")
                    artworkKey = nil
                    return
                }

                // Reaching here, `image` is nil only because Music genuinely
                // reported no artwork — worth remembering, so it is not asked
                // for again on every track change back to this song.
                artworkCache.store(image, for: track.artworkKey)

                // Only paint it if the track has not moved on underneath us.
                guard self.track?.artworkKey == track.artworkKey else { return }
                artwork = image

                let elapsed = ContinuousClock.now - started
                let ms = Double(elapsed.components.seconds) * 1000
                    + Double(elapsed.components.attoseconds) / 1e15
                let size = data?.count ?? 0
                logger.notice("\(String(format: "artwork fetched in %.1f ms (%d bytes)", ms, size), privacy: .public)")
            } catch {
                guard !Task.isCancelled else { return }
                // An error is transient — Music busy, connection stale, timed
                // out. Emphatically NOT evidence that the track has no artwork,
                // so nothing is cached and the key is cleared so the next sync
                // tries again.
                artworkKey = nil
                logger.notice("artwork fetch failed, will retry: \((error as? MusicBridgeError)?.localizedDescription ?? "\(error)", privacy: .public)")
            }
        }
    }

    // MARK: - Volume (§4.6)

    /// Called continuously while dragging. Updates the UI at once and sends to
    /// Music at no more than 15 Hz, as §4.6 requires.
    func setVolume(_ newValue: Int, committing: Bool) {
        let clamped = min(max(0, newValue), 100)
        volume = clamped
        isAdjustingVolume = !committing

        if committing {
            // §4.6's final value on release, always sent regardless of timing.
            pendingVolumeSend?.cancel()
            pendingVolumeSend = nil
            lastVolumeSend = nil
            Task {
                await send(volume: clamped)
                // The tick was suppressed during the drag, so catch up now.
                await resync()
            }
            return
        }

        // 15 Hz ceiling. A value arriving inside the window is not dropped; it
        // is deferred, so the last position of the drag always gets through.
        let minimumGap: TimeInterval = 1.0 / 15.0
        let now = ContinuousClock.now
        if let last = lastVolumeSend {
            let gap = now - last
            let seconds = Double(gap.components.seconds)
                + Double(gap.components.attoseconds) / 1e18
            if seconds < minimumGap {
                pendingVolumeSend?.cancel()
                pendingVolumeSend = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(minimumGap - seconds))
                    guard !Task.isCancelled, let self else { return }
                    await send(volume: self.volume)
                }
                return
            }
        }
        lastVolumeSend = now
        Task { await send(volume: clamped) }
    }

    private func send(volume value: Int) async {
        lastVolumeSend = .now
        do {
            try await bridge.setVolume(value)
        } catch {
            logger.error("setVolume failed: \((error as? MusicBridgeError)?.localizedDescription ?? "\(error)", privacy: .public)")
        }
    }

    /// The level to come back to when unmuting. Persisted, so a mute that
    /// outlives a relaunch can still be undone.
    private var premuteVolume: Int {
        get { UserDefaults.standard.object(forKey: "PremuteVolume") as? Int ?? 50 }
        set { UserDefaults.standard.set(newValue, forKey: "PremuteVolume") }
    }

    /// §4.6: clicking the low speaker toggles mute.
    ///
    /// Implemented by taking the volume to zero and restoring it, NOT via
    /// Music's `mute` property. Music refuses `set mute to true` with error 9038
    /// on macOS 27 — verified with `tools/run-probe.sh --probe-mute`, where
    /// setting it `false` appears to work only because it was already false.
    /// Since §4.6 asks for "the previous level" to be restored anyway, keeping
    /// that level ourselves is both the only option and the closer reading.
    ///
    /// A mute set from inside Music is still honoured for display, because the
    /// application record's `pMut` is read on every tick; clearing that one does
    /// work, so it is cleared on unmute.
    func toggleMute() async {
        if isEffectivelyMuted {
            let restored = max(1, premuteVolume)
            volume = restored
            isMuted = false
            await send(volume: restored)
            // Only meaningful if Music's own mute was the thing muting us.
            if musicReportsMuted {
                try? await bridge.setMuted(false)
            }
            logger.notice("unmuted, restored to \(restored, privacy: .public)")
        } else {
            premuteVolume = max(1, volume)
            volume = 0
            isMuted = true
            await send(volume: 0)
            logger.notice("muted, remembering \(self.premuteVolume, privacy: .public)")
        }
    }

    /// True when nothing is audible, however it got that way.
    var isEffectivelyMuted: Bool { volume == 0 || musicReportsMuted }

    /// Music's own `mute`, as last read from the application record.
    private(set) var musicReportsMuted = false

    /// §4.6: scrolling over the slider moves it in steps of 2.
    func nudgeVolume(by delta: Int) {
        setVolume(volume + delta, committing: true)
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
            // Start the artwork now rather than waiting for the sync, so it
            // keeps pace with the title.
            loadArtwork(for: track)
        }
        updatePolling()
        Task { await resync() }
    }

    // MARK: - Polling (§3.3)

    private func updatePolling() {
        let shouldPoll = isPanelVisible && playerState.isAdvancing && connection == .connected
        shouldPoll ? startPolling() : stopPolling()
    }

    /// §3.3 says 1 Hz; this is deliberately a little faster.
    ///
    /// §4.6 requires a volume change made inside Music to be reflected within
    /// one second, and the tick is the only thing that notices one. At exactly
    /// 1 Hz the worst case is a change landing just after a tick: a full
    /// interval plus the ~17 ms read, about 1.02 s, which misses by a hair. At
    /// 0.9 s the worst case is ~0.92 s and the criterion is met by
    /// construction rather than on average. A measured sample came in at
    /// 375 ms.
    ///
    /// The cost is 11% more Apple Events on the hot path — under 2 ms a second.
    ///
    /// Overridable for diagnostics without a rebuild:
    ///
    ///     defaults write nz.slstudio.Cue PollSeconds 10
    ///     defaults delete nz.slstudio.Cue PollSeconds
    static var pollInterval: TimeInterval {
        let override = UserDefaults.standard.double(forKey: "PollSeconds")
        return override > 0 ? min(max(override, 0.1), 60) : 0.9
    }

    private func startPolling() {
        guard pollTask == nil else { return }
        let interval = Self.pollInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self else { return }
                await tick()
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Worst gap seen between what the clock was rendering and what Music
    /// actually reported. This is M1's "stays within 0.5 s of Music" criterion
    /// measured against the real app, rather than against a simulation.
    private(set) var worstDriftSeconds: TimeInterval = 0

    /// The hot-path read: two references, no track record. See the note at the
    /// top, and `MusicScript.fetchAppState` for why it is two rather than one.
    private func tick() async {
        // §4.2: a drag owns the position until it is committed.
        guard !clock.isSuppressed else { return }

        // And while the volume is being dragged, stay off the main thread
        // altogether. §4.6 sends volume writes at up to 15 Hz — about 125 ms of
        // blocked main thread per second — and this tick's two references add
        // another 17 ms on top. Competing for the same thread is what made the
        // volume slider hitch. The clock keeps interpolating meanwhile, so the
        // scrub bar carries on, and releasing the slider resyncs.
        guard !isAdjustingVolume else { return }
        do {
            let state = try await bridge.fetchAppState()

            if let position = state.position {
                // Compare before syncing: this is the error the user was seeing.
                let rendered = clock.position()
                let drift = abs(position - rendered)
                if drift > worstDriftSeconds {
                    worstDriftSeconds = drift
                }
                // Formatted up front: os_log interpolation plus concatenation
                // defeats the type checker.
                let line = String(
                    format: "drift %.4fs (rendered %.3f vs music %.3f) worst %.4fs",
                    drift, rendered, position, worstDriftSeconds
                )
                logger.notice("\(line, privacy: .public)")

                clock.sync(position: position, isAdvancing: state.playerState.isAdvancing)
            }

            // §4.6's criterion: a volume change made inside Music has to show up
            // within a second, and this is the only thing that notices it.
            if !isAdjustingVolume {
                if state.volume != volume || state.isMuted != musicReportsMuted {
                    logger.notice("external volume change: \(self.volume, privacy: .public) -> \(state.volume, privacy: .public), music mute \(state.isMuted, privacy: .public)")
                }
                volume = state.volume
                musicReportsMuted = state.isMuted
                isMuted = isEffectivelyMuted
            }
            isShuffling = state.isShuffling
            repeatMode = state.repeatMode

            // A play/pause made inside Music does post a notification, but the
            // tick is a cheap second opinion and keeps §4.4's icon honest.
            if state.playerState != playerState {
                playerState = state.playerState
                clock.setAdvancing(state.playerState.isAdvancing)
                updatePolling()
            }
        } catch MusicBridgeError.musicNotRunning {
            connection = .musicNotRunning
            stopPolling()
        } catch MusicBridgeError.automationDenied {
            connection = .automationDenied
            stopPolling()
        } catch MusicBridgeError.connectionLost {
            // Stale Apple Event connection, not an absent app. Hand it to the
            // recovery loop instead of claiming Music has gone.
            logger.notice("tick: connection lost, handing over to recovery")
            connection = .failed("Reconnecting to Music…")
            stopPolling()
        } catch {
            // A single dropped tick is not worth surfacing; the clock carries on
            // and the next tick or notification corrects it.
        }
    }

    // MARK: - Commands

    // MARK: - §4.5 shuffle, repeat, favourite
    //
    // All three update optimistically and are NOT read back to confirm. Music
    // applies these writes asynchronously — a read in the same breath returns
    // the old value, which would make every button flip back the instant it
    // was clicked. The 0.9 s tick reconciles them, and reverts on a throw.

    func toggleShuffle() async {
        let target = !isShuffling
        isShuffling = target
        do {
            try await bridge.setShuffle(target)
        } catch {
            isShuffling = !target
            logFailure(error, "setShuffle")
        }
    }

    /// §4.5 cycles off → all → one.
    func cycleRepeat() async {
        let target = repeatMode.next
        let previous = repeatMode
        repeatMode = target
        do {
            try await bridge.setRepeat(target)
        } catch {
            repeatMode = previous
            logFailure(error, "setRepeat")
        }
    }

    func toggleFavourite() async {
        guard var current = track else { return }
        let target = !current.isFavourite
        current.isFavourite = target
        track = current
        do {
            try await bridge.setFavourite(target)
        } catch {
            current.isFavourite = !target
            track = current
            logFailure(error, "setFavourite")
        }
    }

    // MARK: - Transport (§4.4)

    /// §4.4: the icon updates optimistically and reconciles on the next sync, so
    /// the button feels instant despite the ~8 ms round trip.
    func togglePlayPause() async {
        let wasAdvancing = playerState.isAdvancing
        playerState = wasAdvancing ? .paused : .playing
        clock.setAdvancing(!wasAdvancing)
        updatePolling()

        do {
            try await bridge.playPause()
        } catch {
            playerState = wasAdvancing ? .playing : .paused
            clock.setAdvancing(wasAdvancing)
            updatePolling()
            logger.error("playPause failed: \((error as? MusicBridgeError)?.localizedDescription ?? "\(error)", privacy: .public)")
        }
        await resync()
    }

    func nextTrack() async {
        do { try await bridge.next() } catch { logFailure(error, "next") }
        await resync()
    }

    /// §4.4: Music's own `previous track` already restarts the track when more
    /// than a few seconds in, so this does not second-guess it.
    func previousTrack() async {
        do { try await bridge.previous() } catch { logFailure(error, "previous") }
        await resync()
    }

    private func logFailure(_ error: Error, _ action: String) {
        logger.error("\(action, privacy: .public) failed: \((error as? MusicBridgeError)?.localizedDescription ?? "\(error)", privacy: .public)")
    }

    /// §4.2: exactly one `set player position` per drag, on release.
    func commitSeek(to position: TimeInterval) async {
        seekCount += 1
        logger.notice("seek committed #\(self.seekCount, privacy: .public) to \(position, privacy: .public)s")
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
        logger.notice("scrubbing \(scrubbing ? "began" : "ended", privacy: .public)")
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
