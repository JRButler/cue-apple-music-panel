//
//  ArtworkView.swift
//  Cue
//
//  §4.3's artwork, as a square panel filling the left-hand end of the layout.
//  Well above §4.3's 64 pt minimum, rounded with a subtle shadow, crossfading
//  over 150 ms on a track change, and falling back to a neutral placeholder —
//  which is not an edge case, since some streamed catalogue tracks carry no
//  artwork at all.
//

import SwiftUI

struct ArtworkView: View {

    let image: NSImage?
    /// Changes on a track change, and is what the crossfade keys on. Using the
    /// image itself would not work: two tracks can both have no artwork.
    let trackKey: String
    /// The square's side. Driven by the panel's height, so the art fills the
    /// left-hand end.
    let size: CGFloat
    /// Width at the trailing edge left free of the drag handle.
    ///
    /// The handle is a real AppKit view, and an NSView wins hit-testing over
    /// SwiftUI content sitting above it. Collapsed, it covered the whole
    /// square including the chevron, so hovers never reached the chevron and
    /// clicks went to "open Music" instead of expanding.
    var dragExclusionTrailing: CGFloat = 0

    /// §4.10. Collapsed, the artwork's leading region is play/pause rather
    /// than a shortcut to Music: collapsed is the state where transport is
    /// most wanted and, until now, the only one with none.
    var showsPlayPause: Bool = false
    var isPlaying: Bool = false
    /// The chevron lives in `PanelView`, but its hover has to raise the same
    /// scrim this view draws — see the overlay below for why there is only one.
    var isHoveringChevron: Bool = false

    let onActivate: () -> Void

    /// The pointer over the play region specifically, for the brighter scrim.
    @State private var isHoveringPlay = false

    /// §4.3's floor, which the layout now comfortably exceeds.
    static let minimumSize: CGFloat = 64
    /// Beyond this the square starts to dominate a tall, narrow panel.
    static let maximumSize: CGFloat = 132

    /// Scaled with the square so it reads as a panel rather than a thumbnail.
    private var cornerRadius: CGFloat { max(6, size * 0.07) }

    var body: some View {
        ZStack {
            placeholder
            if let image {
                Image(nsImage: image)
                    .resizable()
                    // The image is already close to its drawn size, so this is
                    // a short hop rather than a 10x reduction — but ask for the
                    // good filter anyway, it costs nothing at this scale.
                    .interpolation(.high)
                    .antialiased(true)
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.1))
        )
        .shadow(color: .black.opacity(0.28), radius: 4, y: 1)
        // §4.3: 150 ms crossfade.
        .animation(.easeInOut(duration: 0.15), value: trackKey)
        .contentShape(Rectangle())
        // §4.3: clicking brings Music forward — §4.10: or toggles playback
        // when collapsed — and §4.1: dragging here moves the panel either way.
        // See WindowDragging for why both need one gesture.
        .overlay(alignment: .leading) {
            WindowDragHandle(requiredClicks: 1, onClick: onActivate)
                .frame(width: max(0, size - dragExclusionTrailing))
        }
        // §4.10's scrim and glyph, ABOVE the drag handle so it is not dimmed
        // by the artwork, and hit-testing disabled so the press still reaches
        // the handle underneath. Hover is tracked by HoverTracker rather than
        // `.onHover`, which never fires on a view that declines hit testing.
        // §4.10: ONE scrim over the whole square, raised by either control,
        // carrying whichever glyph is active.
        //
        // Two adjacent scrims could not be made to meet. They are anchored to
        // different things — the chevron's is a rounded rectangle positioned
        // against the *panel*, overhanging the artwork's right edge, while the
        // play half's is square-edged and inset within the artwork — so a
        // strip of undimmed art always showed between them. A single cover has
        // no seam to get wrong, and the glyph swaps instead of the backing.
        //
        // Rounded to the artwork's own radius: the clip above it has already
        // been applied, so a plain rectangle would square off the corners.
        .overlay {
            if showsPlayPause {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.black.opacity(0.42))
                    .opacity(isHoveringPlay || isHoveringChevron ? 1 : 0)
                    .animation(.easeInOut(duration: 0.12), value: isHoveringPlay)
                    .animation(.easeInOut(duration: 0.12), value: isHoveringChevron)
                    .allowsHitTesting(false)
            }
        }
        // Centred in the square for free, since the overlay spans the whole
        // frame rather than the play region.
        .overlay {
            if showsPlayPause {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: PanelMetrics.miniTransportGlyph, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .opacity(isHoveringPlay ? 1 : 0)
                    .animation(.easeInOut(duration: 0.12), value: isHoveringPlay)
                    .allowsHitTesting(false)
            }
        }
        // The tracker is a sibling of the scrim rather than inside it: the
        // scrim spends most of its life at zero opacity, and tracking has to
        // keep working while it is invisible.
        .overlay(alignment: .leading) {
            if showsPlayPause {
                HoverTracker { isHoveringPlay = $0 }
                    .frame(width: max(0, size - dragExclusionTrailing), height: size)
                    .allowsHitTesting(false)
            }
        }
        .help(showsPlayPause ? "Click to play or pause, drag to move"
                             : "Click to show in Music, drag to move")
        .accessibilityLabel(image == nil ? "No artwork" : "Album artwork")
    }

    /// Shown whenever there is no album art: a track that carries none, and —
    /// far more often — a stopped player, where §5 says there is nothing to
    /// show. A grey box with a glyph read as something broken; Cue's own reel
    /// reads as "nothing playing".
    ///
    /// Desaturated a little so it is not mistaken for an album cover that
    /// happens to be a tape reel. One number, if that judgement changes.
    private var placeholder: some View {
        Image(.artworkPlaceholder)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fill)
            .saturation(0.75)
            .opacity(0.9)
    }
}
