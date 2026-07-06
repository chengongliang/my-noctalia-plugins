# Hermes Agent

Native Noctalia plugin for Hermes Agent.

Source: [`Nomadcxx/legacy-v4-plugins:add-hermes-agent`](https://github.com/Nomadcxx/legacy-v4-plugins/tree/add-hermes-agent).

Shows live Hermes status in the bar, provides a full chat panel with streaming responses, tool-event activity, approval prompts, interrupt, one-shot prompts, and a launcher provider using `>hermes`.

## Features

- **Bar widget**: traffic-light status indicator (online / busy / needs you / degraded / offline) with click-to-expand summary popup.
- **Panel**: persistent chat with Hermes — send prompts, watch streaming responses, approve tool calls, interrupt, start / resume sessions.
- **Launcher provider**: type `>hermes` in the Noctalia launcher to open the panel, start a session, resume the latest session, or send a one-shot prompt.
- **Settings UI**: configure bridge host / port, state file, Hermes home, poll interval, default provider / model, auto-start bridge, hide-when-idle, pin panel, show tool activity.

## Requirements

- [Hermes Agent](https://github.com/Nomadcxx/legacy-v4-plugins/tree/add-hermes-agent) installed and on `PATH` (or set `hermesCommand` in settings).
- Noctalia 4.4.1 or newer.

## How it works

The plugin ships a small Python bridge (`scripts/hermes_bridge.py`) that exposes local HTTP endpoints for health, state, session, prompt, interrupt, approvals, and one-shot commands. The QML surfaces talk to the bridge and render state from a watched state file.

## Client-only mode (remote Hermes over SSH)

When Hermes runs on a **remote server**, the client machine has no bridge script,
no `~/.hermes`, and no token file — so the default local mode does not work.
Client-only mode keeps every feature (status, chat, approvals, sessions,
launcher) but drives a bridge running on the server, reached over an SSH tunnel.

The bridge binds to `127.0.0.1` on the server (no exposed port, token never
travels in plaintext); the SSH tunnel forwards it to the client.

**On the server** (where Hermes lives):

```bash
cd <plugin-dir>/scripts
./hermes-bridge-serve.sh 19777
```

It starts the bridge and prints the **bridge token**. Copy it.

**On the client**, open the tunnel:

```bash
ssh -L 19777:127.0.0.1:19777 <user>@<server>
```

**In the plugin settings** (Advanced):

1. Enable **Client-only mode (remote bridge)**.
2. Set **Bridge host** = `127.0.0.1`, **Bridge port** = `19777` (the forwarded port).
3. Paste the **Bridge token** from the server helper.

In this mode the plugin never spawns a local bridge; it polls `/state` over HTTP
(fast while a session is running, slower when idle). Gateway controls, model
selection, sessions, approvals, and the `>hermes` launcher all operate against
the remote bridge.

### Troubleshooting

**`bind [127.0.0.1]:19777: Address already in use` when opening the tunnel.**
Something already holds the port on the client — usually a local bridge spawned
by the plugin *before* client-only mode was enabled, or a previous tunnel still
open. Find and stop it, then re-open the tunnel:

```bash
ss -ltnp | grep 19777                 # see what holds the port
pkill -f hermes_bridge.py             # kill a stray local bridge (safe in client-only mode)
```

Enabling client-only mode now tears down any local bridge automatically, so this
only bites when upgrading from an older setup. Tip: if the port is taken, the
tunnel may bind only IPv6 (`::1`) and the plugin (which calls `127.0.0.1`, IPv4)
won't reach it — always free the port first.

**Bar pill is grey / "unknown" even though the tunnel works.** The bridge reports
`hermes.status: "unknown"` until a session runs or a status hook fires. The pill
falls back to the gateway: if the gateway is **running** it shows **idle**; if it
stays unknown, the Hermes gateway is not running on the server (start it, or let
`autoStartGateway` do it).

**Verify the tunnel independently** of the plugin:

```bash
curl -s 127.0.0.1:19777/health                              # -> {"bridge": {"status": "online"}}
curl -s -H "X-Bridge-Token: <token>" 127.0.0.1:19777/state  # -> full state JSON
```

If `/health` works but the plugin still looks disconnected, reload Noctalia so it
re-polls with the tunnel up.

## Settings

| Setting | Default | Description |
|---|---|---|
| `bridgeHost` | `127.0.0.1` | Bridge host |
| `bridgePort` | `19777` | Bridge port |
| `stateFile` | `~/.cache/noctalia-hermes/state.json` | Shared state file |
| `hermesHome` | `~/.hermes` | Hermes home directory |
| `hermesCommand` | `hermes` | Hermes executable |
| `autoStartBridge` | `true` | Start the bridge when Noctalia loads (local mode) |
| `clientOnlyMode` | `false` | Connect to a remote bridge over SSH instead of starting one locally |
| `bridgeTokenManual` | _(empty)_ | Bridge token (required in client-only mode) |
| `statusPollIntervalSec` | `30` | Status poll interval |
| `hideWhenIdle` | `false` | Hide the bar pill when idle |
| `launcherPrefix` | `>hermes` | Launcher command prefix |
| `panelPinned` | `false` | Pin the panel as a persistent side window |
| `showToolActivity` | `false` | Show compact tool-activity line |
| `defaultProvider` | _(empty)_ | Default provider |
| `defaultModel` | _(empty)_ | Default model |

## Credits

Original `hermes-agent` plugin by **nomadx**, from
[`Nomadcxx/legacy-v4-plugins:add-hermes-agent`](https://github.com/Nomadcxx/legacy-v4-plugins/tree/add-hermes-agent).
Client-only mode (remote bridge over SSH) contributed by FelipeMayerDev.

## License

MIT
