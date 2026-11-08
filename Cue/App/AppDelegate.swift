//
//  AppDelegate.swift
//  Cue
//
//  Lifecycle. Normal launch shows the §4.1 panel; the rest are M0/M1
//  diagnostics, which build their own harness and never create a panel.
//
//  Modes:
//    (no arguments)  status item + floating panel
//    --grant         raise the Automation prompt and wait for an answer, then exit
//    --deny          same prompt, but asking for a refusal, to test §5's state
//    --bench         time fetchState variants against each other, then exit
//    --watch         trigger a track change and report every notification seen
//    --probe         run the M0 measurement sequence to stdout, then exit
//
//  The probe exists so M0's acceptance criteria can be checked from a shell and
//  pasted into CLAUDE.md, rather than read off a window by eye.
//

import AppKit
import OSLog

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// The real app.
    private var model: PlayerModel?
    private var panel: PanelController?
    private var statusItem: StatusItemController?

    /// Diagnostics only, and only in a diagnostic mode. Kept separate from
    /// PlayerModel so the two never poll Music at the same time.
    private var diagnostics: M0Controller?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let options = LaunchOptions(arguments: CommandLine.arguments)

        if options.isDiagnostic {
            runDiagnostics(options)
            return
        }

        let model = PlayerModel()
        self.model = model

        let panel = PanelController(model: model)
        self.panel = panel

        statusItem = StatusItemController(
            togglePanel: { panel.toggle() },
            quit: { NSApp.terminate(nil) }
        )

        model.start()
        panel.show()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.stop()
        diagnostics?.stop()
    }

    /// §4.1: using the panel must never activate Cue. An accessory app going
    /// active means something pulled focus, so it is logged as a failure.
    func applicationDidBecomeActive(_ notification: Notification) {
        Logger(subsystem: Bundle.main.bundleIdentifier ?? "nz.slstudio.Cue", category: "Focus")
            .warning("FOCUS: Cue became the active application — should not happen in ordinary use")
    }

    private func runDiagnostics(_ options: LaunchOptions) {
        let controller = M0Controller()
        diagnostics = controller
        controller.start()

        if options.isGrant || options.isDeny {
            let probe = M0Probe(controller: controller, options: options)
            probe.runGrant(expectingRefusal: options.isDeny)
            exit(probe.exitCode)
        }

        if options.isBench {
            Task {
                let probe = M0Probe(controller: controller, options: options)
                await probe.runBenchmark()
                exit(probe.exitCode)
            }
            return
        }

        if options.isTestClock {
            let probe = M0Probe(controller: controller, options: options)
            probe.runClockTests()
            exit(probe.exitCode)
        }

        if options.isMuteProbe {
            Task {
                let probe = M0Probe(controller: controller, options: options)
                await probe.runMuteProbe()
                exit(probe.exitCode)
            }
            return
        }

        if options.isDumpRecords {
            Task {
                let probe = M0Probe(controller: controller, options: options)
                await probe.runDumpRecords()
                exit(probe.exitCode)
            }
            return
        }

        if options.isWatch {
            Task {
                let probe = M0Probe(controller: controller, options: options)
                await probe.runWatch()
                exit(probe.exitCode)
            }
            return
        }

        if options.isProbe {
            Task {
                let probe = M0Probe(controller: controller, options: options)
                await probe.run()
                exit(probe.exitCode)
            }
            return
        }
    }
}

/// Parsed command line. Keeps argument handling out of the delegate body.
struct LaunchOptions: Sendable {
    var isProbe = false
    /// One-time permission bootstrap. Prompts and waits for an answer.
    var isGrant = false
    /// Times fetchState variants against each other.
    var isBench = false
    /// Triggers a real track change and reports every notification it produces.
    var isWatch = false
    /// Raises the prompt expecting a refusal, to exercise §5's denied state.
    var isDeny = false
    /// Dumps the structure of Music's `properties` records.
    var isDumpRecords = false
    /// Runs PlaybackClock's numeric checks. Needs neither Music nor permission.
    var isTestClock = false
    /// Investigates §4.6's mute refusal.
    var isMuteProbe = false
    /// Seconds to keep listening for `playerInfo` after the probe's fixed
    /// sequence, so a track change can be caught and timed.
    var listenSeconds: Int = 0
    var latencySamples: Int = 100

    /// True for any mode that should not build a panel.
    var isDiagnostic: Bool {
        isProbe || isGrant || isDeny || isBench || isWatch || isDumpRecords || isTestClock || isMuteProbe
    }

    init(arguments: [String]) {
        var iterator = arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--probe":
                isProbe = true
            case "--grant":
                isGrant = true
            case "--bench":
                isBench = true
            case "--watch":
                isWatch = true
            case "--deny":
                isDeny = true
            case "--dump-records":
                isDumpRecords = true
            case "--test-clock":
                isTestClock = true
            case "--probe-mute":
                isMuteProbe = true
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
