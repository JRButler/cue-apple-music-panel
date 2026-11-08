//
//  PanelMetrics.swift
//  Cue
//
//  Every height in the panel, in one place.
//
//  This exists because the window's height and the layout's height were
//  computed separately and drifted: the window was 4 pt shy of what the stack
//  needed, which clipped the end-time line off the bottom of the scrub bar and
//  pushed the artwork square flush against the edge. The obvious safeguard —
//  comparing against `NSHostingView.fittingSize` — turned out to be useless
//  here, because it reports 0 x 0 and kept passing silently.
//
//  So the arithmetic is shared instead of checked. `PanelController` sizes the
//  window from `contentHeight`, `PanelView` lays out to the same numbers, and
//  there is nowhere for them to disagree.
//
//  The panel resizes horizontally only, between `minimumWidth` and a maximum.
//  The height is fixed.
//

import Foundation

enum PanelMetrics {

    // MARK: - Components

    /// Title line plus artist/album line.
    ///
    /// These component figures are estimates; what matters is `stack`, which is
    /// checked against the real rendered height at runtime — `PanelView` logs
    /// a METRICS line whenever the two disagree. The last measurement put the
    /// stack at 112 pt against a predicted 115, so the slack below absorbs a
    /// few points either way rather than the panel clipping.
    static let titleBlock: CGFloat = 33
    /// §4.4's transport row, sized by the 46 pt play/pause target.
    static let transport: CGFloat = 46
    /// §4.2's scrub bar: just the 24 pt track row. The end-time caption that
    /// used to sit under it was dropped — it cost 17 pt of panel height, and
    /// the same information is now in the trailing label's tooltip.
    static let scrubBar: CGFloat = 24
    /// §4.6's volume row, when it has one of its own.
    static let volumeRow: CGFloat = 22

    /// Vertical gap between rows of the right-hand stack.
    static let rowGap: CGFloat = 6
    /// Padding around the whole content.
    static let padding: CGFloat = 12

    // MARK: - Derived

    /// The right-hand stack: title line, transport, scrub bar.
    static var stack: CGFloat {
        titleBlock + rowGap + transport + rowGap + scrubBar
    }

    /// Breathing room below the stack, on top of the padding. Generous on
    /// purpose: twice now a tight value has put the scrub bar uncomfortably
    /// close to the bottom edge, and a few points of air costs nothing.
    static let slack: CGFloat = 16

    /// How far the artwork square is inset within the padded area, so it reads
    /// as a panel sitting in the layout rather than something cropped by it.
    static let artworkInset: CGFloat = 10

    /// The panel has ONE height. It is not vertically resizable: there is
    /// nothing to gain by making it taller, and an earlier version that varied
    /// the height with the width — moving the volume control onto and off the
    /// title's line — was more trouble than the space it saved.
    static var contentHeight: CGFloat { stack + 2 * padding + slack }

    /// The artwork square fills the content height inside the padding, so it
    /// reads as a panel at the left-hand end rather than a thumbnail.
    static var artworkSize: CGFloat { contentHeight - 2 * padding - artworkInset }

    /// §4.6 floors the volume track at 160 pt, which with its two speaker icons
    /// and gaps is 216 pt. The minimum width is whatever leaves room for that
    /// alongside the artwork and a title worth reading.
    static let volumeZoneMinimum: CGFloat = 216
    static let volumeZoneMaximum: CGFloat = 320
    static let titleMinimum: CGFloat = 130

    static var minimumWidth: CGFloat {
        2 * padding + artworkSize + 12 + titleMinimum + 12 + volumeZoneMinimum
    }
}
