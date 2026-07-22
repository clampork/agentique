#!/usr/bin/env swift
import AppKit

// Rasterise vector artwork so the Python preview tools can composite it—PIL reads no
// SVG or PDF, but AppKit reads both, and this is the same loader the app itself uses.
//
//   swift Tools/rasterize.swift <input.svg|pdf> <output.png> <height>

let arguments = CommandLine.arguments
guard arguments.count >= 4,
      let height = Double(arguments[3]),
      let image = NSImage(contentsOf: URL(fileURLWithPath: arguments[1])),
      image.size.height > 0
else {
    FileHandle.standardError.write(Data("usage: rasterize <in> <out.png> <height>\n".utf8))
    exit(1)
}

let target = NSSize(
    width: max(1, (image.size.width / image.size.height * height).rounded()),
    height: height
)
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(target.width),
    pixelsHigh: Int(target.height),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else { exit(1) }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
image.draw(in: NSRect(origin: .zero, size: target))
NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: arguments[2]))
