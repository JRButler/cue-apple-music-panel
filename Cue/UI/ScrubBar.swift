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
//  HOW THE THUMB MOVES — not by redrawing on a timer.
//
//  Earlier attempts sampled the clock from a TimelineView and redrew. That cost
//  5–6% of a core, and worse, it did not respond sensibly to the rate: 5 Hz and
//  30 Hz measured the same, because the work done per tick dominated. Shrinking
//  the per-tick work made it worse still.
//
//  Instead, each sync hands the bar a *target* one poll-interval ahead, plus a
//  linear animation to reach it. Core Animation interpolates on the render server
//  at true display refresh rate, and SwiftUI evaluates this view once per sync —
//  about 1 Hz — instead of once per frame.
//
//  Both moving parts are deliberately transforms rather than layout:
//    · the fill is a capsule with a horizontal scaleEffect, clipped so its ends
//      stay round
//    · the thumb is an offset
//  Animating a width would re-run layout every frame, which is the cost being
//  avoided.
//
//  A drag bypasses all of it: `dragPosition` drives the view directly with
//  animation disabled, so the thumb tracks the pointer exactly.
//

import SwiftUI

struct ScrubBar: View {

    /// Read live rather than passed as a snapshot, so the view can take both its
    /// animation target and its label values from one source.
    let clock: PlaybackClock
    let duration: TimeInterval
    let isPlaying: Bool
    /// False when nothing is queued at all. §5 wants an empty bar for that;
    /// §4.2's indeterminate bar means something different — a real track whose
    /// duration Music will not report, as some streams do. Rendering both the
    /// same way made a parked player look like it was endlessly seeking.
    let hasTrack: Bool

    /// Called once, on release, with the committed position.
    let onSeek: (TimeInterval) -> Void
    /// Called with true as a drag begins and false as it ends, so the model can
    /// suppress clock updates for its duration.
    let onScrubbingChanged: (Bool) -> Void

    @State private var dragPosition: TimeInterval?
    @State private var isHovering = false

    @Environment(\.playerModel) private var model

    /// §4.2: at least 20 pt of interactive height. 22 keeps a point in hand
    /// over the floor while giving the panel back two.
    private let interactiveHeight: CGFloat = 22
    private let trackHeight: CGFloat = 5
    private let thumbDiameter: CGFloat = 13

    /// How often the thumb is repositioned during passive playback.
    ///
    /// Overridable without a rebuild, so the rate can be judged by eye against
    /// its measured cost:
    ///
    ///     defaults write nz.slstudio.Cue ThumbHz 10
    ///     defaults delete nz.slstudio.Cue ThumbHz     # back to the default
    static let defaultThumbHz: Double = 2

    private static var thumbRefreshInterval: TimeInterval {
        let override = UserDefaults.standard.double(forKey: "ThumbHz")
        let hz = override > 0 ? min(max(override, 0.5), 120) : defaultThumbHz
        return 1.0 / hz
    }

    private var isSeekable: Bool { duration > 0 }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            elapsedLabel
            trackArea
            trailingLabel
        }
    }

    /// The position the labels should show: the drag if one is in progress, else
    /// the interpolated clock.
    private func displayPosition() -> TimeInterval {
        dragPosition ?? clock.position()
    }

    // MARK: - Labels
    //
    // No timeline and no animation. PlaybackClock is @Observable, so reading it
    // registers a dependency and these refresh when it syncs — 1 Hz, which is
    // exactly the rate at which their text can change.

    private var elapsedLabel: some View {
        Text(TimeFormatting.position(displayPosition(), trackDuration: duration))
            // An explicit size rather than `.caption`, which is around 10 pt
            // and reads small beside the enlarged transport glyphs. 13 pt still
            // sits inside the 24 pt row, so the panel height is unchanged.
            .font(.system(size: PanelMetrics.timeFont, weight: .medium, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .frame(minWidth: 44, alignment: .leading)
    }

    /// §4.2: clicking toggles between remaining and total. The choice persists,
    /// which is why it lives in PlayerModel rather than in @State here.
    private var trailingLabel: some View {
        Button {
            model?.showsTotalTime.toggle()
        } label: {
            Text(trailingText)
                .font(.system(size: PanelMetrics.timeFont, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 50, alignment: .trailing)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(trailingHelp)
    }

    /// §4.2's end time lives here now rather than on a line of its own, which
    /// cost more vertical space than it earned.
    private var trailingHelp: String {
        guard isSeekable else { return "This track has no duration" }
        var parts = ["Track length \(TimeFormatting.total(duration))"]
        if isPlaying {
            parts.append(TimeFormatting.endTime(remaining: max(0, duration - displayPosition())))
        } else {
            parts.append("paused")
        }
        parts.append("click to switch")
        return parts.joined(separator: " — ")
    }

    private var trailingText: String {
        guard isSeekable else { return hasTrack ? "--:--" : "" }
        if model?.showsTotalTime == true {
            return TimeFormatting.total(duration)
        }
        return TimeFormatting.remaining(max(0, duration - displayPosition()), trackDuration: duration)
    }



    // MARK: - Track

    private var trackArea: some View {
        trackBody
            .frame(height: interactiveHeight)
            .frame(maxWidth: .infinity)
    }

    /// Static structure. None of this is rebuilt to move the thumb.
    private var trackBody: some View {
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
                    ticker {
                        fill
                        thumb(width: width)
                    }
                } else {
                    // §4.2's stream case: indeterminate, and not seekable.
                    IndeterminateBar(height: trackHeight, isAnimating: isPlaying)
                }
            }
            .frame(maxHeight: .infinity)
            .onHover { isHovering = $0 }
            .gesture(dragGesture(width: width))
            .overlay(alignment: .topLeading) {
                if let dragPosition {
                    TimeBubble(text: TimeFormatting.position(dragPosition, trackDuration: duration))
                        .offset(x: bubbleOffset(width: width, progress: renderProgress), y: -22)
                }
            }
        }
    }

    /// A scaleEffect rather than a width: a transform Core Animation can
    /// interpolate without re-running layout every frame.
    private var fill: some View {
        Capsule()
            .fill(.tint)
            .frame(height: trackHeight)
            .scaleEffect(x: max(0.0001, renderProgress), y: 1, anchor: .leading)
            .clipShape(Capsule())
    }

    private func thumb(width: CGFloat) -> some View {
        Circle()
            .fill(.white)
            // No .shadow(): it forces an offscreen pass every time the thumb
            // moves. A hairline border reads as well against the track.
            .overlay(Circle().strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
            .frame(width: thumbDiameter, height: thumbDiameter)
            .offset(x: width * renderProgress - thumbDiameter / 2)
            .opacity(isHovering || dragPosition != nil ? 1 : 0.9)
    }

    /// Advances the moving parts while something is playing.
    ///
    /// INTERIM. Measured on a Mac Studio M1, 20 s windows, playing:
    ///
    ///     static bar (no motion)        0.45%
    ///     this ticker at 2 Hz           1.13%
    ///     this ticker at 5-30 Hz        5.1-5.7%
    ///     SwiftUI .animation            6.4-8.8%
    ///
    /// Everything that moves the thumb through SwiftUI runs on the main thread,
    /// including `.animation` — SwiftUI drives its own interpolation rather than
    /// handing the transform to Core Animation, so animating cost *more* than
    /// ticking, not less. 2 Hz is the honest compromise until the bar is drawn
    /// with CALayers, where the render server can interpolate for free. See §7.4.
    @ViewBuilder
    private func ticker<Content: View>(@ViewBuilder _ content: @escaping () -> Content) -> some View {
        if isPlaying {
            TimelineView(.periodic(from: .now, by: Self.thumbRefreshInterval)) { _ in
                ZStack(alignment: .leading) { content() }
            }
        } else {
            ZStack(alignment: .leading) { content() }
        }
    }

    /// Where the thumb should be drawn now.
    private var renderProgress: Double {
        guard isSeekable else { return 0 }
        if let dragPosition { return clamp(dragPosition / duration) }
        return clamp(clock.position() / duration)
    }

    private func clamp(_ value: Double) -> Double { min(max(0, value), 1) }

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
    private func bubbleOffset(width: CGFloat, progress: Double) -> CGFloat {
        let bubbleWidth: CGFloat = 46
        let ideal = width * progress - bubbleWidth / 2
        return min(max(0, ideal), max(0, width - bubbleWidth))
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
                .fill(.tint.opacity(isAnimating ? 0.65 : 0.3))
                .frame(width: geometry.size.width * (isAnimating ? 0.3 : 1), height: height)
                .offset(x: isAnimating ? geometry.size.width * phase : 0)
        }
        .frame(height: height)
        .clipShape(Capsule())
        .onAppear { if isAnimating { start() } }
        .onChange(of: isAnimating) { _, animating in animating ? start() : stop() }
    }

    private func start() {
        phase = -0.4
        withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: false)) {
            phase = 1.1
        }
    }

    /// A `repeatForever` animation does not end on its own. Without explicitly
    /// replacing it with a zero-duration change, the bar carried on sliding
    /// after playback stopped — which looked exactly like the panel was still
    /// seeking through a track that had finished.
    private func stop() {
        withAnimation(.linear(duration: 0)) {
            phase = -0.4
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
