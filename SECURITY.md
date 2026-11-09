# Security policy

AgentDeck runs locally, reads other apps' local data and can start coding agents, so security reports are taken
seriously.

## Supported versions

Only the latest version on `main` is supported.

## Reporting a vulnerability

Please **don't open a public issue**. Report it privately through
[GitHub private vulnerability reporting](https://github.com/ucaboro/agentdeck/security/advisories/new).

Include what you found, how to reproduce it, and what an attacker could do with it. You should get an acknowledgement
within a few days. Once a fix is ready, the report is credited unless you'd rather stay anonymous.

## What's in scope

For example:

- Ways for a web page, another app or another user to make AgentDeck or the AgentDeck Bridge run commands, start
  agents or answer approvals (for example by bypassing the bridge token).
- AgentDeck storing or exposing credentials, tokens or conversation content.
- Ways to make AgentDeck use API-key or API-billed access without the user choosing it.
- Unsafe changes to `~/.claude/settings.json` by the hooks integration.

Bugs in Claude Code or Cursor themselves should be reported to Anthropic or Anysphere.
