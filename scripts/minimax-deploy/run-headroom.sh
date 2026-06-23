#!/usr/bin/env bash
set -euo pipefail
export HEADROOM_OUTPUT_SHAPER=1
export HEADROOM_VERBOSITY_LEVEL=1
export HEADROOM_EFFORT_ROUTER=1
export HEADROOM_TELEMETRY=off
# Route Anthropic-format requests to the Mavis Code gateway instead of api.anthropic.com.
# Auth model: per-session JWT (`eyJ…`) fetched from the Codex/Mavis Agent
# localStorage via macOS keychain. The proxy substitutes the client's
# Authorization header with this token before forwarding upstream.
export ANTHROPIC_TARGET_API_URL="https://agent.minimax.io/mavis/api/v1/llm/v1"
export MINIMAX_SESSION_TOKEN="$(security find-generic-password -s "minimax-session-token" -w 2>/dev/null || true)"
if [ -z "${MINIMAX_SESSION_TOKEN:-}" ]; then
  echo "[run-headroom] WARN: minimax-session-token not in keychain — headroom will return 401" >&2
fi
exec /Users/axel/.local/bin/headroom install agent run --profile default
