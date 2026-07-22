import AppKit

/// One glyph to draw: which vector, in what color, at what alpha.
struct GlyphSpec {
    let key: String
    let color: NSColor
    let alpha: CGFloat
    /// cmux group. Spacing is uniform, so this only feeds the redraw signature.
    let groupID: String?
}

/// Draws the row of agent glyphs that becomes the status item's image.
///
/// Glyphs come from `Resources/agents/<key>.pdf` when present and fall back to built-in
/// vector shapes otherwise, so dropping a PDF in is the whole install step. The artwork
/// is used purely as a silhouette — its alpha channel is tinted at draw time — which is
/// why a flat single-color export is what the loader expects.
enum GlyphRenderer {
    /// Glyph height in points, sized against the system items sharing the bar: filled
    /// icons there (Telegram, coffee pot) measure ~16pt tall, and the glyphs are dense
    /// silhouettes of the same kind. Kept whole so the glyph lands on exact pixels at 2x.
    static var glyphSize: CGFloat = 16
    /// Clear space between glyphs. Half the ~20pt rhythm macOS leaves between neighbouring
    /// status items, so the row reads as one item rather than several.
    ///
    /// A gap rather than a center distance, because artwork is fitted by height and a
    /// wide glyph would otherwise overlap its neighbour.
    static var gap: CGFloat = 10
    /// Ceiling on how wide a single glyph may get relative to its height.
    static var maxAspect: CGFloat = 1.8
    /// Overall image height.
    static var height: CGFloat = 18
    static var edgeInset: CGFloat = 4

    private static var cache: [String: NSImage] = [:]

    // MARK: - Artwork

    /// Vector is preferred, but raster art is accepted — at 11pt it is drawn into 22
    /// pixels on a 2x display, so anything 256px or larger downsamples cleanly.
    private static let artworkExtensions = ["pdf", "svg", "png"]

    private static func artwork(for key: String) -> NSImage? {
        if let cached = cache[key] { return cached }
        guard let resources = Bundle.main.resourceURL else { return nil }
        for ext in artworkExtensions {
            let url = resources.appendingPathComponent("agents/\(key).\(ext)")
            guard FileManager.default.fileExists(atPath: url.path),
                  let image = NSImage(contentsOf: url)
            else { continue }
            let trimmed = trimmingTransparentEdges(image)
            cache[key] = trimmed
            return trimmed
        }
        return nil
    }

    /// Crops fully transparent margins so every glyph is sized by its actual artwork.
    ///
    /// Export padding varies wildly between tools, and without this a glyph centered in a
    /// roomy canvas renders visibly smaller than its neighbours for no reason the author
    /// can see.
    private static func trimmingTransparentEdges(_ image: NSImage) -> NSImage {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return image
        }
        let width = source.width
        let height = source.height
        guard width > 0, height > 0 else { return image }

        // Redraw into a known RGBA layout before scanning. CGImage byte order varies by
        // source — SVG and PNG decode differently — and guessing the alpha offset made
        // trimming fail silently on vector art, which then rendered undersized because
        // its transparent margin was being scaled as though it were artwork.
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = buffer.withUnsafeMutableBytes({ raw in
            CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo
            )
        }) else { return image }
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))

        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let row = y * width * 4
            for x in 0..<width where buffer[row + x * 4 + 3] > 8 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return image }

        // The scan ran in the context's bottom-up space; cropping is top-down.
        let box = CGRect(
            x: minX,
            y: height - 1 - maxY,
            width: maxX - minX + 1,
            height: maxY - minY + 1
        )
        guard box.width < CGFloat(width) || box.height < CGFloat(height),
              let cropped = source.cropping(to: box)
        else { return image }
        return NSImage(cgImage: cropped, size: NSSize(width: box.width, height: box.height))
    }

    static func clearCache() {
        cache.removeAll()
    }

    /// Resolves `labelColor` against the menu bar's appearance, for workspaces with no
    /// color of their own.
    static func neutralColor(for appearance: NSAppearance?) -> NSColor {
        var resolved = NSColor.labelColor
        let target = appearance ?? NSApp.effectiveAppearance
        target.performAsCurrentDrawingAppearance {
            resolved = NSColor.labelColor.usingColorSpace(.sRGB) ?? NSColor.labelColor
        }
        return resolved
    }

    static func isDark(_ appearance: NSAppearance?) -> Bool {
        let target = appearance ?? NSApp.effectiveAppearance
        return target.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    // MARK: - Drawing

    /// Drawn size of a glyph: artwork is fitted to `glyphSize` in height, so a wide glyph
    /// stays legible instead of being shrunk to fit a square.
    private static func drawnSize(for spec: GlyphSpec) -> NSSize {
        guard let art = artwork(for: spec.key), art.size.height > 0 else {
            return NSSize(width: glyphSize, height: glyphSize)
        }
        let aspect = min(art.size.width / art.size.height, maxAspect)
        return NSSize(width: glyphSize * aspect, height: glyphSize)
    }

    /// Left edge of each glyph, spaced by a uniform gap regardless of group membership.
    private static func layout(_ specs: [GlyphSpec]) -> (origins: [CGFloat], sizes: [NSSize], width: CGFloat) {
        var origins: [CGFloat] = []
        var sizes: [NSSize] = []
        var x = edgeInset

        for (index, spec) in specs.enumerated() {
            if index > 0 {
                x += sizes[index - 1].width + gap
            }
            origins.append(x)
            sizes.append(drawnSize(for: spec))
        }

        let width = (origins.last ?? edgeInset) + (sizes.last?.width ?? glyphSize) + edgeInset
        return (origins, sizes, width)
    }

    /// Where each glyph lands inside the row image, for hit-testing clicks.
    static func frames(for specs: [GlyphSpec]) -> [NSRect] {
        let (origins, sizes, _) = layout(specs)
        return zip(origins, sizes).map { origin, size in
            NSRect(
                x: origin,
                y: (height - size.height) / 2,
                width: size.width,
                height: size.height
            )
        }
    }

    static func rowImage(specs: [GlyphSpec], appearance: NSAppearance?) -> NSImage {
        let (origins, sizes, rowWidth) = layout(specs)
        let size = NSSize(width: max(rowWidth, glyphSize + edgeInset * 2), height: height)

        return NSImage(size: size, flipped: false) { _ in
            for (index, spec) in specs.enumerated() {
                let box = NSRect(
                    x: origins[index],
                    y: (height - sizes[index].height) / 2,
                    width: sizes[index].width,
                    height: sizes[index].height
                )
                draw(spec, in: box)
            }
            return true
        }
    }

    private static func draw(_ spec: GlyphSpec, in box: NSRect) {
        let color = spec.color.withAlphaComponent(spec.alpha)

        guard let art = artwork(for: spec.key) else {
            drawFallback(key: spec.key, color: color, in: box)
            return
        }

        // Fit the artwork's aspect inside the box so non-square glyphs stay undistorted.
        let scale = min(box.width / art.size.width, box.height / art.size.height)
        let fitted = NSSize(width: art.size.width * scale, height: art.size.height * scale)
        let target = NSRect(
            x: box.midX - fitted.width / 2,
            y: box.midY - fitted.height / 2,
            width: fitted.width,
            height: fitted.height
        )

        NSGraphicsContext.saveGraphicsState()
        art.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1)
        color.set()
        // sourceAtop recolors only where the artwork already has coverage.
        target.fill(using: .sourceAtop)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Shape used until an agent's real artwork is dropped in.
    private static func drawFallback(key: String, color: NSColor, in box: NSRect) {
        color.set()
        NSBezierPath(ovalIn: box).fill()
    }

    /// Small glyph used as the leading swatch on each dropdown row.
    static func swatch(_ spec: GlyphSpec) -> NSImage {
        let size = NSSize(width: 12, height: 12)
        return NSImage(size: size, flipped: false) { _ in
            draw(spec, in: NSRect(x: 1, y: 1, width: 10, height: 10))
            return true
        }
    }
}
