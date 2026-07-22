# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-07-22

Initial release.

### Added

- A menu bar status item drawing one mark per cmux workspace, in that workspace's
  session color.
- Agent state shown by brightness and motion: a mid-turn agent pulses, a finished turn
  holds at full brightness until you visit its workspace, and a visited one settles.
- Workspaces that have never loaded an AI are left out of the row.
- Per-agent artwork loaded from `Assets/agents/<agent>.{pdf,svg,png}`, tinted at draw
  time, falling back to a filled circle.
- Click a mark to jump to its workspace; click the padding or right-click for the
  workspace list.
- `--dump`, `--preview <path>`, `--version` and `--help` for checking behaviour without
  reading the menu bar.
- `build.sh` with `build`, `run`, `install` and `uninstall`, installing a launch agent
  so the app starts at login.

[Unreleased]: https://github.com/clampork/agentique/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/clampork/agentique/releases/tag/v0.1.0
