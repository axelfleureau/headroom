#!/usr/bin/env bash
# minimax-headroom-doctor.sh — diagnose why Headroom × MiniMax might not be
# working. Read-only: never modifies the system. Safe to run any time.
#
# Exit code:
#   0  everything is healthy
#   1  at least one check failed (printed at the end)

set -uo pipefail

PROXY_PORT="${HEADROOM_PORT:-8787}"
LOGS_DIR="$HOME/.headroom/logs"
LEVELDB_DIR="$HOME/Library/Application Support/MiniMax Agent/Local Storage/leveldb"
KEYCHAIN_SERVICE="minimax-session-token"

green()  { printf "\033[32m  ✓ %s\033[0m\n" "$*"; }
red()    { printf "\033[31m  ✗ %s\033[0m\n" "$*" >&2; }
yellow() { printf "\033[33m  ! %s\033[0m\n" "$*"; }
section(){ printf "\n\033[1m[%s]\033[0m\n" "$*"; }

FAILS=0

# ── 1. MiniMax Code installed & logged in ─────────────────────────────
section "MiniMax Code"
if [ -d "$LEVELDB_DIR" ]; then
  green "MiniMax Code installed at $LEVELDB_DIR"
else
  red "MiniMax Code NOT installed"
  echo "       download: https://agent.minimax.io"
  FAILS=$((FAILS + 1))
fi

# Look for at least one valid (future-expiry) JWT.
LATEST_EXP=0
shopt -s nullglob
for f in "$LEVELDB_DIR"/*.log; do
  [ -f "$f" ] || continue
  while IFS= read -r token; do
    [ -z "$token" ] && continue
    payload_b64=$(echo "$token" | cut -d. -f2)
    payload_b64=${payload_b64//-/+}
    payload_b64=${payload_b64//_/\/}
    case $((${#payload_b64} % 4)) in
      2) payload_b64="${payload_b64}==" ;;
      3) payload_b64="${payload_b64}=" ;;
    esac
    exp=$(echo "$payload_b64" | base64 -d 2>/dev/null | python3 -c "import sys, json; print(json.load(sys.stdin).get('exp', 0))" 2>/dev/null || echo 0)
    if [ "$exp" -gt "$LATEST_EXP" ]; then LATEST_EXP=$exp; fi
  done < <(strings "$f" 2>/dev/null | grep -oE "eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+" || true)
done
shopt -u nullglob

NOW=$(date +%s)
if [ "$LATEST_EXP" -gt "$NOW" ]; then
  exp_iso=$(date -u -r "$LATEST_EXP" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "unknown")
  green "active session in MiniMax Code (expires $exp_iso)"
else
  red "no active session in MiniMax Code"
  echo "       open MiniMax Code, sign in, send one message"
  FAILS=$((FAILS + 1))
fi

# ── 2. headroom-ai installed & patched ───────────────────────────────
section "headroom-ai"
if [ -x "/Users/axel/.local/bin/headroom" ]; then
  green "headroom-ai binary at /Users/axel/.local/bin/headroom"
else
  red "headroom-ai not installed"
  echo "       install: uv tool install -e ~/headroom"
  FAILS=$((FAILS + 1))
fi

HEADROOM_PKG="/Users/axel/.local/share/uv/tools/headroom-ai/lib/python3.11/site-packages/headroom"
if [ -d "$HEADROOM_PKG" ]; then
  green "headroom-ai python package at $HEADROOM_PKG"
  if grep -q "MINIMAX_SESSION_TOKEN" "$HEADROOM_PKG/proxy/server.py" 2>/dev/null; then
    green "auth shim applied to server.py"
  else
    red "auth shim NOT applied to server.py"
    echo "       run: $HOME/.headroom/deploy/default/install-minimax-headroom.sh"
    FAILS=$((FAILS + 1))
  fi
  if grep -q "MINIMAX_SESSION_TOKEN" "$HEADROOM_PKG/proxy/handlers/streaming.py" 2>/dev/null; then
    green "auth shim applied to streaming.py"
  else
    yellow "auth shim NOT applied to streaming.py (streaming may 401)"
  fi
  if grep -q "minimax-code" "$HEADROOM_PKG/proxy/auth_mode.py" 2>/dev/null; then
    green "agent-detection shim applied to auth_mode.py"
  else
    yellow "agent-detection shim NOT applied to auth_mode.py (dashboard may show 'Claude')"
  fi
else
  red "headroom-ai python package not found at $HEADROOM_PKG"
  FAILS=$((FAILS + 1))
fi

# ── 3. launchd services ───────────────────────────────────────────────
section "launchd services"
SVC_LABEL="com.headroom.default"
if launchctl print "gui/$(id -u)/$SVC_LABEL" >/dev/null 2>&1; then
  state=$(launchctl print "gui/$(id -u)/$SVC_LABEL" 2>/dev/null | grep -E "^[[:space:]]*state[[:space:]]*=" | head -1 | awk -F= '{print $2}' | xargs || echo "unknown")
  green "$SVC_LABEL: $state"
else
  red "$SVC_LABEL NOT loaded"
  echo "       run: $HOME/.headroom/deploy/default/install-minimax-headroom.sh"
  FAILS=$((FAILS + 1))
fi

REF_LABEL="com.headroom.minimax-token-refresher"
if launchctl print "gui/$(id -u)/$REF_LABEL" >/dev/null 2>&1; then
  green "$REF_LABEL: loaded (auto-refreshes the JWT every 6h)"
else
  yellow "$REF_LABEL NOT loaded — run install-minimax-headroom.sh to enable auto-refresh"
fi

# ── 4. proxy health ──────────────────────────────────────────────────
section "proxy health"
HEALTH=$(curl -sS --max-time 5 "http://127.0.0.1:$PROXY_PORT/health" 2>/dev/null || echo "")
if [ -n "$HEALTH" ]; then
  python3 -c "
import json, sys
d = json.loads('''$HEALTH''')
print(f'  ✓ service={d.get(\"service\")} status={d.get(\"status\")} version={d.get(\"version\")}')
upstream = d.get('checks', {}).get('upstream', {})
print(f'  ✓ upstream={upstream.get(\"url\")} ({upstream.get(\"status\")})')
" 2>/dev/null || echo "  ! could not parse /health"
else
  red "proxy not responding on :$PROXY_PORT"
  echo "       logs: tail -n 50 $LOGS_DIR/proxy.log 2>/dev/null"
  FAILS=$((FAILS + 1))
fi

# ── 5. live request to MiniMax M3 ────────────────────────────────────
section "live request to MiniMax-M3"
if [ -n "$HEALTH" ]; then
  RESP=$(curl -sS --max-time 30 -X POST "http://127.0.0.1:$PROXY_PORT/v1/messages" \
    -H "Content-Type: application/json" \
    -H "x-api-key: dummy" \
    -H "anthropic-version: 2023-06-01" \
    -H "User-Agent: MiniMax Code/doctor" \
    -d '{"model":"MiniMax-M3","max_tokens":15,"messages":[{"role":"user","content":"Rispondi solo: HEALTHY"}]}' \
    2>&1)
  if echo "$RESP" | grep -q '"MiniMax-M3"' && echo "$RESP" | grep -q 'HEALTHY'; then
    green "M3 responded correctly through the proxy"
  else
    red "M3 request failed: $RESP"
    FAILS=$((FAILS + 1))
  fi
fi

# ── summary ───────────────────────────────────────────────────────────
echo ""
if [ "$FAILS" -eq 0 ]; then
  green "✓ All checks passed. Headroom × MiniMax is healthy."
  exit 0
else
  red "✗ $FAILS check(s) failed. See above for what to fix."
  echo "  Common fixes:"
  echo "    • re-run: $HOME/.headroom/deploy/default/install-minimax-headroom.sh"
  echo "    • or:    $HOME/.headroom/deploy/default/minimax-headroom-token-refresher.sh"
  exit 1
fi
