#!/usr/bin/env bash
# minimax-headroom-token-refresher.sh — LaunchAgent companion that keeps the
# Mavis Code session JWT fresh in the macOS keychain every 6 hours, and
# restarts the headroom proxy to pick up the new token.
#
# Designed to run unattended. Idempotent. Safe to re-run manually.
#
# Exit codes:
#   0  token refreshed (or already fresh)
#   1  Codex/MiniMax Code not installed or not logged in
#   2  keychain write failed
#   3  proxy restart failed (but token was written)
#
# Logs to: ~/.headroom/logs/token-refresher.log

set -uo pipefail

LOG_DIR="$HOME/.headroom/logs"
LOG_FILE="$LOG_DIR/token-refresher.log"
LEVELDB_DIR="$HOME/Library/Application Support/MiniMax Agent/Local Storage/leveldb"
KEYCHAIN_SERVICE="minimax-session-token"
REFRESH_THRESHOLD_SECONDS=21600  # 6 hours

mkdir -p "$LOG_DIR" 2>/dev/null || true

log() {
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  echo "[$ts] $*" | tee -a "$LOG_FILE" >&2
}

# 1. Sanity: Codex installed?
if [ ! -d "$LEVELDB_DIR" ]; then
  log "ERROR: MiniMax Code leveldb not found at $LEVELDB_DIR"
  log "       install MiniMax Code from https://agent.minimax.io and log in"
  exit 1
fi

# 2. Extract the JWT with the highest 'exp' claim from leveldb .log files.
LATEST=""
LATEST_EXP=0
for f in "$LEVELDB_DIR"/*.log; do
  [ -f "$f" ] || continue
  while IFS= read -r token; do
    [ -z "$token" ] && continue
    # Decode the exp claim (segment 2) from the JWT.
    payload_b64=$(echo "$token" | cut -d. -f2)
    payload_b64=${payload_b64//-/+}
    payload_b64=${payload_b64//_/\/}
    case $((${#payload_b64} % 4)) in
      2) payload_b64="${payload_b64}==" ;;
      3) payload_b64="${payload_b64}=" ;;
    esac
    exp=$(echo "$payload_b64" | base64 -d 2>/dev/null | python3 -c "import sys, json; print(json.load(sys.stdin).get('exp', 0))" 2>/dev/null || echo 0)
    if [ "$exp" -gt "$LATEST_EXP" ]; then
      LATEST_EXP=$exp
      LATEST="$token"
    fi
  done < <(strings "$f" 2>/dev/null | grep -oE "eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+" || true)
done

if [ -z "$LATEST" ]; then
  log "ERROR: no JWT found in leveldb — please sign in to MiniMax Code"
  exit 1
fi

# 3. Check if the current keychain token is still fresh.
CURRENT=$(security find-generic-password -s "$KEYCHAIN_SERVICE" -w 2>/dev/null)
SAME=no
if [ -n "$CURRENT" ] && [ "$CURRENT" = "$LATEST" ]; then
  SAME=yes
fi

# Always (re)write — ensures the keychain is in sync with what leveldb has.
if security delete-generic-password -s "$KEYCHAIN_SERVICE" >/dev/null 2>&1; then :; fi
if ! security add-generic-password -s "$KEYCHAIN_SERVICE" -a "$USER" -w "$LATEST" -U >/dev/null 2>&1; then
  log "ERROR: failed to write JWT to keychain"
  exit 2
fi

# 4. Decode expiry for the log line.
exp_iso=$(date -u -r "$LATEST_EXP" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "unknown")
if [ "$SAME" = "yes" ]; then
  log "  ✓ token unchanged (expires $exp_iso) — no restart needed"
  exit 0
fi

log "  ✓ token refreshed (expires $exp_iso) — restarting headroom proxy"

# 5. Restart headroom so it picks up the new env var.
# Use kickstart -k which is non-blocking and atomic.
if launchctl kickstart -k "gui/$(id -u)/com.headroom.default" >/dev/null 2>&1; then
  log "  ✓ headroom proxy restarted (PID changes within ~3s)"
  exit 0
else
  log "WARN: launchctl kickstart failed — proxy still has the old token"
  log "      run manually: launchctl kickstart -k gui/\$(id -u)/com.headroom.default"
  exit 3
fi
