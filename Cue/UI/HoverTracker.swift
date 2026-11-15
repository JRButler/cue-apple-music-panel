//
//  HoverTracker.swift
//  Cue
//
//  Hover reporting that survives the view moving under a stationary pointer.
//
//  SwiftUI's `.onHover` is driven by mouse-entered and mouse-exited events,
//  and macOS sends neither when a window resizes beneath a cursor that has not
//  moved. Collapsing the panel does exactly that: the chevron arrives under
//  the pointer having never been "entered", so it stays hidden until the mouse
//  leaves and comes back.
//
//  An NSTrackingArea has the same blind spot, so this additionally asks the
//  window where the pointer actually is whenever the tracking areas are
//  rebuilt — which AppKit does on every resize.
//

import AppKit
import SwiftUI

struct HoverTracker: NSViewRepresentable {

    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> TrackerView {
        let view = TrackerView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: TrackerView, context: Context) {
        nsView.onChange = onChange
    }

    final class TrackerView: NSView {
        var onChange: ((Bool) -> Void)?
        private var lastReported: Bool?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas { removeTrackingArea(area) }
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self
            ))
            // The event-based path cannot see a pointer that was already here,
            // so settle it by asking directly.
            report(pointerIsInside)
        }

        private var pointerIsInside: Bool {
            guard let window else { return false }
            let inWindow = window.mouseLocationOutsideOfEventStream
            return bounds.contains(convert(inWindow, from: nil))
        }

        override func mouseEntered(with event: NSEvent) { report(true) }
        override func mouseExited(with event: NSEvent) { report(false) }

        private func report(_ inside: Bool) {
            guard inside != lastReported else { return }
            lastReported = inside
            onChange?(inside)
        }

        /// Purely an observer; it must never take a click.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
