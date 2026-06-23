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
# 1. Save the session JWT into the macOS keychain (one-time)
TOKEN=$(plutil -p ~/Library/Application\ Support/MiniMax\ Agent/Local\ Storage/leveldb/*.log 2>/dev/null \
  | python3 -c "import sys, re; raw=sys.stdin.read(); m=re.search(r'\"_token\"[^a-zA-Z]+(eyJ[A-Za-z0-9._-]+)', raw); print(m.group(1) if m else '')")
[ -n "$TOKEN" ] && security add-generic-password -s "minimax-session-token" -a "$USER" -w "$TOKEN" -U

# 2. Install Headroom (this fork)
git clone https://github.com/axelfleureau/headroom.git
cd headroom && pip install -e .

# 3. Run Headroom pointed at the MiniMax gateway
ANTHROPIC_TARGET_API_URL="https://agent.minimax.io/mavis/api/v1/llm/v1" \
MINIMAX_SESSION_TOKEN="$(security find-generic-password -s minimax-session-token -w)" \
headroom proxy --port 8787 &

# 4. Point Claude Code (or any Anthropic-compat client) at Headroom
ANTHROPIC_BASE_URL=http://127.0.0.1:8787 \
ANTHROPIC_MODEL=MiniMax-M3 claude
```

That's it. You're now running Claude Code against MiniMax M3 through the
full Headroom optimization stack (SmartCrusher, cache alignment, rate
limiting, telemetry, savings dashboard).

### Tested models

| Model                   | Context | Output | Notes                          |
| :---------------------- | :------ | :----- | :----------------------------- |
| `MiniMax-M3`            | 450K    | 128K   | Multimodal (text+image+video). |
| `MiniMax-M2.7-highspeed` | 200K   | 128K   | Text only, lowest latency.     |
| `MiniMax-M2.7`          | 200K    | 128K   | Text only, deepest reasoning.  |

All three support extended thinking (`thinking: { type: "adaptive" }`).

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
