//
//  MarqueeText.swift
//  Cue
//
//  A single line that scrolls itself when it does not fit, and does nothing
//  at all when it does.
//
//  WHY THIS IS APPKIT. Continuous motion driven by SwiftUI costs 5–8% of a core
//  on this machine, measured during M1 — SwiftUI interpolates on the main
//  thread, and `.animation` is no cheaper than a timer (§7.4). A marquee is
//  precisely the case Core Animation is for: a constant-velocity transform of a
//  static rendering. One CABasicAnimation runs on the render server and costs
//  the main thread nothing per frame.
//
//  It also stops completely when the text fits, which is most of the time — an
//  idle panel should cost nothing, and §4.3's "truncating cleanly" remains the
//  behaviour whenever scrolling is not warranted.
//
//  The motion wraps rather than reverses. An earlier version slid left, paused
//  and slid back, and the return journey read as a mistake rather than a loop.
//  A second copy of the text follows the first in from the right, so the cycle
//  has no visible reversal and the jump back happens when both copies are
//  exactly aligned, where it cannot be seen.
//

import AppKit
import OSLog
import SwiftUI

struct MarqueeText: NSViewRepresentable {

    let text: String
    let font: NSFont
    let colour: NSColor
    /// Seconds to hold still at each end before moving off again.
    var pause: TimeInterval = 2.0
    /// Points travelled per second while moving.
    var speed: CGFloat = 22

    func makeNSView(context: Context) -> MarqueeView {
        let view = MarqueeView()
        view.apply(text: text, font: font, colour: colour, pause: pause, speed: speed)
        return view
    }

    func updateNSView(_ nsView: MarqueeView, context: Context) {
        nsView.apply(text: text, font: font, colour: colour, pause: pause, speed: speed)
    }
}

final class MarqueeView: NSView {

    /// CATextLayer, not NSTextField.
    ///
    /// An NSTextField draws through a cell, and the cell caches a layout from
    /// its previous frame. Giving it a wider frame was not enough: it kept
    /// rasterising the older, narrower layout, so the marquee scrolled a
    /// *snapshot* of the clipped text rather than the whole string. Resizing
    /// the panel happened to force the cell to refresh, which is why dragging
    /// the window appeared to fix it while a track change did not.
    ///
    /// A CATextLayer renders the string into whatever bounds it is given, with
    /// no cell and no cached layout, so the full string is always there.
    private let container = CALayer()
    private let first = CATextLayer()
    private let second = CATextLayer()

    private var current: String = ""
    private var currentFont: NSFont = .systemFont(ofSize: NSFont.systemFontSize)
    private var pause: TimeInterval = 2
    private var speed: CGFloat = 22

    /// Space between the end of one copy and the start of the next.
    private let gap: CGFloat = 44

    /// What the running animation was built for, so it is rebuilt only when
    /// something actually changes. `updateNSView` runs on every SwiftUI update
    /// and the panel re-renders about once a second from the clock; rebuilding
    /// each time meant the animation never escaped its opening pause.
    private var builtFor: (text: String, width: CGFloat, font: NSFont)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.addSublayer(container)
        for text in [first, second] {
            text.isWrapped = false
            text.truncationMode = .none
            text.alignmentMode = .left
            container.addSublayer(text)
        }
        applyScale()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Without this the text is soft on a Retina display.
    private func applyScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        for layer in [container, first, second] { layer.contentsScale = scale }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyScale()
        builtFor = nil
        reflowIfNeeded()
    }

    func apply(text: String, font: NSFont, colour: NSColor, pause: TimeInterval, speed: CGFloat) {
        self.pause = pause
        self.speed = speed
        current = text
        currentFont = font

        for layer in [first, second] {
            layer.string = text
            layer.font = font
            layer.fontSize = font.pointSize
            layer.foregroundColor = colour.cgColor
        }
        reflowIfNeeded()
    }

    override func layout() {
        super.layout()
        reflowIfNeeded()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: ceil(currentFont.boundingRectForFont.height))
    }

    /// Rebuilds only when the text, the font or the available width changed.
    private func reflowIfNeeded() {
        let signature = (text: current, width: bounds.width, font: currentFont)
        if let builtFor,
           builtFor.text == signature.text,
           abs(builtFor.width - signature.width) < 0.5,
           builtFor.font == signature.font {
            return
        }
        builtFor = signature
        Self.rebuilds += 1
        reflow()
    }

    /// Counts rebuilds across all instances, so "it restarts constantly" can be
    /// told apart from "it was logged once" — the log dedupes otherwise.
    nonisolated(unsafe) static var rebuilds = 0

    private func reflow() {
        let textWidth = measuredWidth()
        let available = bounds.width
        let height = ceil(currentFont.boundingRectForFont.height)
        let y = ((bounds.height - height) / 2).rounded()

        container.removeAnimation(forKey: "marquee")
        // Layer frame changes animate implicitly by default, which would make
        // every track change slide into place.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        guard available > 0, textWidth > available + 1 else {
            second.isHidden = true
            container.frame = CGRect(x: 0, y: y, width: max(textWidth, available), height: height)
            first.frame = CGRect(x: 0, y: 0, width: max(textWidth, available), height: height)
            if available > 0 {
                Self.log("[rebuild #\(Self.rebuilds)] fits (\(Int(textWidth))pt in \(Int(available))pt): static")
            }
            return
        }

        second.isHidden = false
        let cycle = textWidth + gap
        container.frame = CGRect(x: 0, y: y, width: cycle + textWidth, height: height)
        first.frame = CGRect(x: 0, y: 0, width: textWidth, height: height)
        second.frame = CGRect(x: cycle, y: 0, width: textWidth, height: height)

        let travel = TimeInterval(cycle / speed)
        let total = pause + travel
        let startX = container.position.x

        // Hold at the start, then travel exactly one cycle. At the end the
        // second copy sits precisely where the first began, so the restart is
        // invisible — no reversal, no jump.
        let animation = CAKeyframeAnimation(keyPath: "position.x")
        animation.values = [startX, startX, startX - cycle]
        animation.keyTimes = [0, NSNumber(value: pause / total), 1]
        animation.timingFunctions = [
            CAMediaTimingFunction(name: .linear),
            CAMediaTimingFunction(controlPoints: 0.35, 0, 1, 1),
        ]
        animation.duration = total
        animation.repeatCount = .infinity
        container.add(animation, forKey: "marquee")

        Self.log("[rebuild #\(Self.rebuilds)] scrolling \(Int(textWidth))pt in \(Int(available))pt — \(current)")
    }

    /// The full rendered width of the string, independent of any frame.
    private func measuredWidth() -> CGFloat {
        ceil((current as NSString).size(withAttributes: [.font: currentFont]).width)
    }

    /// Only logs when the state actually changes, so a resize does not spam.
    nonisolated(unsafe) private static var lastLogged = ""

    private static func log(_ message: String) {
        guard message != lastLogged else { return }
        lastLogged = message
        Logger(subsystem: Bundle.main.bundleIdentifier ?? "nz.slstudio.Cue", category: "Marquee")
            .notice("\(message, privacy: .public)")
    }
}
