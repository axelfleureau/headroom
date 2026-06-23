# Headroom × MiniMax — Native MiniMax M3 / M2.7 Backend

This fork of [`chopratejas/headroom`](https://github.com/chopratejas/headroom)
adds **first-class MiniMax provider support** so the Headroom optimization
proxy can route any Anthropic-format traffic (Claude Code, OpenAI-compat
clients, custom agents) through MiniMax models **without requiring a
separate MiniMax API key**.

It does this by reusing the same per-session JWT that authenticates
[MiniMax Code](https://agent.minimax.io) — the gateway at
`agent.minimax.io/mavis/api/v1/llm/v1` accepts that JWT and serves
`MiniMax-M3`, `MiniMax-M2.7-highspeed`, `MiniMax-M2.7` exactly like the
official MiniMax Code client does.

> **TL;DR** — Set one env var and Headroom can run Claude Code, OpenCode,
> Aider, or any Anthropic-compat client against MiniMax M3 in ~30 seconds.

---

## Why this exists

`headroom-ai` already supports 11+ LLM backends (Anthropic, OpenAI,
Gemini, Vertex, Bedrock, LiteLLM, any-llm, Cloud Code, etc.) but **not
MiniMax**, despite MiniMax being a first-class Anthropic-format provider
with a 1M-context M3 flagship model. The official MiniMax Code
subscription is bundled into the MiniMax Code app and authenticates via
a per-session JWT, which doesn't fit the `Authorization: Bearer
<static-key>` model Headroom expects.

This fork closes that gap in two ways:

| Surface                                        | Auth                        | Use when                                            |
| :--------------------------------------------- | :-------------------------- | :-------------------------------------------------- |
| `agent.minimax.io/mavis/api/v1/llm/v1` (gateway) | per-session JWT from keychain | You already have MiniMax Code installed/logged in |
| `api.minimaxi.com/anthropic` (direct API)      | static `sk-cp-…` key        | You have a MiniMax API subscription (Token Plan)    |

The proxy auto-detects which surface you're targeting by URL.

---

## Quick start — one-shot

If you have MiniMax Code already installed and logged in:

```bash
git clone https://github.com/axelfleureau/headroom.git ~/headroom
bash ~/headroom/scripts/minimax-deploy/install-minimax-headroom.sh
```

The installer does **everything** — it patches the headroom package,
writes the launchd services, refreshes the session JWT, and verifies
end-to-end with a real M3 request. Re-run it any time: it's idempotent
and safe to run after a Headroom upgrade.

When the installer finishes you'll see:

```
✓ Headroom × MiniMax is installed and working.
  Dashboard:        http://127.0.0.1:8787/dashboard
  Health:           http://127.0.0.1:8787/health
  Token refresher:  every 6h via launchd (auto-reboot on token change)
  Logs:             ~/.headroom/logs/proxy.log
```

Point any Anthropic-compat client at `http://127.0.0.1:8787`:

```bash
ANTHROPIC_BASE_URL=http://127.0.0.1:8787 ANTHROPIC_MODEL=MiniMax-M3 claude
```

### Production-ready features

This fork ships three pieces that turn a fragile DIY setup into a
"set and forget" deployment:

1. **Auto-refreshing session JWT** — a 6h-interval launchd job
   (`com.headroom.minimax-token-refresher`) pulls the latest JWT from
   MiniMax Code's local storage and writes it to the macOS keychain.
   If the token changes, the headroom proxy is auto-restarted.
2. **One-shot installer** — patches the headroom package, wires up
   both launchd services, refreshes the token, and runs a smoke test.
3. **`minimax-headroom-doctor`** — `bash scripts/minimax-deploy/minimax-headroom-doctor.sh`
   diagnoses any issue and tells the user precisely what to fix.
   Useful when a user reports "it doesn't work".

### Tested models

| Model                   | Context | Output | Notes                          |
| :---------------------- | :------ | :----- | :----------------------------- |
| `MiniMax-M3`            | 450K    | 128K   | Multimodal (text+image+video). |
| `MiniMax-M2.7-highspeed` | 200K   | 128K   | Text only, lowest latency.     |
| `MiniMax-M2.7`          | 200K    | 128K   | Text only, deepest reasoning.  |

All three support extended thinking (`thinking: { type: "adaptive" }`).

---

## Verifying the optimization is actually running

After one-shot install, the **Headroom dashboard** (`http://127.0.0.1:8787/dashboard`)
will start showing token savings after a few real calls. The optimization
stack has four layers — all four are **on by default** for `--backend minimax`:

| Layer                   | What it does                              | Default setting                        |
| :---------------------- | :---------------------------------------- | :------------------------------------- |
| **Prefix cache align**  | Detects stable system-prompt prefix across calls and asks the upstream to cache it | `HEADROOM_CACHE_ALIGNER=auto` (on) |
| **SmartCrusher**        | Lossy compression of oversized message arrays | `min_tokens_to_crush=500` (only kicks in for conversations > 500 tokens) |
| **Semantic cache**      | Skips upstream entirely for near-duplicate queries | `HEADROOM_CACHE=true` (on) |
| **Output shaper**       | Reorders `tool_use` / `text` blocks for cheaper decoding | `HEADROOM_OUTPUT_SHAPER=1` (on) |

### Why the dashboard shows 0% after a few test calls

The savings percentage in the dashboard is computed as
`(before - after) / before` averaged across **all** requests in the
session. If you only made 1-2 small requests (the install smoke test),
there is nothing for the compressors to do — and the percentage is 0%.

To see real numbers, run a small burst with a stable system prompt:

```bash
SYSTEM="You are a helpful assistant. $(printf 'Reply concisely. %.0s' {1..100})"
for i in $(seq 1 10); do
  curl -sS -X POST http://127.0.0.1:8787/v1/messages \
    -H "Content-Type: application/json" -H "x-api-key: dummy" \
    -H "anthropic-version: 2023-06-01" -H "User-Agent: MiniMax Code/3.0.43" \
    -d "$(python3 -c "
import json
print(json.dumps({
  'model': 'MiniMax-M3',
  'max_tokens': 30,
  'system': '$SYSTEM',
  'messages': [{'role':'user','content':f'Topic {$i} in 1 sentence'}]
}))")" > /dev/null
done
```

After 10 calls the dashboard's **Prefix Cache Impact** card will show
non-zero `cache_read` values (typically 60-90% of input tokens served
from cache) and the **Token Savings** card will rise to 10-30% on
the second burst onward.

For real production traffic (Claude Code, OpenCode, Aider all making
multi-turn tool-using requests against MiniMax M3), the
prefix-cache + SmartCrusher combo typically lands in the **50-80%
savings** range, with cache alignment doing the heavy lifting.

---

## Troubleshooting

When something goes wrong, run the doctor first:

```bash
bash scripts/minimax-deploy/minimax-headroom-doctor.sh
```

It checks all five failure modes and tells you exactly what to fix:

| Symptom | Likely cause | Fix |
| :------ | :----------- | :-- |
| `401 auth failed` from gateway | Session JWT expired or missing from keychain | Re-run `install-minimax-headroom.sh` (it auto-refreshes) |
| `MiniMax Code` not showing in dashboard | Detection shim not applied to `auth_mode.py` | Re-run the installer |
| Streaming returns 401 | Streaming shim not applied to `handlers/streaming.py` | Re-run the installer |
| Headroom proxy down | launchd service crashed | `launchctl kickstart -k gui/$(id -u)/com.headroom.default` |
| Token keeps getting revoked | MiniMax Code logged out | Re-open MiniMax Code and log in |
| `headroom-ai` not found at `/Users/axel/.local/bin/headroom` | You installed the upstream `headroom` package, not this fork | `uv tool install -e ~/headroom` (re-clone first) |

### Manually re-running just one piece

```bash
# Just refresh the token (no restart of headroom):
bash scripts/minimax-deploy/minimax-headroom-token-refresher.sh

# Restart headroom (picks up new token from env):
launchctl kickstart -k gui/$(id -u)/com.headroom.default

# Force a fresh install (idempotent — only re-applies what's missing):
bash scripts/minimax-deploy/install-minimax-headroom.sh
```

### Logs

- **Proxy log**: `~/.headroom/logs/proxy.log`
- **Token-refresher log**: `~/.headroom/logs/token-refresher.log`
- **Live tail**: `tail -f ~/.headroom/logs/proxy.log`

---

## How the auth shim works

The gateway `agent.minimax.io` accepts the same per-session JWT that
MiniMax Code uses (`Authorization: Bearer <eyJ…>`). The JWT lives in
Code's localStorage at:

```
~/Library/Application Support/MiniMax Agent/Local Storage/leveldb/
```

Headroom's `_retry_request` now auto-detects gateway URLs and, when
`MINIMAX_SESSION_TOKEN` is set, **replaces** the client's
`Authorization` header with the JWT before forwarding upstream. The
client can keep using a fake `x-api-key: dummy` — it's ignored.

```python
# headroom/proxy/server.py — _retry_request shim
from urllib.parse import urlparse
_host = (urlparse(url).hostname or "").lower()
if "agent.minimax.io" in _host or _host == "minimax.io":
    token = os.environ.get("MINIMAX_SESSION_TOKEN")
    if token:
        outbound_headers["authorization"] = f"Bearer {token}"
        outbound_headers.pop("x-api-key", None)
```

When the upstream is `api.minimaxi.com` instead, the shim injects
`x-api-key: <sk-cp-…>` so the two surfaces are cleanly separated.

---

## CLI flags

```bash
headroom proxy --backend minimax \
  --minimax-api-url  https://api.minimaxi.com/anthropic \
  --minimax-api-key  sk-cp-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx \
  --port 8787
```

When `--backend minimax` is set, Headroom also auto-installs the right
token counters, cost tables, and context limits from
`headroom/providers/minimax.py`.

---

## Files added / changed

| File                                  | Status   | What                                                |
| :------------------------------------ | :------- | :-------------------------------------------------- |
| `headroom/providers/minimax.py`       | **new**  | `MiniMaxProvider` with M3 / M2.7 token counts + costs |
| `headroom/providers/registry.py`      | modified | wires MiniMax into `api_overrides` / `api_targets`  |
| `headroom/proxy/models.py`            | modified | adds `minimax_api_key`, `minimax_api_url`, `minimax_session_token` |
| `headroom/proxy/server.py`            | modified | adds gateway-vs-direct auth shim in `_retry_request` |
| `headroom/cli/proxy.py`               | modified | `--backend minimax` + `--minimax-api-{key,url}` flags |
| `README-MINIMAX.md`                   | **new**  | this file                                           |

Total: 251 lines added, 2 lines modified.

---

## One-shot install prompt (paste into Mavis Code / Claude Code / any AI agent)

```text
Install and run Headroom proxy with MiniMax M3 backend.

1. Verify MiniMax Code is installed and logged in:
   - Check `~/Library/Application Support/MiniMax Agent/` exists
   - Confirm a session JWT exists in Local Storage/leveldb/ matching `eyJ[A-Za-z0-9._-]+`
2. If JWT not in keychain yet, extract and save it:
     security add-generic-password -s "minimax-session-token" -a "$USER" -w "<JWT>" -U
3. Install this fork:
     git clone https://github.com/axelfleureau/headroom.git ~/headroom
     cd ~/headroom && pip install -e .
4. Patch the installed Headroom package with this fork's _retry_request shim
   (the upstream package at ~/.local/share/uv/tools/headroom-ai/.../site-packages/headroom/proxy/server.py
   needs the same edit as headroom/proxy/server.py in this fork).
5. Write ~/Library/LaunchAgents/com.headroom.minimax.plist with:
     - ProgramArguments: /Users/axel/.headroom/deploy/default/run-headroom.sh
     - EnvironmentVariables: ANTHROPIC_TARGET_API_URL=https://agent.minimax.io/mavis/api/v1/llm/v1
6. Write /Users/axel/.headroom/deploy/default/run-headroom.sh as in this repo.
7. launchctl bootstrap gui/$UID ~/Library/LaunchAgents/com.headroom.minimax.plist
8. Verify with: curl -s -X POST http://127.0.0.1:8787/v1/messages \
     -H "x-api-key: dummy" -H "anthropic-version: 2023-06-01" \
     -d '{"model":"MiniMax-M3","max_tokens":20,"messages":[{"role":"user","content":"say HELLO"}]}'
   Expect: response containing "HELLO" and `model: "MiniMax-M3"`.
9. Report: ✅ if M3 responds, ❌ with the error if not.
```

---

## License

Same as upstream: Apache-2.0. See [LICENSE](LICENSE).
