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

    /// The margin around everything, equal on all four sides.
    ///
    /// Tunable without a rebuild; restart Cue to see a change:
    ///
    ///     defaults write nz.slstudio.Cue PanelMargin 18
    ///     defaults delete nz.slstudio.Cue PanelMargin
    static let defaultMargin: CGFloat = 14

    static var margin: CGFloat {
        let override = UserDefaults.standard.double(forKey: "PanelMargin")
        return override > 0 ? CGFloat(min(max(override, 4), 40)) : defaultMargin
    }

    /// Optical alignment of the artwork's top edge with the title's first line.
    /// A Text view's bounding box starts above its glyphs, so matching the two
    /// geometrically leaves the square looking high.
    /// Tunable: `defaults write nz.slstudio.Cue ArtworkTopNudge 4`.
    static var artworkTopNudge: CGFloat {
        let override = UserDefaults.standard.object(forKey: "ArtworkTopNudge") as? Double
        return CGFloat(min(max(override ?? 3, 0), 20))
    }

    // MARK: - Derived

    /// The right-hand stack: title line, transport, scrub bar.
    static var stack: CGFloat {
        titleBlock + rowGap + transport + rowGap + scrubBar
    }

    /// The artwork square is exactly the stack's height, so the two columns
    /// start and finish level with each other.
    static var artworkSize: CGFloat { stack }

    /// The inset that produces an equal margin on every side.
    ///
    /// The optical nudge shifts the artwork down, so without adding it back the
    /// bottom margin ends up `nudge` points narrower than the top — which is
    /// exactly what the equal-looking sides made obvious.
    static var edgeInset: CGFloat { margin + artworkTopNudge }

    /// The panel has ONE height, derived from the artwork and its margins
    /// rather than guessed at. It is not vertically resizable.
    static var contentHeight: CGFloat { artworkSize + 2 * edgeInset }

    /// §4.6 floors the volume track at 160 pt, which with its two speaker icons
    /// and gaps is 216 pt. The minimum width is whatever leaves room for that
    /// alongside the artwork and a title worth reading.
    static let volumeZoneMinimum: CGFloat = 216
    static let volumeZoneMaximum: CGFloat = 320
    static let titleMinimum: CGFloat = 130

    static var minimumWidth: CGFloat {
        2 * edgeInset + artworkSize + 12 + titleMinimum + 12 + volumeZoneMinimum
    }
}
