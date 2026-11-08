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
import OSLog
import SwiftUI

@MainActor
final class PanelController: NSObject, NSWindowDelegate {

    private let panel: CuePanel
    private let model: PlayerModel

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "nz.slstudio.Cue",
                                category: "Focus")

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

    // MARK: - Focus invariants (§4.1)
    //
    // The panel must never become key and Cue must never become active through
    // ordinary use. Both are logged rather than assumed, so the claim can be
    // checked against a real session instead of taken on trust:
    //
    //     log show --last 5m --predicate 'subsystem == "nz.slstudio.Cue"' | grep -i focus

    func windowDidBecomeKey(_ notification: Notification) {
        logger.warning("FOCUS: panel became key — this should not happen in ordinary use")
    }

    func windowDidResignKey(_ notification: Notification) {
        logger.notice("FOCUS: panel resigned key")
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
    /// sits off-screen, is pulled back.
    ///
    /// `screens` can be supplied to test the arithmetic without rearranging real
    /// displays — see `M1PanelTests`. "Substantially visible somewhere" is the
    /// test — a panel hanging slightly off an edge is a legitimate position the
    /// user chose, so it is left alone.
    static func clamped(_ frame: NSRect, screens screensOverride: [NSRect]? = nil) -> NSRect {
        let screens = screensOverride ?? NSScreen.screens.map(\.visibleFrame)
        guard !screens.isEmpty else { return frame }

        // Step 1: sanitise the SIZE before anything else. A restored frame is
        // untrusted input — an older build, a hand-edited plist or a corrupt
        // default can all produce nonsense — and §4.1 fixes the width range.
        //
        // This has to come first. Checking visibility on the raw frame treats a
        // panel wider than the display as "substantially visible", because it
        // overlaps plenty, and then leaves it that wide.
        var result = frame
        let widest = screens.map(\.width).max() ?? maxWidth
        let tallest = screens.map(\.height).max() ?? result.height
        result.size.width = min(max(result.width, minWidth), min(maxWidth, widest))
        result.size.height = min(max(result.height, defaultSize.height), tallest)

        // Step 2: if it is substantially visible on some screen, the position is
        // one the user chose — including hanging off an edge — so keep it.
        let isUsable = screens.contains { visible in
            let overlap = visible.intersection(result)
            guard !overlap.isNull else { return false }
            return overlap.width >= min(result.width * 0.5, 140)
                && overlap.height >= min(result.height * 0.5, 44)
        }
        if isUsable { return result }

        // Step 3: otherwise pull it onto a screen.
        guard let visible = screensOverride?.first ?? NSScreen.main?.visibleFrame ?? screens.first else {
            return result
        }
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
