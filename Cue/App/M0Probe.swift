//
//  M0Probe.swift
//  Cue
//
//  Runs M0's acceptance criteria as a headless sequence and prints a verdict,
//  so the numbers that go into CLAUDE.md are measured rather than estimated.
//
//  Run it from the built bundle, never from a loose binary: Automation access is
//  granted to a code signature, so `Cue.app/Contents/MacOS/Cue --probe` keeps the
//  same TCC identity as the real app and reuses the grant.
//

import AppKit
import Foundation

@MainActor
final class M0Probe {

    private let controller: M0Controller
    private let options: LaunchOptions
    private var failures: [String] = []
    private var skipped: [String] = []

    var exitCode: Int32 { failures.isEmpty ? 0 : 1 }

    /// The report is duplicated to a file because the probe is launched with
    /// `open`, which gives the app no usable stdout. See tools/run-probe.sh.
    private let reportURL: URL
    private var reportHandle: FileHandle?

    init(controller: M0Controller, options: LaunchOptions) {
        self.controller = controller
        self.options = options

        let directory = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Cue", isDirectory: true)
        reportURL = directory.appendingPathComponent("m0-probe-report.txt")

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Truncated per run: the report describes this run only.
        FileManager.default.createFile(atPath: reportURL.path, contents: nil)
        reportHandle = try? FileHandle(forWritingTo: reportURL)
    }

    /// Writes one report line to stdout and to the report file.
    private func emit(_ line: String = "") {
        print(line)
        fflush(stdout)
        reportHandle?.write(Data((line + "\n").utf8))
    }

    func run() async {
        heading("M0 — bridge spike probe")
        emit("Cue \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")"
            + "  bundle \(Bundle.main.bundleIdentifier ?? "?")")
        emit("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        emit("")

        await checkErrorMapping()
        await checkScriptsCompiled()
        await checkGuardWhenMusicClosed()
        await checkPermission()
        await checkFetchState()
        await checkFavouriteProperty()
        await checkLatency()
        await listenForNotifications()

        printVerdict()
    }

    /// One-time permission bootstrap.
    ///
    /// Deliberately does NOT send an Apple Event. Sending one does raise the
    /// prompt, but the event carries our `with timeout` and gives up after a
    /// couple of seconds, and the dialog goes with the process when it exits —
    /// so a human never gets a chance to answer it.
    /// `AEDeterminePermissionToAutomateTarget(askUserIfNeeded: true)` is the
    /// purpose-built call: it raises the same prompt and blocks until answered,
    /// with no event and no timeout.
    func runGrant(expectingRefusal: Bool = false) {
        heading("Automation permission")

        guard controller.bridge.isMusicRunning else {
            fail("Music is not running. Open Music first — there is nothing to ask about.")
            printVerdict()
            return
        }

        let before = controller.bridge.automationPermission(askIfNeeded: false)
        emit("  Current state: \(Self.describe(before))")

        if before == .granted, !expectingRefusal {
            pass("already granted — nothing to do")
            printVerdict()
            return
        }
        if before == .granted, expectingRefusal {
            fail("still granted. Run `tccutil reset AppleEvents nz.slstudio.Cue` first, "
                + "otherwise no prompt is raised.")
            printVerdict()
            return
        }

        emit("")
        if expectingRefusal {
            emit("  Raising the prompt now. Click DON'T ALLOW — this run is")
            emit("  deliberately testing the refusal path. Waiting…")
        } else {
            emit("  Raising the prompt now. Look for a dialog saying Cue wants to")
            emit("  control Music, and click OK. Waiting…")
        }
        emit("")

        let after = controller.bridge.automationPermission(askIfNeeded: true)

        switch after {
        case .granted:
            expectingRefusal
                ? fail("granted, but this run wanted a refusal — click DON'T ALLOW")
                : pass("granted — run the probe next")
        case .denied:
            expectingRefusal
                ? pass("refused, as asked. §5's denied state is now reachable; "
                    + "run the probe to see it reported, then --grant to restore.")
                : fail("refused. Re-enable Cue under System Settings → Privacy & Security → Automation.")
        case .notDetermined:
            fail("still undetermined — the prompt was dismissed without an answer.")
        case .musicNotRunning:
            fail("Music quit while we were asking.")
        case let .unknown(status):
            fail("unexpected OSStatus \(status)")
        }

        printVerdict()
    }

    private static func describe(_ permission: AutomationPermission) -> String {
        switch permission {
        case .granted: "granted"
        case .denied: "denied"
        case .notDetermined: "not yet determined"
        case .musicNotRunning: "Music not running"
        case let .unknown(status): "unknown (OSStatus \(status))"
        }
    }

    /// Times each `M0Benchmark` variant and prints a table, so the shape of the
    /// ~90 ms `fetchState()` cost is visible rather than guessed at.
    func runBenchmark() async {
        heading("fetchState() variants")

        guard controller.bridge.isMusicRunning else {
            fail("Music is not running")
            printVerdict()
            return
        }

        let samples = max(10, options.latencySamples)
        emit("  \(samples) samples each. Expected events assume one Apple Event per reference.")
        emit("")
        emit(String(format: "  %-26s %5s  %8s  %8s  %8s   %s",
                    ("variant" as NSString).utf8String!,
                    ("evts" as NSString).utf8String!,
                    ("min" as NSString).utf8String!,
                    ("median" as NSString).utf8String!,
                    ("p95" as NSString).utf8String!,
                    ("ms/event" as NSString).utf8String!))
        emit("  " + String(repeating: "─", count: 76))

        var results: [(M0Benchmark.Variant, MusicBridge.LatencyReport)] = []

        for variant in M0Benchmark.variants {
            do {
                let report = try controller.bridge.benchmarkAdHoc(source: variant.source, samples: samples)
                results.append((variant, report))
                let perEvent = report.medianMS / Double(variant.expectedEvents)
                emit(String(format: "  %-26@ %5d  %7.1f  %7.1f  %7.1f   %7.1f",
                            variant.name as NSString,
                            variant.expectedEvents,
                            report.minMS, report.medianMS, report.p95MS, perEvent))
            } catch {
                fail("\(variant.name): \((error as? MusicBridgeError)?.localizedDescription ?? "\(error)")")
            }
        }

        emit("")
        heading("What each variant was testing")
        for variant in M0Benchmark.variants {
            emit("  \(variant.name)")
            emit("      \(variant.rationale)")
        }

        // The decisive comparison: does collapsing references collapse the time?
        if let current = results.first(where: { $0.0.name == "ten-references" }),
           let candidate = results.first(where: { $0.0.name == "SHIPPED-poll" }) {
            heading("Verdict on the hypothesis")
            let factor = current.1.medianMS / max(candidate.1.medianMS, 0.001)
            emit(String(format: "  today, polled at 1 Hz (10 references):  %.1f ms median", current.1.medianMS))
            emit(String(format: "  proposed 1 Hz hot path (position only): %.1f ms median", candidate.1.medianMS))
            emit(String(format: "  speed-up: %.1fx", factor))
            if candidate.1.p95MS < 10 {
                pass(String(format: "candidate p95 %.1f ms is inside §3.1's 10 ms budget", candidate.1.p95MS))
            } else {
                note(String(format: "candidate p95 %.1f ms still exceeds 10 ms — needs another approach", candidate.1.p95MS))
            }
        }

        printVerdict()
    }

    /// Settles §3.2 without needing anyone at the keyboard.
    ///
    /// A listen-only run cannot tell "the notification name is wrong" from
    /// "nothing happened in Music", so this drives a real track change with the
    /// M0 commands and then restores the position.
    func runWatch() async {
        heading("playerInfo discovery (§3.2)")

        guard controller.bridge.isMusicRunning else {
            fail("Music is not running")
            printVerdict()
            return
        }

        await controller.resync(reason: "watch baseline")
        guard let baseline = controller.lastState else {
            fail("could not read a baseline state")
            printVerdict()
            return
        }

        let originalPosition = baseline.position
        emit("  Baseline: \(baseline.playerState.rawValue), \"\(baseline.track?.name ?? "(none)")\""
            + (originalPosition.map { String(format: ", %.2f s", $0) } ?? ""))
        if baseline.playerState == .playing {
            note("Music is playing, so the track change will be audible.")
        }

        let countBefore = controller.playerInfoCount
        emit("")
        emit("  Triggering: next track →  wait  →  previous track")

        await controller.next()
        try? await Task.sleep(for: .seconds(2))
        await controller.previous()
        try? await Task.sleep(for: .seconds(2))

        if let originalPosition, baseline.track != nil {
            await controller.seek(to: originalPosition)
            emit(String(format: "  Restored position to %.2f s", originalPosition))
        }

        heading("Delivery")
        let delivered = controller.playerInfoCount - countBefore
        if delivered == 0 {
            fail("no playerInfo delivered during a real track change")
        } else {
            pass("\(delivered) notification(s) delivered via the block-based observer")
        }

        if !controller.observedPayloadKeys.isEmpty {
            heading("Payload keys (§3.2)")
            for key in controller.observedPayloadKeys { emit("  \(key)") }
        }

        if let payload = controller.lastPayload {
            heading("Last payload, normalised")
            for line in payload.fullDescription.split(separator: "\n", omittingEmptySubsequences: false) {
                emit("  \(line)")
            }
        }

        if let worst = controller.worstResyncMS {
            heading("M0's 200 ms criterion")
            let line = String(format: "worst notification → state logged: %.1f ms", worst)
            worst <= 200 ? pass(line) : fail(line + " (over 200 ms)")
        }

        printVerdict()
    }

    /// Prints the full structure of Music's `properties` records: every keyword,
    /// its descriptor type, and its value. The parser in MusicBridge is written
    /// against this output rather than against assumptions.
    func runDumpRecords() async {
        heading("properties record structure")

        guard controller.bridge.isMusicRunning else {
            fail("Music is not running")
            printVerdict()
            return
        }

        let sources: [(String, String)] = [
            ("application", """
            with timeout of 5 seconds
                tell application id "com.apple.Music" to return properties
            end timeout
            """),
            ("current track", """
            with timeout of 5 seconds
                tell application id "com.apple.Music" to return properties of current track
            end timeout
            """),
        ]

        for (label, source) in sources {
            heading("properties of \(label)")
            do {
                let descriptor = try controller.bridge.rawDescriptor(source: source)
                emit("  descriptorType: \(AEKeyword(descriptor.descriptorType).fourCharText)"
                    + "   fields: \(descriptor.numberOfItems)")
                emit("")
                emit(String(format: "  %-6@ %-10@ %@", "code" as NSString, "type" as NSString, "value" as NSString))
                emit("  " + String(repeating: "─", count: 70))

                guard descriptor.numberOfItems > 0 else {
                    fail("\(label) returned no fields — is a track loaded?")
                    continue
                }

                for index in 1 ... descriptor.numberOfItems {
                    let keyword = descriptor.keywordForDescriptor(at: index)
                    guard let field = descriptor.forKeyword(keyword) else { continue }
                    let type = AEKeyword(field.descriptorType).fourCharText
                    emit(String(format: "  %-6@ %-10@ %@",
                                AEKeyword(keyword).fourCharText as NSString,
                                type as NSString,
                                Self.render(field) as NSString))
                }
            } catch {
                fail("\(label): \((error as? MusicBridgeError)?.localizedDescription ?? "\(error)")")
            }
        }

        printVerdict()
    }

    /// Renders a field whichever way its descriptor type suggests, so the output
    /// shows which accessor the parser should use.
    private static func render(_ field: NSAppleEventDescriptor) -> String {
        let type = AEKeyword(field.descriptorType).fourCharText
        switch type {
        case "enum", "type":
            return "\(AEKeyword(field.enumCodeValue).fourCharText)  (enumCodeValue)"
        case "utxt", "TEXT":
            let text = field.stringValue ?? "<nil>"
            return "\"\(text.count > 60 ? String(text.prefix(60)) + "…" : text)\""
        case "doub", "sing":
            return String(format: "%.4f  (doubleValue)", field.doubleValue)
        case "long", "shor", "comp", "magn":
            return "\(field.int32Value)  (int32Value)"
        case "bool", "true", "fals":
            return "\(field.booleanValue)  (booleanValue)"
        case "msng":
            return "missing value"
        case "obj ", "reco", "list":
            return "<\(type), \(field.numberOfItems) item(s)>"
        default:
            if let text = field.stringValue { return "\"\(text)\"  (stringValue)" }
            return "<\(type)>"
        }
    }

    /// PlaybackClock's numeric checks. Pure arithmetic — no Music, no permission.
    func runClockTests() {
        heading("PlaybackClock (§3.3, §4.2)")

        let results = M1ClockTests.runAll()
        for result in results {
            if result.passed {
                pass("\(result.name) — \(result.detail)")
            } else {
                fail("\(result.name) — \(result.detail)")
            }
        }
        emit("")
        emit("  \(results.filter(\.passed).count)/\(results.count) passed")
        printVerdict()
    }

    // MARK: - Checks

    /// Verifies every row of §3.1's error table without provoking each condition.
    /// A real refusal needs a human to click Don't Allow; a real -1712 needs
    /// Music to hang. The mapping itself can be checked directly.
    private func checkErrorMapping() async {
        heading("0. Error mapping (§3.1)")

        let cases: [(code: Int, expected: MusicBridgeError, label: String)] = [
            (-1743, .automationDenied, "errAEEventNotPermitted"),
            (-1744, .automationDenied, "errAEEventWouldRequireUserConsent"),
            (-600, .musicNotRunning, "procNotFound"),
            (-609, .musicNotRunning, "connectionInvalid"),
            (-1712, .timedOut, "errAETimeout"),
            (-1728, .scriptError(code: -1728, message: "synthetic"), "arbitrary → scriptError"),
        ]

        for item in cases {
            let synthetic: NSDictionary = [
                NSAppleScript.errorNumber: NSNumber(value: item.code),
                NSAppleScript.errorMessage: "synthetic",
            ]
            let mapped = MusicBridge.mapError(synthetic)
            if mapped == item.expected {
                pass("\(item.code) \(item.label) → \(mapped)")
            } else {
                fail("\(item.code) \(item.label) mapped to \(mapped), expected \(item.expected)")
            }
        }
    }

    private func checkScriptsCompiled() async {
        heading("1. Script compilation")
        let failed = controller.bridge.compilationFailures
        if failed.isEmpty {
            pass("all \(MusicScript.allCases.count) scripts compiled")
        } else {
            for (script, reason) in failed.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                fail("\(script.rawValue) did not compile: \(reason)")
            }
        }
    }

    /// M0: "Music is never launched by Cue." The only honest test is to call
    /// every entry point with Music closed and confirm two things: each refuses,
    /// and Music is still closed afterwards.
    private func checkGuardWhenMusicClosed() async {
        heading("2. Running-app guard (§3.1)")

        guard !controller.bridge.isMusicRunning else {
            skip("Music is running, so the guard cannot be exercised. "
                + "Quit Music and re-run to test it.")
            return
        }

        let before = controller.bridge.guardedCallCount
        var unexpected: [String] = []

        for (label, call) in Self.guardedCalls(controller.bridge) {
            do {
                try await call()
                unexpected.append("\(label) returned without error")
            } catch MusicBridgeError.musicNotRunning {
                continue
            } catch {
                unexpected.append("\(label) threw \(error) instead of .musicNotRunning")
            }
        }

        let guarded = controller.bridge.guardedCallCount - before

        if !unexpected.isEmpty {
            for problem in unexpected { fail(problem) }
        } else {
            pass("\(guarded) call(s) refused with .musicNotRunning")
        }

        // The decisive part: did any of that start Music?
        if controller.bridge.isMusicRunning {
            fail("Music was launched by one of those calls")
        } else {
            pass("Music is still not running")
        }
    }

    private static func guardedCalls(_ bridge: MusicBridge) -> [(String, () async throws -> Void)] {
        [
            ("fetchState()", { _ = try await bridge.fetchState() }),
            ("playPause()", { try await bridge.playPause() }),
            ("next()", { try await bridge.next() }),
            ("previous()", { try await bridge.previous() }),
            ("seek(to:)", { try await bridge.seek(to: 0) }),
        ]
    }

    private func checkPermission() async {
        heading("3. Automation permission")
        controller.refreshEnvironment()

        switch controller.permission {
        case .granted:
            pass("granted")
        case .denied:
            fail("DENIED. Grant Cue access to Music in System Settings → "
                + "Privacy & Security → Automation, then re-run.")
        case .notDetermined:
            skip("not yet determined. The first event prompts; approve it and re-run.")
        case .musicNotRunning:
            skip("Music is not running, so there is nothing to ask about.")
        case let .unknown(status):
            fail("unexpected OSStatus \(status)")
        }
    }

    private func checkFetchState() async {
        heading("4. fetchState()")
        guard controller.bridge.isMusicRunning else {
            skip("Music is not running")
            return
        }

        await controller.resync(reason: "probe")

        if let error = controller.lastError {
            fail(error)
            return
        }
        guard let state = controller.lastState else {
            fail("no state returned")
            return
        }

        pass("player state: \(state.playerState.rawValue)")
        pass("volume: \(state.volume)   shuffle: \(state.isShuffling)   repeat: \(state.repeatMode.rawValue)")

        if let track = state.track {
            pass("track: \"\(track.name)\" — \(track.artist) — \(track.album)")
            pass("persistent ID: \(track.persistentID.isEmpty ? "(empty — streamed?)" : track.persistentID)")
            if track.duration > 0 {
                pass(String(format: "duration: %.2f s", track.duration))
            } else {
                note("duration is 0 or missing — §4.2's indeterminate-bar case")
            }
        } else {
            note("no current track (stopped with nothing queued)")
        }

        if let position = state.position {
            pass(String(format: "position: %.2f s", position))
        } else {
            note("position unavailable, expected while stopped")
        }
    }

    private func checkFavouriteProperty() async {
        heading("5. Favourite property name (§4.5)")
        guard controller.bridge.isMusicRunning else {
            skip("Music is not running")
            return
        }
        guard controller.lastState?.track != nil else {
            skip("no current track to read the property from")
            return
        }

        await controller.probeFavourite()
        if let probe = controller.favouriteProbe {
            pass(probe)
            note("the name that returns true/false is the one to use in M3")
        } else {
            fail(controller.lastError ?? "probe returned nothing")
        }
    }

    private func checkLatency() async {
        heading("6. fetchState() latency")
        guard controller.bridge.isMusicRunning else {
            skip("Music is not running")
            return
        }

        await controller.measureLatency(samples: options.latencySamples)
        guard let report = controller.latency else {
            fail(controller.lastError ?? "measurement failed")
            return
        }

        pass(report.summary)
        // §3.1 budgets each call at well under 10 ms.
        if report.p95MS < 10 {
            pass(String(format: "p95 %.1f ms is inside §3.1's 10 ms budget", report.p95MS))
        } else {
            note(String(format: "p95 %.1f ms exceeds §3.1's 10 ms budget — worth revisiting", report.p95MS))
        }
    }

    /// Track changes cannot be forced from here without disturbing playback, so
    /// this waits and reports anything that arrives, with its timing.
    private func listenForNotifications() async {
        heading("7. playerInfo notifications (§3.2)")

        guard options.listenSeconds > 0 else {
            skip("not listening. Pass --listen <seconds> and change track to survey the payload.")
            return
        }

        emit("Listening for \(options.listenSeconds)s — change track in Music now.")
        try? await Task.sleep(for: .seconds(options.listenSeconds))

        let count = controller.playerInfoCount
        if count == 0 {
            fail("no playerInfo notifications in \(options.listenSeconds)s. "
                + "Either nothing changed, or the notification name is wrong on this macOS.")
            return
        }

        pass("\(count) notification(s) received")
        pass("payload keys observed: \(controller.observedPayloadKeys.joined(separator: ", "))")

        if let worst = controller.worstResyncMS {
            let line = String(format: "worst notification → state logged: %.1f ms", worst)
            worst <= 200 ? pass(line + " (inside M0's 200 ms)") : fail(line + " (over M0's 200 ms)")
        }
    }

    // MARK: - Output

    private func printVerdict() {
        heading("Verdict")
        if !skipped.isEmpty {
            emit("Skipped \(skipped.count) check(s):")
            for item in skipped { emit("  – \(item)") }
            emit("")
        }
        if failures.isEmpty {
            emit("PASS — no failures\(skipped.isEmpty ? "" : ", but see the skipped checks above")")
        } else {
            emit("FAIL — \(failures.count) problem(s):")
            for item in failures { emit("  ✗ \(item)") }
        }
        if let url = controller.log.logFileURL {
            emit("")
            emit("Full log:   \(url.path)")
        }
        emit("This report: \(reportURL.path)")
        fflush(stdout)
        try? reportHandle?.close()
        reportHandle = nil
    }

    private func heading(_ title: String) {
        emit("")
        emit("── \(title) " + String(repeating: "─", count: max(0, 60 - title.count)))
    }

    private func pass(_ message: String) { emit("  ✓ \(message)") }
    private func note(_ message: String) { emit("  · \(message)") }

    private func fail(_ message: String) {
        failures.append(message)
        emit("  ✗ \(message)")
    }

    private func skip(_ message: String) {
        skipped.append(message)
        emit("  – \(message)")
    }
}
