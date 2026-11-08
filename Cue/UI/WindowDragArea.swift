//
//  WindowDragArea.swift
//  Cue
//
//  §4.1 asks for the panel to be movable by its background, and
//  `isMovableByWindowBackground` alone does not deliver that here.
//
//  AppKit only drags the window when the click lands on a view whose
//  `mouseDownCanMoveWindow` is true. Inside an NSHostingView the click lands on
//  SwiftUI's own layer, and a filled Shape — the panel's vibrancy background is
//  one — is hit-testable, so it swallows the press and the window never moves.
//  The visible result is a panel that can only be dragged by the slim
//  transparent titlebar.
//
//  Two halves to the fix, and both are needed:
//    · this view, sitting *behind* the content, reports that a press on it may
//      move the window
//    · the vibrancy layer above it is marked `allowsHitTesting(false)`, so a
//      press on empty panel background falls through to this view
//
//  Controls keep their own hit testing, so buttons and sliders are unaffected.
//

import AppKit
import SwiftUI

struct WindowDragArea: NSViewRepresentable {

    func makeNSView(context: Context) -> NSView { DragView() }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        /// Dragging the window explicitly, rather than relying only on
        /// `mouseDownCanMoveWindow`, keeps the mouse grabbed for the duration.
        /// Without it the pointer's motion also reaches whatever is underneath —
        /// dragging the panel across Music made its rows light up under the
        /// cursor, which looks like the panel is interacting with them.
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}
