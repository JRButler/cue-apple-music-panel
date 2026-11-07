//
//  AppDelegate.swift
//  Cue
//
//  M0 lifecycle. Two modes:
//    (no arguments)  status item + debug window, for watching events live
//    --probe         run the M0 measurement sequence to stdout, then exit
//
//  The probe exists so M0's acceptance criteria can be checked from a shell and
//  pasted into CLAUDE.md, rather than read off a window by eye.
//

import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let controller = M0Controller()
    private var statusItem: StatusItemController?
    private var debugWindow: DebugWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let options = LaunchOptions(arguments: CommandLine.arguments)

        controller.start()

        if options.isProbe {
            Task {
                let probe = M0Probe(controller: controller, options: options)
                await probe.run()
                exit(probe.exitCode)
            }
            return
        }

        statusItem = StatusItemController(
            showDebugWindow: { [weak self] in self?.presentDebugWindow() },
            quit: { NSApp.terminate(nil) }
        )

        presentDebugWindow()
        Task { await controller.resync(reason: "launch") }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stop()
    }

    private func presentDebugWindow() {
        if debugWindow == nil {
            debugWindow = DebugWindowController(controller: controller)
        }
        debugWindow?.present()
    }
}

/// Parsed command line. Keeps argument handling out of the delegate body.
struct LaunchOptions: Sendable {
    var isProbe = false
    /// Seconds to keep listening for `playerInfo` after the probe's fixed
    /// sequence, so a track change can be caught and timed.
    var listenSeconds: Int = 0
    var latencySamples: Int = 100

    init(arguments: [String]) {
        var iterator = arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--probe":
                isProbe = true
            case "--listen":
                if let value = iterator.next(), let seconds = Int(value) { listenSeconds = seconds }
            case "--samples":
                if let value = iterator.next(), let count = Int(value) { latencySamples = count }
            default:
                break
            }
        }
    }
}
