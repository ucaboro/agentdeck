# Contributing to AgentDeck

Thanks for helping improve AgentDeck. This guide covers how to report problems, propose changes and send a pull request.

## Reporting bugs and requesting features

- Search [existing issues](https://github.com/ucaboro/agentdeck/issues) first.
- Use the **Bug report** or **Feature request** template. For bugs, include your macOS version, the Claude Code and/or
  Cursor versions (`claude --version`, `cursor-agent --version`, Cursor → About), and what you expected to see.
- If a provider update broke something, say so: AgentDeck reads some undocumented local formats, and those reports are
  the most useful ones.
- **Don't paste conversation content, tokens or private paths** into issues. Redact them.
- Security problems go through [SECURITY.md](SECURITY.md), not public issues.

## Development setup

Requirements: macOS 14+, Xcode 16+ (Swift 6 toolchain). There are no third-party dependencies.

```bash
swift build                  # debug build
swift test                   # tests
./scripts/build-app.sh       # release .app bundle in build/
open build/AgentDeck.app
```

`AGENTDECK_DEBUG=1` prints refresh diagnostics to stderr. The Cursor extension lives in
`integrations/cursor-bridge`; `./build.sh` there packages and installs it.

## Pull requests

1. Fork the repo and create a branch from `main` (`feat/…`, `fix/…`, `docs/…`).
2. Keep each PR focused on one change. Open an issue first for anything large.
3. Make sure `swift build` and `swift test` pass. CI runs both on every PR.
4. Add or update tests when you change how a provider format is read
   ([`Tests/AgentDeckTests/FormatTests.swift`](Tests/AgentDeckTests/FormatTests.swift)). Base fixtures on real records,
   trimmed to the fields AgentDeck uses and with personal data removed.
5. Update the README when behaviour, settings or integrations change.
6. Describe what you changed and how you tested it in the PR template.

## Principles

These come from AgentDeck's design and are checked in review:

- **Use only what providers really expose.** Don't invent CLI flags, APIs or capabilities. Read local formats
  read-only and tolerate missing fields.
- **Never bypass approvals** and never run a command without the user's explicit action. Show the command first.
- **Subscription sign-in only.** Never add an API-key or API-billed path, and keep stripping API keys from child
  processes.
- **No made-up numbers.** Show progress or usage only when the provider records it.
- **Local and private.** No telemetry, no network calls, no storing conversation content or credentials.
- **Capabilities drive the UI.** Only show an action if `AgentCapabilities` says it can be done.

## Code style

Follow the existing Swift style: SwiftUI views in `Views/`, provider logic behind `AgentAdapter`, `@MainActor` state in
`AgentManager`. Prefer small, readable functions and comments that explain *why*.

## Code of Conduct

This project follows the [Code of Conduct](CODE_OF_CONDUCT.md). By participating, you agree to uphold it.
