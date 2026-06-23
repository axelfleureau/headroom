#!/usr/bin/env bash
# minimax-token-fetch.sh — Estrae il session JWT dal localStorage di Mavis Code.
#
# Strategia: il token è in localStorage Chromium (leveldb), salvato come JSON.
# Scandiamo tutti i file .ldb/.log, estraiamo ogni JWT valido, decodifichiamo
# il claim 'exp' e ritorniamo quello con 'exp' più alto (= più recente).
#
# Output: solo il token su stdout (mai loggato). Exit 0 se trovato, 1 altrimenti.
# Exit 2 se Mavis Code non è installato.
#
# Usage:  minimax-token-fetch.sh
#         $(minimax-token-fetch.sh)  # espande inline

set -uo pipefail

LEVELDB_DIR="$HOME/Library/Application Support/MiniMax Agent/Local Storage/leveldb"

# --- preflight ---
if [ ! -d "$LEVELDB_DIR" ]; then
  echo "ERROR: Mavis Code localStorage non trovato in $LEVELDB_DIR" >&2
  echo "       installa Mavis Code da https://agent.minimax.io" >&2
  exit 2
fi

# --- decode del payload JWT (segmento 2) ---
# input: token su stdin
# output: integer exp su stdout, oppure 0 se non parsabile
decode_exp() {
  python3 -c "
import sys, json, base64
parts = sys.stdin.read().strip().split('.')
if len(parts) != 3:
    print(0)
    sys.exit(0)
p = parts[1]
p += '=' * ((4 - len(p) % 4) % 4)
try:
    decoded = base64.urlsafe_b64decode(p)
    obj = json.loads(decoded)
    print(int(obj.get('exp', 0)))
except Exception:
    print(0)
" 2>/dev/null
}

# --- scan leveldb ---
# raccoglie candidati: "exp<TAB>token"
CANDIDATES=""
shopt -s nullglob
for f in "$LEVELDB_DIR"/*.ldb "$LEVELDB_DIR"/*.log; do
  [ -f "$f" ] || continue
  while IFS= read -r tok; do
    [ -z "$tok" ] && continue
    exp=$(printf '%s' "$tok" | decode_exp)
    [ "$exp" -gt 0 ] || continue
    # solo token che scadono nel futuro (almeno 1h di margine)
    now=$(date +%s)
    if [ "$exp" -gt $((now + 3600)) ]; then
      CANDIDATES+="${exp}"$'\t'"${tok}"$'\n'
    fi
  done < <(strings "$f" 2>/dev/null | grep -oE "eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+")
done
shopt -u nullglob

if [ -z "$CANDIDATES" ]; then
  echo "ERROR: nessun JWT valido trovato in $LEVELDB_DIR" >&2
  echo "       fai login in Mavis Code e invia un messaggio per generare il token" >&2
  exit 1
fi

# --- prendi il token con exp più alto ---
best=$(printf '%s' "$CANDIDATES" | sort -t$'\t' -k1 -n -r | head -1)
TOKEN="${best#*$'\t'}"

# output: SOLO il token (no newline extra per non sporcare $(...) substitution)
printf '%s' "$TOKEN"
exit 0