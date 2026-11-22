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

/// §4.9a: the panel's overall size, as a multiplier on every length in
/// `PanelMetrics`. Added because the medium panel, tuned on a Mac Studio's
/// display, is overbearing on a laptop.
///
/// One setting covers the expanded panel and the collapsed square alike: the
/// artwork must not change size when the drawer opens, or the collapse
/// animation stops looking like one object moving.
enum PanelSize: String, CaseIterable, Sendable {
    case small, medium, large

    /// Everything in `PanelMetrics` is this multiple of its medium value.
    ///
    /// 0.85 puts the transport row at 37 pt and the scrub bar at 19, under
    /// §4.4's and §4.2's stated floors. Those floors were inherited from
    /// iOS, where 44 pt is a *fingertip*; Cue is pointer-driven, where macOS
    /// imposes nothing comparable and ordinary controls sit at 20–28 pt. See
    /// §4.2 and §4.4, both amended rather than quietly breached.
    var scale: CGFloat {
        switch self {
        case .small: Self.tweak("PanelSmallScale", default: 0.85)
        case .medium: 1
        case .large: Self.tweak("PanelLargeScale", default: 1.15)
        }
    }

    /// Small and Large are tunable without a rebuild, because the display they
    /// need to suit is rarely the one the build is made on. Restart Cue after
    /// changing one:
    ///
    ///     defaults write nz.slstudio.Cue PanelSmallScale 0.8
    ///     defaults delete nz.slstudio.Cue PanelSmallScale
    ///
    /// Clamped well inside the absurd on both sides. Medium is deliberately
    /// not tunable: it is the reference the other two are expressed against,
    /// and §4.6a's geometry was tuned by eye at exactly 1.0.
    private static func tweak(_ key: String, default fallback: CGFloat) -> CGFloat {
        guard let override = UserDefaults.standard.object(forKey: key) as? Double else {
            return fallback
        }
        return CGFloat(min(max(override, 0.6), 1.6))
    }

    var title: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }
}

enum PanelMetrics {

    // MARK: - Scale

    static let sizeKey = "PanelSize"

    /// Read rather than cached, matching `margin` below. `UserDefaults` serves
    /// these from memory after the first read, and the panel already consults
    /// it on every layout pass without measurable cost — §7.1's budget is
    /// spent on Apple Events, not on dictionary lookups.
    static var size: PanelSize {
        get {
            PanelSize(rawValue: UserDefaults.standard.string(forKey: sizeKey) ?? "") ?? .medium
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: sizeKey)
        }
    }

    static var scale: CGFloat { size.scale }

    // MARK: - Components

    /// Title line plus artist/album line.
    ///
    /// These component figures are estimates; what matters is `stack`, which is
    /// checked against the real rendered height at runtime — `PanelView` logs
    /// a METRICS line whenever the two disagree. The last measurement put the
    /// stack at 112 pt against a predicted 115, so the slack below absorbs a
    /// few points either way rather than the panel clipping.
    static var titleBlock: CGFloat { 31 * scale }
    /// §4.4's transport row, sized by the play/pause target. 44 is §4.4's
    /// stated floor, so this is as tight as the spec allows.
    static var transport: CGFloat { 44 * scale }
    /// §4.2's scrub bar. The spec's floor for the interactive area is 20 pt;
    /// 22 keeps a point of margin over it. The end-time caption that used to
    /// sit under this was dropped — it cost 17 pt, and the same information is
    /// in the trailing label's tooltip.
    static var scrubBar: CGFloat { 22 * scale }
    /// §4.6's volume row, when it has one of its own.
    static var volumeRow: CGFloat { 22 * scale }

    /// Vertical gap between rows of the right-hand stack.
    static var rowGap: CGFloat { 4 * scale }

    /// The margin around everything, equal on all four sides.
    ///
    /// NOTE: the *visible* margin is `edgeInset`, which is this plus
    /// `artworkTopNudge`. 12 here gives the 15 pt you actually see. The
    /// optical nudge is folded in so the artwork sits with an equal margin on
    /// every side rather than 3 pt tighter at the bottom.
    ///
    /// Tunable without a rebuild; restart Cue to see a change:
    ///
    ///     defaults write nz.slstudio.Cue PanelMargin 15   # -> 18 pt visible
    ///     defaults delete nz.slstudio.Cue PanelMargin
    static let defaultMargin: CGFloat = 12

    static var margin: CGFloat {
        let override = UserDefaults.standard.double(forKey: "PanelMargin")
        let base = override > 0 ? CGFloat(min(max(override, 4), 40)) : defaultMargin
        return base * scale
    }

    /// Optical alignment of the artwork's top edge with the title's first line.
    /// A Text view's bounding box starts above its glyphs, so matching the two
    /// geometrically leaves the square looking high.
    /// Tunable: `defaults write nz.slstudio.Cue ArtworkTopNudge 4`.
    static var artworkTopNudge: CGFloat {
        let override = UserDefaults.standard.object(forKey: "ArtworkTopNudge") as? Double
        return CGFloat(min(max(override ?? 3, 0), 20)) * scale
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
    /// The volume zone is a FIXED width, not a range.
    ///
    /// Given a range it won the negotiation with the title every time and sat
    /// at its maximum while the title was pinned to its 118 pt minimum — even
    /// on a 589 pt panel, which made ordinary titles scroll needlessly. Fixing
    /// it makes the split predictable: the volume gets a generous, constant
    /// zone and every spare point goes to the title.
    ///
    /// 230 pt leaves roughly 190 pt of track, comfortably over §4.6's 160 pt
    /// floor and never "icon-sized".
    static var volumeZoneWidth: CGFloat { 230 * scale }
    static var volumeZoneMinimum: CGFloat { volumeZoneWidth }
    /// How narrow the title column may get before the panel refuses to shrink.
    ///
    /// Briefly raised to 220 while the marquee appeared broken at small sizes.
    /// That turned out to be a rendering fault, not a width problem — see
    /// §4.3 — and with the marquee genuinely scrolling the whole string a
    /// narrow column reads fine: the text simply takes longer to go by. Back
    /// to 118, which keeps the compact panel Julian prefers at a 557 pt
    /// minimum. The default width stays generous at 760 so titles mostly do
    /// not need to scroll at all.
    static var titleMinimum: CGFloat { 118 * scale }

    /// §4.5's favourite button, which shares the title's line.
    static var favouriteWidth: CGFloat { 24 * scale }

    /// Every element on the title row has to be counted here. Leaving the
    /// favourite button out of this sum is why it vanished: the row was
    /// over-constrained at the panel's existing width and SwiftUI squeezed the
    /// fixed-size control to nothing.
    /// A lane on the right-hand edge for the collapse chevron, so it does not
    /// sit on top of the volume control or the scrub bar's trailing label.
    static var chevronLane: CGFloat { 18 * scale }

    /// Breathing room between the controls and the chevron's hover scrim, so
    /// the two do not touch.
    static var chevronGap: CGFloat { 8 * scale }

    /// Total width the chevron claims on the right: its own lane, the gap
    /// before it, and the margin after it — which is what puts the scrim
    /// inside the panel's border rather than flush against the window edge.
    static var chevronReserve: CGFloat { chevronLane + chevronGap }

    /// Collapsed, the panel is exactly the artwork square plus its margins —
    /// the chevron overlays the art rather than taking a lane of its own.
    static var collapsedWidth: CGFloat { artworkSize + 2 * edgeInset }

    /// The gap between the panel's columns.
    static var columnGap: CGFloat { 12 * scale }

    static var minimumWidth: CGFloat {
        2 * edgeInset
            + artworkSize + columnGap
            + titleMinimum + columnGap
            + favouriteWidth + columnGap
            + volumeZoneMinimum
            + chevronReserve
    }

    // MARK: - Type and glyphs
    //
    // Scaled alongside the box. A smaller panel carrying full-size text does
    // not read as small, it reads as broken — which is why these moved here
    // from six separate views rather than being left behind.
    //
    // `ScrubBar`'s tooltip caption and the §5 placeholder messages keep their
    // semantic fonts (.caption2, .body): they are prose rather than chrome,
    // and they follow the system text size as they should.

    /// §4.3's title line. 13 pt is `NSFont.systemFontSize` at medium.
    static var titleFont: CGFloat { 13 * scale }
    /// §4.3's artist/album line. 11 pt is `NSFont.smallSystemFontSize`.
    static var subtitleFont: CGFloat { 11 * scale }
    /// §4.2's elapsed and remaining labels. Explicitly sized rather than
    /// `.caption`, which reads small beside the enlarged transport glyphs.
    static var timeFont: CGFloat { 13 * scale }
    /// §4.6's speaker icons at each end of the volume track.
    static var volumeGlyph: CGFloat { 13 * scale }
    /// §4.5's shuffle and repeat glyphs. 16 was the point they became
    /// legible; 18 sits better beside the transport.
    static var shuffleRepeatGlyph: CGFloat { 18 * scale }
    /// §4.5's favourite star.
    static var favouriteGlyph: CGFloat { 15 * scale }
    /// The collapse chevron.
    static var chevronGlyph: CGFloat { 11 * scale }

    /// §4.4's previous/next glyphs and their click target.
    static var transportSideGlyph: CGFloat { 19 * scale }
    static var transportSideTarget: CGFloat { 34 * scale }
    /// §4.4's play/pause glyph. Its target is the transport row itself, so
    /// the two cannot drift apart.
    static var transportCentreGlyph: CGFloat { 27 * scale }
    static var transportCentreTarget: CGFloat { transport }
    /// Spacing between the transport buttons.
    static var transportSpacing: CGFloat { 6 * scale }
}
