//
//  ArtworkView.swift
//  Cue
//
//  §4.3's artwork. 64 pt minimum in the compact layout, growing with the panel,
//  rounded with a subtle shadow, crossfading over 150 ms on a track change, and
//  falling back to a neutral placeholder — which is not an edge case, since some
//  streamed catalogue tracks carry no artwork at all.
//

import SwiftUI

struct ArtworkView: View {

    let image: NSImage?
    /// Changes on a track change, and is what the crossfade keys on. Using the
    /// image itself would not work: two tracks can both have no artwork.
    let trackKey: String
    let onActivate: () -> Void

    /// §4.3's floor. The panel scales this up as it grows.
    static let minimumSize: CGFloat = 64

    private let cornerRadius: CGFloat = 6

    var body: some View {
        ZStack {
            placeholder
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            }
        }
        .frame(width: Self.minimumSize, height: Self.minimumSize)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.1))
        )
        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
        // §4.3: 150 ms crossfade.
        .animation(.easeInOut(duration: 0.15), value: trackKey)
        .contentShape(Rectangle())
        // §4.3: clicking brings Music forward — and §4.1: dragging here moves
        // the panel. See WindowDragging for why both need one gesture.
        .windowDraggable(onClick: onActivate)
        .help("Click to show in Music, drag to move")
        .accessibilityLabel(image == nil ? "No artwork" : "Album artwork")
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.quaternary)
            .overlay(
                Image(systemName: "music.note")
                    .font(.system(size: Self.minimumSize * 0.34, weight: .light))
                    .foregroundStyle(.tertiary)
            )
    }
}
