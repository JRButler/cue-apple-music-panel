//
//  PanelView.swift
//  Cue
//
//  The panel's contents. M1 scope: §4.6a's layout with the title/artist lines
//  and the scrub bar only. Artwork is M2, transport is M2, volume is M2.
//
//  Also renders §5's state table, because a panel that shows nothing when Music
//  is closed is worse than one that says so.
//

import SwiftUI

struct PanelView: View {

    let model: PlayerModel

    var body: some View {
        ZStack {
            // §4.1: vibrancy with rounded corners. The window itself is clear.
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(.white.opacity(0.08))
                )

            content
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
        }
        .environment(\.playerModel, model)
        .frame(minWidth: 320, maxWidth: 900, minHeight: 96)
    }

    @ViewBuilder
    private var content: some View {
        switch model.connection {
        case .musicNotRunning:
            Placeholder(
                title: "Music isn’t open",
                detail: nil,
                actionTitle: "Open Music",
                action: { Task { await model.openMusic() } }
            )

        case .automationDenied:
            Placeholder(
                title: "Cue needs permission to control Music",
                detail: "Allow Cue under Privacy & Security → Automation.",
                actionTitle: "Open System Settings",
                action: { model.openAutomationSettings() }
            )

        case let .failed(message):
            Placeholder(
                title: "Music isn’t responding",
                detail: message,
                actionTitle: "Try again",
                action: { Task { await model.resync() } }
            )

        case .connected:
            connected
        }
    }

    private var connected: some View {
        VStack(alignment: .leading, spacing: 10) {
            NowPlayingLines(track: model.track, onActivate: { model.activateMusic() })
            scrubBar
        }
    }

    /// §4.2 renders the interpolated clock, not the last polled value, which is
    /// what lets a 1 Hz poll drive a bar that moves smoothly.
    ///
    /// `paused:` is what keeps the panel at zero cost while nothing is playing —
    /// M1's "idle CPU under 1% while paused" criterion. A 30 Hz ceiling rather
    /// than full refresh rate is deliberate: the thumb travels about a pixel a
    /// second, so 30 Hz is already sub-pixel per frame, and it is a quarter of
    /// the work of 120 Hz. Dragging is unaffected — the gesture drives its own
    /// repaints, so the thumb still tracks the pointer 1:1.
    private var scrubBar: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !model.playerState.isAdvancing)) { _ in
            ScrubBar(
                position: model.clock.position(),
                duration: model.track?.duration ?? 0,
                isPlaying: model.playerState.isAdvancing,
                onSeek: { target in Task { await model.commitSeek(to: target) } },
                onScrubbingChanged: { model.setScrubbing($0) }
            )
        }
    }
}

// MARK: - Now playing

private struct NowPlayingLines: View {
    let track: TrackInfo?
    let onActivate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(track?.name ?? "Nothing playing")
                .font(.system(.body, design: .rounded).weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(track == nil ? .secondary : .primary)

            Text(subtitle)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onActivate)
        .help(track == nil ? "" : "Double-click to show in Music")
    }

    private var subtitle: String {
        guard let track else { return " " }
        let parts = [track.artist, track.album].filter { !$0.isEmpty }
        return parts.isEmpty ? " " : parts.joined(separator: " — ")
    }
}

// MARK: - States (§5)

private struct Placeholder: View {
    let title: String
    let detail: String?
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(.body, design: .rounded).weight(.medium))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(actionTitle, action: action)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
