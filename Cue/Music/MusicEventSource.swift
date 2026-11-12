//
//  MusicEventSource.swift
//  Cue
//
//  §3.2: event-driven updates. Watches the notification Music posts on track
//  change and on play/pause/stop, plus Music launching and quitting, and asks
//  whoever owns it to resync.
//
//  One trap here, established by measurement in M0:
//
//  `addObserver(forName: nil, …)` NEVER fires on a DistributedNotificationCenter.
//  Distributed delivery is routed by name, so a wildcard matches nothing. It
//  fails silently rather than erroring, which reads exactly like "this app posts
//  no notifications at all" — there is no way to enumerate what a process posts.
//  Always register an explicit name. A controlled test also showed the failure is
//  contained: a nil-name registration does not disturb other registrations on the
//  same observer object, and both the block-based and selector-based APIs deliver
//  correctly. The block-based one is used here because converting to a Sendable
//  payload at the `queue: .main` boundary keeps Notification, which is not
//  Sendable, from crossing into the main actor.
//

import AppKit
import Foundation
import OSLog

@MainActor
final class MusicEventSource: NSObject {

    /// Verified posted by Music on macOS 27.0.1 (see §3.2).
    static let playerInfoNotification = Notification.Name("com.apple.Music.playerInfo")
    /// Music posts this too, with a byte-identical payload. Deliberately NOT
    /// observed: registering both would double-handle every change.
    static let legacyITunesNotification = Notification.Name("com.apple.iTunes.playerInfo")

    struct Handlers {
        var playerInfo: (PlayerInfoPayload) -> Void = { _ in }
        var musicLaunched: () -> Void = {}
        var musicTerminated: () -> Void = {}
        /// The machine woke. Apple Event connections do not reliably survive a
        /// sleep, so whoever owns this should resync rather than trust the
        /// state it had before.
        var systemDidWake: () -> Void = {}
    }

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "nz.slstudio.Cue",
                                category: "MusicEventSource")
    private var handlers = Handlers()
    private var isObserving = false
    private var blockObserver: NSObjectProtocol?

    private(set) var playerInfoCount = 0
    private(set) var observedPlayerInfoKeys: Set<String> = []

    func start(handlers: Handlers) {
        guard !isObserving else { return }
        self.handlers = handlers
        isObserving = true

        let center = DistributedNotificationCenter.default()

        // The real path. `queue: .main` means the block runs on the main queue,
        // so the main-actor hop below is sound.
        blockObserver = center.addObserver(
            forName: Self.playerInfoNotification,
            object: nil,
            queue: .main
        ) { notification in
            // Notification is not Sendable, so it is converted to a Sendable
            // snapshot here, on the main queue, and never crosses a boundary.
            let payload = PlayerInfoPayload(notification: notification)
            let keys = Set((notification.userInfo?.keys ?? [:].keys).compactMap { $0 as? String })
            MainActor.assumeIsolated {
                self.playerInfoCount += 1
                self.observedPlayerInfoKeys.formUnion(keys)
                self.handlers.playerInfo(payload)
            }
        }

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(
            self,
            selector: #selector(appDidLaunch(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(appDidTerminate(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
        // Sleep is the most likely way a long-running connection goes stale.
        workspaceCenter.addObserver(
            self,
            selector: #selector(systemDidWake(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    func stop() {
        guard isObserving else { return }
        if let blockObserver {
            DistributedNotificationCenter.default().removeObserver(blockObserver)
        }
        blockObserver = nil
        DistributedNotificationCenter.default().removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        isObserving = false
    }

    // MARK: - Workspace
    //
    // These stay selector-based. NSWorkspace's centre is an ordinary
    // NotificationCenter, not a distributed one, and selectors work fine there.

    @objc private func appDidLaunch(_ notification: Notification) {
        guard Self.isMusic(notification) else { return }
        logger.info("Music launched")
        handlers.musicLaunched()
    }

    @objc private func appDidTerminate(_ notification: Notification) {
        guard Self.isMusic(notification) else { return }
        logger.info("Music terminated")
        handlers.musicTerminated()
    }

    @objc private func systemDidWake(_ notification: Notification) {
        logger.info("System woke — resyncing, the Apple Event connection may be stale")
        handlers.systemDidWake()
    }

    private static func isMusic(_ notification: Notification) -> Bool {
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        return app?.bundleIdentifier == MusicBridge.musicBundleID
    }
}

// MARK: - Payload

/// A `playerInfo` payload, normalised so its values line up with what
/// `MusicBridge` returns. Two conversions are needed and neither is obvious:
///
/// - `PersistentID` arrives as a *signed* 64-bit decimal, while AppleScript's
///   `persistent ID` is a 16-digit uppercase hex string. They are the same
///   number. Without reinterpreting the bit pattern, §4.3's artwork cache would
///   never get a key hit between the two sources.
/// - `Total Time` is in **milliseconds**; AppleScript's `duration` is in seconds.
struct PlayerInfoPayload: Sendable, Equatable {
    var playerState: PlayerState
    var trackName: String?
    var artist: String?
    var album: String?
    var genre: String?
    var composer: String?
    /// Seconds, converted from the payload's milliseconds.
    var duration: TimeInterval?
    /// Uppercase 16-digit hex, matching AppleScript's `persistent ID`.
    var persistentID: String?
    /// Everything as it arrived, for logging and for keys we do not model yet.
    var raw: [String: String]

    init(notification: Notification) {
        let info = notification.userInfo ?? [:]
        func value(_ key: String) -> Any? { info[key] }
        func text(_ key: String) -> String? { value(key) as? String }

        playerState = PlayerState(appleScriptText: text("Player State") ?? "unknown")
        trackName = text("Name")
        artist = text("Artist")
        album = text("Album")
        genre = text("Genre")
        composer = text("Composer")

        if let milliseconds = (value("Total Time") as? NSNumber)?.doubleValue, milliseconds > 0 {
            duration = milliseconds / 1000
        } else {
            duration = nil
        }

        persistentID = Self.hexID(from: value("PersistentID"))

        raw = Dictionary(uniqueKeysWithValues: info.compactMap { key, element in
            (key as? String).map { ($0, String(describing: element)) }
        })
    }

    /// Reinterprets the signed decimal the notification carries as the unsigned
    /// hex string AppleScript reports.
    static func hexID(from value: Any?) -> String? {
        guard let number = value as? NSNumber else { return nil }
        return String(format: "%016llX", UInt64(bitPattern: number.int64Value))
    }

    var summary: String {
        var parts = [playerState.rawValue]
        if let trackName { parts.append("\"\(trackName)\"") }
        if let artist { parts.append(artist) }
        if let duration { parts.append(String(format: "dur %.1fs", duration)) }
        if let persistentID { parts.append("pid \(persistentID)") }
        return parts.joined(separator: "  ")
    }

    var fullDescription: String {
        var lines = ["normalised: \(summary)"]
        lines.append("raw userInfo: \(raw.count) key(s)")
        for (key, element) in raw.sorted(by: { $0.key < $1.key }) {
            lines.append("  \(key) = \(element)")
        }
        return lines.joined(separator: "\n")
    }
}
