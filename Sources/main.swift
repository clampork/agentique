import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = StatusRowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.start()
    }
}

// Version comes from the bundle, so Info.plist stays the one place it is written down.
if CommandLine.arguments.contains("--version") {
    let info = Bundle.main.infoDictionary
    let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
    let build = info?["CFBundleVersion"] as? String ?? "0"
    print("Agentique \(version) (\(build))")
    exit(0)
}

if CommandLine.arguments.contains("--help") || CommandLine.arguments.contains("-h") {
    print("""
        Agentique—a macOS menu bar status item for cmux agent state.

        usage: Agentique [--dump | --preview <path> | --version | --help]

        Runs as a menu bar item when given no options.

          --dump            print the row's state mapping as text
          --preview <path>  render the row to a PNG over both menu bar backgrounds
          --version         print the version
          --help, -h        print this message
        """)
    exit(0)
}

// `--dump` prints the row the app would draw, for checking state mapping headlessly.
if CommandLine.arguments.contains("--dump") {
    let sessions = CmuxBridge.liveSessions()
    let tags = CmuxBridge.workspaceTags()

    let slots = CmuxBridge.workspaces().map { workspace in
        AgentSlot(
            workspace: workspace,
            session: sessions[workspace.id],
            tag: tags[workspace.id]
        )
    }.filter(\.isVisible)

    func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    print(pad("WORKSPACE", 17) + pad("STATE", 10) + pad("GLYPH", 10) + pad("COLOR", 9) + "TREATMENT")
    for slot in slots {
        let color: String = slot.workspace.colorHex ?? "neutral"
        let treatment: String = slot.state.pulses ? "pulsing" : slot.detail
        var line = pad(slot.workspace.title, 17)
        line += pad(slot.detail, 10)
        line += pad(slot.glyphKey, 10)
        line += pad(color, 9)
        line += treatment
        print(line)
    }
    exit(0)
}

// `--preview <path>` renders the row exactly as the status item draws it, at 4x, over
// both menu bar backgrounds. Verifies artwork without needing to see the menu bar.
if let index = CommandLine.arguments.firstIndex(of: "--preview"),
   CommandLine.arguments.count > index + 1 {
    let path = CommandLine.arguments[index + 1]
    let sessions = CmuxBridge.liveSessions()
    let tags = CmuxBridge.workspaceTags()

    let slots = CmuxBridge.workspaces().map { workspace in
        AgentSlot(
            workspace: workspace,
            session: sessions[workspace.id],
            tag: tags[workspace.id]
        )
    }.filter(\.isVisible)

    func specs(isDark: Bool, pulse: CGFloat) -> [GlyphSpec] {
        slots.map { slot in
            let session = CmuxColor.display(hex: slot.workspace.colorHex, isDark: isDark)
                ?? (isDark ? NSColor.white : NSColor.black)
            let fraction = slot.state.pulses
                ? Palette.settled + (Palette.full - Palette.settled) * pulse
                : Palette.full
            let color = CmuxColor.dim(session, to: fraction)
            return GlyphSpec(key: slot.glyphKey, color: color, groupID: slot.workspace.groupID)
        }
    }

    let scale: CGFloat = 4
    // Dark bar at peak and trough of the pulse, then the light bar.
    let rows: [(NSColor, [GlyphSpec])] = [
        (NSColor(white: 0.13, alpha: 1), specs(isDark: true, pulse: 1.0)),
        (NSColor(white: 0.13, alpha: 1), specs(isDark: true, pulse: 0.0)),
        (NSColor(white: 0.92, alpha: 1), specs(isDark: false, pulse: 1.0)),
    ]

    let rowImages = rows.map { GlyphRenderer.rowImage(specs: $0.1, appearance: nil) }
    let width = (rowImages.map(\.size.width).max() ?? 100) * scale
    let rowHeight = GlyphRenderer.height * scale
    let canvas = NSSize(width: width, height: rowHeight * CGFloat(rows.count))

    let out = NSImage(size: canvas, flipped: false) { _ in
        for (index, row) in rows.enumerated() {
            let y = canvas.height - rowHeight * CGFloat(index + 1)
            let band = NSRect(x: 0, y: y, width: canvas.width, height: rowHeight)
            row.0.setFill()
            band.fill()
            let image = rowImages[index]
            image.draw(
                in: NSRect(x: 0, y: y, width: image.size.width * scale, height: rowHeight),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
        }
        return true
    }

    if let tiff = out.tiffRepresentation,
       let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: path))
        print("wrote \(path) (\(Int(canvas.width))x\(Int(canvas.height)))")
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

extension NSColor {
    var hexString: String {
        let rgb = usingColorSpace(.sRGB) ?? self
        return String(
            format: "#%02X%02X%02X",
            Int((rgb.redComponent * 255).rounded()),
            Int((rgb.greenComponent * 255).rounded()),
            Int((rgb.blueComponent * 255).rounded())
        )
    }
}
