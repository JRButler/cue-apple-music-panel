//
//  WindowDragging.swift
//  Cue
//
//  §4.1: the panel is movable by its background. Two cases, two mechanisms.
//
//  `WindowDragArea` covers genuinely empty background: an NSView reporting
//  `mouseDownCanMoveWindow`, sitting behind content that declines hit testing.
//
//  `WindowDragHandle` covers a view that must ALSO respond to clicks — the
//  artwork opens Music, the title lines open it on a double-click, and both
//  should still drag the panel. AppKit cannot do both on its own: once a view
//  says a press may move the window, that press never reaches the view.
//
//  The drag is handed to `performDrag(with:)` rather than driven from SwiftUI's
//  DragGesture, and that matters. A DragGesture reports its translation in the
//  view's own coordinate space, and that space moves with the window — so
//  moving the window changes the reported translation, which moves the window
//  again. The result is a visible feedback loop: the panel lags the pointer and
//  pops about. `performDrag` runs AppKit's own drag loop against screen
//  coordinates and has no such problem.
//
//  Click detection falls out of it for free: `performDrag` returns once the
//  mouse is released, so a press that left the window where it started was a
//  click rather than a drag.
//

import AppKit
import SwiftUI

/// Empty background: a press here moves the panel.
struct WindowDragArea: NSViewRepresentable {

    func makeNSView(context: Context) -> NSView { DragView() }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}

/// A view that both drags the panel and reports clicks that did not drag it.
struct WindowDragHandle: NSViewRepresentable {

    /// Clicks of at least this many taps trigger `onClick`. 1 for the artwork,
    /// 2 for the title lines.
    let requiredClicks: Int
    let onClick: () -> Void

    func makeNSView(context: Context) -> HandleView {
        let view = HandleView()
        view.requiredClicks = requiredClicks
        view.onClick = onClick
        return view
    }

    func updateNSView(_ nsView: HandleView, context: Context) {
        nsView.requiredClicks = requiredClicks
        nsView.onClick = onClick
    }

    final class HandleView: NSView {
        var requiredClicks = 1
        var onClick: (() -> Void)?

        /// How far the window may end up from where it started and still count
        /// as not having been dragged.
        private let slop: CGFloat = 2

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }

            let clicks = event.clickCount
            let before = window.frame.origin

            // AppKit's own drag loop. Returns on mouse-up.
            window.performDrag(with: event)

            let after = window.frame.origin
            let moved = hypot(after.x - before.x, after.y - before.y) > slop

            if !moved, clicks >= requiredClicks {
                onClick?()
            }
        }

        override func resetCursorRects() {
            // Nothing: the default arrow is right for both dragging and clicking.
        }
    }
}

extension View {
    /// Makes a view drag the panel, while a press that did not move it still
    /// counts as a click.
    func windowDraggable(requiredClicks: Int = 1, onClick: @escaping () -> Void) -> some View {
        overlay(WindowDragHandle(requiredClicks: requiredClicks, onClick: onClick))
    }
}
