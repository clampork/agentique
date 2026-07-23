# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Agentique—a macOS menu bar status item showing one glyph per cmux Workspace, colored by session and animated by agent state. cmux's own nouns (Workspace, Workspace Group) are the vocabulary in docs and prose. Single AppKit app, no Xcode project, no package manager: `swiftc` compiles `Sources/*.swift` directly.

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
build/Agentique.app/Contents/MacOS/Agentique --version         # reads CFBundleShortVersionString from the bundle
```

CI (`.github/workflows/ci.yml`) can only build and run `--version`/`--help`: a runner has no cmux, so `--dump` and `--preview` have nothing to report.

Artwork tooling (per the global Python rule, always via `uv`):

```
uv run --with pillow python3 Tools/preview-glyphs.py   # every glyph at true menu bar size → ~/Desktop
uv run --with pillow python3 Tools/preview-opacity.py  # compare Palette.settled candidates over a real menu bar screenshot
uv run --with pillow python3 Tools/make-demo.py        # regenerate docs/pulse.png and docs/click.png
swift Tools/rasterize.swift <in.svg|pdf> <out.png> <height>  # rasterize vectors for the Python tools
swift Tools/make-icon.swift                            # regenerate Assets/AppIcon.icns
```

`make-demo.py` is entirely synthetic—an invented Workspace row and a hand-drawn cmux mock—so the README renders identically everywhere, no real project names leak, and the images regenerate without cmux running. Its geometry and `Palette` constants are copied from the Swift and must be updated alongside it.

Runtime diagnostics land in `~/Library/Logs/Agentique.log` (slot count, status item placement, cmux command failures).

## Architecture

Four source files with a strict layering—cmux I/O, domain model, controller, drawing:

- **`CmuxBridge.swift`**—the only place that touches cmux. Shells out to the `cmux` binary (`workspace list`, `rpc workspace.group.list`, `top --all --processes`, `select-workspace`) and reads the hook session files `~/.cmuxterm/<agent>-hook-sessions.json`. Session entries are only trusted while their pid is alive; a `running` session whose transcript tail ends in a client-only command (`/clear`) is marked `parkedOnLocalCommand`.
- **`AgentState.swift`**—domain model. `AgentSlot` combines a `Workspace`, optional `AgentSession` (hook file), and optional `WorkspaceTag` (`cmux top`) into a `SlotState` (`working` / `ready` / `terminal`). Also holds `Palette` (brightness fractions and pulse timing—the tunables) and `CmuxColor`, which brightens Workspace colors for a dark bar so glyphs match the shades cmux renders.
- **`StatusRowController.swift`**—owns the single `NSStatusItem`. Refresh: a `DispatchSource` watch on `~/.cmuxterm` (debounced 120ms) plus a 2s poll; Workspaces, Workspace Groups and tags refresh on a 10s cadence, or immediately when the set of Workspaces with a live session changes. Tracks "unacknowledged" finished turns (ended while you looked elsewhere → full brightness until visited). `render()` skips redraws when a signature of the row is unchanged. Clicks on a glyph jump to that Workspace; clicks on padding or right-clicks open the menu—deliberately no attached `statusItem.menu`.
- **`GlyphRenderer.swift`**—draws the row image. Artwork from `Resources/agents/<key>.{pdf,svg,png}` is used as a silhouette: only the alpha channel survives, tinted with the session color at draw time. Transparent margins are trimmed at load. Sizing constants (`glyphSize`, `gap`, `height`, `edgeInset`) live at the top, and spacing is a single uniform gap.

`main.swift` handles the `--version`, `--help`, `--dump` and `--preview` CLI modes before starting the app.

## Invariants

- **Color means identity, never state.** Every glyph is drawn in its Workspace's session color; state rides on brightness and motion only. Dimming is done in color (a darker shade at full opacity), not alpha, so glyphs stay true to their hue over the translucent bar.
- **Only live signals decide state.** Hook files keep finished sessions for restore; a dead pid must never resurrect a Workspace as a live agent. A Workspace with no session and no tag has never loaded an agent and is hidden entirely.
- **Workspace Groups are excluded.** cmux models a Group as a Workspace that anchors it, so `workspace list` returns both indistinguishably; `workspace.group.list` supplies the anchors to filter out. Group membership still rides on `GlyphSpec.groupID` but no longer affects layout—it only feeds the redraw signature.

## Where the docs live

`README.md` is task-oriented: what it is, install, configure, use, customize, develop. `DESIGN.md` holds the internals and the rationale—where each signal comes from, the color matching, and the rejected alternatives. Keep rationale out of the README; it was extracted once already.

Four files restate values that live in the Swift: `README.md` (state table, sizing, artwork specs), `DESIGN.md` (the refresh cadences), `Tools/make-demo.py` (geometry and `Palette`, to draw the README media), and this file. `Palette` in `Sources/AgentState.swift` and the sizing block in `Sources/GlyphRenderer.swift` are the source of truth. Changing either means updating all four and re-running `make-demo.py`; this has drifted before.

## Releasing

Versioning is [SemVer](https://semver.org/spec/v2.0.0.html), pre-1.0. `CFBundleShortVersionString` in `Info.plist` is the single source of the version; `--version` reads it back out of the bundle. A release is: bump `Info.plist` (and `CFBundleVersion`), move the `CHANGELOG.md` entry out of Unreleased, commit, tag `vX.Y.Z`, push the tag, then `gh release create`.

## cmux socket access

The installed app runs under launchd, so cmux must allow non-cmux clients: `~/.config/cmux/cmux.json` sets `"automation": { "socketControlMode": "allowAll" }` (then `cmux reload-config`). Anything launched from a cmux terminal inherits access regardless—so a test passing from a cmux shell does not prove the installed app can connect; check the log's slot count.
