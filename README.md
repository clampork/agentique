## What this is

Agentique — a macOS menu bar status item showing one mark per cmux workspace, colored
by session and animated by agent state.

## Build

```
./build.sh           # compile build/Agentique.app
./build.sh run       # compile and relaunch from build/
./build.sh install   # copy to /Applications, start at login
./build.sh uninstall
```

No dependencies beyond the Swift toolchain shipped with Xcode.

## cmux socket access (required)

cmux defaults `automation.socketControlMode` to `cmuxOnly`, which admits only processes
started inside cmux. Agentique runs from `/Applications` under launchd, so it is refused
with `Access denied - only processes started inside cmux can connect` and draws an empty
row. `~/.config/cmux/cmux.json` therefore sets:

```json
"automation": { "socketControlMode": "allowAll" }
```

followed by `cmux reload-config`. `password` mode plus `--password` on each call is the
narrower alternative if this ever needs tightening.

Anything launched from a cmux terminal inherits the capability, so testing from a cmux
shell passes even when the installed app cannot connect. `~/Library/Logs/Agentique.log`
records slot count and status item width once per launch to tell those cases apart.

## State mapping

Every mark is drawn in its workspace's session color. Color means identity — which
project — and never state, so a busy workspace is still identifiable at a glance. State
rides on opacity and motion instead:

| Condition | Treatment |
| --- | --- |
| Agent mid-turn | pulsing `settled`–100%, 1.4s cycle |
| Turn finished, not yet seen | 100%, static |
| Turn finished, already visited | `settled`, static |
| Plain terminal, no AI ever loaded | hidden entirely |

`Palette.settled` (0.60) is the one tunable: it is both the resting level of a seen mark
and the floor of the working pulse, so a working agent swings between resting and full
rather than introducing a second dim level.

There is no dimmer "stopped" tier. One existed briefly, but it was only reachable when a
session's process was alive while its lifecycle was `unknown` *and* cmux emitted no tag
for it — a case that essentially never fires. Every visible mark is a live agent, so the
two static levels differ only by whether you have looked at it yet.

An earlier build tinted a working agent in cmux's Amber. It was dropped because it
overrode the session color exactly when you most want to know *which* project is busy,
and because it competed with the workspace colors around it.

A workspace that has never loaded an AI is left out of the row: the row is about agents,
and a plain shell has nothing to report.

"Finished" and "waiting on you" are not separated, because for a coding agent they are
the same condition: a finished turn *is* the agent waiting. What is separated is whether
you have *seen* it: a turn that ends while you are looking elsewhere stays at full
opacity until you visit that workspace, then drops to `settled`. A turn that finishes
while you are watching never brightens at all. An earlier build drove this off unread
cmux notifications (`rpc notification.list`, `is_read == false`) instead — that signal
is the hook to restore if visiting ever proves too blunt.

Only live signals decide state. Hook files keep finished sessions around for restore, so
a workspace whose agent exited days ago still has history on disk — trusting that history
resurrected dead workspaces as live agents, which is why nothing but a live session or a
live cmux tag counts now.

`render()` compares a signature of the drawn row before touching the image, so refreshes
and appearance changes that produce an identical row cost nothing.

Folders are excluded. cmux models a sidebar folder as a workspace that anchors a group,
so `workspace list` returns folders and real workspaces indistinguishably; the anchors
come from `workspace.group.list` and are filtered out.

## Color

Session color is the workspace's `custom_color`, which cmux shares across a group's
members. On a dark bar it is brightened before drawing, so the shade matches what cmux
itself renders in dark mode rather than the raw hex.

## Agent artwork

Drop `Assets/agents/<agent>.<ext>` and rebuild — `pdf`, `svg`, or `png`, resolved in that
order. The name matches the agent key cmux uses: `claude`, `codex`, plus `fallback` for
the other agents cmux integrates with. A filled circle stands in for anything missing.

**Design at 256px tall, up to 460px wide, exported as SVG.** Height is the only fixed
dimension: every mark is scaled to `markSize` and width follows its aspect. Past 1.8:1 the
mark is fitted by width instead and ends up shorter than its neighbours. Transparent
margins are trimmed at load, so padding is irrelevant — but the *content* bounding box is
what sets the aspect, so a stray pixel resizes the whole mark.

Artwork is a silhouette: only the alpha channel survives, filled with the session color at
draw time. One flat color, no gradients or shading. At 14pt the mark is 28 physical pixels
tall on a 2x display, so anything under 2px — about 18px in a 256px frame — disappears.

Sizing lives at the top of `Sources/MarkRenderer.swift`: `markSize` 16pt, `gap` 10pt,
`height` 18pt. The mark is sized against the filled icons sharing the bar, which measure
~16pt tall. The gap is half the ~20pt rhythm macOS leaves between neighbouring status
items, so the row reads as one item rather than several. Spacing is uniform: an earlier
build widened the gap across a cmux group boundary, but group membership is no longer
drawn.

`Tools/preview-marks.py` writes `~/Desktop/agentique-marks.png` showing every mark at true
menu bar size — judge legibility on the small render, not the magnified one. Anything with
no artwork falls back to a filled circle.

## How state is read

- **Lifecycle**—`~/.cmuxterm/<agent>-hook-sessions.json`, written by the cmux agent hooks.
  Each session carries `agentLifecycle` (`running` | `idle` | `needsInput` | `unknown`),
  `workspaceId`, and `pid`. Entries are only trusted when the pid is still alive.
- **Agent identity**—the hook filename. Events also carry it as `_source`.
- **AI loaded at all**—`cmux top --all --processes` emits a per-workspace tag row
  (`workspace:<uuid>:tag:claude_code`) with a `Running`/`Idle` label. A workspace running
  only a shell emits no tag row, which is what distinguishes a plain terminal from a
  workspace whose agent exited.
- **Names, order, color**—`cmux workspace list --json --id-format both`, per window.
- **Change detection**—a `DispatchSource` watch on `~/.cmuxterm` (the hook files are
  replaced atomically, so the directory is what changes), debounced 120ms, with a 2s poll
  as a safety net. Workspaces, groups and tags refresh every 10s since `cmux top` samples
  CPU.

`cmux events --category agent --reconnect` is an available alternative source, carrying
the same information plus `workspace_id`. The session files already hold the resolved
lifecycle, so watching them avoids re-deriving state and keeps a subprocess out of the
picture.

## Interaction

Clicking a mark jumps straight to that workspace, via `cmux select-workspace` plus
activating cmux. Clicking the padding around the marks opens the workspace list instead,
as does any right-click or control-click. The status item deliberately has no attached
`menu`, since that would make every click open the list.

`--dump` prints the row to stdout, and `--preview <path>` renders it to a PNG over both
menu bar backgrounds — either one checks behaviour without reading the menu bar.
