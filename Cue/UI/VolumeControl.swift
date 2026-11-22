//
//  VolumeControl.swift
//  Cue
//
//  §4.6's volume: Music's own `sound volume`, 0–100, not the system level.
//
//  Built by hand rather than with SwiftUI's `Slider` for the same reason as the
//  scrub bar: §4.6 sets a 160 pt minimum width and a 20 pt interactive height,
//  and needs the drag distinguished from its release so that updates can be
//  throttled to 15 Hz with a final value on commit. A stock Slider gives no
//  control over any of that.
//
//  Nothing here redraws continuously — it repaints when the value changes, on
//  drag or on sync, so it costs nothing at rest.
//

import SwiftUI

struct VolumeControl: View {

    let volume: Int
    let isMuted: Bool
    let isEnabled: Bool

    /// `committing` is false during a drag and true on release, so the model can
    /// apply §4.6's 15 Hz ceiling and still always send the final value.
    let onChange: (Int, Bool) -> Void
    let onToggleMute: () -> Void
    /// §4.6: scrolling adjusts in steps of 2.
    let onNudge: (Int) -> Void

    @State private var dragValue: Int?

    /// §4.6's minimums.
    static let minimumTrackWidth: CGFloat = 160
    private let interactiveHeight: CGFloat = 22
    private let trackHeight: CGFloat = 4
    private let thumbDiameter: CGFloat = 11

    private var displayValue: Int { dragValue ?? volume }
    private var progress: Double { Double(displayValue) / 100 }

    var body: some View {
        HStack(spacing: 8) {
            // §4.6: the low icon toggles mute.
            Button(action: onToggleMute) {
                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.fill")
                    .font(.system(size: PanelMetrics.volumeGlyph))
                    .foregroundStyle(isMuted ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .frame(width: 22, height: interactiveHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isMuted ? "Unmute" : "Mute")

            track
                .frame(minWidth: Self.minimumTrackWidth, maxWidth: .infinity)
                .frame(height: interactiveHeight)

            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: PanelMetrics.volumeGlyph))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: interactiveHeight)
        }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
    }

    private var track: some View {
        GeometryReader { geometry in
            let width = geometry.size.width

            ZStack(alignment: .leading) {
                // The full height is hit-testable, not just the 4 pt track.
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())

                Capsule()
                    .fill(.quaternary)
                    .frame(height: trackHeight)

                Capsule()
                    .fill(isMuted ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.tint))
                    .frame(width: max(trackHeight, width * progress), height: trackHeight)

                Circle()
                    .fill(.white)
                    .overlay(Circle().strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
                    .frame(width: thumbDiameter, height: thumbDiameter)
                    .offset(x: width * progress - thumbDiameter / 2)
            }
            .frame(maxHeight: .infinity)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let next = level(fromX: value.location.x, width: width)
                        dragValue = next
                        onChange(next, false)
                    }
                    .onEnded { value in
                        let next = level(fromX: value.location.x, width: width)
                        dragValue = nil
                        // §4.6's final value on release.
                        onChange(next, true)
                    }
            )
            // §4.6: steps of 2 per scroll notch.
            .onScrollWheel { delta in
                guard delta != 0 else { return }
                onNudge(delta > 0 ? 2 : -2)
            }
        }
    }

    private func level(fromX x: CGFloat, width: CGFloat) -> Int {
        guard width > 0 else { return displayValue }
        let fraction = min(max(0, x / width), 1)
        return Int((fraction * 100).rounded())
    }
}

// MARK: - Scroll wheel

/// SwiftUI has no scroll-wheel hook for a non-scrolling view, so §4.6's
/// scroll-to-adjust needs a thin AppKit view sitting over the slider.
private struct ScrollWheelCatcher: NSViewRepresentable {
    let onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.onScroll = onScroll
    }

    final class CatcherView: NSView {
        var onScroll: ((CGFloat) -> Void)?

        override func scrollWheel(with event: NSEvent) {
            // Vertical or horizontal, whichever the device reports, so a
            // trackpad two-finger swipe and a wheel both work.
            let delta = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX)
                ? event.scrollingDeltaY
                : event.scrollingDeltaX
            if delta == 0 {
                super.scrollWheel(with: event)
            } else {
                onScroll?(delta)
            }
        }

        /// Clicks must fall through to the SwiftUI slider underneath.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

private extension View {
    func onScrollWheel(_ action: @escaping (CGFloat) -> Void) -> some View {
        overlay(ScrollWheelCatcher(onScroll: action))
    }
}
