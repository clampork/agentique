<h1 align="center">Agentique</h1>

<p align="center">
  <img src="docs/pulse.png" width="334" alt="A row of colored glyphs; two pulse while their agents work.">
</p>

<p align="center">
  One glyph per <a href="https://www.cmux.dev/">cmux</a> Workspace in the macOS menu bar,
  colored by project and animated by what its agent is doing.
</p>

<p align="center">
  <a href="https://github.com/clampork/agentique/actions/workflows/ci.yml"><img src="https://github.com/clampork/agentique/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/clampork/agentique/releases/latest"><img src="https://img.shields.io/github/v/release/clampork/agentique?sort=semver" alt="Latest release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="License"></a>
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B%20Apple%20Silicon-lightgrey" alt="Platform">
</p>

## Why

The menu bar is the one strip of screen no window covers. Agentique puts your agents
there, so cmux can sit behind your editor or your browser while you work. A glance tells
you which Workspaces are still thinking and which one has stopped and is waiting on you;
clicking its glyph drops you straight into that Workspace.

## What the glyphs mean

Color is identity, never state. Every glyph is drawn in its Workspace's cmux color, so a
busy project stays recognizable as *that* project. State rides on brightness and motion:

| Condition | Treatment |
| --- | --- |
| Agent mid-turn | pulsing |
| Turn finished, not yet seen | full brightness |
| Turn finished, already visited | dimmed |
| Plain terminal, no agent ever loaded | hidden |

Glyphs dim by color rather than opacity, so a resting one is a darker shade of itself
instead of a translucent one bleeding into the bar behind it.

## Requirements

- **macOS 14 or later.** Agentique builds against 13, but cmux needs 14.
- **Apple Silicon.** The build targets `arm64`.
- **[cmux](https://www.cmux.dev/)**, with at least one Workspace.
- **Xcode Command Line Tools**, for the Swift compiler. Full Xcode also works.

## Install

There is no prebuilt download: shipping a macOS app that opens without a Gatekeeper
warning needs a paid Apple Developer ID. Building it yourself takes seconds and avoids
that.

```sh
xcode-select --install        # skip if you have them
brew install --cask cmux      # skip if you have it

git clone https://github.com/clampork/agentique.git
cd agentique
./build.sh install
```

That compiles the app, copies it to `/Applications`, and registers a launch agent so it
starts at login. Then grant socket access, or the row comes up empty.

### Granting cmux socket access

cmux defaults `automation.socketControlMode` to `cmuxOnly`, which admits only processes
started inside cmux. Agentique runs from `/Applications` under launchd, so it is refused
with `Access denied - only processes started inside cmux can connect`. Add to
`~/.config/cmux/cmux.json`:

```json
{
  "automation": { "socketControlMode": "allowAll" }
}
```

then run `cmux reload-config`.

`allowAll` lets any local process drive cmux. `password` mode is the narrower option,
though Agentique does not yet pass one.

### Checking it worked

Glyphs should appear within a couple of seconds. If the row is empty:

```sh
/Applications/Agentique.app/Contents/MacOS/Agentique --dump
```

Mind the catch: anything launched from a cmux terminal inherits socket access whatever
`socketControlMode` says, so `--dump` can succeed in a cmux shell while the installed app
is still refused. `~/Library/Logs/Agentique.log` records the glyph count once per launch,
which tells the two apart.

### Uninstalling

```sh
./build.sh uninstall
```

## Using it

Click a glyph to jump to its Workspace. Click the padding around them, or right-click
anywhere on the item, for the Workspace list. The status item has no attached menu on
purpose, since that would make every click open the list.

## Custom agent artwork

Drop `Assets/agents/<agent>.<ext>` and rebuild. `pdf`, `svg` and `png` resolve in that
order, and the name matches the agent key cmux uses: `claude`, `codex`, plus `fallback`
for anything else. Missing artwork falls back to a filled circle.

**Design at 256px tall, up to 460px wide, exported as SVG.** Height is the only fixed
dimension: glyphs scale to `glyphSize` and width follows the aspect ratio. Past 1.8:1 a
glyph is fitted by width instead and ends up shorter than its neighbours. Transparent
margins are trimmed on load, so padding is irrelevant, but the *content* bounding box sets
the aspect ratio, so a stray pixel resizes the whole glyph.

Only the alpha channel survives; the shape is flooded with the session color at draw time.
One flat color, no gradients. At 16pt a glyph is 32 physical pixels tall on a 2x display,
so anything under 2px, roughly 16px in a 256px frame, disappears.

## How it works

### Where state comes from

- **Lifecycle**—`~/.cmuxterm/<agent>-hook-sessions.json`, written by the cmux agent hooks.
  Each session carries `agentLifecycle` (`running` | `idle` | `needsInput` | `unknown`),
  `workspaceId` and `pid`. Entries count only while the pid is alive.
- **Agent identity**—the hook filename.
- **Whether an agent is loaded at all**—`cmux top --all --processes` emits a per-Workspace
  tag row (`workspace:<uuid>:tag:claude_code`) labelled `Running` or `Idle`. A Workspace
  running only a shell emits none, which is what separates a plain terminal from one whose
  agent exited.
- **Names, order and color**—`cmux workspace list --json --id-format both`, per window.
- **Change detection**—a `DispatchSource` watch on `~/.cmuxterm`, debounced 120ms, with a
  2s poll behind it. The hook files are replaced atomically, so the directory is what
  changes. Workspaces, Workspace Groups and tags refresh every 10s, since `cmux top`
  samples CPU.

`cmux events --category agent --reconnect` carries the same information plus
`workspace_id`. The session files already hold the resolved lifecycle, so watching them
avoids re-deriving state and keeps a subprocess out of the picture.

Only live signals count. Hook files keep finished sessions around for restore, so a
Workspace whose agent exited days ago still has history on disk. Trusting it resurrected
dead Workspaces as live agents, which is why nothing but a live session or a live cmux tag
counts now.

### Color

The session color is the Workspace's `custom_color`, which cmux shares across a Workspace
Group's members. On a dark bar it is brightened first, so the shade matches what cmux
renders in dark mode rather than the raw hex.

### Design decisions

There is no dimmer "stopped" tier. One existed briefly, reachable only when a session's
process was alive while its lifecycle was `unknown` *and* cmux emitted no tag, which
essentially never fires. Every visible glyph is a live agent, so the two static levels
differ only by whether you have looked at it.

An earlier build tinted working agents in cmux's Amber. It overrode the session color
exactly when you most want to know *which* project is busy.

A Workspace that has never loaded an agent is left out: the row is about agents, and a
plain shell has nothing to report.

"Finished" and "waiting on you" are not separated, because for a coding agent they are the
same thing: a finished turn *is* the agent waiting. What is separated is whether you have
*seen* it. A turn ending while you look elsewhere stays bright until you visit that
Workspace; one finishing while you watch never brightens. An earlier build drove this off
unread cmux notifications (`rpc notification.list`, `is_read == false`), the hook to
restore if visiting proves too blunt.

Workspace Groups are filtered out. cmux models a Group as a Workspace that anchors it, so
`workspace list` returns both indistinguishably; the anchors come from
`workspace.group.list`.

`render()` compares a signature of the row before touching the image, so refreshes that
produce an identical row cost nothing.

## Development

```sh
./build.sh          # compile build/Agentique.app
./build.sh run      # compile, then relaunch from build/
./build.sh install  # compile, copy to /Applications, start at login
./build.sh uninstall
```

No dependencies and no Xcode project: `build.sh` runs `swiftc` over `Sources/*.swift`.

Two flags check behaviour without reading the menu bar:

```sh
build/Agentique.app/Contents/MacOS/Agentique --dump             # the row, as text
build/Agentique.app/Contents/MacOS/Agentique --preview out.png  # the row, over both bar backgrounds
```

Sizing lives at the top of `Sources/GlyphRenderer.swift`: `glyphSize` 16pt, `gap` 10pt,
`height` 18pt. Glyphs are sized against the filled icons sharing the bar, which run about
16pt tall, and the gap is half the roughly 20pt rhythm macOS leaves between status items,
so the row reads as one item rather than several.

Supporting scripts, run from the repository root:

```sh
uv run --with pillow python3 Tools/preview-glyphs.py   # every glyph at true menu bar size
uv run --with pillow python3 Tools/preview-opacity.py  # compare resting-brightness candidates
uv run --with pillow python3 Tools/make-demo.py        # regenerate docs/pulse.png
swift Tools/rasterize.swift <in.svg|pdf> <out.png> <height>
swift Tools/make-icon.swift                            # regenerate Assets/AppIcon.icns
```

`preview-glyphs.py` and `preview-opacity.py` write to `~/Desktop` and read the live row,
so judge legibility on the actual-size render, not the magnified one.

## License

[MIT](LICENSE). An independent project, not affiliated with cmux.
