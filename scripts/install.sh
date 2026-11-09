#!/bin/zsh
# AgentDeck installer: checks requirements, builds from source and installs AgentDeck.app.
# Non-interactive and safe to run again (it replaces an existing install of AgentDeck only).
#
# Usage: scripts/install.sh [--dest DIR] [--with-cursor-bridge] [--no-open] [--check]
#   --dest DIR             install into DIR (default: /Applications, or ~/Applications if not writable)
#   --with-cursor-bridge   also install the AgentDeck Bridge extension into Cursor (needs Cursor installed)
#   --no-open              don't launch AgentDeck afterwards
#   --check                only check requirements, change nothing
#
# Exit codes: 0 success · 1 requirement missing · 2 build failed · 3 install failed · 64 bad usage
#
# What this script never does: change Claude Code or Cursor settings, sign in to anything,
# enable Claude Code hooks, or send data anywhere.
set -euo pipefail
cd "$(dirname "$0")/.."

DEST=""; BRIDGE=0; OPEN=1; CHECK_ONLY=0
while (( $# )); do
  case "$1" in
    --dest) DEST="${2:?--dest needs a directory}"; shift 2 ;;
    --with-cursor-bridge) BRIDGE=1; shift ;;
    --no-open) OPEN=0; shift ;;
    --check) CHECK_ONLY=1; shift ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1 (see --help)" >&2; exit 64 ;;
  esac
done

ok()   { print -P "%F{green}✔%f $*"; }
warn() { print -P "%F{yellow}!%f $*"; }
fail() { print -P "%F{red}✘%f $*" >&2; }
step() { print -P "\n%B==> $*%b"; }

# --- Requirements -------------------------------------------------------------------------------
step "Checking requirements"
missing=0

os_version="$(sw_vers -productVersion)"
if [[ "$(uname -s)" != "Darwin" ]]; then
  fail "AgentDeck is a macOS app (this is $(uname -s))."; exit 1
elif (( ${os_version%%.*} < 14 )); then
  fail "macOS 14 or later is required (found $os_version)."; missing=1
else
  ok "macOS $os_version ($(uname -m))"
fi

if ! xcode-select -p >/dev/null 2>&1 || ! command -v swift >/dev/null 2>&1; then
  fail "Swift toolchain not found. Install Xcode 16+ from the App Store (or run: xcode-select --install), then re-run."
  missing=1
else
  swift_line="$(swift --version 2>&1 | grep -o 'Swift version [0-9.]*' | head -1)"
  swift_major="$(echo "$swift_line" | grep -o '[0-9][0-9]*' | head -1)"
  if [[ -z "$swift_major" || "$swift_major" -lt 6 ]]; then
    fail "Swift 6 or later is required (found: ${swift_line:-unknown}). Update Xcode to 16+."; missing=1
  else
    ok "$swift_line"
  fi
fi

# Providers are optional: AgentDeck shows whatever is installed.
providers=0
if command -v claude >/dev/null 2>&1; then ok "Claude Code CLI: $(claude --version 2>/dev/null | head -1)"; providers=1
elif [[ -d "/Applications/Claude.app" ]]; then ok "Claude app found"; providers=1
else warn "Claude Code not found (optional): https://docs.claude.com/en/docs/claude-code"; fi
if [[ -d "/Applications/Cursor.app" ]]; then ok "Cursor app found"; providers=1; fi
if command -v cursor-agent >/dev/null 2>&1; then ok "Cursor CLI: $(cursor-agent --version 2>/dev/null | head -1)"; providers=1; fi
(( providers )) || warn "Neither Claude Code nor Cursor was found. AgentDeck will run but show no agents until one is installed."

if (( missing )); then fail "Requirements missing; nothing was installed."; exit 1; fi
if (( CHECK_ONLY )); then ok "All requirements met."; exit 0; fi

# --- Build --------------------------------------------------------------------------------------
step "Building AgentDeck (release; first build takes a minute or two)"
if ! ./scripts/build-app.sh; then fail "Build failed. Re-run with output above and see CONTRIBUTING.md."; exit 2; fi

# --- Install ------------------------------------------------------------------------------------
if [[ -z "$DEST" ]]; then
  if [[ -w /Applications ]]; then DEST=/Applications; else DEST="$HOME/Applications"; fi
fi
mkdir -p "$DEST"
TARGET="$DEST/AgentDeck.app"

step "Installing to $TARGET"
# Only quit an AgentDeck that is running from the copy being replaced.
running_from_target() {
  local pid
  for pid in $(pgrep -x AgentDeck 2>/dev/null); do
    [[ "$(ps -o comm= -p "$pid" 2>/dev/null)" == "$TARGET/Contents/MacOS/AgentDeck" ]] && { echo "$pid"; return 0; }
  done
  return 1
}
if pid="$(running_from_target)"; then
  kill -TERM "$pid" 2>/dev/null || true
  for _ in {1..20}; do running_from_target >/dev/null || break; sleep 0.25; done
  running_from_target >/dev/null && { fail "AgentDeck is still running from $TARGET; quit it and re-run."; exit 3; }
  ok "Quit the running AgentDeck"
fi
if [[ -e "$TARGET" ]]; then
  existing_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$TARGET/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$existing_id" != "app.agentdeck.AgentDeck" ]]; then
    fail "$TARGET exists and isn't AgentDeck (bundle id: ${existing_id:-unknown}); not replacing it."; exit 3
  fi
  rm -rf "$TARGET"
fi
if ! ditto build/AgentDeck.app "$TARGET"; then fail "Could not copy the app to $DEST."; exit 3; fi
ok "Installed $TARGET ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$TARGET/Contents/Info.plist"))"

# --- Optional Cursor bridge ---------------------------------------------------------------------
if (( BRIDGE )); then
  step "Installing the AgentDeck Bridge into Cursor"
  CURSOR_CLI="/Applications/Cursor.app/Contents/Resources/app/bin/cursor"
  if [[ -x "$CURSOR_CLI" ]]; then
    vsix="$(ls "$TARGET"/Contents/Resources/agentdeck-bridge-*.vsix | head -1)"
    if "$CURSOR_CLI" --install-extension "$vsix" --force >/dev/null 2>&1; then
      ok "Bridge installed. In each open Cursor window run: Developer: Restart Extension Host"
    else
      warn "Cursor didn't accept the extension; install it later from AgentDeck → Settings → Integrations → Cursor."
    fi
  else
    warn "Cursor not found at /Applications/Cursor.app; skipped the bridge."
  fi
fi

# --- Done ---------------------------------------------------------------------------------------
if (( OPEN )); then open "$TARGET"; ok "AgentDeck launched"; fi
print -P "\n%BDone.%b Next steps (in AgentDeck):"
print "  • Settings → Integrations shows whether Claude Code and Cursor were detected."
print "  • Optional: turn on 'Show when Claude is waiting for you' (adds a hook to ~/.claude/settings.json, with a backup)."
(( BRIDGE )) || print "  • Optional: install the Cursor bridge there to open exact Cursor chats and answer approvals."
print "  • macOS may ask for access to folders like ~/Documents the first time; AgentDeck only reads git metadata there."
