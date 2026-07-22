import AppKit

/// Lifecycle values cmux writes into `~/.cmuxterm/<agent>-hook-sessions.json`.
enum AgentLifecycle: String {
    case running
    case idle
    case needsInput
    case unknown
}

/// What a single mark in the row is showing.
enum SlotState {
    /// Agent is mid-turn. The only state that animates.
    case working
    /// Turn finished, which for a coding agent is the same as waiting on you.
    case ready
    /// Plain terminal — no AI has ever been loaded in this workspace. Not drawn.
    case terminal

    /// Hue is reserved for identity, so state is carried by motion and brightness alone.
    var pulses: Bool { self == .working }
}

/// A live agent session, as recorded by the cmux hooks.
struct AgentSession {
    let sessionID: String
    let agent: String
    let workspaceID: String
    let lifecycle: AgentLifecycle
    let pid: Int32?
    let updatedAt: Double
    let cwd: String?
    let transcriptPath: String?
    /// Set when cmux still calls this `running` but the transcript shows it is parked on a
    /// client-only command like `/clear` that never runs a turn — see
    /// `CmuxBridge.liveSessions`. Such a session is treated as finished, not working.
    var parkedOnLocalCommand = false
}

/// cmux's own per-workspace agent tag, from `cmux top --processes`.
///
/// The tag is the authoritative answer to "has an AI been loaded here at all" —
/// a workspace running only a shell emits no tag row.
struct WorkspaceTag {
    /// e.g. `claude_code`, `codex`.
    let kind: String
    /// `Running`, `Idle`, or empty.
    let label: String

    /// Maps cmux's tag names onto the agent keys the hook files use.
    var agentKey: String {
        switch kind {
        case "claude_code": return "claude"
        default: return kind
        }
    }
}

/// One workspace in the cmux sidebar.
struct Workspace {
    let id: String
    let title: String
    let index: Int
    let selected: Bool
    /// Hex string from cmux, e.g. `#3D59A1`. Shared across a group's members.
    let colorHex: String?
    /// The cmux group (sidebar folder) this workspace belongs to, if any.
    let groupID: String?
}

/// A workspace paired with whatever is running in it — one mark in the row.
struct AgentSlot {
    let workspace: Workspace
    let session: AgentSession?
    let tag: WorkspaceTag?

    /// Only live signals count. Hook files keep finished sessions around for restore, so
    /// old history must never resurrect a workspace that is now just a shell.
    var state: SlotState {
        if let session {
            switch session.lifecycle {
            // A session parked on a local command (`/clear`) is pinned at `running` by cmux
            // even though no turn is in flight; it reads as finished, not working.
            case .running: return session.parkedOnLocalCommand ? .ready : .working
            case .idle, .needsInput: return .ready
            case .unknown: break
            }
        }
        // cmux's own tag is the tiebreaker when the hook file is stale or absent.
        if let tag {
            return tag.label == "Running" ? .working : .ready
        }
        return session == nil ? .terminal : .ready
    }

    /// Which vector to draw.
    var markKey: String {
        session?.agent ?? tag?.agentKey ?? "fallback"
    }

    /// A workspace that has never loaded an AI is left out of the row entirely — the row
    /// is about agents, and a plain shell has nothing to report.
    var isVisible: Bool { state != .terminal }

    var detail: String {
        switch state {
        case .working: return "working"
        case .ready: return "done"
        case .terminal: return "terminal"
        }
    }

    var agentLabel: String? {
        session?.agent ?? tag?.agentKey
    }
}

/// Every mark carries its session color; these fractions separate states by brightness.
///
/// Dimming is done in color, not opacity: a settled mark is a *darker* version of its
/// session color at full opacity, so it stays true to its hue instead of blending into
/// the translucent menu bar. An earlier build tinted a working agent in cmux's Amber,
/// which overrode the session color exactly when you most want to know which project is
/// busy; identity now always survives, and state rides on brightness and motion.
enum Palette {
    /// Finished and not yet looked at — full brightness, the loudest a static mark gets.
    static let full: CGFloat = 1.0
    /// Finished and already seen — a dimmer static mark that still reads as its own color.
    static let settled: CGFloat = 0.70
    /// Floor of the working pulse: a mid-turn mark swings between this and full brightness.
    static let pulseFloor: CGFloat = 0.35

    /// Seconds per full pulse cycle.
    static let pulsePeriod: Double = 1.4
}

/// cmux's color handling, reproduced so Agentique renders the same shades cmux shows.
enum CmuxColor {
    static func from(hex: String?) -> NSColor? {
        guard let hex else { return nil }
        let body = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard body.count == 6, let value = UInt64(body, radix: 16) else { return nil }
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    /// Verbatim port of `WorkspaceTabColorSettings.brightenedForDarkAppearance`.
    static func brightenedForDarkAppearance(_ color: NSColor) -> NSColor {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        let boostedBrightness = min(1, max(brightness, 0.62) + ((1 - brightness) * 0.28))
        // Preserve neutral grays when brightening to avoid introducing hue shifts.
        let boostedSaturation = saturation <= 0.08
            ? saturation
            : min(1, saturation + ((1 - saturation) * 0.12))

        return NSColor(
            hue: hue,
            saturation: boostedSaturation,
            brightness: boostedBrightness,
            alpha: alpha
        )
    }

    /// Port of `WorkspaceTabColorSettings.displayNSColor`.
    static func display(hex: String?, isDark: Bool) -> NSColor? {
        guard let base = from(hex: hex) else { return nil }
        return isDark ? brightenedForDarkAppearance(base) : base
    }

    /// Dims a color to `fraction` of its brightness, keeping hue and saturation, so a
    /// dimmed mark reads as a darker version of the same color rather than a transparent
    /// one that blends into the menu bar behind it.
    static func dim(_ color: NSColor, to fraction: CGFloat) -> NSColor {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return NSColor(hue: hue, saturation: saturation, brightness: brightness * fraction, alpha: alpha)
    }
}
