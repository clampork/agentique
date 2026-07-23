# Design notes

Why Agentique reads cmux the way it does, and why the state model ended up this small.
For what the app is and how to install it, see the [README](README.md).

## Where state comes from

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

## Color

The session color is the Workspace's `custom_color`, which cmux shares across a Workspace
Group's members. On a dark bar it is brightened first, so the shade matches what cmux
renders in dark mode rather than the raw hex.

## Design decisions

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
