# AgentDeck

A native macOS command centre for local AI coding agents: **Claude Code** and **Cursor**.
It uses the sign-ins you already have with those tools and adds no API keys or API billing.

## Build & run

```bash
./scripts/build-app.sh          # release build → build/AgentDeck.app (ad-hoc signed)
open build/AgentDeck.app
```

Requires macOS 14+, Xcode 16+ / Swift 6 toolchain. No third-party dependencies.

```bash
swift test                      # fixture tests for the provider formats AgentDeck reads
```
The first time AgentDeck reads a project in a protected folder (e.g. ~/Documents), macOS asks for access. AgentDeck only reads git metadata there.

## Architecture

```
Sources/AgentDeck/
  App/             SwiftUI app, menus & shortcuts, menu-bar extra, AppDelegate (notifications, quit safety)
  AgentCore/       Unified models (Agent, status, capabilities, events), AgentAdapter protocol, AgentManager
  Adapters/Claude  ClaudeAdapter, transcript reader, opt-in hooks relay
  Adapters/Cursor  CursorAdapter, ACP (Agent Client Protocol) JSON-RPC client
  Process/         ProcessRunner (async CLI exec), ProcessInspector (libproc), TerminalLauncher, FSEvents watcher
  Persistence/     SQLite wrapper + typed store (projects, agents, pins, events, settings)
  Projects/        Git detection (incl. linked worktrees) without spawning git
  DesignSystem/    Tokens (light/dark), status colours, shared components
  Views/           Sidebar, dashboard, cards, inspector, activity, projects, settings, new-agent flow
```

`AgentManager` (main actor) owns the adapters. It merges their snapshots into one registry, derives
activity events and notifications from state changes, and persists everything to SQLite. Refreshes are
event-driven (FSEvents on `~/.claude/projects`, `~/.cursor/chats` and the hook spool), with a configurable
fallback poll. Adapters are isolated: if one throws, it only marks that provider as degraded.
To add a provider, add a `ProviderKind` case and an `AgentAdapter` implementation; the UI doesn't change.

**Managed** agents were launched by AgentDeck and can be controlled from it. **Monitored** (discovered) agents are only observed.
Every action button comes from the agent's `AgentCapabilities`, so the UI never offers control it doesn't have.

## Integrations

| | Claude Code | Cursor |
|---|---|---|
| Discovery | `claude agents --json --all` (live interactive + background sessions); recent transcripts for resumable sessions | `~/.cursor/chats/<md5(cwd)>/<id>/meta.json` + plain `meta` row of `store.db` (read-only; encrypted blobs never read); liveness inferred from running `cursor-agent` processes |
| Launch (managed) | `claude --bg -n … [--model] [--permission-mode] [--worktree] <task>` | `cursor-agent acp`: `initialize` → `session/new` → `session/set_model`/`set_mode` → `session/prompt` |
| Launch (terminal) | `claude --session-id <uuid> …` in your terminal | `cursor-agent --workspace … <task>` in your terminal |
| Status | `busy`/`idle` + background `state`; permission prompts via optional hooks | ACP `session/update` (messages, tool calls, plan progress), `stopReason` |
| Approvals | Answered in Claude Code (AgentDeck shows "waiting for approval") | ACP `session/request_permission` relayed to the inspector; you pick an option |
| Stop / interrupt | `claude stop <id>` (background sessions) | `session/cancel`, process termination (ACP sessions) |
| Focus / resume | Activate the hosting app; `claude attach <id>`; `claude --resume <session>` | Open workspace in Cursor; `cursor-agent --resume <chat>` |
| Model | From session transcript (best effort) | ACP `currentModelId`; not exposed for terminal chats |
| Auth | `claude auth status` (warns if not claude.ai auth) | `cursor-agent status` |

### Desktop apps

| | Claude app (Code tab) | Cursor app |
|---|---|---|
| Discovery | Session files in `~/Library/Application Support/Claude/claude-code-sessions/…/local_*.json` map Claude sessions to the app (title, `local_` id) | `globalStorage/state.vscdb`: `composerHeaders` + `composerData:<id>` (name, folder, status, model, context %, lines changed), read-only via `json_extract` |
| Running / waiting | From Claude Code (CLI listing + hooks) | Cursor doesn't save "running", so it's inferred from live message records (`bubbleId:<chat>:…`): a tool call `loading`, or a message in the last 90 s. A loading `ask_question` = waiting for input; `hasBlockingPendingActions` = waiting for approval |
| Open exact session | `claude://code/continue?session=local_<id>` | AgentDeck Bridge: `composer.openComposer` |
| Start new | `claude://code/new?folder=…&q=…` (opens prefilled; you press Enter) | AgentDeck Bridge: `composer.createNew` with the prompt, auto-submitted |
| Approve / reject | Answered in the app | AgentDeck Bridge: `composer.accept/rejectPendingFromNotification` (inspector or notification buttons) |

### AgentDeck Bridge (Cursor extension)
`integrations/cursor-bridge/`: about 100 lines, no network access. It handles `cursor://agentdeck.agentdeck-bridge/open|decide|new`.
`decide` and `new` act on your behalf, so they require a random token stored 0600 at
`~/Library/Application Support/AgentDeck/bridge-token`. A web page or another app that knows the link format can't use them.
Install it from Settings → Integrations → Cursor (it ships inside AgentDeck.app) or with `integrations/cursor-bridge/build.sh`.
The bridge calls Cursor commands that aren't documented, so a Cursor update may break it. AgentDeck then falls back to bringing the right window forward.

AgentDeck removes `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN` and `CURSOR_API_KEY` from the processes it spawns, so a launch can never quietly move to API billing.

### Optional Claude Code hooks
Settings → Integrations → *Precise status via Claude Code hooks*. This adds a relay command to
`~/.claude/settings.json` (a timestamped backup is written first) for SessionStart, UserPromptSubmit, Pre/PostToolUse,
PermissionRequest, Notification, Stop and SessionEnd. The relay only copies the hook payload into
`~/Library/Application Support/AgentDeck/hooks/spool` and always exits 0, so it can never approve or block anything.
Turning the toggle off removes exactly those entries.

## Known limitations
- Cursor app chats come from Cursor's internal database, which may change. When a reader stops matching, Settings and the status bar show a warning instead of chats silently disappearing.
- A Cursor run's end is detected up to ~90 s late, because Cursor doesn't save "running".
- Without the bridge, opening a Cursor app chat brings the right window forward but can't select the chat.
- Claude app sessions started from AgentDeck open prefilled; you start them in the app.
- Cursor CLI chats started in a terminal expose no model or live state. "Running" is inferred from processes.
- Interactive Claude Code sessions belong to their terminal or the Claude app. AgentDeck can bring that app forward but can't stop them.
- Claude transcripts aren't a stable API, so model, title and branch are read best-effort.
- ACP agents are child processes of AgentDeck and end when it quits (you're asked to confirm). Their chats stay resumable.
- `session/list` over ACP doesn't currently return CLI chats, so discovery reads the local chat store instead.

## Privacy
All data stays local in `~/Library/Application Support/AgentDeck` (owner-only permissions). AgentDeck stores
metadata only: no credentials and no conversation content. No telemetry.

## Shortcuts
⌘N new agent · ⌘K / ⌥⌘K (any app) jump to an agent · ⌘F search · ⌘1–4 sections · ⌘⇧A all agents · ⌘⇧W needs attention ·
⌘↩ focus · ⌘⇧P pin · ⌘. interrupt · ⌘R refresh · ⌘⌥I inspector

## Development aids
- `AGENTDECK_DEBUG=1`: refresh diagnostics on stderr.
- `--snapshot <png> [delay]`: render the main window to a PNG (`AGENTDECK_SECTION=settings|activity|projects|all`).
- `--dev-launch <claude|cursor> <dir> <mode> <task>`: exercise the managed launch path without the UI.
