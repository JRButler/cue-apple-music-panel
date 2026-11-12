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
    /// One height, shared with the layout via PanelMetrics. The panel resizes
    /// horizontally only.
    static var contentHeight: CGFloat { PanelMetrics.contentHeight }

    /// Wide enough that ordinary titles do not scroll. At the 557 pt minimum
    /// the title column is exactly its own 118 pt floor, so everything of any
    /// length marches — which is what made the marquee look broken rather than
    /// helpful.
    private static var defaultSize: NSSize { NSSize(width: 760, height: contentHeight) }
    /// Wide enough that §4.6's volume control always fits beside the artwork
    /// and a readable title, so neither ever has to move or shrink.
    private static var minWidth: CGFloat { PanelMetrics.minimumWidth }

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

        let hostingView = NSHostingView(rootView: PanelView(model: model))

        // `sizingOptions = []` and an autoresizing mask, deliberately, rather
        // than the two mixed.
        //
        // `.minSize` publishes an Auto Layout constraint for the content's
        // minimum, and combining that with a springs-and-struts mask gives two
        // systems an opinion about the same frame. During a live resize they
        // disagree for a frame at a time and the content is momentarily
        // compressed — the panel appears to squash vertically until the mouse
        // is released.
        //
        // Nothing is lost by dropping the constraint: `windowWillResize`
        // enforces the width range and the fixed height itself, which is a
        // stronger guarantee than the content's own minimum ever was.
        hostingView.sizingOptions = []
        hostingView.translatesAutoresizingMaskIntoConstraints = true
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
        // Deliberately NOT `hostingView.frame = panel.contentLayoutRect`.
        //
        // With `.fullSizeContentView` the content view spans the entire window,
        // but `contentLayoutRect` reports only the part the titlebar does not
        // cover — 123 pt of a 155 pt window. Assigning it squashed the SwiftUI
        // content into that shorter box and cut the scrub bar in half at the
        // bottom edge. AppKit sizes the content view itself; leave it alone.

        panel.setFrame(Self.restoredFrame(), display: false)

        // Must be set, and must be set here: `windowWillResize` is the only
        // thing holding the panel to one height per layout, and without a
        // delegate it is never called. Losing this line let the panel be
        // dragged to any height and stopped the saved frame being restored.
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

        // §4.1: the width is the user's to set, the height is fixed by content.
        //
        // minSize/maxSize alone proved insufficient — the panel could still be
        // dragged thin and tall by its corner, because `sizingOptions = []`
        // detaches the hosting view from Auto Layout and so removes the
        // content's own minimum. `windowWillResize` below is the clamp that
        // actually holds; these are belt and braces.
        panel.minSize = NSSize(width: Self.minWidth, height: Self.contentHeight)
        panel.maxSize = NSSize(width: Self.maxWidth, height: Self.contentHeight)

        // §4.2's keyboard, wired even though the focus contract above makes it
        // hard to reach. It costs nothing and works if the panel is ever key.
        panel.onSeekBy = { [weak self] delta in
            guard let self else { return }
            let target = max(0, model.clock.position() + delta)
            Task { await self.model.commitSeek(to: target) }
        }
        panel.onTogglePlayPause = { [weak self] in
            guard let self else { return }
            Task { await self.model.togglePlayPause() }
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

        // The hosting view's own frame is the number that matters: it is what
        // SwiftUI lays out into. `contentLayoutRect` excludes the titlebar and
        // is misleading here, which is how a bad frame assignment hid in plain
        // sight while the log looked plausible.
        let hostFrame = panel.contentView?.frame ?? .zero
        let message = String(
            format: "FRAME: window %.0fx%.0f, hostingView %.0fx%.0f, layoutRect h%.0f, expected h%.0f, artwork %.0f",
            panel.frame.width, panel.frame.height,
            hostFrame.width, hostFrame.height,
            panel.contentLayoutRect.height,
            Self.contentHeight, PanelMetrics.artworkSize
        )
        logger.notice("\(message, privacy: .public)")
    }


    func hide() {
        panel.orderOut(nil)
        model.setPanelVisible(false)
    }

    func toggle() {
        isVisible ? hide() : show()
    }

    /// The clamp that actually holds. Every resize, from any edge or corner,
    /// arrives here, so the panel cannot be made narrower than its controls nor
    /// any height but the one its content needs.
    /// Horizontal resizing only, between the minimum and maximum widths. The
    /// height is fixed, so every resize comes back to the same number whichever
    /// edge or corner it was dragged from.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        NSSize(
            width: min(max(frameSize.width, Self.minWidth), Self.maxWidth),
            height: Self.contentHeight
        )
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
        var result = clamped(frame)
        result.size.height = contentHeight
        return result
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
        result.size.height = min(result.height, tallest)

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
    /// §4.4: space toggles play/pause.
    var onTogglePlayPause: (() -> Void)?

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
            // §4.4: space toggles play/pause.
            if event.charactersIgnoringModifiers == " " {
                onTogglePlayPause?()
            } else {
                super.keyDown(with: event)
            }
        }
    }
}
