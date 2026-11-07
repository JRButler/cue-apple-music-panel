//
//  ScrubBar.swift
//  Cue
//
//  §4.2, the core feature. Fixing a fiddly control is the point of the app, so
//  the generous hit target is not a nicety — it is the requirement.
//
//  Three rules from §4.2 drive the implementation:
//    · the interactive area is at least 20 pt tall, whatever the track looks like
//    · a drag commits exactly ONE seek, on release
//    · while dragging, Music's reports must not move the thumb
//

import SwiftUI

struct ScrubBar: View {

    let position: TimeInterval
    let duration: TimeInterval
    let isPlaying: Bool

    /// Called once, on release, with the committed position.
    let onSeek: (TimeInterval) -> Void
    /// Called with true as a drag begins and false as it ends, so the model can
    /// suppress clock updates for its duration.
    let onScrubbingChanged: (Bool) -> Void

    @State private var dragPosition: TimeInterval?
    @State private var isHovering = false

    /// §4.2: at least 20 pt of interactive height.
    private let interactiveHeight: CGFloat = 24
    private let trackHeight: CGFloat = 5
    private let thumbDiameter: CGFloat = 13

    private var isSeekable: Bool { duration > 0 }

    /// What the bar should render: the drag, if one is in progress, otherwise
    /// the clock.
    private var displayPosition: TimeInterval {
        dragPosition ?? position
    }

    private var progress: Double {
        guard isSeekable else { return 0 }
        return min(max(0, displayPosition / duration), 1)
    }

    var body: some View {
        VStack(spacing: 3) {
            HStack(alignment: .center, spacing: 10) {
                Text(TimeFormatting.position(displayPosition, trackDuration: duration))
                    .font(.system(.caption, design: .rounded).weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 38, alignment: .leading)

                track
                    .frame(height: interactiveHeight)
                    .frame(maxWidth: .infinity)

                trailingLabel
            }

            endTimeLabel
        }
    }

    // MARK: - Track

    private var track: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                // The whole height is hit-testable, not just the visible track.
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())

                Capsule()
                    .fill(.quaternary)
                    .frame(height: trackHeight)

                if isSeekable {
                    Capsule()
                        .fill(.tint)
                        .frame(width: max(trackHeight, width * progress), height: trackHeight)

                    Circle()
                        .fill(.white)
                        .shadow(radius: 1.5, y: 0.5)
                        .frame(width: thumbDiameter, height: thumbDiameter)
                        .offset(x: width * progress - thumbDiameter / 2)
                        .opacity(isHovering || dragPosition != nil ? 1 : 0.85)
                        .animation(.easeOut(duration: 0.12), value: isHovering)
                } else {
                    // §4.2's stream case: indeterminate, and not seekable.
                    IndeterminateBar(height: trackHeight, isAnimating: isPlaying)
                }
            }
            .frame(maxHeight: .infinity)
            .overlay(alignment: .topLeading) {
                if let dragPosition {
                    TimeBubble(text: TimeFormatting.position(dragPosition, trackDuration: duration))
                        .offset(x: bubbleOffset(width: width), y: -22)
                }
            }
            .onHover { isHovering = $0 }
            .gesture(dragGesture(width: width))
        }
    }

    /// A click anywhere seeks there; a drag scrubs. `minimumDistance: 0` makes a
    /// plain click a zero-length drag, so one gesture covers both and they
    /// cannot disagree about where the press landed.
    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard isSeekable else { return }
                if dragPosition == nil { onScrubbingChanged(true) }
                dragPosition = position(fromX: value.location.x, width: width)
            }
            .onEnded { value in
                guard isSeekable else { return }
                let target = position(fromX: value.location.x, width: width)
                dragPosition = nil
                onScrubbingChanged(false)
                // §4.2: exactly one seek, here and nowhere else.
                onSeek(target)
            }
    }

    private func position(fromX x: CGFloat, width: CGFloat) -> TimeInterval {
        guard width > 0, duration > 0 else { return 0 }
        let fraction = min(max(0, x / width), 1)
        return fraction * duration
    }

    /// Keeps the bubble inside the bar's width instead of letting it hang off
    /// either end.
    private func bubbleOffset(width: CGFloat) -> CGFloat {
        let bubbleWidth: CGFloat = 46
        let ideal = width * progress - bubbleWidth / 2
        return min(max(0, ideal), max(0, width - bubbleWidth))
    }

    // MARK: - Labels

    /// §4.2: clicking toggles between remaining and total. The choice persists,
    /// which is why the binding lives in PlayerModel rather than here.
    @Environment(\.playerModel) private var model

    private var trailingLabel: some View {
        Button {
            model?.showsTotalTime.toggle()
        } label: {
            Text(trailingText)
                .font(.system(.caption, design: .rounded).weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 42, alignment: .trailing)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isSeekable
              ? "Track length \(TimeFormatting.total(duration)) — click to switch"
              : "This track has no duration")
    }

    private var trailingText: String {
        guard isSeekable else { return "--:--" }
        if model?.showsTotalTime == true {
            return TimeFormatting.total(duration)
        }
        return TimeFormatting.remaining(max(0, duration - displayPosition), trackDuration: duration)
    }

    /// §4.2: the wall-clock finish time while playing, "paused" otherwise.
    private var endTimeLabel: some View {
        Text(endTimeText)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private var endTimeText: String {
        guard isSeekable else { return isPlaying ? "live" : "paused" }
        guard isPlaying else { return "paused" }
        return TimeFormatting.endTime(remaining: max(0, duration - displayPosition))
    }
}

// MARK: - Pieces

private struct TimeBubble: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(.caption2, design: .rounded).weight(.semibold))
            .monospacedDigit()
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.thickMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.quaternary))
            .shadow(radius: 3, y: 1)
            .fixedSize()
    }
}

/// §4.2: shown when Music reports no duration, as some streams do.
private struct IndeterminateBar: View {
    let height: CGFloat
    let isAnimating: Bool

    @State private var phase: CGFloat = -0.4

    var body: some View {
        GeometryReader { geometry in
            Capsule()
                .fill(.tint.opacity(0.65))
                .frame(width: geometry.size.width * 0.3, height: height)
                .offset(x: geometry.size.width * phase)
        }
        .frame(height: height)
        .clipShape(Capsule())
        .onAppear { if isAnimating { animate() } }
        .onChange(of: isAnimating) { _, animating in if animating { animate() } }
    }

    private func animate() {
        withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: false)) {
            phase = 1.1
        }
    }
}

// MARK: - Environment

/// Passed through the environment so the scrub bar's trailing label can toggle
/// the persisted remaining/total choice without threading a binding through
/// every intermediate view.
private struct PlayerModelKey: EnvironmentKey {
    static let defaultValue: PlayerModel? = nil
}

extension EnvironmentValues {
    var playerModel: PlayerModel? {
        get { self[PlayerModelKey.self] }
        set { self[PlayerModelKey.self] = newValue }
    }
}
