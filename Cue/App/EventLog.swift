//
//  EventLog.swift
//  Cue
//
//  M0 scaffolding. The debug window renders this, and every line also goes to
//  stdout and to ~/Library/Logs/Cue/m0-debug.log, so the milestone's numbers can
//  be read back from a shell instead of squinting at a window.
//
//  This is a milestone-0 instrument, not app chrome. It goes away, or shrinks to
//  an os.Logger, once the panel exists.
//

import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class EventLog {

    enum Category: String, Sendable {
        case lifecycle = "life"
        case notification = "notif"
        case bridge = "bridge"
        case measurement = "measure"
        case failure = "error"
    }

    struct Entry: Identifiable, Sendable {
        let id = UUID()
        let at: Date
        let category: Category
        let message: String

        /// Monotonic stamp, for measuring intervals between entries.
        let instant: ContinuousClock.Instant
    }

    /// Newest first, so the window needs no scroll management.
    private(set) var entries: [Entry] = []

    private let limit = 600
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "nz.slstudio.Cue",
                                category: "M0")
    private let fileHandle: FileHandle?
    private let timestampFormatter: DateFormatter
    private(set) var logFileURL: URL?

    init() {
        timestampFormatter = DateFormatter()
        timestampFormatter.dateFormat = "HH:mm:ss.SSS"

        let directory = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Cue", isDirectory: true)
        let url = directory.appendingPathComponent("m0-debug.log")

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            handle.seekToEndOfFile()
            fileHandle = handle
            logFileURL = url
        } catch {
            fileHandle = nil
            logFileURL = nil
        }
    }

    func append(_ category: Category, _ message: String) {
        let entry = Entry(at: Date(), category: category, message: message, instant: .now)
        entries.insert(entry, at: 0)
        if entries.count > limit {
            entries.removeLast(entries.count - limit)
        }

        let stamp = timestampFormatter.string(from: entry.at)
        let line = "[\(stamp)] [\(category.rawValue)] \(message)"

        print(line)
        fflush(stdout)
        fileHandle?.write(Data((line + "\n").utf8))

        switch category {
        case .failure:
            logger.error("\(message, privacy: .public)")
        default:
            logger.info("\(message, privacy: .public)")
        }
    }

    func clear() {
        entries.removeAll()
    }

    /// Multi-line payloads indent so the dump stays readable in the window.
    func appendBlock(_ category: Category, title: String, body: String) {
        let indented = body
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "    \($0)" }
            .joined(separator: "\n")
        append(category, "\(title)\n\(indented)")
    }
}
