# Hermes Agent

Native Noctalia status and chat surface for Hermes Agent: a bar pill that shows what Hermes
is doing, a chat panel with a streaming transcript, tool approvals and interrupt, and a
launcher provider for one-shot prompts.

This is the Noctalia v5 (Luau) rewrite of the original v4 QML plugin. The bundled Python
bridge is unchanged, so an existing Hermes setup keeps working; only the Noctalia-facing
side was ported.

## Plugin

Manifest id: `chengongliang/hermes-agent`.

The plugin exposes four entries:

- `bridge` — a headless service. It owns the bridge process, performs every HTTP call, and
  republishes the bridge snapshot on `noctalia.state` for the UI entries. It renders
  nothing.
- `status` — the bar widget. A Hermes icon, a status-coloured dot and the status word
  (Online, Working, Needs You, Degraded, Offline). Left click opens the chat panel; right
  click opens this widget's settings.
- `chat` — the chat panel: transcript, tool approvals, tool-activity line, a summary strip,
  a provider and model picker, and the composer. Open it with:

  ```sh
  noctalia msg panel-toggle chengongliang/hermes-agent:chat
  ```

- `hermes` — the launcher provider, under the prefix `/hermes`:

  ```text
  /hermes summarize the failing test in src/parser.luau
  ```

  With text it offers a one-shot prompt; with no text it offers to open the panel, start a
  new session, or resume the stored session.

### How the pieces talk

v5 entries are isolated Luau VMs: they share no memory and there is no `main` entry. The
service is therefore the only entry that touches HTTP, and it communicates through
`noctalia.state`:

| Key | Direction | Contents |
|---|---|---|
| `hermes.state` | service to UI | The whole bridge snapshot |
| `hermes.bridge` | service to UI | `status` (`online` or `offline`) and the last `error` |
| `hermes.providers` | service to UI | Provider list for the model picker |
| `hermes.models` | service to UI | Model list for one provider |
| `hermes.cmd` | UI to service | A command: `refresh`, `new_session`, `resume`, `prompt`, `interrupt`, `approval`, `model`, `oneshot`, `gateway_start`, `load_providers`, `load_models` |

The service clears `hermes.cmd` after running it, so a command is executed exactly once.

### The bridge

`scripts/hermes_bridge.py` is the same Python bridge the v4 plugin shipped. It speaks
JSON-RPC to the Hermes gateway, normalises a state snapshot, writes it to the state file,
and serves it over HTTP on `127.0.0.1` behind a shared token. The plugin calls:

`GET /health`, `GET /state`, `GET /detect`, `GET /providers`,
`GET /models?provider=...&refresh=0|1`, `POST /session/create`, `POST /session/resume`,
`POST /prompt`, `POST /interrupt`, `POST /approval`, `POST /model`, `POST /oneshot`,
`POST /gateway/start`, `POST /gateway/stop`.

Every request carries `X-Bridge-Token` except `/health` and `/detect`, which the bridge
leaves unauthenticated.

## Usage

Start Hermes as usual, then place the `status` widget on a bar. The pill is offline until
the bridge answers; the first successful health check also runs a one-time detection that
records the Hermes home and command, and starts the gateway when it is not running.

Click the pill to open the chat panel. Type a prompt and press Enter (Shift+Enter inserts a
newline). While Hermes works the send button becomes Interrupt. When Hermes asks for
approval, a card appears above the transcript with Deny, Allow and Allow Session.

The sliders button in the panel header opens the model picker, which lists the providers and
models the bridge reports. Apply model to session changes the running session; Save as
global default also persists it in the Hermes configuration.

Anything the bar and panel can do is also reachable from the command line:

```sh
noctalia msg plugin chengongliang/hermes-agent:bridge all refresh
noctalia msg plugin chengongliang/hermes-agent:bridge all new-session
noctalia msg plugin chengongliang/hermes-agent:bridge all prompt "explain this stack trace"
noctalia msg plugin chengongliang/hermes-agent:bridge all oneshot "summarise the changelog"
noctalia msg plugin chengongliang/hermes-agent:bridge all interrupt
noctalia msg plugin chengongliang/hermes-agent:bridge all approve
noctalia msg plugin chengongliang/hermes-agent:bridge all deny
noctalia msg plugin chengongliang/hermes-agent:bridge all gateway-start
```

### Client-only mode: a remote Hermes over SSH

When Hermes runs on another machine, the client has no bridge, no Hermes home and no token
file. Enable Client-only mode, point host and port at a forwarded port, and paste the token.

On the server:

```sh
cd scripts
./hermes-bridge-serve.sh 19777
```

It starts the bridge on `127.0.0.1`, prints the token, and stays in the foreground.

On the client:

```sh
ssh -L 19777:127.0.0.1:19777 user@server
```

Then in the plugin settings enable Client-only mode, set Bridge host `127.0.0.1`, Bridge
port `19777`, and paste the token. The plugin never creates the tunnel itself; in this mode
it also never spawns a bridge and never runs pkill.

Verify the tunnel without the plugin:

```sh
curl -s 127.0.0.1:19777/health
curl -s -H "X-Bridge-Token: TOKEN" 127.0.0.1:19777/state
```

### What this plugin touches

- **Network** — HTTP to the configured bridge host and port. Nothing else, and nothing
  leaves the machine unless you point it at one.
- **Filesystem** — writes `detection.json` into the plugin data directory. The bridge
  writes its state file and `bridge.token` next to it (mode 0600); the plugin only reads the
  token.
- **Processes** — spawns `python3 scripts/hermes_bridge.py` when not in client-only mode.
  Stopping it is a `pkill -f hermes_bridge.py`, because the runtime exposes no process id.
  It also runs `ssh` only if you start the tunnel yourself.

## Requirements

- `python3` — runs the bundled bridge, which is started automatically unless client-only
  mode is on. It may re-exec itself with the Hermes virtualenv's interpreter when one exists.
- `ssh` — only for client-only mode, and only ever run by you to open the tunnel.
- Hermes Agent installed on the bridge machine, with its gateway available.

## Settings

Every setting is plugin-level, so the service, widget, panel and launcher all read the same
values. The technical plumbing is marked advanced in the settings page.

| Setting | Default | Effect |
|---|---|---|
| Bridge host | `127.0.0.1` | Host of the bridge; in client-only mode, the forwarded address |
| Bridge port | `19777` | Must match the local port of the SSH tunnel |
| Client-only mode | off | Talk to a remote bridge instead of spawning a local one |
| Bridge token | empty | Token pasted from the server helper; only shown in client-only mode |
| Hide when idle | off | Collapse the bar pill while Hermes is idle |
| Show tool activity | off | Keep the compact tool-activity line visible when not busy |
| Status poll interval | `30` | Seconds between health checks and idle state polls |
| State file | `~/.cache/noctalia-hermes/state.json` | Bridge state path; the token is read from the same directory |
| Hermes home | `~/.hermes` | Hermes configuration directory; auto-detected at the default |
| Hermes command | `hermes` | Executable the bridge runs for gateway and one-shot commands |
| Auto-start bridge | on | Start the local bridge when Noctalia loads |
| Auto-start gateway | on | Start the Hermes gateway when the first detection finds it stopped |
| Default provider | empty | Fallback label when the session reports no provider |
| Default model | empty | Fallback label when the session reports no model |

Two settings from the v4 plugin are intentionally gone:

- **Launcher prefix** — in v5 the prefix belongs to the manifest, so it is fixed at
  `/hermes`.
- **Pin side panel** — see below.

## Changes from the v4 plugin

The behaviour is the same, minus the pieces v5 has no API for:

- **Pinned side panel removed.** v4 could promote the panel to an always-on-top layer-shell
  window (`PinnedPanelWindow.qml`). v5 panels are host-owned: the format has no layer-shell
  control, no exclusion mode and no always-on-top window. The chat panel is now a floating
  panel docked right and full height, which is the closest available equivalent.
- **The bar right-click menu became a gesture binding.** There is no bar context-menu API
  in v5, so the menu's entries moved: open, new session, interrupt, refresh and start
  gateway all live in the panel, and right-click opens the widget's settings.
- **The settings page is manifest-declared.** v5 has no settings script, so the provider and
  model dropdowns, the connection test and the advanced reveal from `Settings.qml` could not
  be ported as settings. The dropdowns moved into the panel; the connection is now verified
  by the widget's own status.
- **Markdown is rendered by the host.** `ui.markdown` replaces `MarkdownLogic.js` and
  `MarkdownView.qml`. It has no code-block slot, so the panel splits assistant messages on
  fenced code and draws those slabs itself, with the copy button. Table styling, blockquote
  colouring and the copy-button flash are host-controlled now.
- **State is polled, not watched.** v5 has no file-watch API, so the bridge state file is
  not watched; `/state` is polled instead (every 1.5 s while a session runs, otherwise at
  the configured interval).
- **First-run detection is latched in the data directory.** Settings are read-only in v5, so
  the `/detect` result cannot be written back the way v4 wrote it into `settings.json`. It
  is stored in `detection.json` under the plugin data directory instead, and used as a
  fallback while the Hermes home and command keep their default values.
- **The bar pill has no per-status glyph.** The declarative tree cannot detect a failed
  image load, so v4's icon-then-glyph fallback (power, loader, bell-ringing) is replaced by
  the shipped icon plus the status dot and status word.

## Troubleshooting

**The pill stays offline.** Check the token file next to the state file and confirm the
bridge is listening. Set Auto-start bridge on, or start the bridge by hand with
`python3 scripts/hermes_bridge.py`.

**The pill is grey even though the tunnel works.** The bridge reports `unknown` until a
session runs or a status hook fires. The pill then falls back to the gateway: a running
gateway shows as Online. If it stays unknown, the gateway on the server is not running.

**Address already in use when opening the tunnel.** Something on the client already holds
the port, usually a local bridge started before client-only mode was enabled. Free it first,
because a tunnel that cannot bind may listen on IPv6 only while the plugin connects over
IPv4.

**The token was regenerated.** The plugin drops its cached token on the first 403 and
re-reads the file, so a restarted local bridge recovers on its own. In client-only mode,
paste the new token into the settings.

## Credits

Original `hermes-agent` plugin by nomadx. Client-only mode (remote bridge over SSH)
contributed by FelipeMayerDev. Ported to the Noctalia v5 plugin format by chengongliang.

## License

MIT
