# Changelog

All notable changes are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- `scripts/install.sh`: one-step, re-runnable installer with requirement checks and exit codes.
- `INSTALL.md` with step-by-step instructions for AI coding agents, and a copy-paste install prompt in the README.

### Fixed
- `build-app.sh` builds for the Mac's own architecture, so it works on Intel Macs too.

## [0.1.0] - 2026-11-09

### Added
- Dashboard for Claude Code and Cursor agents: terminal and background sessions, the Claude app's Code tab, Cursor app
  chats and Cursor CLI chats, grouped by project and git worktree.
- Statuses: working, idle, waiting for approval, waiting for input, completed, failed, not running.
- Open the exact session in the Claude app or the exact chat in Cursor (via the AgentDeck Bridge extension).
- Accept / reject Cursor approvals from AgentDeck and from notifications.
- Start agents in the Claude app, the Cursor app, as managed background / ACP sessions, or in a terminal.
- Optional Claude Code hooks for precise waiting states.
- Notifications, waiting reminders, quick switcher (⌘K, ⌥⌘K from any app), pins, archive and auto-archive.
- Usage on cards (lines changed, files, context) when the provider records it; GitHub / GitLab / Bitbucket links.
- Activity log with daily summaries.
- Warnings when a provider's local format changes; fixture tests for those formats.
