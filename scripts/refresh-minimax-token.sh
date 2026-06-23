#!/usr/bin/env bash
# refresh-minimax-token.sh — pull the latest session JWT from MiniMax Code's
# local storage and write it to the macOS keychain. Run this if the proxy
# starts returning 401s from `agent.minimax.io` even though you are still
# logged in to MiniMax Code.
#
# Usage:  ./scripts/refresh-minimax-token.sh
#
# No flags. Safe to re-run; idempotent (overwrites the existing keychain entry).

set -euo pipefail

LEVELDB_DIR="$HOME/Library/Application Support/MiniMax Agent/Local Storage/leveldb"
KEYCHAIN_SERVICE="minimax-session-token"

if [ ! -d "$LEVELDB_DIR" ]; then
  echo "ERROR: $LEVELDB_DIR not found — is MiniMax Code installed?" >&2
  exit 1
fi

# Concatenate all leveldb .log files and extract the most recent JWT.
# LevelDB stores keys/values as length-prefixed binary; for our purposes
# `strings` is enough since the JWT is plain ASCII.
LATEST=""
for f in "$LEVELDB_DIR"/*.log; do
  [ -f "$f" ] || continue
  found=$(strings "$f" | grep -oE "eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+" || true)
  for token in $found; do
    # Decode the exp claim from the JWT payload (segment 2) and prefer
    # the highest expiry.
    payload_b64=$(echo "$token" | cut -d. -f2)
    # base64url -> base64
    payload_b64=${payload_b64//-/+}
    payload_b64=${payload_b64//_/\/}
    case $((${#payload_b64} % 4)) in
      2) payload_b64="${payload_b64}==" ;;
      3) payload_b64="${payload_b64}=" ;;
    esac
    exp=$(echo "$payload_b64" | base64 -d 2>/dev/null | python3 -c "import sys, json; print(json.load(sys.stdin).get('exp', 0))" 2>/dev/null || echo 0)
    if [ -n "$exp" ] && [ "$exp" -gt 0 ]; then
      if [ -z "$LATEST" ]; then
        LATEST="$token"
      else
        prev_payload=$(echo "$LATEST" | cut -d. -f2)
        prev_payload=${prev_payload//-/+}
        prev_payload=${prev_payload//_/\/}
        case $((${#prev_payload} % 4)) in
          2) prev_payload="${prev_payload}==" ;;
          3) prev_payload="${prev_payload}=" ;;
        esac
        prev_exp=$(echo "$prev_payload" | base64 -d 2>/dev/null | python3 -c "import sys, json; print(json.load(sys.stdin).get('exp', 0))" 2>/dev/null || echo 0)
        if [ "$exp" -gt "$prev_exp" ]; then
          LATEST="$token"
        fi
      fi
    fi
  done
done

if [ -z "$LATEST" ]; then
  echo "ERROR: no JWT tokens found in $LEVELDB_DIR — please sign in to MiniMax Code first." >&2
  exit 2
fi

# Persist to the keychain (overwrite).
# `security` writes verbose keychain metadata to stderr on macOS — silence it.
security delete-generic-password -s "$KEYCHAIN_SERVICE" 2>/dev/null >/dev/null || true
security add-generic-password -s "$KEYCHAIN_SERVICE" -a "$USER" -w "$LATEST" -U 2>/dev/null >/dev/null

# Print a friendly summary.
payload_b64=$(echo "$LATEST" | cut -d. -f2)
payload_b64=${payload_b64//-/+}
payload_b64=${payload_b64//_/\/}
case $((${#payload_b64} % 4)) in
  2) payload_b64="${payload_b64}==" ;;
  3) payload_b64="${payload_b64}=" ;;
esac
exp_iso=$(echo "$payload_b64" | base64 -d 2>/dev/null | python3 -c "import sys, json, datetime; d=json.load(sys.stdin); print(datetime.datetime.fromtimestamp(d.get('exp', 0)).strftime('%Y-%m-%d %H:%M:%S'))" 2>/dev/null || echo "unknown")

echo "  ✓ Token written to keychain '$KEYCHAIN_SERVICE'"
echo "  ✓ Expires: $exp_iso"
echo ""
echo "Restart headroom to pick up the new token:"
echo "  launchctl kickstart -k gui/\$(id -u)/com.headroom.default"
