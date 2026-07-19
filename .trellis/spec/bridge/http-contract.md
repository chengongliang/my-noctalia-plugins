# Bridge HTTP Contract

## Server Boundary

`hermes-agent/scripts/hermes_bridge.py` uses `ThreadingHTTPServer` with
`BridgeRequestHandler`. The default bind address is `127.0.0.1`; remote use is
through the SSH tunnel documented in `hermes-agent/README.md`. Keep the bridge
loopback-only unless the transport and authentication design changes together.

## Authentication And Payloads

`/health` is the only unauthenticated GET endpoint. Other GET and all POST
requests require the `X-Bridge-Token` header, checked with
`secrets.compare_digest`. Tokens are generated under the state directory,
written through a temporary file, atomically replaced, and chmodded `0600`.

JSON bodies are bounded by `MAX_BODY_BYTES`, decoded as UTF-8, and required to
be objects. Invalid JSON, non-object payloads, and oversized bodies return
explicit 400 or 413 JSON errors.

## State And Side Effects

`HermesState` owns the normalized state model and writes JSON atomically. The
request handler updates that state before or after dispatching commands so the
QML client can poll a consistent snapshot. Keep subprocess execution behind
the handler's injected `command_runner` boundary, with argument arrays,
`capture_output=True`, text mode, and finite timeouts.

Endpoints are grouped by side effect:

- GET `/health` and authenticated GET `/state` expose status and snapshots.
- POST session, prompt, interrupt, approval, model, one-shot, and gateway
  actions dispatch to Hermes RPC or the configured command.

Return a machine-readable `error` code and a useful `message` on failures.
Do not return raw secrets, full authorization headers, or unbounded subprocess
output.

## Shell Wrapper

`hermes-bridge-serve.sh` starts the bridge on loopback, waits for the token
file, prints connection instructions, and traps termination to stop the child.
Preserve `set -eu`, the explicit port argument, and the SSH-tunnel workflow.
