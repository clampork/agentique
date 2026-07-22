# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Agentique—a macOS menu bar status item showing one mark per cmux workspace, colored by session and animated by agent state. Single AppKit app, no Xcode project, no package manager: `swiftc` compiles `Sources/*.swift` directly.

## Commands

```
./build.sh           # compile build/Agentique.app
./build.sh run       # compile and relaunch from build/
./build.sh install   # copy to /Applications, start at login (launchd)
./build.sh uninstall
```

No tests or linter. Verification is headless, via the built binary:

```
build/Agentique.app/Contents/MacOS/Agentique --dump            # print the row's state mapping
build/Agentique.app/Contents/MacOS/Agentique --preview out.png # render the row over both menu bar backgrounds
```

Artwork tooling (per the global Python rule, always via `uv`):

```
uv run --with pillow python3 Tools/preview-marks.py    # every mark at true menu bar size → ~/Desktop
uv run --with pillow python3 Tools/preview-opacity.py  # compare Palette.settled candidates over a real menu bar screenshot
swift Tools/rasterize.swift <in.svg|pdf> <out.png> <height>  # rasterize vectors for the Python tools
swift Tools/make-icon.swift                            # regenerate Assets/AppIcon.icns
```

Runtime diagnostics land in `~/Library/Logs/Agentique.log` (slot count, status item placement, cmux command failures).

## Architecture

Four source files with a strict layering—cmux I/O, domain model, controller, drawing:

- **`CmuxBridge.swift`**—the only place that touches cmux. Shells out to the `cmux` binary (`workspace list`, `rpc workspace.group.list`, `top --all --processes`, `select-workspace`) and reads the hook session files `~/.cmuxterm/<agent>-hook-sessions.json`. Session entries are only trusted while their pid is alive; a `running` session whose transcript tail ends in a client-only command (`/clear`) is marked `parkedOnLocalCommand`.
- **`AgentState.swift`**—domain model. `AgentSlot` combines a `Workspace`, optional `AgentSession` (hook file), and optional `WorkspaceTag` (`cmux top`) into a `SlotState` (`working` / `ready` / `terminal`). Also holds `Palette` (brightness fractions and pulse timing—the tunables) and `CmuxColor`, which brightens workspace colors for a dark bar so marks match the shades cmux renders.
- **`StatusRowController.swift`**—owns the single `NSStatusItem`. Refresh: a `DispatchSource` watch on `~/.cmuxterm` (debounced 120ms) plus a 2s poll; workspaces/groups/tags refresh on a 10s cadence, or immediately when the set of live-session workspaces changes. Tracks "unacknowledged" finished turns (ended while you looked elsewhere → full brightness until visited). `render()` skips redraws when a signature of the row is unchanged. Clicks on a mark jump to that workspace; clicks on padding or right-clicks open the menu—deliberately no attached `statusItem.menu`.
- **`MarkRenderer.swift`**—draws the row image. Artwork from `Resources/agents/<key>.{pdf,svg,png}` is used as a silhouette: only the alpha channel survives, tinted with the session color at draw time. Transparent margins are trimmed at load. Sizing constants (`markSize`, `gap`, `height`, `edgeInset`) live at the top; spacing is a single uniform gap, not the per-group pair the README still describes.

`main.swift` handles the `--dump`/`--preview` CLI modes before starting the app.

## Invariants

- **Color means identity, never state.** Every mark is drawn in its workspace's session color; state rides on brightness and motion only. Dimming is done in color (a darker shade at full opacity), not alpha, so marks stay true to their hue over the translucent bar.
- **Only live signals decide state.** Hook files keep finished sessions for restore; a dead pid must never resurrect a workspace as a live agent. A workspace with no session and no tag has never loaded an AI and is hidden entirely.
- **Folders are excluded.** cmux models a sidebar folder as an anchor workspace; `workspace.group.list` supplies the anchors to filter and the group membership used for spacing.

## README vs code

`README.md` is the design document—rationale for the state mapping, rejected alternatives, and artwork specs. Constants quoted there can drift; `Palette` in `Sources/AgentState.swift` and the sizing block in `Sources/MarkRenderer.swift` are the source of truth (e.g. the README currently says `settled` is 0.60 and calls it the pulse floor; the code has `settled` 0.70 with a separate `pulseFloor` 0.35). When changing behavior or constants, update the README to match.

## cmux socket access

The installed app runs under launchd, so cmux must allow non-cmux clients: `~/.config/cmux/cmux.json` sets `"automation": { "socketControlMode": "allowAll" }` (then `cmux reload-config`). Anything launched from a cmux terminal inherits access regardless—so a test passing from a cmux shell does not prove the installed app can connect; check the log's slot count.
