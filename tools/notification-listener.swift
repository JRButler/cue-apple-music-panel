//
//  notification-listener.swift
//  Run:  swift tools/notification-listener.swift [seconds]
//
//  A distributed-notification listener with no dependency on Cue's code.
//
//  It exists because during M0 a bug in Cue's own diagnostics led to the
//  conclusion that Music had stopped broadcasting player state on macOS 27.
//  This script disproved that in one run. When an instrument says a system
//  feature is gone, check it from outside the code under test.
//
//  Listening needs no permission; only sending Apple Events is gated by TCC.
//  Note that a nil notification name NEVER fires on a distributed centre, so
//  every name of interest has to be registered explicitly.
//

import Foundation

let seconds = Double(CommandLine.arguments.dropFirst().first ?? "20") ?? 20
let names = [
    "com.apple.Music.playerInfo",
    "com.apple.iTunes.playerInfo",
]

var counts: [String: Int] = [:]
let center = DistributedNotificationCenter.default()

for name in names {
    center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { note in
        counts[name, default: 0] += 1
        print("\n\(name)  #\(counts[name]!)")
        for (key, value) in (note.userInfo ?? [:])
            .sorted(by: { String(describing: $0.key) < String(describing: $1.key) }) {
            print("   \(key) [\(type(of: value))] = \(value)")
        }
        fflush(stdout)
    }
}

print("Listening \(seconds)s for: \(names.joined(separator: ", "))")
print("Change track, or play/pause, in Music now.")
fflush(stdout)

DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
    print("\n--- done ---")
    for name in names { print("  \(name): \(counts[name] ?? 0)") }
    fflush(stdout)
    exit(0)
}
RunLoop.main.run()
