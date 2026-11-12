//
//  ShuffleRepeatControls.swift
//  Cue
//
//  §4.5's shuffle and repeat, which §4.6a places flanking the transport group.
//
//  Both are state-bearing rather than momentary, so they tint when active —
//  a plain glyph gives no way to tell shuffle-on from shuffle-off at a glance.
//  Repeat carries a third state: `repeat one` gets its own glyph rather than a
//  badge, which at 13 pt would be unreadable.
//

import SwiftUI

struct ShuffleButton: View {
    let isOn: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        StateGlyph(
            symbol: "shuffle",
            isOn: isOn,
            isEnabled: isEnabled,
            help: isOn ? "Shuffle on" : "Shuffle off",
            action: action
        )
    }
}

struct RepeatButton: View {
    let mode: RepeatMode
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        StateGlyph(
            // `repeat one` needs its own glyph: a badge on the standard one is
            // illegible at this size.
            symbol: mode == .one ? "repeat.1" : "repeat",
            isOn: mode != .off,
            isEnabled: isEnabled,
            help: help,
            action: action
        )
    }

    private var help: String {
        switch mode {
        case .off: "Repeat off"
        case .all: "Repeat all"
        case .one: "Repeat this track"
        }
    }
}

/// A small toggle that reads as on or off at a glance.
private struct StateGlyph: View {
    let symbol: String
    let isOn: Bool
    let isEnabled: Bool
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    private let target: CGFloat = 30

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(isHovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
                Image(systemName: symbol)
                    // 18 pt. At 12 the numeral inside `repeat.1` was invisible,
                    // so repeat-one and repeat-all could not be told apart and
                    // the control read as unresponsive rather than three-state;
                    // 16 was the point it became legible, and 18 sits better
                    // beside the enlarged transport glyphs. Still well inside
                    // the 30 pt target, so the row does not grow.
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
            .frame(width: target, height: target)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// §4.5's favourite. Lives beside the title rather than in the transport row:
/// it is a property of the track, not a playback control.
struct FavouriteButton: View {
    let isFavourite: Bool
    let isEnabled: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: isFavourite ? "star.fill" : "star")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(isFavourite ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 24, height: 24)
                .background(
                    Circle().fill(isHovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { isHovering = $0 }
        .help(isFavourite ? "Remove from favourites" : "Add to favourites")
        .accessibilityLabel(isFavourite ? "Favourited" : "Not favourited")
    }
}
