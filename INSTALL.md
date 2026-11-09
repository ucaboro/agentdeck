# Installing AgentDeck

AgentDeck is built from source. One script does everything: [`scripts/install.sh`](scripts/install.sh).

```bash
git clone https://github.com/ucaboro/agentdeck.git
cd agentdeck
./scripts/install.sh
```

| Option | What it does |
|---|---|
| `--check` | Only check requirements; change nothing |
| `--dest DIR` | Install somewhere else (default `/Applications`, or `~/Applications` if that isn't writable) |
| `--with-cursor-bridge` | Also install the AgentDeck Bridge extension into Cursor |
| `--no-open` | Don't launch AgentDeck afterwards |

Exit codes: `0` success · `1` a requirement is missing · `2` build failed · `3` install failed · `64` bad option.
Running it again updates an existing install.

**Requirements:** macOS 14+, Xcode 16+ (Swift 6). Claude Code and/or Cursor, signed in, so there's something to show.

**Uninstall:** quit AgentDeck, delete `AgentDeck.app`, and optionally delete
`~/Library/Application Support/AgentDeck`. If you turned on Claude Code hooks, turn them off in
*Settings → Integrations* first; that removes AgentDeck's entries from `~/.claude/settings.json`.

---

## Instructions for AI coding agents

Use this section if a user asked you (Claude Code, Cursor, Codex or similar) to install AgentDeck for them. Follow the
steps in order and report the result of each.

### 1. Check requirements

```bash
git clone https://github.com/ucaboro/agentdeck.git ~/agentdeck   # skip if already cloned; or use the folder the user chose
cd ~/agentdeck
./scripts/install.sh --check
```

- Exit `0`: continue.
- Exit `1`: stop. Tell the user exactly what's missing using the script's output. The usual fix is installing or
  updating Xcode from the App Store, which the user must do themselves.

### 2. Install

```bash
./scripts/install.sh
```

- Add `--with-cursor-bridge` **only if the user uses the Cursor app and agreed to install a Cursor extension.**
- The first build takes one to three minutes. Run it in the foreground and wait for it to finish.
- Exit `2` (build failed): show the user the last 30 lines of output. Don't change the source code to make it build.
- Exit `3` (install failed): if `/Applications` isn't writable, re-run with `--dest ~/Applications`.

### 3. Verify

```bash
test -d /Applications/AgentDeck.app || test -d ~/Applications/AgentDeck.app && echo installed
pgrep -x AgentDeck >/dev/null && echo running
```

Both lines should print. If AgentDeck isn't running, start it with `open -a AgentDeck`.

### 4. Hand over to the user

Tell the user:

1. AgentDeck is installed and where.
2. macOS may ask once for access to folders such as `~/Documents`. AgentDeck only reads git metadata there.
3. Optional settings they can turn on themselves in *AgentDeck → Settings → Integrations*:
   - **Show when Claude is waiting for you**: adds a hook to `~/.claude/settings.json` (with a backup) so AgentDeck can
     show approvals and questions from Claude sessions.
   - **AgentDeck Bridge for Cursor**, if not installed in step 2. After installing, run
     *Developer: Restart Extension Host* in each open Cursor window.

### Rules for agents

- **Don't** edit `~/.claude/settings.json`, Cursor settings or any other configuration yourself. The optional
  integrations are switched on by the user inside AgentDeck.
- **Don't** sign in, create accounts, or enter API keys or tokens. AgentDeck uses the user's existing Claude and Cursor
  sign-ins and never needs an API key.
- **Don't** use `sudo`, disable Gatekeeper, or change security settings. If something needs elevated rights, stop and
  ask the user.
- **Don't** modify the AgentDeck source to work around a failure; report the error instead.
- Ask before installing anything that isn't covered here, such as Xcode, Claude Code or Cursor.
