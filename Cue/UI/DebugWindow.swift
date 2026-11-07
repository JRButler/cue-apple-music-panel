//
//  DebugWindow.swift
//  Cue
//
//  M0's entire UI. An ordinary titled NSWindow — explicitly not the §4.1 panel,
//  which is M1's job. This exists to drive the bridge by hand and watch the
//  event stream; it is deleted once PanelView can do the same.
//

import AppKit
import SwiftUI

@MainActor
final class DebugWindowController {

    private let window: NSWindow

    init(controller: M0Controller) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Cue — M0 Bridge Spike"
        window.contentViewController = NSHostingController(rootView: DebugView(controller: controller))
        window.setContentSize(NSSize(width: 820, height: 640))
        window.center()
        window.isReleasedWhenClosed = false
    }

    func present() {
        window.makeKeyAndOrderFront(nil)
        // An accessory app has to activate explicitly to come to the front. This
        // is fine for a debug window; §4.1's panel must never do it.
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - View

private struct DebugView: View {

    let controller: M0Controller

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StatusHeader(controller: controller)
            Divider()
            ActionBar(controller: controller)
            Divider()
            StateReadout(controller: controller)
            Divider()
            LogList(entries: controller.log.entries)
        }
        .padding(16)
        .frame(minWidth: 680, minHeight: 520)
    }
}

// MARK: - Header

private struct StatusHeader: View {

    let controller: M0Controller

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 20) {
            Badge(
                label: "Music",
                value: controller.isMusicRunning ? "running" : "not running",
                tint: controller.isMusicRunning ? .green : .secondary
            )
            Badge(
                label: "Automation",
                value: permissionText,
                tint: permissionTint
            )
            Badge(
                label: "Guarded calls",
                value: "\(controller.guardedCallCount)",
                tint: .secondary
            )
            Badge(
                label: "playerInfo",
                value: "\(controller.playerInfoCount)",
                tint: controller.playerInfoCount > 0 ? .green : .secondary
            )
            Spacer()
        }
    }

    private var permissionText: String {
        switch controller.permission {
        case .granted: "granted"
        case .denied: "denied"
        case .notDetermined: "not asked"
        case .musicNotRunning: "n/a"
        case let .unknown(status): "? \(status)"
        }
    }

    private var permissionTint: Color {
        switch controller.permission {
        case .granted: .green
        case .denied: .red
        case .notDetermined: .orange
        default: .secondary
        }
    }
}

private struct Badge: View {
    let label: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.body, design: .rounded).weight(.medium))
                .foregroundStyle(tint)
        }
    }
}

// MARK: - Actions

private struct ActionBar: View {

    let controller: M0Controller

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button("Fetch State") { Task { await controller.resync(reason: "manual") } }
                Button("Play/Pause") { Task { await controller.playPause() } }
                Button("Previous") { Task { await controller.previous() } }
                Button("Next") { Task { await controller.next() } }
                Button("−10 s") { Task { await controller.seek(by: -10) } }
                Button("+10 s") { Task { await controller.seek(by: 10) } }
            }
            HStack(spacing: 8) {
                Button("Measure Latency (×100)") { Task { await controller.measureLatency() } }
                Button("Probe favorited / loved") { Task { await controller.probeFavourite() } }
                Button("Re-check Permission") { controller.refreshEnvironment() }
                Button("Open Music") { Task { await controller.openMusic() } }
                Button("Automation Settings…") { controller.openAutomationSettings() }
                Spacer()
                Button("Clear Log") { controller.log.clear() }
            }
        }
    }
}

// MARK: - State

private struct StateReadout: View {

    let controller: M0Controller

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let state = controller.lastState {
                HStack(spacing: 16) {
                    Text(state.playerState.rawValue)
                        .font(.system(.body, design: .rounded).weight(.semibold))
                    Text(positionText(state))
                        .monospacedDigit()
                    Text("vol \(state.volume)")
                    Text("shuffle \(state.isShuffling ? "on" : "off")")
                    Text("repeat \(state.repeatMode.rawValue)")
                }
                .font(.callout)

                if let track = state.track {
                    Text("\(track.name) — \(track.artist) — \(track.album)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text("persistent ID \(track.persistentID.isEmpty ? "(none)" : track.persistentID)"
                        + (track.isSeekable ? "" : "   · no duration, seeking disabled"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("no current track")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("no state yet")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let latency = controller.latency {
                Text(latency.summary)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if let probe = controller.favouriteProbe {
                Text(probe)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = controller.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func positionText(_ state: MusicState) -> String {
        guard let position = state.position else { return "pos —" }
        guard let duration = state.track?.duration, duration > 0 else {
            return String(format: "pos %.1f s", position)
        }
        return String(format: "pos %.1f / %.1f s", position, duration)
    }
}

// MARK: - Log

private struct LogList: View {

    let entries: [EventLog.Entry]

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(entries) { entry in
                    HStack(alignment: .top, spacing: 8) {
                        Text(Self.formatter.string(from: entry.at))
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                        Text(entry.category.rawValue)
                            .foregroundStyle(tint(entry.category))
                            .frame(width: 54, alignment: .leading)
                        Text(entry.message)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.system(size: 11, design: .monospaced))
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 6))
    }

    private func tint(_ category: EventLog.Category) -> Color {
        switch category {
        case .lifecycle: .secondary
        case .notification: .blue
        case .bridge: .green
        case .measurement: .purple
        case .failure: .red
        }
    }
}
