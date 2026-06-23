# Changelog

All notable changes to this fork of `headroom-ai` are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

> **Branch convention:** the upstream `chopratejas/headroom` releases
> under `0.x.y`. We publish MiniMax-flavoured releases as
> `0.x.y-minimax.N` so a user can pin to the latest MiniMax-ready
> build while staying on the same upstream minor.

---

## [0.27.0-minimax.4] - 2026-06-23

### Added — production hardening

- **`minimax-token-refresher.sh` + LaunchAgent dedicato** (`com.headroom.minimax-token-refresher`)
  che gira ogni 6h. Rilegge il JWT dal localStorage Mavis Code, aggiorna il
  keychain se cambiato, kickstart headroom-MiniMax. Sicuro: log solo
  `unchanged/updated` + exp timestamp, mai il token in chiaro. Idempotente.
- **Test E2E verificati end-to-end** con token reale:
  - M2.7-highspeed via gateway diretto + header Token → 200 OK
  - M2.7-highspeed via headroom-MiniMax 8788 + Token → 200 OK
  - M3 con `thinking: { type: "adaptive" }` → thinking block + text block OK
  - M3 con tool_use → 200 OK, tool chiamato correttamente
  - Streaming SSE: message_start → content_block_delta → message_stop OK
  - 20 chiamate streaming seriali: 20/20 OK, ~1.1s/call
  - Fallback wrapper: proxy up→8788, proxy down→diretto OK

### Changed

- `headroom-minimax-enable.sh` ora installa anche il LaunchAgent
  `com.headroom.minimax-token-refresher` automaticamente dopo aver verificato
  end-to-end il proxy.

---

## [0.27.0-minimax.3] - 2026-06-23

### Changed — major architectural simplification

- **NO patch al package headroom-ai.** L'analisi del codice reale di Mavis Code
  (`daemon.js`) ha rivelato che Mavis Code gestisce già l'auth via header
  `Token: <jwt>` tramite `readMavisAuthToken()`. Headroom forwarda i client
  headers intatti al gateway, quindi nessuna auth shim è necessaria.
- **Profilo headroom separato** su porta 8788 invece di patchare il profilo
  Codex esistente. Il plist `com.headroom.default` resta intatto.
- **Auth model chiarito**: il gateway `agent.minimax.io` accetta solo
  `Token: <jwt>` (non `Authorization: Bearer`) per managed providers.
  Managed providers identificati da `MANAGED_PROVIDER_HOSTS`:
  agent.minimax.io, agent.minimaxi.com, matrix-*.xaminim.com.

### Added

- **`minimax-token-fetch.sh`** — estrae JWT dal localStorage leveldb di
  Mavis Code (`~/Library/Application Support/MiniMax Agent/Local Storage/leveldb/`),
  seleziona quello con `exp` claim più alto (= più recente), output solo
  su stdout (mai log).
- **`minimax-with-fallback.sh`** — wrapper che testa headroom-MiniMax (8788)
  e ripiega automaticamente sul gateway diretto se il proxy è giù.
  Failover in <100ms, mai bloccante.
- **`headroom-minimax-enable.sh` v3** — riscritto per la nuova architettura:
  - estrae JWT live
  - salva nel keychain
  - scrive plist dedicato (no patch al package)
  - verifica `/v1/messages` end-to-end con token reale
  - rollback automatico se qualsiasi step fallisce
  - nessuna modifica a `~/.mavis/config.yaml` o `opencode.json`

### Removed

- Le patch a `handlers/anthropic.py`, `streaming.py`, `auth_mode.py` sono
  state rimosse perché inutili (Mavis Code già manda `Token: <jwt>` corretto).
- Lo script `minimax-headroom-token-refresher.sh` (LaunchAgent auto-refresh)
  è stato rimosso. Per refresh, rieseguire `headroom-minimax-enable.sh --yes`.

### Verified end-to-end

- M2.7-highspeed via gateway diretto con header Token → 200 OK
- M2.7-highspeed via headroom-MiniMax (8788) con header Token → 200 OK
- Codex profile (8787) → Anthropic API intatto
- Fallback wrapper: proxy attivo → 8788, proxy spento → diretto

---

## [0.27.0-minimax.2] - 2026-06-23

### Added
- **One-shot installer** (`scripts/minimax-deploy/install-minimax-headroom.sh`).
  Idempotent, handles every error path that a non-technical user could
  hit (Codex not installed, not logged in, headroom not installed,
  patches not applied, keychain write fails, proxy doesn't come up,
  M3 request fails). 8 numbered steps, each with a clear "✓ / ✗ / ⚠"
  outcome. Re-run any time — safe after a Headroom upgrade.
- **Auto-refreshing session JWT** via a second launchd job
  (`com.headroom.minimax-token-refresher`) that runs every 6 hours.
  Pulls the latest JWT from MiniMax Code's leveldb, picks the one
  with the highest `exp` claim, writes it to the macOS keychain, and
  calls `launchctl kickstart -k` on `com.headroom.default` if the
  token actually changed. No human in the loop.
- **`minimax-headroom-doctor`**: read-only diagnostic that checks all
  five failure modes (Codex installed, headroom-ai installed, patches
  applied, services loaded, M3 request works). Prints a precise
  remediation for each failure.
- **Patches directory** (`scripts/minimax-patches/`) holding the
  three pre-built file patches the installer applies to the installed
  headroom package:
    - `headroom/proxy/server.py` — non-streaming auth shim
    - `headroom/proxy/handlers/streaming.py` — streaming auth shim
    - `headroom/proxy/auth_mode.py` — agent-detection shim
  These are the exact bytes the installer drops into
  `~/.local/share/uv/tools/headroom-ai/.../site-packages/headroom/...`
  on the user's box.
- **Troubleshooting section** in `README-MINIMAX.md` mapping the 6
  most common "it doesn't work" reports to their fix.

### Changed
- `run-headroom.sh` is now a 1:1 copy shipped in the repo
  (`scripts/minimax-deploy/run-headroom.sh`) so the installer can
  reference a known-good version, not one that drifts per machine.

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
