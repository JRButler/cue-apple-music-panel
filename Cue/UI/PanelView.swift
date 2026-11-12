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

import OSLog
import SwiftUI

struct PanelView: View {

    let model: PlayerModel

    var body: some View {
        ZStack {
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

            content
                // One inset on every side. The artwork's own top nudge is
                // already folded into it, so the square sits with an equal
                // margin all round rather than 3 pt tighter at the bottom.
                // Genuinely uniform now: the artwork is the tallest element in
                // the row and carries no nudge of its own, so this inset is its
                // margin on all four sides.
                .padding(PanelMetrics.edgeInset)
        }
        .environment(\.playerModel, model)
        // The window's size is authoritative; asking for more than it has is
        // what made a live resize look like the panel was squashing.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Essential with `.fullSizeContentView`. The titlebar is 32 pt, and
        // although the content view spans the whole window, SwiftUI applies a
        // safe-area inset for the titlebar and lays the content out in the
        // remaining 117 pt of a 149 pt panel. The content then overflows that
        // box evenly, 16 pt each way, which put the artwork 33 pt from the top
        // and 1 pt from the bottom — measured, after reasoning about it failed
        // twice. The panel draws its own background, so there is no safe area
        // worth respecting here.
        .ignoresSafeArea()
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

    /// Artwork on the left as a full-height square, everything else stacked
    /// beside it. Putting the art in its own column rather than its own row is
    /// what lets the panel be shorter: the title, transport and scrub bar share
    /// the vertical space the art used to sit above.
    private var connected: some View {
        // Top-aligned, not centred. The artwork square and the stack beside it
        // are different heights, so centring offset the art downwards by half
        // the difference and it no longer started level with the title.
        HStack(alignment: .top, spacing: 12) {
            ArtworkView(
                image: model.artwork,
                trackKey: model.track?.id ?? "none",
                size: PanelMetrics.artworkSize,
                onActivate: { model.activateMusic() }
            )
            // Reports where the square actually lands in the window, so the
            // margins can be read off rather than reasoned about.
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { rect in
                PanelView.reportArtworkFrame(rect)
            }

            VStack(alignment: .leading, spacing: PanelMetrics.rowGap) {
                // Title and artist, with the volume beside them when there is room.
                HStack(alignment: .top, spacing: 12) {
                    NowPlayingLines(track: model.track, onActivate: { model.activateMusic() })
                        .frame(minWidth: PanelMetrics.titleMinimum, maxWidth: .infinity, alignment: .leading)

                    // Always on the title's line. The minimum width guarantees
                    // room for it, so it never has to move.
                    volumeControl
                        .frame(
                            minWidth: PanelMetrics.volumeZoneMinimum,
                            maxWidth: PanelMetrics.volumeZoneMaximum
                        )
                }

                // Transport sits directly above the scrub bar, centred, and
                // takes the slack the artwork row used to occupy.
                // §4.6a: shuffle and repeat flank the centred transport group.
                HStack(spacing: 4) {
                    Spacer(minLength: 0)
                    ShuffleButton(
                        isOn: model.isShuffling,
                        isEnabled: model.connection == .connected,
                        action: { Task { await model.toggleShuffle() } }
                    )
                    TransportControls(
                        isPlaying: model.playerState.isAdvancing,
                        isEnabled: model.connection == .connected,
                        onPrevious: { Task { await model.previousTrack() } },
                        onPlayPause: { Task { await model.togglePlayPause() } },
                        onNext: { Task { await model.nextTrack() } }
                    )
                    .fixedSize()
                    RepeatButton(
                        mode: model.repeatMode,
                        isEnabled: model.connection == .connected,
                        action: { Task { await model.cycleRepeat() } }
                    )
                    Spacer(minLength: 0)
                }

                scrubBar
            }
            // The optical nudge is applied HERE, to the text column, not to the
            // artwork. A Text view's box starts a little above its glyphs, so
            // the two only look level if the text rises slightly. Nudging the
            // square down instead is what left its bottom margin narrower than
            // its top while the sides looked correct.
            .padding(.top, -PanelMetrics.artworkTopNudge)
            // Measures what the stack actually renders at, rather than what my
            // arithmetic in PanelMetrics predicts. Two separate off-by-a-few
            // errors have clipped the bottom of this panel.
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                PanelView.reportStackHeight(size.height)
            }
        }
    }


    /// Logs the stack's rendered height once per distinct value.
    nonisolated(unsafe) private static var lastReported: CGFloat = 0

    static func reportStackHeight(_ height: CGFloat) {
        guard height > 0, abs(height - lastReported) > 0.5 else { return }
        lastReported = height
        let predicted = PanelMetrics.stack
        let message = String(
            format: "METRICS: stack renders at %.1fpt, PanelMetrics predicts %.1fpt (delta %+.1f)",
            height, predicted, height - predicted
        )
        Logger(subsystem: Bundle.main.bundleIdentifier ?? "nz.slstudio.Cue", category: "Layout")
            .notice("\(message, privacy: .public)")
    }

    nonisolated(unsafe) private static var lastArtworkFrame: CGRect = .zero

    static func reportArtworkFrame(_ rect: CGRect) {
        guard rect.height > 0,
              abs(rect.minY - lastArtworkFrame.minY) > 0.5 || abs(rect.height - lastArtworkFrame.height) > 0.5
        else { return }
        lastArtworkFrame = rect
        let message = String(
            format: "ARTFRAME: y %.1f..%.1f (h %.1f) x %.1f, expected inset %.1f",
            rect.minY, rect.maxY, rect.height, rect.minX, PanelMetrics.edgeInset
        )
        Logger(subsystem: Bundle.main.bundleIdentifier ?? "nz.slstudio.Cue", category: "Layout")
            .notice("\(message, privacy: .public)")
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
        .windowDraggable(requiredClicks: 2, onClick: onActivate)
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
