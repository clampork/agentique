import AppKit
import Foundation

/// Reads cmux state: Workspaces and Workspace Groups over the control socket, agent lifecycle
/// from the hook session files the agent integrations write.
enum CmuxBridge {
    static let sessionDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cmuxterm")

    static let cmuxBundleID = "com.cmuxterm.app"

    private static let candidateBinaries = [
        "/opt/homebrew/bin/cmux",
        "/usr/local/bin/cmux",
        "\(NSHomeDirectory())/.local/bin/cmux",
    ]

    static var binary: String? = {
        candidateBinaries.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    /// Appends a diagnostic line to `~/Library/Logs/Agentique.log`.
    static func log(_ message: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Agentique.log")
        guard let data = "[\(Date())] \(message)\n".data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    // MARK: - Shelling out

    @discardableResult
    static func run(_ arguments: [String]) -> String? {
        guard let binary else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_QUIET"] = "1"
        process.environment = environment

        let pipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            log("spawn failed \(arguments.first ?? "?"): \(error)")
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8) ?? ""
            log("exit \(process.terminationStatus) for \(arguments.joined(separator: " ")): "
                + message.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Workspaces

    /// Every Workspace across every cmux window, in sidebar order, excluding Group anchors.
    static func workspaces() -> [Workspace] {
        let groups = groupMembership()
        let windows = windowIDs()
        let raw = windows.isEmpty
            ? workspaces(window: nil)
            : windows.flatMap { workspaces(window: $0) }

        var seen = Set<String>()
        return raw
            .filter { !groups.anchors.contains($0.id) && seen.insert($0.id).inserted }
            .map { workspace in
                Workspace(
                    id: workspace.id,
                    title: workspace.title,
                    index: workspace.index,
                    selected: workspace.selected,
                    colorHex: workspace.colorHex,
                    groupID: groups.byWorkspace[workspace.id]
                )
            }
            .sorted { $0.index < $1.index }
    }

    /// Workspace Group anchors, and which Group each Workspace belongs to.
    ///
    /// cmux models a Workspace Group as a Workspace that anchors it, so the anchor
    /// and its members come back indistinguishable from `workspace list`; the Group
    /// listing is what separates them.
    private static func groupMembership() -> (anchors: Set<String>, byWorkspace: [String: String]) {
        guard let output = run(["rpc", "workspace.group.list"]),
              let data = output.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let groups = root["groups"] as? [[String: Any]]
        else { return ([], [:]) }

        var anchors = Set<String>()
        var byWorkspace: [String: String] = [:]
        for group in groups {
            guard let id = group["id"] as? String else { continue }
            if let anchor = group["anchor_workspace_id"] as? String {
                anchors.insert(anchor)
            }
            for member in (group["member_workspace_ids"] as? [String]) ?? [] {
                byWorkspace[member] = id
            }
        }
        return (anchors, byWorkspace)
    }

    private static func windowIDs() -> [String] {
        guard let output = run(["list-windows"]) else { return [] }
        // Lines look like: `* 0: <UUID> selected_workspace=<UUID> workspaces=8`
        return output.split(separator: "\n").compactMap { line in
            line.split(separator: " ")
                .map(String.init)
                .first { $0.count == 36 && $0.contains("-") }
        }
    }

    private static func workspaces(window: String?) -> [Workspace] {
        var arguments = ["workspace", "list", "--json", "--id-format", "both"]
        if let window {
            arguments += ["--window", window]
        }
        guard let output = run(arguments),
              let data = output.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = root["workspaces"] as? [[String: Any]]
        else { return [] }

        return raw.compactMap { entry -> Workspace? in
            guard let id = entry["id"] as? String else { return nil }
            let title = (entry["custom_title"] as? String)
                ?? (entry["title"] as? String)
                ?? URL(fileURLWithPath: (entry["current_directory"] as? String) ?? "").lastPathComponent
            return Workspace(
                id: id,
                title: title.isEmpty ? "untitled" : title,
                index: (entry["index"] as? Int) ?? 0,
                selected: (entry["selected"] as? Bool) ?? false,
                colorHex: entry["custom_color"] as? String,
                groupID: nil
            )
        }
    }

    // MARK: - Workspace agent tags

    /// cmux's own agent tags, keyed by Workspace ID.
    ///
    /// Output rows are tab separated as `cpu, mem, count, kind, id, parent, label`, and a
    /// tag row's id looks like `workspace:<UUID>:tag:claude_code`. A Workspace running
    /// only a shell produces no tag row at all, which is how a plain terminal is told
    /// apart from a Workspace whose agent has exited.
    static func workspaceTags() -> [String: WorkspaceTag] {
        guard let output = run(["top", "--all", "--processes", "--format", "tsv"]) else { return [:] }
        var tags: [String: WorkspaceTag] = [:]

        for line in output.split(separator: "\n") {
            let fields = line.components(separatedBy: "\t")
            guard fields.count >= 5, fields[3] == "tag" else { continue }
            let identifier = fields[4]
            guard identifier.hasPrefix("workspace:"),
                  let tagRange = identifier.range(of: ":tag:")
            else { continue }

            let workspaceID = String(identifier[
                identifier.index(identifier.startIndex, offsetBy: "workspace:".count)..<tagRange.lowerBound
            ])
            let kind = String(identifier[tagRange.upperBound...])
            // cmux emits a canonical agent tag (`codex`, `claude_code`) plus a per-session
            // sub-tag (`codex.<uuid>`) that carries no lifecycle label. Drop the sub-tag:
            // being written last, it would otherwise overwrite the canonical tag and blank
            // the label, so the agent never reads as Running—its glyph never pulses and a
            // finished turn never brightens—and its `agentKey` stops matching artwork.
            guard !kind.contains(".") else { continue }
            let label = fields.count >= 7 ? fields[6].trimmingCharacters(in: .whitespaces) : ""
            tags[workspaceID] = WorkspaceTag(kind: kind, label: label)
        }
        return tags
    }

    // MARK: - Agent sessions

    /// Live agent sessions keyed by Workspace ID.
    ///
    /// The hook files keep finished sessions around for restore, so entries are only
    /// trusted when their process is still alive—that is also what makes a
    /// hibernated or exited agent drop out of the live set.
    static func liveSessions() -> [String: AgentSession] {
        var best: [String: AgentSession] = [:]
        for session in allSessions() where isAlive(session.pid) {
            if let existing = best[session.workspaceID], existing.updatedAt >= session.updatedAt {
                continue
            }
            best[session.workspaceID] = session
        }
        // cmux flips a session to `running` the moment any input is submitted, including
        // client-only commands like `/clear` that never issue a model turn and so never
        // complete—leaving the glyph pulsing until the next real turn. The transcript is
        // the tiebreaker: only sessions with a live turn stay `working`.
        for (workspaceID, session) in best
        where session.lifecycle == .running && endsWithLocalCommand(session.transcriptPath) {
            var parked = session
            parked.parkedOnLocalCommand = true
            best[workspaceID] = parked
        }
        return best
    }

    /// Whether the last real turn in a transcript is a local slash command rather than a
    /// live model turn. cmux logs `/clear` as a user entry wrapped in `<command-name>`; if
    /// that is the last conversational entry, no turn is in flight. Bookkeeping rows that
    /// carry no message (mode, title, snapshots) are skipped to reach it.
    private static func endsWithLocalCommand(_ transcriptPath: String?) -> Bool {
        guard let transcriptPath,
              let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: transcriptPath))
        else { return false }
        defer { try? handle.close() }

        // Transcripts grow without bound and this runs every poll, so only the tail is read.
        let size = (try? handle.seekToEnd()) ?? 0
        let window: UInt64 = 64 * 1024
        try? handle.seek(toOffset: size > window ? size - window : 0)
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8)
        else { return false }

        for line in text.split(separator: "\n").reversed() {
            guard let lineData = line.data(using: .utf8),
                  let entry = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let message = entry["message"] as? [String: Any],
                  let role = message["role"] as? String
            else { continue }
            // The last conversational entry decides it: a local command is a user entry, so
            // anything ending in an assistant or tool turn is a genuine turn in flight.
            guard role == "user" else { return false }
            return contentText(message["content"]).contains("<command-name>")
        }
        return false
    }

    /// Flattens a transcript entry's `content`, which is either a plain string or an array of
    /// typed blocks, into text so it can be scanned for the local-command marker.
    private static func contentText(_ content: Any?) -> String {
        if let string = content as? String { return string }
        if let array = content,
           let data = try? JSONSerialization.data(withJSONObject: array),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return ""
    }

    private static func allSessions() -> [AgentSession] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: sessionDirectory,
            includingPropertiesForKeys: nil
        )) ?? []

        return files
            .filter { $0.lastPathComponent.hasSuffix("-hook-sessions.json") }
            .flatMap { sessions(in: $0) }
    }

    private static func sessions(in file: URL) -> [AgentSession] {
        let agent = file.lastPathComponent
            .replacingOccurrences(of: "-hook-sessions.json", with: "")
        guard let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = root["sessions"] as? [String: Any]
        else { return [] }

        return raw.compactMap { sessionID, value -> AgentSession? in
            guard let entry = value as? [String: Any],
                  let workspaceID = entry["workspaceId"] as? String
            else { return nil }
            let lifecycle = AgentLifecycle(
                rawValue: (entry["agentLifecycle"] as? String) ?? "unknown"
            ) ?? .unknown
            return AgentSession(
                sessionID: sessionID,
                agent: agent,
                workspaceID: workspaceID,
                lifecycle: lifecycle,
                pid: (entry["pid"] as? NSNumber)?.int32Value,
                updatedAt: (entry["updatedAt"] as? Double) ?? 0,
                cwd: entry["cwd"] as? String,
                transcriptPath: entry["transcriptPath"] as? String
            )
        }
    }

    private static func isAlive(_ pid: Int32?) -> Bool {
        guard let pid, pid > 0 else { return false }
        // Signal 0 performs the permission and existence checks without delivering.
        return kill(pid, 0) == 0 || errno == EPERM
    }

    // MARK: - Attention

    /// The Workspace you are currently looking at: selected in cmux, with cmux frontmost.
    ///
    /// Selection alone is not enough—the selected Workspace stays selected while cmux
    /// sits in the background, which is exactly when a finished turn goes unseen.
    static func visibleWorkspaceID() -> String? {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == cmuxBundleID,
              let output = run(["rpc", "workspace.current"]),
              let data = output.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let workspace = root["workspace"] as? [String: Any]
        else { return nil }
        return workspace["id"] as? String
    }

    // MARK: - Actions

    static func focus(workspace id: String) {
        run(["select-workspace", "--workspace", id])
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: cmuxBundleID).first {
            app.activate(options: [.activateAllWindows])
        }
    }
}
