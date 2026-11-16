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
    let onActivate: () -> Void

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
        // §4.3: clicking brings Music forward — and §4.1: dragging here moves
        // the panel. See WindowDragging for why both need one gesture.
        .overlay(alignment: .leading) {
            WindowDragHandle(requiredClicks: 1, onClick: onActivate)
                .frame(width: max(0, size - dragExclusionTrailing))
        }
        .help("Click to show in Music, drag to move")
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
