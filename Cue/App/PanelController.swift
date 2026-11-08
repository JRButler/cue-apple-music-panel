//
//  PanelController.swift
//  Cue
//
//  §4.1's floating panel: owner of the NSPanel and of its persisted frame.
//
//  The focus rule is the delicate part. §4.1 requires that using the panel never
//  activates Cue or steals focus, and M1's acceptance criteria restate it. That
//  is achieved with `.nonactivatingPanel` plus `becomesKeyOnlyIfNeeded`, and it
//  has a consequence worth knowing: a panel that never takes key status cannot
//  receive key events either, so §4.2's arrow-key seeking is unreachable in
//  normal use. See §7.3 — the answer is §4.9's global hotkey, not weakening this.
//

import AppKit
import SwiftUI

@MainActor
final class PanelController: NSObject, NSWindowDelegate {

    private let panel: CuePanel
    private let model: PlayerModel

    private static let frameKey = "PanelFrame"
    private static let defaultSize = NSSize(width: 420, height: 104)
    private static let minWidth: CGFloat = 320
    private static let maxWidth: CGFloat = 900

    var isVisible: Bool { panel.isVisible }

    init(model: PlayerModel) {
        self.model = model

        panel = CuePanel(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            // §4.1's mask, plus .resizable for the width range it asks for.
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )

        super.init()

        configure()

        // `sizingOptions = []` detaches the hosting view from the window's Auto
        // Layout. By default it publishes the SwiftUI content's intrinsic size,
        // so every label whose text changes invalidates the window's layout and
        // provokes a full `-[NSWindow layoutIfNeeded]` pass — once a second, at
        // enough cost to dominate the panel's CPU while playing. The panel's size
        // is the user's to set (§4.1 makes it resizable), so nothing is lost.
        let hostingView = NSHostingView(rootView: PanelView(model: model))
        hostingView.sizingOptions = []
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
        panel.setFrame(Self.restoredFrame(), display: false)
        panel.delegate = self
    }

    private func configure() {
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // The focus contract. `becomesKeyOnlyIfNeeded` is what stops a click on
        // a control pulling key status away from whatever the user is typing in.
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.worksWhenModal = true

        // §4.1: transparent titlebar, no traffic lights, drag by the background.
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }

        // The rounded vibrancy lives in SwiftUI, so the window itself is clear.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true

        panel.minSize = NSSize(width: Self.minWidth, height: Self.defaultSize.height)
        panel.maxSize = NSSize(width: Self.maxWidth, height: Self.defaultSize.height * 2)

        // §4.2's keyboard, wired even though the focus contract above makes it
        // hard to reach. It costs nothing and works if the panel is ever key.
        panel.onSeekBy = { [weak self] delta in
            guard let self else { return }
            let target = max(0, model.clock.position() + delta)
            Task { await self.model.commitSeek(to: target) }
        }
    }

    // MARK: - Visibility

    func show() {
        panel.orderFrontRegardless()
        model.setPanelVisible(true)
    }

    func hide() {
        panel.orderOut(nil)
        model.setPanelVisible(false)
    }

    func toggle() {
        isVisible ? hide() : show()
    }

    // MARK: - Frame persistence (§4.1)

    func windowDidMove(_ notification: Notification) { saveFrame() }
    func windowDidResize(_ notification: Notification) { saveFrame() }

    private func saveFrame() {
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: Self.frameKey)
    }

    private static func restoredFrame() -> NSRect {
        guard let stored = UserDefaults.standard.string(forKey: Self.frameKey) else {
            return defaultFrame()
        }
        let frame = NSRectFromString(stored)
        guard frame.width > 0, frame.height > 0 else { return defaultFrame() }
        return clamped(frame)
    }

    private static func defaultFrame() -> NSRect {
        guard let screen = NSScreen.main else {
            return NSRect(origin: .zero, size: defaultSize)
        }
        let visible = screen.visibleFrame
        return NSRect(
            x: visible.midX - defaultSize.width / 2,
            y: visible.minY + 120,
            width: defaultSize.width,
            height: defaultSize.height
        )
    }

    /// §4.1: a frame saved on a display that is no longer attached, or that now
    /// sits off-screen, is pulled back. "Substantially visible somewhere" is the
    /// test — a panel hanging slightly off an edge is a legitimate position the
    /// user chose, so it is left alone.
    private static func clamped(_ frame: NSRect) -> NSRect {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return frame }

        let isUsable = screens.contains { screen in
            let overlap = screen.visibleFrame.intersection(frame)
            guard !overlap.isNull else { return false }
            return overlap.width >= min(frame.width * 0.5, 140)
                && overlap.height >= min(frame.height * 0.5, 44)
        }
        if isUsable { return frame }

        guard let screen = NSScreen.main ?? screens.first else { return frame }
        let visible = screen.visibleFrame
        var result = frame
        result.size.width = min(max(result.width, minWidth), min(maxWidth, visible.width))
        result.size.height = min(result.height, visible.height)
        result.origin.x = min(max(visible.minX, result.minX), visible.maxX - result.width)
        result.origin.y = min(max(visible.minY, result.minY), visible.maxY - result.height)
        return result
    }
}

// MARK: - Panel

/// An `NSPanel` that can host key equivalents without a titlebar, and that
/// forwards §4.2's seek keys.
///
/// A borderless-style panel does not get `keyDown` routed to it by default
/// unless it can become key, so `canBecomeKey` is overridden to allow it *when
/// asked* — `becomesKeyOnlyIfNeeded` on the instance is what keeps a click from
/// asking.
final class CuePanel: NSPanel {

    /// Seconds to seek by. Set by PanelController.
    var onSeekBy: ((TimeInterval) -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        let shift = event.modifierFlags.contains(.shift)
        // §4.2: ← / → seek ±5 s, ⇧← / ⇧→ seek ±30 s.
        let step: TimeInterval = shift ? 30 : 5

        switch event.specialKey {
        case .leftArrow:
            onSeekBy?(-step)
        case .rightArrow:
            onSeekBy?(step)
        default:
            super.keyDown(with: event)
        }
    }
}
