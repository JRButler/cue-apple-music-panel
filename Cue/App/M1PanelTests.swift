//
//  M1PanelTests.swift
//  Cue
//
//  Numeric checks for §4.1's frame clamping, run with `--test-clock`.
//
//  The real condition — a saved frame on a display that is no longer attached —
//  needs hardware to be unplugged. The arithmetic does not, so it is tested with
//  synthetic screen rectangles instead.
//

import AppKit
import Foundation

@MainActor
struct M1PanelTests {

    /// A single 1920x1080 display with the menu bar accounted for.
    private static let oneScreen = [NSRect(x: 0, y: 0, width: 1920, height: 1055)]
    /// A second display to the right, as a saved frame might remember.
    private static let twoScreens = [
        NSRect(x: 0, y: 0, width: 1920, height: 1055),
        NSRect(x: 1920, y: 0, width: 1920, height: 1055),
    ]

    static func runAll() -> [M1ClockTests.Result] {
        var results: [M1ClockTests.Result] = []

        // Fully on-screen: left exactly alone.
        let onScreen = NSRect(x: 700, y: 120, width: 420, height: 104)
        results.append(same("a frame fully on-screen is untouched",
                            PanelController.clamped(onScreen, screens: oneScreen), onScreen))

        // Deliberately hanging off an edge is a position the user chose, and
        // "substantially visible" is the test, so it must survive.
        let slightlyOff = NSRect(x: -60, y: 120, width: 420, height: 104)
        results.append(same("a frame hanging slightly off an edge is left alone",
                            PanelController.clamped(slightlyOff, screens: oneScreen), slightlyOff))

        // Saved on a second display that is now gone: must come back.
        let onMissingScreen = NSRect(x: 2400, y: 300, width: 420, height: 104)
        let recovered = PanelController.clamped(onMissingScreen, screens: oneScreen)
        results.append(M1ClockTests.Result(
            name: "a frame on a detached display is pulled back on-screen",
            passed: oneScreen[0].contains(recovered),
            detail: "\(rect(recovered)) — must sit inside \(rect(oneScreen[0]))"
        ))

        // The same frame with that display still attached: left alone.
        results.append(same("a frame on a display that is still attached is untouched",
                            PanelController.clamped(onMissingScreen, screens: twoScreens), onMissingScreen))

        // Far off the bottom-left.
        let wayOff = NSRect(x: -5000, y: -4000, width: 420, height: 104)
        let pulled = PanelController.clamped(wayOff, screens: oneScreen)
        results.append(M1ClockTests.Result(
            name: "a wildly off-screen frame is pulled back",
            passed: oneScreen[0].contains(pulled),
            detail: "\(rect(pulled))"
        ))

        // Wider than the display it is being pulled onto.
        let tooWide = NSRect(x: -3000, y: 200, width: 4000, height: 104)
        let narrowed = PanelController.clamped(tooWide, screens: oneScreen)
        results.append(M1ClockTests.Result(
            name: "a frame wider than the display is narrowed to fit",
            passed: narrowed.width <= oneScreen[0].width && oneScreen[0].contains(narrowed),
            detail: "\(rect(narrowed)) — must fit inside \(rect(oneScreen[0]))"
        ))

        return results
    }

    private static func same(_ name: String, _ actual: NSRect, _ expected: NSRect) -> M1ClockTests.Result {
        M1ClockTests.Result(
            name: name,
            passed: actual.equalTo(expected),
            detail: actual.equalTo(expected) ? rect(actual) : "got \(rect(actual)), expected \(rect(expected))"
        )
    }

    private static func rect(_ r: NSRect) -> String {
        String(format: "(%.0f,%.0f %.0fx%.0f)", r.origin.x, r.origin.y, r.width, r.height)
    }
}
