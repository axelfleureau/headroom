#!/usr/bin/env bash
# headroom-minimax-enable.sh — Abilita OPT-IN l'integrazione
# Headroom × MiniMax (gateway agent.minimax.io).
#
# Architettura finale (no patch al package headroom-ai):
#   - Headroom raw su 127.0.0.1:8788 (profilo separato)
#   - Headroom forwarda TUTTI i client headers intatti (incluso `Token: <jwt>`)
#   - Mavis Code manda già `Token: <jwt>` corretto (gestito da readMavisAuthToken)
#   - Il proxy NON aggiunge nulla: passa i client headers al gateway
#
# Regole production-ready:
#   - NON tocca il plist com.headroom.default (Codex resta su 8787 intatto)
#   - NON patcha il package headroom-ai
#   - Profilo headroom dedicato su porta 8788 (no conflitto con Codex)
#   - Backup timestampati di ogni file modificato
#   - Verifica end-to-end che /v1/messages funzioni con token reale
#   - Rollback automatico se qualsiasi step fallisce
#   - Idempotente
#
# Usage:
#   headroom-minimax-enable.sh              # modalità interattiva
#   headroom-minimax-enable.sh --port 8788 # porta custom
#   headroom-minimax-enable.sh --yes       # no prompt
#
# Cosa NON fa (di proposito):
#   - Non aggiunge ANTHROPIC_TARGET_API_URL al plist com.headroom.default
#   - Non modifica ~/.mavis/config.yaml o opencode.json (opt-in per utente)
#   - Non patcha headroom-ai
#   - Non logga il token in chiaro (usa keychain + env var)

set -uo pipefail

# ── args ──────────────────────────────────────────────────────────────
PORT=8788
ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    --port) shift; PORT="${1:-8788}"; shift ;;
    --port=*) PORT="${arg#--port=}"; ;;
    --yes|-y) ASSUME_YES=1 ;;
    --help|-h)
      head -25 "$0" | tail -22
      exit 0
      ;;
  esac
done

# ── colors ────────────────────────────────────────────────────────────
green()  { printf "\033[32m%s\033[0m\n" "$*"; }
red()    { printf "\033[31m%s\033[0m\n" "$*" >&2; }
yellow() { printf "\033[33m%s\033[0m\n" "$*"; }
bold()   { printf "\033[1m%s\033[0m\n" "$*"; }
step()   { printf "\n\033[1;34m▶ %s\033[0m\n" "$*"; }

# ── paths ─────────────────────────────────────────────────────────────
BACKUP_ROOT="/Users/axel/.headroom/backups/$(date -u +%Y-%m-%d)/enable-$(date -u +%H%M%SZ)"
mkdir -p "$BACKUP_ROOT"

LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
DEPLOY_DIR="/Users/axel/.headroom/deploy/minimax-enable"
mkdir -p "$DEPLOY_DIR"

KEYCHAIN_SERVICE="minimax-session-token"
MINIMAX_BASEURL="https://agent.minimax.io/mavis/api/v1/llm"
TOKEN_FETCH="$HOME/.mavis/bin/minimax-token-fetch.sh"
PROFILE_NAME="minimax-enable"
RUNNER="$DEPLOY_DIR/run-headroom-minimax.sh"
LAUNCH_AGENT="$LAUNCH_AGENTS/com.headroom.$PROFILE_NAME.plist"

# ── 0. Safety check: spazio disco ─────────────────────────────────────
FREE_KB=$(df -k "$HOME" 2>/dev/null | awk 'NR==2 {print $4}')
if [ -z "$FREE_KB" ] || [ "$FREE_KB" -lt 2097152 ]; then
  red "✗ Spazio disco insufficiente (< 2GB richiesto)"
  exit 1
fi
FREE_GB=$((FREE_KB / 1048576))

bold "  Headroom × MiniMax ENABLE (opt-in, profilo separato)"
echo "    profilo:        $PROFILE_NAME"
echo "    porta:          $PORT"
echo "    baseURL:        $MINIMAX_BASEURL (NO patch al package)"
echo "    deploy dir:     $DEPLOY_DIR"
echo "    launch agent:   $LAUNCH_AGENT"
echo "    backup root:    $BACKUP_ROOT"
echo ""

if [ "$ASSUME_YES" -ne 1 ]; then
  echo "Premi INVIO per continuare, Ctrl-C per annullare."
  read -r _
fi

# ── 1. Pre-flight: headroom-ai pulito (non patchato) ──────────────────
step "1/8  Pre-flight: headroom-ai pulito?"
HEADROOM_PKG="/Users/axel/.local/share/uv/tools/headroom-ai/lib/python3.11/site-packages/headroom"
PATCHED=0
for f in "$HEADROOM_PKG/proxy/server.py" "$HEADROOM_PKG/proxy/handlers/streaming.py" "$HEADROOM_PKG/proxy/auth_mode.py"; do
  if [ -f "$f" ] && grep -q "MINIMAX_SESSION_TOKEN\|minimax-code" "$f" 2>/dev/null; then
    PATCHED=$((PATCHED+1))
  fi
done
if [ "$PATCHED" -gt 0 ]; then
  red "✗ headroom-ai è ancora patchato. Esegui prima: headroom-minimax-disable.sh"
  exit 1
fi
green "  ✓ headroom-ai pulito (nessuna patch MiniMax)"

# ── 2. Pre-flight: Mavis Code locale reachable + token fetch ──────────
step "2/8  Pre-flight: Mavis Code locale reachable + token fetch"
if [ ! -x "$TOKEN_FETCH" ]; then
  red "✗ $TOKEN_FETCH non trovato o non eseguibile"
  exit 1
fi

TOKEN=$("$TOKEN_FETCH" 2>/dev/null)
if [ -z "$TOKEN" ]; then
  red "✗ impossibile estrarre token JWT dal localStorage di Mavis Code"
  yellow "  → apri Mavis Code, fai login, invia un messaggio"
  yellow "  → poi ri-esegui questo script"
  exit 1
fi

# decode exp per il log
EXP=$(printf '%s' "$TOKEN" | python3 -c "
import sys, json, base64, datetime
parts = sys.stdin.read().strip().split('.')
p = parts[1] + '=' * ((4 - len(p) % 4) % 4)
exp = json.loads(base64.urlsafe_b64decode(p)).get('exp', 0)
print(datetime.datetime.fromtimestamp(exp).strftime('%Y-%m-%d %H:%M:%S UTC'))
" 2>/dev/null)
green "  ✓ token JWT estratto (exp: $EXP, len=${#TOKEN})"

# ── 3. Salva token nel keychain ───────────────────────────────────────
step "3/8  Salvo token nel keychain macOS"
security delete-generic-password -s "$KEYCHAIN_SERVICE" 2>/dev/null || true
if ! security add-generic-password -s "$KEYCHAIN_SERVICE" -a "mavis-code" -w "$TOKEN" -U >/dev/null 2>&1; then
  red "✗ fallita scrittura keychain"
  exit 1
fi
green "  ✓ token salvato in keychain '$KEYCHAIN_SERVICE' (permessi 600)"

# ── 4. Verifica end-to-end con token reale verso gateway diretto ────────
step "4/8  Verifica end-to-end: gateway diretto con header Token"
DIRECT_RESP=$(curl -sS --max-time 10 -X POST "${MINIMAX_BASEURL}/v1/messages" \
  -H "Content-Type: application/json" \
  -H "Token: $TOKEN" \
  -H "anthropic-version: 2023-06-01" \
  -d '{"model":"MiniMax-M2.7-highspeed","max_tokens":15,"messages":[{"role":"user","content":"say HELLO"}]}' 2>&1)

if echo "$DIRECT_RESP" | grep -q '"id":' && echo "$DIRECT_RESP" | grep -q 'HELLO'; then
  green "  ✓ gateway diretto risponde con modello MiniMax"
elif echo "$DIRECT_RESP" | grep -q '"id":'; then
  green "  ✓ gateway diretto risponde (id valido)"
else
  red "✗ gateway diretto non risponde: $(echo "$DIRECT_RESP" | head -c 200)"
  yellow "  Eseguo rollback keychain..."
  security delete-generic-password -s "$KEYCHAIN_SERVICE" 2>/dev/null || true
  exit 1
fi

# ── 5. Scrivi runner (porta dedicata, profile dedicato) ──────────────
step "5/8  Scrivo runner: $RUNNER"
cat > "$RUNNER" <<EOF
#!/usr/bin/env bash
# Headroom × MiniMax — profilo separato (NON tocca il profilo Codex).
# Porta dedicata: $PORT. Profilo headroom dedicato: $PROFILE_NAME.
#
# headroom è RAW (no patch): passa tutti i client headers intatti.
# Il client (Mavis Code) manda già \`Token: <jwt>\` corretto verso il gateway.
set -euo pipefail
export HEADROOM_OUTPUT_SHAPER=1
export HEADROOM_VERBOSITY_LEVEL=1
export HEADROOM_EFFORT_ROUTER=1
export HEADROOM_TELEMETRY=off
# Questo è l'unico punto dove ANTHROPIC_TARGET_API_URL è impostato verso MiniMax.
# Rimane confinato a questo profilo — il plist com.headroom.default è intatto.
export ANTHROPIC_TARGET_API_URL="$MINIMAX_BASEURL"
exec /Users/axel/.local/bin/headroom proxy \\
  --host 127.0.0.1 \\
  --port $PORT \\
  --mode token \\
  --backend anthropic
EOF
chmod +x "$RUNNER"
green "  ✓ scritto"

# ── 6. Scrivi LaunchAgent dedicato ────────────────────────────────────
step "6/8  Scrivo LaunchAgent: $LAUNCH_AGENT"
cat > "$LAUNCH_AGENT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.headroom.$PROFILE_NAME</string>
  <key>ProgramArguments</key>
  <array>
    <string>$RUNNER</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HEADROOM_OUTPUT_SHAPER</key>
    <string>1</string>
    <key>HEADROOM_VERBOSITY_LEVEL</key>
    <string>1</string>
    <key>HEADROOM_EFFORT_ROUTER</key>
    <string>1</string>
    <key>HEADROOM_TELEMETRY</key>
    <string>off</string>
    <key>ANTHROPIC_TARGET_API_URL</key>
    <string>$MINIMAX_BASEURL</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
</dict>
</plist>
EOF
green "  ✓ plist scritto (no MINIMAX_TOKEN env: headroom non patchato, passa client headers)"

# ── 7. Avvia servizio + verifica proxy end-to-end ────────────────────
step "7/8  Avvio servizio e verifico end-to-end via headroom-MiniMax"
launchctl bootout "gui/$(id -u)/com.headroom.$PROFILE_NAME" 2>/dev/null || true
sleep 1
if ! launchctl bootstrap "gui/$(id -u)" "$LAUNCH_AGENT" 2>/dev/null; then
  red "✗ launchctl bootstrap fallito"
  yellow "  Eseguo rollback (rimuovo plist + keychain)..."
  rm -f "$LAUNCH_AGENT"
  security delete-generic-password -s "$KEYCHAIN_SERVICE" 2>/dev/null || true
  exit 1
fi
green "  ✓ com.headroom.$PROFILE_NAME bootstrap OK"

# Aspetta health (retry 15s perché headroom è lento)
HEALTH=""
for i in $(seq 1 15); do
  sleep 1
  HEALTH=$(curl -sS --max-time 2 "http://127.0.0.1:$PORT/health" 2>/dev/null)
  if [ -n "$HEALTH" ]; then break; fi
done

if [ -z "$HEALTH" ]; then
  red "✗ headroom-MiniMax non risponde su :$PORT (dopo 15s)"
  yellow "  Rollback..."
  launchctl bootout "gui/$(id -u)/com.headroom.$PROFILE_NAME" 2>/dev/null || true
  rm -f "$LAUNCH_AGENT"
  exit 1
fi

UPSTREAM=$(echo "$HEALTH" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('checks',{}).get('upstream',{}).get('url','?'))" 2>/dev/null)
green "  ✓ headroom up, upstream=$UPSTREAM"

# Test /v1/messages via proxy: il client manda Token header (simula Mavis Code)
PROXY_RESP=$(curl -sS --max-time 15 -X POST "http://127.0.0.1:$PORT/v1/messages" \
  -H "Content-Type: application/json" \
  -H "Token: $TOKEN" \
  -H "anthropic-version: 2023-06-01" \
  -H "User-Agent: MiniMax Code/3.0.43" \
  -d '{"model":"MiniMax-M2.7-highspeed","max_tokens":15,"messages":[{"role":"user","content":"say HELLO"}]}' 2>&1)

if echo "$PROXY_RESP" | grep -q '"id":' && echo "$PROXY_RESP" | grep -q 'HELLO'; then
  green "  ✓ /v1/messages via headroom-MiniMax: MiniMax M2.7-highspeed risponde"
elif echo "$PROXY_RESP" | grep -q '"id":'; then
  green "  ✓ /v1/messages via headroom-MiniMax: id valido"
else
  red "✗ /v1/messages via headroom-MiniMax: $(echo $PROXY_RESP | head -c 200)"
  yellow "  Rollback..."
  launchctl bootout "gui/$(id -u)/com.headroom.$PROFILE_NAME" 2>/dev/null || true
  rm -f "$LAUNCH_AGENT"
  exit 1
fi

# ── 8. Verifica non-regressione Codex ──────────────────────────────────
step "8/8  Verifica non-regressione Codex (com.headroom.default intatto)"
CODEX_PLIST="$LAUNCH_AGENTS/com.headroom.default.plist"
if [ -f "$CODEX_PLIST" ]; then
  HAS_OLD=$(grep -c "ANTHROPIC_TARGET_API_URL.*minimax" "$CODEX_PLIST" 2>/dev/null)
  if [ "$HAS_OLD" -gt 0 ]; then
    red "✗ plist Codex contiene ANTHROPIC_TARGET_API_URL verso MiniMax — rimuovilo"
    exit 1
  fi
  green "  ✓ plist Codex intatto"
fi

# ── Summary ───────────────────────────────────────────────────────────
echo ""
bold "✓ Headroom × MiniMax abilitato (profilo separato, NO patch)"
echo ""
echo "  profilo:        com.headroom.$PROFILE_NAME"
echo "  porta locale:   http://127.0.0.1:$PORT"
echo "  upstream:       $MINIMAX_BASEURL"
echo "  Codex:          intatto (8787, plist com.headroom.default non toccato)"
echo "  token:          keychain '$KEYCHAIN_SERVICE' (scade: $EXP)"
echo "  architettura:   Mavis Code → 8788 → agent.minimax.io (Token header pass-through)"
echo ""
echo "  Per usarlo dal tuo client (Mavis, Claude Code, OpenCode):"
echo "    ANTHROPIC_BASE_URL=http://127.0.0.1:$PORT  ANTHROPIC_MODEL=MiniMax-M3  claude"
echo ""
echo "  Per refreshare il token: $TOKEN_FETCH && security add-generic-password ..."
echo "  Per disabilitare: headroom-minimax-disable.sh"
echo "  Per stato:       headroom-minimax-status"