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

    /// Two identical labels, the second trailing the first by `gap`, so the
    /// text can wrap without a visible seam.
    private let track = NSView()
    private let label = NSTextField(labelWithString: "")
    private let trailing = NSTextField(labelWithString: "")

    private var current: String = ""
    private var pause: TimeInterval = 2
    private var speed: CGFloat = 22

    /// Space between the end of one copy and the start of the next.
    private let gap: CGFloat = 44

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true

        for field in [label, trailing] {
            field.isBezeled = false
            field.drawsBackground = false
            field.isEditable = false
            field.isSelectable = false
            field.lineBreakMode = .byClipping
            field.cell?.usesSingleLineMode = true
        }
        track.wantsLayer = true
        track.addSubview(label)
        track.addSubview(trailing)
        addSubview(track)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func apply(text: String, font: NSFont, colour: NSColor, pause: TimeInterval, speed: CGFloat) {
        self.pause = pause
        self.speed = speed

        let changed = text != current || label.font != font || label.textColor != colour
        current = text
        for field in [label, trailing] {
            field.stringValue = text
            field.font = font
            field.textColor = colour
            field.sizeToFit()
        }

        if changed { needsLayout = true }
        reflow()
    }

    override func layout() {
        super.layout()
        reflow()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: label.intrinsicContentSize.height)
    }

    private func reflow() {
        // Measured from the string and font directly, NOT from sizeToFit().
        // sizeToFit can settle on whatever the field's current frame allows,
        // which silently produced a truncated "full" width — so the marquee
        // scrolled a string that had already lost its tail.
        let textWidth = measuredWidth()
        let available = bounds.width
        let height = ceil(label.intrinsicContentSize.height)
        let y = (bounds.height - height) / 2

        track.layer?.removeAnimation(forKey: "marquee")

        // Fits: one copy, no animation, nothing running, nothing to pay for.
        guard available > 0, textWidth > available + 1 else {
            trailing.isHidden = true
            track.frame = NSRect(x: 0, y: y, width: max(textWidth, available), height: height)
            label.frame = NSRect(x: 0, y: 0, width: textWidth, height: height)
            if available > 0 { Self.log("fits (\(Int(textWidth))pt in \(Int(available))pt): static") }
            return
        }

        // Overflowing: lay out both copies and wrap between them.
        trailing.isHidden = false
        let cycle = textWidth + gap
        track.frame = NSRect(x: 0, y: y, width: cycle + textWidth, height: height)
        label.frame = NSRect(x: 0, y: 0, width: textWidth, height: height)
        trailing.frame = NSRect(x: cycle, y: 0, width: textWidth, height: height)

        let travel = TimeInterval(cycle / speed)
        let total = pause + travel
        let startX = track.layer?.position.x ?? 0

        // Hold at the start, then travel exactly one cycle. At the end of it
        // the second copy sits precisely where the first began, so restarting
        // is invisible — no reversal, no jump.
        let animation = CAKeyframeAnimation(keyPath: "position.x")
        animation.values = [startX, startX, startX - cycle]
        animation.keyTimes = [0, NSNumber(value: pause / total), 1]
        animation.timingFunctions = [
            CAMediaTimingFunction(name: .linear),
            // Eases away from rest, then holds a steady pace to the wrap.
            CAMediaTimingFunction(controlPoints: 0.35, 0, 1, 1),
        ]
        animation.duration = total
        animation.repeatCount = .infinity
        track.layer?.add(animation, forKey: "marquee")

        Self.log("scrolling: text \(Int(textWidth))pt in \(Int(available))pt, cycle \(Int(cycle))pt over \(String(format: "%.1f", total))s — \(current)")
    }

    /// The full rendered width of the string, independent of any frame.
    private func measuredWidth() -> CGFloat {
        guard let font = label.font else { return 0 }
        let size = (current as NSString).size(withAttributes: [.font: font])
        return ceil(size.width)
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
