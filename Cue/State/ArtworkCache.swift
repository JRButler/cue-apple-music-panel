//
//  ArtworkCache.swift
//  Cue
//
//  §4.3's artwork cache: the last 20 tracks, keyed by persistent ID, least
//  recently used evicted first.
//
//  Two things the key has to cope with. Some streamed catalogue tracks report an
//  empty persistent ID, so `TrackInfo.id` falls back to title/artist/album —
//  which is why the cache keys on that rather than on the raw ID. And a track
//  can legitimately have *no* artwork, which is worth remembering too: without
//  caching the negative, every sync would re-fetch nothing at some cost.
//

import AppKit
import Foundation

@MainActor
final class ArtworkCache {

    /// §4.3: the last 20 tracks.
    private let capacity: Int

    /// `nil` means "asked, and this track genuinely has no artwork".
    private var entries: [String: NSImage?] = [:]
    /// Most recently used last.
    private var order: [String] = []

    init(capacity: Int = 20) {
        self.capacity = max(1, capacity)
    }

    /// Returns `.some(nil)` when the track is known to have no artwork, and
    /// `nil` when it has not been looked up at all. The distinction is what
    /// stops a track without art being re-fetched forever.
    func lookup(_ key: String) -> NSImage?? {
        guard let entry = entries[key] else { return nil }
        touch(key)
        return .some(entry)
    }

    func store(_ image: NSImage?, for key: String) {
        entries[key] = image
        touch(key)
        evictIfNeeded()
    }

    func removeAll() {
        entries.removeAll()
        order.removeAll()
    }

    var count: Int { entries.count }

    private func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    private func evictIfNeeded() {
        while order.count > capacity {
            let oldest = order.removeFirst()
            entries.removeValue(forKey: oldest)
        }
    }
}
