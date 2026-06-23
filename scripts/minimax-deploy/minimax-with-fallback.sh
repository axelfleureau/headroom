#!/usr/bin/env bash
# minimax-with-fallback.sh — Wrapper con fallback automatico.
#
# Logica:
#   1. testa http://127.0.0.1:8788/health (timeout 2s)
#   2. se risponde → export ANTHROPIC_BASE_URL=http://127.0.0.1:8788
#   3. altrimenti → export ANTHROPIC_BASE_URL=https://agent.minimax.io/mavis/api/v1/llm/v1
#   4. exec il comando passato come argomenti
#
# Usage:
#   minimax-with-fallback.sh claude
#   minimax-with-fallback.sh --model MiniMax-M3 --no-cache
#   ANTHROPIC_MODEL=MiniMax-M3 minimax-with-fallback.sh claude

set -uo pipefail

PROXY_URL="http://127.0.0.1:8788"
DIRECT_URL="https://agent.minimax.io/mavis/api/v1/llm/v1"
HEALTH_TIMEOUT=2

if [ $# -lt 1 ]; then
  echo "usage: $(basename "$0") <command> [args...]" >&2
  echo "" >&2
  echo "  Sets ANTHROPIC_BASE_URL to headroom-MiniMax (8788) if available," >&2
  echo "  otherwise falls back to the direct MiniMax gateway." >&2
  exit 2
fi

# Test health del proxy (silenzioso: stdout niente, solo exit code)
if curl -sS --max-time "$HEALTH_TIMEOUT" "$PROXY_URL/health" >/dev/null 2>&1; then
  export ANTHROPIC_BASE_URL="$PROXY_URL"
  echo "[minimax] via headroom-MiniMax proxy (8788)" >&2
else
  export ANTHROPIC_BASE_URL="$DIRECT_URL"
  echo "[minimax] via direct gateway (fallback)" >&2
fi

exec "$@"