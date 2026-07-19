# Hermes Bridge Guidelines

The bridge is the Python runtime under `hermes-agent/scripts/`. It is a local
HTTP adapter for Hermes Agent, not a general backend service.

## Guides

| Guide | Use it for |
| --- | --- |
| [HTTP Contract](./http-contract.md) | Endpoints, state shape, authentication, and process boundaries |

## Pre-Development Checklist

- [ ] Read `hermes-agent/scripts/hermes_bridge.py`, the shell wrapper, and the client-only section of `hermes-agent/README.md`.
- [ ] Identify whether a change affects state normalization, HTTP payloads, Hermes RPC, or subprocess commands.
- [ ] Preserve loopback binding, token authentication, body limits, and atomic state writes.

## Quality Check

- [ ] Run `python3 -m py_compile hermes-agent/scripts/hermes_bridge.py`.
- [ ] Run `hermes-agent/scripts/hermes-bridge-serve.sh` only on loopback and verify `/health` plus an authenticated `/state` request.
- [ ] Confirm malformed JSON, oversized payloads, missing tokens, and command failures return explicit JSON errors.
- [ ] Do not expose the bridge on a public interface or log the bridge token.
