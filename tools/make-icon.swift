//
// make-icon.swift — generate Cue's app icon into Cue/Assets.xcassets.
//
//   swift tools/make-icon.swift
//
// Takes tools/icon-master.png — a 1024×1024 reel-to-reel tape reel — and
// produces the full macOS icon ladder from it: each size composited at its own
// resolution and masked to the macOS icon shape.
//
// Cue is an agent app with no Dock icon, so this icon is seen in Finder, in
// System Settings (Login Items, and Privacy & Security → Automation) and in the
// GitHub release — all places where a generic blank app looks untrustworthy.
//
// An earlier version drew a mark procedurally; git history has it if the
// master ever needs replacing with something generated.
//

import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

let masterPath = "tools/icon-master.png"

// --- Shape ----------------------------------------------------------------

// A macOS icon does not fill its square. The 100/1024 inset and 185/1024
// corner radius are macOS's own proportions, and matching them is what makes
// an icon sit correctly beside other apps in Finder.
//
// Small sizes get less inset, so the artwork itself is drawn larger. At 16 px
// a correctly-inset icon is mostly empty margin around an unreadable smudge;
// giving the artwork the extra pixels is the only thing that helps. Apple's
// own icon sets vary per size for this reason.

struct Shape {
    var inset: CGFloat
    var corner: CGFloat
}

let large = Shape(inset: 100.0 / 1024.0, corner: 185.0 / 1024.0)
let small = Shape(inset: 40.0 / 1024.0, corner: 215.0 / 1024.0)

func shape(for size: CGFloat) -> Shape { size <= 32 ? small : large }

/// A continuous-curve rounded rectangle — Apple's icon shape. Core Graphics
/// only offers circular corners, so this borrows SwiftUI's path, which is the
/// only place the continuous curve is exposed.
func squirclePath(in rect: CGRect, radius: CGFloat) -> CGPath {
    RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect).cgPath
}

// --- Compositing ----------------------------------------------------------

guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: masterPath) as CFURL, nil),
      let master = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fatalError("could not read \(masterPath)")
}
print("master: \(master.width)×\(master.height)")

func drawIcon(size: CGFloat) -> CGImage {
    let ctx = CGContext(data: nil,
                        width: Int(size), height: Int(size),
                        bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    let s = shape(for: size)
    let art = CGRect(x: s.inset * size, y: s.inset * size,
                     width: (1 - 2 * s.inset) * size, height: (1 - 2 * s.inset) * size)

    ctx.saveGState()
    ctx.addPath(squirclePath(in: art, radius: s.corner * size))
    ctx.clip()
    ctx.draw(master, in: art)
    ctx.restoreGState()

    return ctx.makeImage()!
}

// --- Writing the asset catalog -------------------------------------------

struct Entry {
    let size: Int        // the point size Xcode names it by
    let scale: Int
    var pixels: Int { size * scale }
    var filename: String { "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png" }
}

let entries = [16, 32, 128, 256, 512].flatMap { [Entry(size: $0, scale: 1), Entry(size: $0, scale: 2)] }

let catalog = URL(fileURLWithPath: "Cue/Assets.xcassets")
let iconSet = catalog.appendingPathComponent("AppIcon.appiconset")
try! FileManager.default.createDirectory(at: iconSet, withIntermediateDirectories: true)

for entry in entries {
    let image = drawIcon(size: CGFloat(entry.pixels))
    let url = iconSet.appendingPathComponent(entry.filename)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(entry.filename)") }
    print("  \(entry.filename)  \(entry.pixels)px")
}

func json(_ body: String) -> Data { Data(body.utf8) }

let images = entries.map { e in
    """
        {
          "filename" : "\(e.filename)",
          "idiom" : "mac",
          "scale" : "\(e.scale)x",
          "size" : "\(e.size)x\(e.size)"
        }
    """
}.joined(separator: ",\n")

try! json("""
{
  "images" : [
\(images)
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
""").write(to: iconSet.appendingPathComponent("Contents.json"))

try! json("""
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
""").write(to: catalog.appendingPathComponent("Contents.json"))

print("\nWrote \(entries.count) sizes to \(iconSet.path)")

// --- §4.3's artwork placeholder ------------------------------------------
//
// The same reel, full-bleed. ArtworkView clips it to its own rounded corners
// and draws its own border, so this must carry neither the icon's squircle nor
// its inset: it stands in for album art, not for an app icon in a box.

func drawPlaceholder(size: CGFloat) -> CGImage {
    let ctx = CGContext(data: nil,
                        width: Int(size), height: Int(size),
                        bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(master, in: CGRect(x: 0, y: 0, width: size, height: size))
    return ctx.makeImage()!
}

let placeholderSet = catalog.appendingPathComponent("ArtworkPlaceholder.imageset")
try! FileManager.default.createDirectory(at: placeholderSet, withIntermediateDirectories: true)

// ArtworkView draws at most 132 pt, so 2x needs 264. 512 leaves headroom
// without carrying the whole 1024 master into the bundle.
for (name, px) in [("placeholder.png", 256.0), ("placeholder@2x.png", 512.0)] {
    let url = placeholderSet.appendingPathComponent(name)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, drawPlaceholder(size: px), nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(name)") }
    print("  \(name)  \(Int(px))px")
}

try! json("""
{
  "images" : [
    {
      "filename" : "placeholder.png",
      "idiom" : "universal",
      "scale" : "1x"
    },
    {
      "filename" : "placeholder@2x.png",
      "idiom" : "universal",
      "scale" : "2x"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
""").write(to: placeholderSet.appendingPathComponent("Contents.json"))

print("Wrote the artwork placeholder to \(placeholderSet.path)")

