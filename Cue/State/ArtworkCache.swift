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
import ImageIO
import UniformTypeIdentifiers

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

    /// Decodes artwork at the size it will actually be drawn.
    ///
    /// `NSImage(data:)` decodes at full resolution — a 1.1 MB cover is often
    /// 1400x1400 — and then SwiftUI resamples it down to a 105 pt square on
    /// every draw. That resampling is what makes the art look harsh, or
    /// "sizzled": high-frequency detail aliasing as it is crushed by a factor
    /// of ten.
    ///
    /// ImageIO can decode straight to a thumbnail of the right size, using a
    /// proper downsampling filter. The result is both smoother and cheaper:
    /// less work at decode time, and a far smaller image to draw and hold.
    static func decode(_ data: Data, displaySize: CGFloat) -> NSImage? {
        // Generous headroom over the 2x most displays use, so the art stays
        // crisp if the panel ever draws it larger.
        let maxPixel = Int((displaySize * 3).rounded())

        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return NSImage(data: data)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            // Fall back rather than lose the artwork over a decode quirk.
            return NSImage(data: data)
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private func evictIfNeeded() {
        while order.count > capacity {
            let oldest = order.removeFirst()
            entries.removeValue(forKey: oldest)
        }
    }
}
