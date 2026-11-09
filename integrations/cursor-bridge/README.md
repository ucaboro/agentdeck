# AgentDeck Bridge

A small Cursor extension that lets AgentDeck work with Cursor's agent chats.

| Link | What it does | Token |
|---|---|---|
| `cursor://agentdeck.agentdeck-bridge/open?chat=<id>` | Shows that chat (`composer.openComposer`). | no |
| `…/decide?chat=<id>&decision=accept\|reject&token=<t>` | Accepts or rejects what the chat is waiting on (the commands behind Cursor's own approval notifications). | yes |
| `…/new?prompt=<text>&mode=agent\|plan\|chat&token=<t>` | Starts a chat in the current window and submits the prompt. | yes |

`decide` and `new` act on your behalf, so they require a random token that AgentDeck writes to
`~/Library/Application Support/AgentDeck/bridge-token` (mode 0600). A web page or another app that
knows the link format can't use them without it. The extension has no network access and reads no
other files.

The first time AgentDeck opens a link, Cursor asks whether to allow it. Tick "Do not ask again".

Build and install: `./build.sh` (writes `agentdeck-bridge-<version>.vsix` and installs it with the
`cursor` CLI). `./build.sh --no-install` only packages it.
