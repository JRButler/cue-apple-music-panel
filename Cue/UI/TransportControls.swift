//
//  TransportControls.swift
//  Cue
//
//  §4.4's transport: previous · play/pause · next, centred, with play/pause
//  visibly larger than its neighbours.
//
//  The hit targets are the point of the app, so they are explicit: at least
//  32 pt for previous and next, at least 44 pt for play/pause. The glyphs are
//  smaller than that — the target is the frame plus `contentShape`, not the
//  drawn symbol.
//

import SwiftUI

struct TransportControls: View {

    let isPlaying: Bool
    let isEnabled: Bool
    let onPrevious: () -> Void
    let onPlayPause: () -> Void
    let onNext: () -> Void

    /// §4.4's minimum hit targets.
    private let sideTarget: CGFloat = 34
    private let centreTarget: CGFloat = 46

    var body: some View {
        HStack(spacing: 6) {
            TransportButton(
                symbol: "backward.fill",
                glyphSize: 14,
                target: sideTarget,
                help: "Previous",
                action: onPrevious
            )

            TransportButton(
                // §4.4: reflects the actual player state, updated optimistically
                // on click and reconciled on the next sync.
                symbol: isPlaying ? "pause.fill" : "play.fill",
                glyphSize: 21,
                target: centreTarget,
                help: isPlaying ? "Pause" : "Play",
                action: onPlayPause
            )

            TransportButton(
                symbol: "forward.fill",
                glyphSize: 14,
                target: sideTarget,
                help: "Next",
                action: onNext
            )
        }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

private struct TransportButton: View {
    let symbol: String
    let glyphSize: CGFloat
    let target: CGFloat
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                // The hit target, independent of the glyph's size.
                Circle()
                    .fill(isHovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
                Image(systemName: symbol)
                    .font(.system(size: glyphSize, weight: .medium))
                    .foregroundStyle(.primary)
            }
            .frame(width: target, height: target)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}
