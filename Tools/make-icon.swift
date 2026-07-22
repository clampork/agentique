#!/usr/bin/env swift
import AppKit

// Renders Assets/AppIcon.icns — a row of colored dots on a dark squircle. Deliberately
// abstract: the dots read as "a row of things" without committing to any one mark, and
// stay legible down to 16pt where detailed artwork would not.
//
//   swift Tools/make-icon.swift

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath)

/// Tokyo Night accents, matching the workspace colors cmux assigns.
let dots: [NSColor] = [
    NSColor(srgbRed: 0.490, green: 0.812, blue: 1.000, alpha: 1),  // blue
    NSColor(srgbRed: 0.620, green: 0.808, blue: 0.416, alpha: 1),  // green
    NSColor(srgbRed: 0.733, green: 0.604, blue: 0.969, alpha: 1),  // purple
    NSColor(srgbRed: 0.969, green: 0.463, blue: 0.557, alpha: 1),  // rose
]

func drawIcon(size: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
        let unit = size / 1024

        // Apple's icon grid: content occupies ~824pt of a 1024pt canvas.
        let plate = NSRect(x: 100 * unit, y: 100 * unit, width: 824 * unit, height: 824 * unit)
        let platePath = NSBezierPath(roundedRect: plate, xRadius: 185 * unit, yRadius: 185 * unit)

        NSGraphicsContext.saveGraphicsState()
        platePath.addClip()
        NSGradient(colors: [
            NSColor(srgbRed: 0.176, green: 0.192, blue: 0.235, alpha: 1),
            NSColor(srgbRed: 0.090, green: 0.098, blue: 0.129, alpha: 1),
        ])?.draw(in: plate, angle: -90)

        // Dots on the centerline, mirroring the menu bar row.
        let diameter = 150 * unit
        let gap = 56 * unit
        let totalWidth = diameter * CGFloat(dots.count) + gap * CGFloat(dots.count - 1)
        var x = plate.midX - totalWidth / 2
        let y = plate.midY - diameter / 2

        for color in dots {
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: y, width: diameter, height: diameter)).fill()
            x += diameter + gap
        }

        NSGraphicsContext.restoreGraphicsState()

        // Hairline rim, the way system icons catch light at the top edge.
        NSColor.white.withAlphaComponent(0.10).setStroke()
        platePath.lineWidth = 2 * unit
        platePath.stroke()
        return true
    }
}

func png(_ image: NSImage, _ pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    drawIcon(size: CGFloat(pixels)).draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// The sizes iconutil expects, each at 1x and 2x.
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = base * scale
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        guard let data = png(drawIcon(size: CGFloat(pixels)), pixels) else { continue }
        try data.write(to: iconset.appendingPathComponent(name))
    }
}

let assets = root.appendingPathComponent("Assets")
try? FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

let convert = Process()
convert.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
convert.arguments = [
    "-c", "icns", iconset.path,
    "-o", assets.appendingPathComponent("AppIcon.icns").path,
]
try convert.run()
convert.waitUntilExit()

// Keep a full-size render around for eyeballing the artwork.
if let data = png(drawIcon(size: 1024), 1024) {
    try data.write(to: root.appendingPathComponent("build/AppIcon-preview.png"))
}

print("wrote Assets/AppIcon.icns (exit \(convert.terminationStatus))")
