#!/usr/bin/env bash
# minimax-token-refresher.sh — Refresh automatico del session JWT.
# Gira come LaunchAgent ogni 6h.
#
# Comportamento:
#   - legge il token corrente dal keychain
#   - estrae il token live dal localStorage di Mavis Code
#   - se sono uguali → esce silenziosamente (nessuna modifica)
#   - se diversi → aggiorna keychain + kickstart headroom-MiniMax
#   - se Mavis Code non loggato → log warning, NON tocca keychain (mantiene token vecchio)
#
# Sicuro: NON logga il token in chiaro. Solo "unchanged"/"updated" + exp timestamp.

set -uo pipefail

KEYCHAIN_SERVICE="minimax-session-token"
TOKEN_FETCH="$HOME/.mavis/bin/minimax-token-fetch.sh"
LOG="$HOME/.headroom/logs/token-refresher.log"
PROXY_LABEL="com.headroom.minimax-enable"

mkdir -p "$(dirname "$LOG")"

log() {
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  echo "[$ts] $*" >> "$LOG"
}

# --- 1. Sanity: Mavis Code reachable? ---
if [ ! -x "$TOKEN_FETCH" ]; then
  log "ERROR: $TOKEN_FETCH non trovato"
  exit 1
fi

# --- 2. Estrai token live ---
NEW_TOKEN=$("$TOKEN_FETCH" 2>/dev/null)
if [ -z "$NEW_TOKEN" ]; then
  log "WARN: impossibile estrarre token da Mavis Code (login assente?). keychain non modificato."
  exit 0  # non-blocking: meglio vecchio token che nessuno
fi

# decode exp del nuovo token
NEW_EXP=$(printf '%s' "$NEW_TOKEN" | python3 -c "
import sys, json, base64, datetime
try:
    parts = sys.stdin.read().strip().split('.')
    p = parts[1] + '=' * ((4 - len(p) % 4) % 4)
    exp = json.loads(base64.urlsafe_b64decode(p)).get('exp', 0)
    print(datetime.datetime.fromtimestamp(exp).strftime('%Y-%m-%d %H:%M:%S UTC'))
except Exception:
    print('unknown')
" 2>/dev/null)

# --- 3. Leggi token corrente dal keychain ---
OLD_TOKEN=$(security find-generic-password -s "$KEYCHAIN_SERVICE" -w 2>/dev/null || echo "")

# --- 4. Se uguali, esci ---
if [ -n "$OLD_TOKEN" ] && [ "$OLD_TOKEN" = "$NEW_TOKEN" ]; then
  log "unchanged (exp $NEW_EXP)"
  exit 0
fi

# --- 5. Aggiorna keychain ---
security delete-generic-password -s "$KEYCHAIN_SERVICE" >/dev/null 2>&1 || true
if ! security add-generic-password -s "$KEYCHAIN_SERVICE" -a "mavis-code" -w "$NEW_TOKEN" -U >/dev/null 2>&1; then
  log "ERROR: scrittura keychain fallita"
  exit 1
fi

log "updated (exp $NEW_EXP)"

# --- 6. Kickstart headroom-MiniMax per rileggere ---
# (in realtà headroom non patchato, legge solo al suo startup — quindi kickstart)
# il plist ha KeepAlive=true, quindi crash=restart automatico.
# No-op se già running.
if launchctl print "gui/$(id -u)/$PROXY_LABEL" >/dev/null 2>&1; then
  # Solo kickstart se il servizio è loaded. kickstart -k forza restart.
  launchctl kickstart -k "gui/$(id -u)/$PROXY_LABEL" >/dev/null 2>&1 || true
  log "kicked headroom-MiniMax (restart per applicare nuovo token via re-bootstrap)"
fi

exit 0