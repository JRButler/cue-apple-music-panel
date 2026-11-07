//
//  MusicEventSource.swift
//  Cue
//
//  §3.2: event-driven updates. Watches the distributed notification Music posts
//  on track change and on play/pause/stop, plus Music launching and quitting,
//  and asks whoever owns it to resync.
//
//  Observers use the selector-based APIs deliberately. The block-based
//  `addObserver(forName:object:queue:using:)` wants a `@Sendable` closure, which
//  Notification is not, and the distributed-notification observer needs
//  `.deliverImmediately`: without it macOS queues notifications for an app that
//  is not active, which for an LSUIElement agent is nearly always.
//

import AppKit
import Foundation
import OSLog

@MainActor
final class MusicEventSource: NSObject {

    /// Music's long-standing distributed notification. Still unverified on
    /// macOS 27 at the time of writing, which is what M0 is for.
    static let playerInfoNotification = Notification.Name("com.apple.Music.playerInfo")

    struct Handlers {
        var playerInfo: (Notification) -> Void = { _ in }
        var musicLaunched: () -> Void = {}
        var musicTerminated: () -> Void = {}
    }

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "nz.slstudio.Cue",
                                category: "MusicEventSource")
    private var handlers = Handlers()
    private var isObserving = false

    /// Every `playerInfo` notification seen this session, for M0's key survey.
    private(set) var observedPlayerInfoKeys: Set<String> = []
    private(set) var playerInfoCount = 0

    func start(handlers: Handlers) {
        guard !isObserving else { return }
        self.handlers = handlers
        isObserving = true

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(playerInfoDidChange(_:)),
            name: Self.playerInfoNotification,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )

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
    }

    func stop() {
        guard isObserving else { return }
        DistributedNotificationCenter.default().removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        isObserving = false
    }

    // MARK: - Distributed notification

    @objc private func playerInfoDidChange(_ notification: Notification) {
        playerInfoCount += 1
        if let userInfo = notification.userInfo {
            observedPlayerInfoKeys.formUnion(userInfo.keys.compactMap { $0 as? String })
        }
        handlers.playerInfo(notification)
    }

    // MARK: - Workspace

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

    private static func isMusic(_ notification: Notification) -> Bool {
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        return app?.bundleIdentifier == MusicBridge.musicBundleID
    }

    // MARK: - M0 payload survey

    /// Renders a notification's `userInfo` in full, with the real key names and
    /// the dynamic type of each value, so §3.2 can be filled in from observation
    /// rather than from the keys we assumed.
    static func describePayload(_ notification: Notification) -> String {
        var lines: [String] = []
        lines.append("name: \(notification.name.rawValue)")
        lines.append("object: \(String(describing: notification.object))")

        guard let userInfo = notification.userInfo, !userInfo.isEmpty else {
            lines.append("userInfo: <empty>")
            return lines.joined(separator: "\n")
        }

        lines.append("userInfo: \(userInfo.count) key(s)")
        let pairs = userInfo
            .map { (String(describing: $0.key), $0.value) }
            .sorted { $0.0 < $1.0 }

        for (key, value) in pairs {
            let type = String(describing: Swift.type(of: value))
            // Artwork-sized values would flood the log, so summarise them.
            let rendered: String
            switch value {
            case let data as Data:
                rendered = "<\(data.count) bytes>"
            case let string as String where string.count > 200:
                rendered = "\(string.prefix(200))… (\(string.count) chars)"
            default:
                rendered = String(describing: value)
            }
            lines.append("  \(key)  [\(type)] = \(rendered)")
        }

        return lines.joined(separator: "\n")
    }
}
