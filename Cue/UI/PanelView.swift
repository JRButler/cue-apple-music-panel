//
//  PanelView.swift
//  Cue
//
//  The panel's contents, laid out per §4.6a. M2 completes it bar shuffle and
//  repeat, which flank the transport group once M3 lands.
//
//  Also renders §5's state table, because a panel that shows nothing when Music
//  is closed is worse than one that says so.
//

import SwiftUI

struct PanelView: View {

    let model: PlayerModel

    /// Width at which the volume control can share the title's line.
    ///
    /// Below it there is not enough room for both: §4.6 sets a 160 pt floor on
    /// the volume track, plus two 20 pt speaker icons and their gaps is 216 pt,
    /// and with 24 pt of padding and the 74 pt artwork column that leaves the
    /// title under 60 pt at minimum width. So the volume moves to its own row
    /// instead of either control being squeezed.
    static let sideBySideWidth: CGFloat = 470

    var body: some View {
        // The arrangement is chosen from the width in the SAME layout pass that
        // uses it. An earlier version kept the width in @State fed by
        // onGeometryChange, which lags the real size by a frame: during a live
        // resize the content laid itself out for the previous width and then
        // corrected, which read as the whole panel squashing vertically until
        // the mouse was released.
        GeometryReader { proxy in
            panel(width: proxy.size.width)
        }
    }

    private func panel(width: CGFloat) -> some View {
        let isWide = width >= Self.sideBySideWidth
        return ZStack {
            // §4.1: the panel is movable by its background. This has to sit
            // behind everything, and the vibrancy above it has to decline hit
            // testing, or a press on the background never reaches it. See
            // WindowDragArea for why both halves are needed.
            WindowDragArea()

            // §4.1: vibrancy with rounded corners. The window itself is clear.
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(.white.opacity(0.08))
                )
                .allowsHitTesting(false)

            content(isWide: isWide, width: width)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
        }
        .environment(\.playerModel, model)
        // No minHeight: the window's height is authoritative, and asking for
        // more than it has is the other half of what caused the squash.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func content(isWide: Bool, width: CGFloat) -> some View {
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
            connected(isWide: isWide, width: width)
        }
    }

    private func connected(isWide: Bool, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Top row: artwork, then the title and artist/album lines, and — if
            // the panel is wide enough — the volume control on the same line.
            HStack(alignment: .top, spacing: 10) {
                ArtworkView(
                    image: model.artwork,
                    trackKey: model.track?.id ?? "none",
                    onActivate: { model.activateMusic() }
                )

                NowPlayingLines(track: model.track, onActivate: { model.activateMusic() })
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(maxHeight: ArtworkView.minimumSize, alignment: .top)

                if isWide {
                    volumeControl
                        .frame(width: volumeZoneWidth(for: width))
                }
            }

            // Transport sits directly above the scrub bar, centred.
            TransportControls(
                isPlaying: model.playerState.isAdvancing,
                isEnabled: model.connection == .connected,
                onPrevious: { Task { await model.previousTrack() } },
                onPlayPause: { Task { await model.togglePlayPause() } },
                onNext: { Task { await model.nextTrack() } }
            )

            scrubBar

            // Narrow panels give the volume its own row rather than squeezing it.
            if !isWide {
                volumeControl
            }
        }
    }

    private var volumeControl: some View {
        VolumeControl(
            volume: model.volume,
            isMuted: model.isEffectivelyMuted,
            isEnabled: model.connection == .connected,
            onChange: { value, committing in
                model.setVolume(value, committing: committing)
            },
            onToggleMute: { Task { await model.toggleMute() } },
            onNudge: { delta in model.nudgeVolume(by: delta) }
        )
    }

    /// Roughly half the width left over after the artwork column, bounded so it
    /// neither drops under §4.6's floor nor crowds out the title.
    private func volumeZoneWidth(for width: CGFloat) -> CGFloat {
        let available = width - 24 - (ArtworkView.minimumSize + 10)
        return min(320, max(216, available * 0.5))
    }

    /// §4.2 renders the interpolated clock, not the last polled value, which is
    /// what lets a 1 Hz poll drive a bar that moves smoothly.
    ///
    /// There is no TimelineView here any more. Wrapping the whole bar in one made
    /// every label and every string format re-evaluate at the thumb's rate, for
    /// 6% of a core; ScrubBar now scopes its own redraws, and the comment at the
    /// top of that file explains how.
    private var scrubBar: some View {
        ScrubBar(
            clock: model.clock,
            duration: model.track?.duration ?? 0,
            isPlaying: model.playerState.isAdvancing,
            onSeek: { target in Task { await model.commitSeek(to: target) } },
            onScrubbingChanged: { model.setScrubbing($0) }
        )
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
        // Drags the panel; a double-click still opens Music.
        .windowDraggable(clickCount: 2, onClick: onActivate)
        .help(track == nil ? "Drag to move" : "Double-click to show in Music, drag to move")
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
