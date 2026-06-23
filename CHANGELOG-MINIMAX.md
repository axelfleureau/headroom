# Changelog

All notable changes to this fork of `headroom-ai` are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

> **Branch convention:** the upstream `chopratejas/headroom` releases
> under `0.x.y`. We publish MiniMax-flavoured releases as
> `0.x.y-minimax.N` so a user can pin to the latest MiniMax-ready
> build while staying on the same upstream minor.

---

## [0.27.0-minimax.1] - 2026-06-23

### Added
- **Native MiniMax provider** (`headroom/providers/minimax.py`).
  Adds the `MiniMaxProvider` class with full token / context / cost
  metadata for `MiniMax-M3` (1M context, multimodal),
  `MiniMax-M2.7-highspeed`, `MiniMax-M2.7`, `MiniMax-M2.5[-highspeed]`,
  `MiniMax-M2.1[-highspeed]`, and `MiniMax-M2`.
- **`--backend minimax` CLI option** in `headroom proxy`, plus
  `--minimax-api-key` and `--minimax-api-url` flags for direct-API
  deployment.
- **Mavis Code gateway auth shim** in `HeadroomProxy._retry_request`
  and the streaming forwarder. The shim auto-detects whether the
  upstream is the gateway (`agent.minimax.io`) or the direct
  Anthropic-compat API (`api.minimaxi.com`) and applies the right
  header strategy:
  - **Gateway:** REPLACES the client's `Authorization: Bearer …` with
    the per-session JWT from `MINIMAX_SESSION_TOKEN` (or the
    `minimax-session-token` macOS keychain entry, fetched by
    `run-headroom.sh`).
  - **Direct API:** INJECTS `x-api-key: <sk-cp-…>` from
    `MINIMAX_API_KEY` (or `ProxyConfig.minimax_api_key`).
- **New `ProxyConfig` fields**:
  - `minimax_api_key: str | None`
  - `minimax_api_url: str | None`
  - `minimax_session_token: str | None`
- **macOS launchd runner**: `~/Library/LaunchAgents/com.headroom.default.plist`
  + `~/.headroom/deploy/default/run-headroom.sh`. Auto-loads the
  session JWT from the keychain on every restart and exports the
  correct `ANTHROPIC_TARGET_API_URL`.
- **`README-MINIMAX.md`**: one-shot install prompt an AI agent can
  paste to bootstrap a fresh machine.
- **Tests**:
  - `tests/test_provider_minimax.py` — token counts, context limits,
    vision capability, model prefix strip, pricing-table sanity.
  - `tests/test_minimax_registry.py` — `ProxyConfig` fields, registry
    wiring, opt-in E2E tests against the live proxy (gated on
    `MINIMAX_E2E=1`).

### Fixed
- **Agent detection mis-classification** (pre-existing, surfaced by
  the MiniMax rollout). Headroom's per-request `classify_client` was
  defaulting anonymous Anthropic-format traffic to `claude-code`,
  which made the dashboard show "Claude" usage even for MiniMax M3
  calls. Now:
  - `CLIENT_UA_MAP` in `headroom/proxy/auth_mode.py` recognises
    `MiniMax Code/…` / `mavis code/…` / `minimax-agent/…` as
    `minimax-code`.
  - The 4 `classify_client(headers, default="claude")` call sites in
    `headroom/proxy/handlers/anthropic.py` now also override the
    default by inspecting the request body's `model` field (so
    even unidentified clients with `model: "MiniMax-M3"` correctly
    show up under "MiniMax Code", not "Claude").
  - `_classify_agent_from_log` in `server.py` learns to recognise
    `minimax*` model names so historical log entries are bucketed
    correctly.
- **Streaming path bypassed the auth shim** (introduced by this
  release). The non-streaming path applied the shim in
  `_retry_request`, but `_stream_response` was sending raw headers
  upstream, so SSE requests hit the gateway with the client's
  fake `x-api-key: dummy` and the gateway returned 401. The same
  shim is now applied to the streaming forwarder
  (`headroom/proxy/handlers/streaming.py`).

### Changed
- `provider_runtime.api_targets.minimax` resolves to
  `https://api.minimaxi.com/anthropic` by default (overridable via
  `MINIMAX_TARGET_API_URL`).
- `format_backend_status(backend="minimax")` prints
  `MINIMAX (Anthropic-compatible, x-api-key injection)` so operators
  can spot MiniMax routes in the proxy banner.

### Security
- The Mavis Code session JWT is never written to disk by Headroom.
  It lives in the macOS keychain and is read into the proxy process
  environment on every launchd restart. The session token is
  short-lived (~30 days) and renews automatically when the user
  signs in to MiniMax Code.
- `--backend minimax` does NOT enable any feature that mutates
  request bodies beyond the auth header swap. Compression and
  caching are still opt-in via existing `--optimize` /
  `--cache` flags.

---

## [0.27.0] - upstream

Tracking `chopratejas/headroom` main. See upstream `CHANGELOG.md`
for the base feature set.
