//
//  WindowDragging.swift
//  Cue
//
//  §4.1: the panel is movable by its background. Two mechanisms are needed,
//  because two different problems are being solved.
//
//  `WindowDragArea` handles genuinely empty background: an NSView reporting
//  `mouseDownCanMoveWindow`, sitting behind content that declines hit testing.
//
//  This file handles the other case — a view that must ALSO respond to clicks.
//  The artwork opens Music, the title lines open Music on a double-click, and
//  both should still drag the panel. AppKit cannot do both: once a view says a
//  press may move the window, the press never reaches the view. So the drag is
//  driven by hand and a press that never travels far enough is treated as a
//  click instead.
//

import AppKit
import SwiftUI

/// Hands back the NSWindow hosting a SwiftUI view, so a gesture can move it.
private struct WindowReader: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ReaderView()
        view.onResolve = onResolve
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class ReaderView: NSView {
        var onResolve: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onResolve?(window)
        }

        /// Purely a probe; it must never take a click.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Drags the panel, while still delivering clicks that did not travel.
private struct DraggableWithClick: ViewModifier {

    let clickCount: Int
    let onClick: () -> Void

    /// How far a press may travel and still count as a click.
    private let slop: CGFloat = 3

    @State private var window: NSWindow?
    @State private var originAtStart: CGPoint?
    @State private var travelled: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .background(WindowReader { window = $0 })
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard let window else { return }
                        if originAtStart == nil {
                            originAtStart = window.frame.origin
                            travelled = 0
                        }
                        guard let start = originAtStart else { return }
                        travelled = max(travelled, hypot(value.translation.width, value.translation.height))
                        guard travelled > slop else { return }
                        // SwiftUI's y grows downward, an NSWindow origin upward.
                        window.setFrameOrigin(CGPoint(
                            x: start.x + value.translation.width,
                            y: start.y - value.translation.height
                        ))
                    }
                    .onEnded { value in
                        let moved = max(travelled, hypot(value.translation.width, value.translation.height)) > slop
                        originAtStart = nil
                        travelled = 0
                        // A press that stayed put was a click, not a drag.
                        if !moved, clickCount == 1 {
                            onClick()
                        }
                    }
            )
            // A double-click target keeps its own gesture: the drag above only
            // claims single presses that did not travel.
            .onTapGesture(count: clickCount == 1 ? 2 : clickCount) {
                if clickCount != 1 { onClick() }
            }
    }
}

extension View {
    /// Makes a view drag the panel, while a press that does not travel still
    /// counts as a click. `clickCount` of 1 fires on release; 2 uses a tap
    /// gesture, leaving single presses to the drag.
    func windowDraggable(clickCount: Int = 1, onClick: @escaping () -> Void) -> some View {
        modifier(DraggableWithClick(clickCount: clickCount, onClick: onClick))
    }
}
