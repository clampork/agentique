import AppKit

/// Owns the single status item and keeps its row of glyphs in sync with cmux.
///
/// Lifecycle comes from the hook session files rather than the `cmux events` stream:
/// the files already carry the exact value we want, every hook writes them, so watching
/// the directory catches changes at the same latency with no subprocess to babysit.
/// The poll timer is a safety net for missed filesystem notifications.
final class StatusRowController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let refreshQueue = DispatchQueue(label: "com.clampork.agentique.refresh")

    private var slots: [AgentSlot] = []
    private var cachedWorkspaces: [Workspace] = []
    private var cachedTags: [String: WorkspaceTag] = [:]
    private var lastStructureRefresh = Date.distantPast
    /// Workspaces that had a live agent last refresh; a change forces a structure refresh
    /// so launches and exits are picked up immediately rather than on the next tick.
    private var trackedSessionWorkspaces: Set<String> = []

    private var pollTimer: Timer?
    private var pulseTimer: Timer?
    private var pulseStart = Date()
    /// Last drawn row, so identical frames are skipped.
    private var lastSignature = ""

    /// Workspaces whose agent finished while you were not looking. These pulse in their
    /// session color until visited, then fall silent for good.
    private var unacknowledged = Set<String>()
    /// Previous state per workspace, to catch the moment a turn ends.
    private var previousStates: [String: SlotState] = [:]

    /// Where each glyph sits inside the row image, and how wide that image is, so a click
    /// can be mapped back to the workspace under the cursor.
    private var glyphFrames: [NSRect] = []
    private var imageWidth: CGFloat = 0

    private var watcher: DispatchSourceFileSystemObject?
    private var debounce: DispatchWorkItem?

    /// How often to re-read the session files.
    private let pollInterval: TimeInterval = 2
    /// Workspaces, groups and agent tags change far less often, and `cmux top` samples
    /// CPU, so that whole set refreshes on a slower cadence.
    private let structureInterval: TimeInterval = 10

    // MARK: - Lifecycle

    func start() {
        // No `statusItem.menu`: that would open the list on any click. Clicks are handled
        // directly so hitting a glyph jumps to its workspace and only the space around
        // the glyphs falls through to the menu.
        statusItem.button?.target = self
        statusItem.button?.action = #selector(handleClick(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem.button?.imageScaling = .scaleNone
        statusItem.button?.setAccessibilityLabel("Agentique")
        // Lets macOS remember this item's slot across relaunches.
        statusItem.autosaveName = "Agentique"
        statusItem.isVisible = true

        render()
        logPlacement()
        startWatchingSessionDirectory()

        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        refresh()
    }

    /// Records where the status item actually landed, so a missing item can be told
    /// apart from an item pushed off the end of a crowded menu bar.
    private func logPlacement() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self else { return }
            let frame = self.statusItem.button?.window?.frame
            let screen = NSScreen.main?.frame.width ?? 0
            CmuxBridge.log(
                "visible=\(self.statusItem.isVisible) "
                + "frame=\(frame.map { "\(Int($0.origin.x)) \(Int($0.width))x\(Int($0.height))" } ?? "nil") "
                + "screenWidth=\(Int(screen)) slots=\(self.slots.count)"
            )
        }
    }

    // MARK: - Refresh

    /// Coalesces the burst of writes a single agent turn produces.
    private func scheduleRefresh() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func refresh() {
        let stale = Date().timeIntervalSince(lastStructureRefresh) > structureInterval
            || cachedWorkspaces.isEmpty

        refreshQueue.async { [weak self] in
            guard let self else { return }
            let sessions = CmuxBridge.liveSessions()

            // Refresh structure the moment the set of workspaces running a live agent
            // changes — one launched or exited — instead of waiting for the next structure
            // tick. A launch otherwise takes until the tick to draw its glyph; an exit
            // otherwise lingers on a stale cached tag until the tick clears it, so a glyph
            // outlives its closed window until something else forces a redraw.
            let sessionWorkspaces = Set(sessions.keys)
            let membershipChanged = sessionWorkspaces != self.trackedSessionWorkspaces
            let needsStructure = stale || membershipChanged

            let workspaces = needsStructure ? CmuxBridge.workspaces() : self.cachedWorkspaces
            let tags = needsStructure ? CmuxBridge.workspaceTags() : self.cachedTags

            let visible = CmuxBridge.visibleWorkspaceID()
            let slots = workspaces.map { workspace in
                AgentSlot(
                    workspace: workspace,
                    session: sessions[workspace.id],
                    tag: tags[workspace.id]
                )
            }
            .filter(\.isVisible)

            DispatchQueue.main.async {
                self.trackedSessionWorkspaces = sessionWorkspaces
                self.trackAcknowledgement(slots: slots, visible: visible)
                if needsStructure {
                    self.cachedWorkspaces = workspaces
                    self.cachedTags = tags
                    self.lastStructureRefresh = Date()
                }
                self.slots = slots
                self.syncPulseTimer()
                self.render()
            }
        }
    }

    // MARK: - Attention

    /// Flags a workspace when its turn ends while you are looking elsewhere, and clears
    /// the flag the moment you visit it. A turn that finishes on screen never flags at
    /// all, so nothing animates for work you already watched land.
    private func trackAcknowledgement(slots: [AgentSlot], visible: String?) {
        var present = Set<String>()
        for slot in slots {
            let id = slot.workspace.id
            present.insert(id)
            if slot.state == .ready, previousStates[id] == .working, id != visible {
                unacknowledged.insert(id)
            }
            if id == visible || slot.state == .working {
                unacknowledged.remove(id)
            }
            previousStates[id] = slot.state
        }
        // Drop workspaces that have gone away.
        unacknowledged.formIntersection(present)
        previousStates = previousStates.filter { present.contains($0.key) }
    }

    // MARK: - Drawing

    /// Every glyph keeps its session color, dimmed by brightness — not opacity — so it
    /// stays a true shade of itself over the translucent bar. A working agent pulses
    /// between settled and full; a finished one is full until seen, then settles.
    private func spec(for slot: AgentSlot, appearance: NSAppearance?, pulse: CGFloat) -> GlyphSpec {
        let session = CmuxColor.display(hex: slot.workspace.colorHex, isDark: GlyphRenderer.isDark(appearance))
            ?? GlyphRenderer.neutralColor(for: appearance)

        let fraction: CGFloat
        switch slot.state {
        case .working:
            fraction = Palette.pulseFloor + (Palette.full - Palette.pulseFloor) * pulse
        case .ready:
            fraction = unacknowledged.contains(slot.workspace.id) ? Palette.full : Palette.settled
        case .terminal:
            fraction = Palette.settled
        }
        let color = CmuxColor.dim(session, to: fraction)
        return GlyphSpec(key: slot.glyphKey, color: color, alpha: 1, groupID: slot.workspace.groupID)
    }

    private func render() {
        let appearance = statusItem.button?.effectiveAppearance
        let pulse = currentPulse()
        let specs = slots.map { spec(for: $0, appearance: appearance, pulse: pulse) }

        // Refreshes and appearance changes often produce an identical row; skipping
        // those avoids pointless image work between real animation frames.
        let signature = specs
            .map { "\($0.key):\($0.groupID ?? "-"):\($0.color.hexString):\(Int($0.alpha * 100))" }
            .joined(separator: "|")
        guard signature != lastSignature else { return }
        lastSignature = signature

        let image = GlyphRenderer.rowImage(specs: specs, appearance: appearance)
        statusItem.button?.image = image
        glyphFrames = GlyphRenderer.frames(for: specs)
        imageWidth = image.size.width

        let working = slots.filter { $0.state == .working }.count
        let ready = slots.filter { $0.state == .ready }.count
        statusItem.button?.setAccessibilityValue("\(working) working, \(ready) ready")
    }

    private func currentPulse() -> CGFloat {
        let elapsed = Date().timeIntervalSince(pulseStart)
        return CGFloat(0.5 + 0.5 * sin(2 * .pi * elapsed / Palette.pulsePeriod))
    }

    /// The animation runs while anything is working or waiting on a response.
    private func syncPulseTimer() {
        let needsPulse = slots.contains { $0.state.pulses }
        if needsPulse, pulseTimer == nil {
            pulseStart = Date()
            let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                self?.render()
            }
            RunLoop.main.add(timer, forMode: .common)
            pulseTimer = timer
        } else if !needsPulse, let timer = pulseTimer {
            timer.invalidate()
            pulseTimer = nil
        }
    }

    // MARK: - Session file watching

    private func startWatchingSessionDirectory() {
        let path = CmuxBridge.sessionDirectory.path
        try? FileManager.default.createDirectory(
            at: CmuxBridge.sessionDirectory,
            withIntermediateDirectories: true
        )
        // The hook files are replaced atomically, so the directory is what changes.
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: DispatchQueue.main
        )
        source.setEventHandler { [weak self] in self?.scheduleRefresh() }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcher = source
    }

    // MARK: - Clicks

    /// A click on a glyph jumps straight to that workspace. A click on the padding around
    /// the glyphs, or any right-click, opens the list instead.
    @objc private func handleClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true

        if !wantsMenu, let location = event?.locationInWindow {
            let point = sender.convert(location, from: nil)
            if let slot = slot(at: point.x, in: sender) {
                refreshQueue.async { CmuxBridge.focus(workspace: slot.workspace.id) }
                return
            }
        }
        showMenu(from: sender)
    }

    /// Maps a click's x position onto a slot. The image is centered in the button, so the
    /// glyph frames have to be shifted by that inset before comparing.
    private func slot(at x: CGFloat, in button: NSStatusBarButton) -> AgentSlot? {
        guard glyphFrames.count == slots.count, imageWidth > 0 else { return nil }
        let inset = (button.bounds.width - imageWidth) / 2
        let local = x - inset
        // A couple of points of slack, so clipping the edge of a glyph still counts.
        for (index, frame) in glyphFrames.enumerated()
        where local >= frame.minX - 2 && local <= frame.maxX + 2 {
            return slots[index]
        }
        return nil
    }

    private func showMenu(from button: NSStatusBarButton) {
        let menu = NSMenu()
        menuNeedsUpdate(menu)
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: button.bounds.height + 5),
            in: button
        )
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let appearance = statusItem.button?.effectiveAppearance

        if slots.isEmpty {
            let item = NSMenuItem(title: "cmux not running", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        for slot in slots {
            let item = NSMenuItem(
                title: slot.workspace.title,
                action: #selector(focusWorkspace(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = slot.workspace.id
            item.image = GlyphRenderer.swatch(spec(for: slot, appearance: appearance, pulse: 1))
            item.state = slot.workspace.selected ? .on : .off
            item.toolTip = slot.session?.cwd
            item.attributedTitle = detailTitle(slot)
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Agentique", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    /// Workspace name on the left, dimmed state and agent on the right.
    private func detailTitle(_ slot: AgentSlot) -> NSAttributedString {
        let title = NSMutableAttributedString(
            string: slot.workspace.title,
            attributes: [.font: NSFont.menuFont(ofSize: 0)]
        )
        var detail = slot.detail
        if let agent = slot.agentLabel, slot.state != .terminal {
            detail += " \u{2014} \(agent)"
        }
        title.append(NSAttributedString(
            string: "   \(detail)",
            attributes: [
                .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        ))
        return title
    }

    @objc private func focusWorkspace(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        refreshQueue.async { CmuxBridge.focus(workspace: id) }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
