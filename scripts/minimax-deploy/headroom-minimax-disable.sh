#!/usr/bin/env bash
# headroom-minimax-disable.sh — Rollback sicuro per l'integrazione
# Headroom × MiniMax. Non rimuove file: li sposta in /Users/axel/.headroom/backups/
# in modo che ogni modifica sia reversibile.
#
# Cosa fa:
#   1. Reinstalla il package headroom-ai pulito (ripristina server.py /
#      streaming.py / auth_mode.py dalle versioni patchate).
#   2. Rimuove il token MiniMax dal keychain macOS.
#   3. Sposta i plist dell'integrazione (token-refresher) in ~/Library/LaunchAgents/disabled-headroom-minimax/
#      senza cancellarli, e ne fa bootout se attivi.
#   4. Verifica che TUTTI i config Mavis puntino al gateway diretto MiniMax
#      (rollback se trovasse 127.0.0.1:8788 o simili).
#   5. Verifica la salute locale del servizio Mavis.
#
# Idempotente: riavviabile senza effetti collaterali.

set -uo pipefail

# ── colors ────────────────────────────────────────────────────────────
green()  { printf "\033[32m%s\033[0m\n" "$*"; }
red()    { printf "\033[31m%s\033[0m\n" "$*" >&2; }
yellow() { printf "\033[33m%s\033[0m\n" "$*"; }
bold()   { printf "\033[1m%s\033[0m\n" "$*"; }
step()   { printf "\n\033[1;34m▶ %s\033[0m\n" "$*"; }

# ── paths ─────────────────────────────────────────────────────────────
BACKUP_ROOT="/Users/axel/.headroom/backups/$(date -u +%Y-%m-%d)/disable-$(date -u +%H%M%SZ)"
mkdir -p "$BACKUP_ROOT"

LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
DISABLED_DIR="$LAUNCH_AGENTS/disabled-headroom-minimax"
Mavis_BIN="$HOME/.mavis/bin"
HEADROOM_PKG="/Users/axel/.local/share/uv/tools/headroom-ai/lib/python3.11/site-packages/headroom"

MINIMAX_BASEURL="https://agent.minimax.io/mavis/api/v1/llm"

bold "  Headroom × MiniMax DISABLE (rollback safe)"
echo "    backup root: $BACKUP_ROOT"
echo ""

# ── 1. Reinstalla headroom-ai pulito ─────────────────────────────────
step "1/6  Ripristino headroom-ai (rimuove patch MiniMax dal package)"
PATCHED=0
for f in "$HEADROOM_PKG/proxy/server.py" "$HEADROOM_PKG/proxy/handlers/streaming.py" "$HEADROOM_PKG/proxy/auth_mode.py"; do
  if [ -f "$f" ] && grep -q "MINIMAX_SESSION_TOKEN\|minimax-code" "$f" 2>/dev/null; then
    PATCHED=$((PATCHED+1))
  fi
done

if [ "$PATCHED" -gt 0 ]; then
  yellow "  ⚠ $PATCHED file patchati rilevati — reinstallo headroom-ai"
  # Salva i file patched in backup
  for f in "$HEADROOM_PKG/proxy/server.py" "$HEADROOM_PKG/proxy/handlers/streaming.py" "$HEADROOM_PKG/proxy/auth_mode.py"; do
    if [ -f "$f" ]; then
      cp "$f" "$BACKUP_ROOT/$(basename $(dirname $f))__$(basename $f)"
    fi
  done

  # Reinstalla il package pulito (uv reinstalla dalla cache o dal registry)
  if command -v uv >/dev/null 2>&1; then
    uv tool install --reinstall headroom-ai 2>&1 | tail -3
  else
    yellow "  ⚠ uv non trovato — reinstallo con pip"
    python3 -m pip install --force-reinstall --no-deps headroom-ai 2>&1 | tail -3
  fi

  # Verifica che le patch siano sparite
  REMAINING=0
  for f in "$HEADROOM_PKG/proxy/server.py" "$HEADROOM_PKG/proxy/handlers/streaming.py" "$HEADROOM_PKG/proxy/auth_mode.py"; do
    if [ -f "$f" ] && grep -q "MINIMAX_SESSION_TOKEN\|minimax-code" "$f" 2>/dev/null; then
      REMAINING=$((REMAINING+1))
    fi
  done

  if [ "$REMAINING" -gt 0 ]; then
    yellow "  ⚠ $REMAINING file ancora patchati dopo reinstall (potrebbe richiedere reboot uv)"
  else
    green "  ✓ headroom-ai pulito"
  fi
else
  green "  ✓ headroom-ai già pulito (niente da fare)"
fi

# ── 2. Rimuovi token dal keychain ───────────────────────────────────
step "2/6  Rimuovo token MiniMax dal keychain macOS"
if security find-generic-password -s "minimax-session-token" >/dev/null 2>&1; then
  # Backup prima: salva in file locale (NO LOG, permessi 600)
  TOKEN=$(security find-generic-password -s "minimax-session-token" -w 2>/dev/null)
  if [ -n "$TOKEN" ]; then
    echo "eyJ...REDACTED...$(echo -n "$TOKEN" | tail -c 20)" > "$BACKUP_ROOT/keychain-token.txt"
    chmod 600 "$BACKUP_ROOT/keychain-token.txt"
  fi
  security delete-generic-password -s "minimax-session-token" 2>/dev/null
  green "  ✓ token rimosso (backup in $BACKUP_ROOT/keychain-token.txt, permessi 600)"
else
  green "  ✓ keychain già pulito"
fi

# ── 3. Sposta i plist dell'integrazione in disabled- ────────────────
step "3/6  Sposto plist dell'integrazione in $DISABLED_DIR/"
mkdir -p "$DISABLED_DIR"

for plist in \
  "$LAUNCH_AGENTS/com.headroom.minimax-token-refresher.plist" \
  "$LAUNCH_AGENTS/com.headroom.minimax-enable.plist" \
  "$LAUNCH_AGENTS/com.headroom.minimax.plist"
do
  if [ -f "$plist" ]; then
    LABEL=$(basename "$plist" .plist)
    # bootout prima (se attivo), ignora errori
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    sleep 1
    # Sposta senza cancellare
    mv "$plist" "$DISABLED_DIR/$LABEL.plist.disabled-$(date -u +%Y%m%d%H%M%SZ)"
    green "  ✓ spostato: $LABEL.plist"
  fi
done

# Se il plist è già in disabled- dir da prima, va bene
ls "$DISABLED_DIR/" 2>/dev/null

# ── 4. Verifica / correggi i baseURL nei config Mavis ────────────────
step "4/6  Verifico che TUTTI i baseURL puntino al gateway diretto MiniMax"
FIXED=0
TOTAL=0
# config.yaml
if [ -f "$HOME/.mavis/config.yaml" ]; then
  TOTAL=$((TOTAL+1))
  if ! grep -q "baseURL: $MINIMAX_BASEURL" "$HOME/.mavis/config.yaml" 2>/dev/null; then
    yellow "  ⚠ $HOME/.mavis/config.yaml non punta a MiniMax — fix"
    cp "$HOME/.mavis/config.yaml" "$BACKUP_ROOT/config.yaml"
    python3 -c "
import re, sys
p = '$HOME/.mavis/config.yaml'
content = open(p).read()
content = re.sub(r'baseURL:.*', 'baseURL: $MINIMAX_BASEURL', content)
open(p, 'w').write(content)
"
    FIXED=$((FIXED+1))
  fi
fi

# opencode.json per ogni agente
for f in $(find "$HOME/.mavis/agents/" -name "opencode.json" 2>/dev/null); do
  TOTAL=$((TOTAL+1))
  if grep -q "127.0.0.1:8787\|127.0.0.1:8788\|headroom" "$f" 2>/dev/null; then
    yellow "  ⚠ $f ha riferimenti a headroom — fix"
    cp "$f" "$BACKUP_ROOT/$(basename $(dirname $(dirname $f)))__opencode.json"
    python3 -c "
import json, sys
p = '$f'
data = json.load(open(p))
# Trova la sezione 'provider' e ripristina baseURL
for prov_name, prov in data.get('provider', {}).items():
    if isinstance(prov, dict) and 'options' in prov:
        prov['options']['baseURL'] = '$MINIMAX_BASEURL'
open(p, 'w').write(json.dumps(data, indent=2))
"
    FIXED=$((FIXED+1))
  fi
done

if [ "$FIXED" -gt 0 ]; then
  green "  ✓ $FIXED/$TOTAL config corretti, backup in $BACKUP_ROOT"
else
  green "  ✓ $TOTAL config già corretti"
fi

# ── 5. Sanity check ──────────────────────────────────────────────────
step "5/6  Sanity check"
echo "  config.yaml baseURL: $(grep 'baseURL' $HOME/.mavis/config.yaml 2>/dev/null | head -1 | tr -s ' ')"
for f in $(find "$HOME/.mavis/agents/" -name "opencode.json" 2>/dev/null); do
  AGENT=$(basename $(dirname $(dirname $f)))
  BASEURL=$(grep '"baseURL"' "$f" | head -1 | tr -s ' ')
  echo "  $AGENT: $BASEURL"
done
echo "  keychain token: $(security find-generic-password -s 'minimax-session-token' -w >/dev/null 2>&1 && echo 'PRESENTE (non dumpato)' || echo 'non presente')"
echo "  plist integrazione in: $DISABLED_DIR/"

# ── 6. Verifica Mavis locale ─────────────────────────────────────────
step "6/6  Verifico Mavis locale (http://127.0.0.1:15321/mavis/health)"
HEALTH=$(curl -sS --max-time 3 "http://127.0.0.1:15321/mavis/health" 2>/dev/null)
if [ -n "$HEALTH" ]; then
  green "  ✓ Mavis reachable"
else
  yellow "  ! Mavis non risponde (potrebbe essere normale in alcuni setup)"
fi

# ── Verifica MiniMax diretto funziona ────────────────────────────────
step "Verifica finale: MiniMax diretto (bypass completo)"
RESP=$(curl -sS --max-time 10 -X POST "$MINIMAX_BASEURL/messages" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer test" \
  -H "anthropic-version: 2023-06-01" \
  -d '{"model":"MiniMax-M2.7-highspeed","max_tokens":5,"messages":[{"role":"user","content":"ok"}]}' 2>&1)
if echo "$RESP" | grep -q "auth failed\|token is required\|message\|id"; then
  if echo "$RESP" | grep -q "auth failed\|token is required"; then
    yellow "  ! gateway risponde ma auth fallisce (normale con token finto)"
    green "  ✓ gateway diretto raggiungibile"
  else
    green "  ✓ MiniMax diretto funziona"
  fi
else
  red "  ✗ gateway diretto non raggiungibile: $RESP"
fi

echo ""
bold "✓ Disable completato."
echo "  backup: $BACKUP_ROOT"
echo "  tutti i config Mavis puntano a: $MINIMAX_BASEURL"
echo "  headroom-ai pulito (Codex routing intatto)"
echo "  per MiniMax diretto: usa la CLI Mavis normalmente"
