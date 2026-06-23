#!/usr/bin/env bash
# install-minimax-headroom.sh — One-shot installer that wires up
# Headroom proxy + MiniMax Mavis Code auth shim on a fresh macOS box.
#
# Designed to be safe to re-run. Handles every error path that an
# "I just want it to work" user would hit. Idempotent.
#
# What it does, in order:
#   1. Verifies MiniMax Code is installed and logged in.
#   2. Verifies headroom-ai (this fork) is installed.
#   3. Patches the installed headroom package with the Mavis Code
#      gateway auth shim (server.py + streaming.py + auth_mode.py).
#   4. Writes the headroom runner script (run-headroom.sh).
#   5. Writes the launchd plist + bootstraps the headroom service.
#   6. Writes the token-refresher LaunchAgent + bootstraps it.
#   7. Refreshes the Mavis Code session JWT into the macOS keychain.
#   8. Sends a smoke-test request to verify end-to-end.
#   9. Prints "done" or a precise error message.
#
# Re-run any time: it's idempotent. Safe to run after a Headroom upgrade.

set -uo pipefail

# ── paths ─────────────────────────────────────────────────────────────
REPO_DIR="$HOME/.headroom/deploy/default"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
LOGS_DIR="$HOME/.headroom/logs"
KEYCHAIN_SERVICE="minimax-session-token"
LEVELDB_DIR="$HOME/Library/Application Support/MiniMax Agent/Local Storage/leveldb"
HEADROOM_PYTHON_DIR="/Users/axel/.local/share/uv/tools/headroom-ai/lib/python3.11/site-packages/headroom"
HEADROOM_BIN="/Users/axel/.local/bin/headroom"
PROXY_PORT="${HEADROOM_PORT:-8787}"
SERVICE_LABEL="com.headroom.default"
REFRESHER_LABEL="com.headroom.minimax-token-refresher"
REFRESHER_INTERVAL_SECONDS=21600  # 6h

mkdir -p "$REPO_DIR" "$LAUNCH_AGENTS_DIR" "$LOGS_DIR"

# ── colours / printing ────────────────────────────────────────────────
green()  { printf "\033[32m%s\033[0m\n" "$*"; }
red()    { printf "\033[31m%s\033[0m\n" "$*" >&2; }
yellow() { printf "\033[33m%s\033[0m\n" "$*"; }
bold()   { printf "\033[1m%s\033[0m\n" "$*"; }
step()   { printf "\n\033[1;34m▶ %s\033[0m\n" "$*"; }

# ── preflight: 1. MiniMax Code installed & logged in ─────────────────
step "1/8  Checking MiniMax Code is installed and logged in"
if [ ! -d "$LEVELDB_DIR" ]; then
  red "   ✗ MiniMax Code is not installed."
  red "     Download it from https://agent.minimax.io and log in once."
  red "     Then re-run this script."
  exit 1
fi

# Extract the latest JWT to confirm at least one valid session exists.
LATEST_TOKEN=""
LATEST_EXP=0
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
    if [ "$exp" -gt "$LATEST_EXP" ]; then
      LATEST_EXP=$exp
      LATEST_TOKEN="$token"
    fi
  done < <(strings "$f" 2>/dev/null | grep -oE "eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+" || true)
done

if [ -z "$LATEST_TOKEN" ]; then
  red "   ✗ No active session found in MiniMax Code."
  red "     Open MiniMax Code, sign in, send one message, then re-run."
  exit 1
fi
exp_iso=$(date -u -r "$LATEST_EXP" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "unknown")
green "   ✓ session JWT found (expires $exp_iso)"

# ── preflight: 2. headroom-ai installed ───────────────────────────────
step "2/8  Checking headroom-ai (this fork) is installed"
if [ ! -x "$HEADROOM_BIN" ]; then
  yellow "   ⚠ headroom-ai not found at $HEADROOM_BIN."
  yellow "     Install with: uv tool install -e $HOME/headroom"
  yellow "     (clone the repo first: git clone https://github.com/axelfleureau/headroom.git ~/headroom)"
  exit 1
fi
if [ ! -d "$HEADROOM_PYTHON_DIR" ]; then
  red "   ✗ headroom-ai python package not found at $HEADROOM_PYTHON_DIR"
  exit 1
fi
green "   ✓ headroom-ai installed at $HEADROOM_BIN"

# ── 3. patch the installed headroom package with the auth shim ───────
step "3/8  Patching headroom with MiniMax auth shim"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# The patch dir sits next to the source tree (the headroom fork). When this
# script is in /Users/axel/.headroom/deploy/default/ it has no sibling
# patches/ dir — fall back to the canonical location inside the headroom repo.
if [ -d "$SCRIPT_DIR/patches" ]; then
  PATCH_DIR="$SCRIPT_DIR/patches"
elif [ -d "$HOME/headroom/scripts/minimax-patches" ]; then
  PATCH_DIR="$HOME/headroom/scripts/minimax-patches"
elif [ -d "/opt/headroom/scripts/minimax-patches" ]; then
  PATCH_DIR="/opt/headroom/scripts/minimax-patches"
else
  PATCH_DIR=""
fi
if [ -z "$PATCH_DIR" ] || [ ! -d "$PATCH_DIR" ]; then
  red "   ✗ patches directory not found"
  red "     expected at: $SCRIPT_DIR/patches"
  red "                : $HOME/headroom/scripts/minimax-patches"
  red "     make sure this fork is cloned: git clone https://github.com/axelfleureau/headroom.git ~/headroom"
  exit 1
fi

# Apply each .py patch with a backup-and-skip-if-already-applied strategy.
for src in "$PATCH_DIR"/*.py; do
  [ -f "$src" ] || continue
  fname=$(basename "$src")
  dest="$HEADROOM_PYTHON_DIR/proxy/$fname"
  if [ ! -f "$dest" ]; then
    red "   ✗ expected $dest but it does not exist"
    exit 1
  fi
  # Detect whether the patch is already applied by looking for a marker string.
  marker="MINIMAX_SESSION_TOKEN"
  if grep -q "$marker" "$dest" 2>/dev/null; then
    green "   ✓ $fname already patched"
    continue
  fi
  # Back up the original once, then apply.
  bak="$dest.orig.$(date +%Y%m%d%H%M%S)"
  cp "$dest" "$bak"
  if cp "$src" "$dest"; then
    green "   ✓ $fname patched (backup: $(basename "$bak"))"
  else
    red "   ✗ failed to patch $fname"
    exit 1
  fi
done

# Patch auth_mode.py separately (different subfolder).
if [ -f "$PATCH_DIR/auth_mode.py" ]; then
  dest="$HEADROOM_PYTHON_DIR/proxy/auth_mode.py"
  marker="minimax-code"
  if grep -q "$marker" "$dest" 2>/dev/null; then
    green "   ✓ auth_mode.py already patched"
  else
    bak="$dest.orig.$(date +%Y%m%d%H%M%S)"
    cp "$dest" "$bak"
    if cp "$PATCH_DIR/auth_mode.py" "$dest"; then
      green "   ✓ auth_mode.py patched (backup: $(basename "$bak"))"
    else
      red "   ✗ failed to patch auth_mode.py"
      exit 1
    fi
  fi
fi

# ── 4. write run-headroom.sh ─────────────────────────────────────────
step "4/8  Writing $REPO_DIR/run-headroom.sh"
cat > "$REPO_DIR/run-headroom.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
export HEADROOM_OUTPUT_SHAPER=1
export HEADROOM_VERBOSITY_LEVEL=1
export HEADROOM_EFFORT_ROUTER=1
export HEADROOM_TELEMETRY=off
# Route Anthropic-format requests to the Mavis Code gateway.
export ANTHROPIC_TARGET_API_URL="https://agent.minimax.io/mavis/api/v1/llm/v1"
# Auth: per-session JWT from the macOS keychain (auto-refreshed by
# com.headroom.minimax-token-refresher every 6h).
export MINIMAX_SESSION_TOKEN="$(security find-generic-password -s "minimax-session-token" -w 2>/dev/null || true)"
if [ -z "${MINIMAX_SESSION_TOKEN:-}" ]; then
  echo "[run-headroom] WARN: minimax-session-token not in keychain — headroom will return 401" >&2
fi
exec /Users/axel/.local/bin/headroom install agent run --profile default
EOF
chmod +x "$REPO_DIR/run-headroom.sh"
green "   ✓ written"

# ── 5. write launchd plist + bootstrap ───────────────────────────────
step "5/8  Writing $LAUNCH_AGENTS_DIR/$SERVICE_LABEL.plist"
cat > "$LAUNCH_AGENTS_DIR/$SERVICE_LABEL.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$SERVICE_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$REPO_DIR/run-headroom.sh</string>
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
    <string>https://agent.minimax.io/mavis/api/v1/llm/v1</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
</dict>
</plist>
EOF
green "   ✓ plist written"

# Copy the token-refresher script if not already there.
if [ -f "$SCRIPT_DIR/minimax-headroom-token-refresher.sh" ]; then
  cp "$SCRIPT_DIR/minimax-headroom-token-refresher.sh" "$REPO_DIR/minimax-headroom-token-refresher.sh"
  chmod +x "$REPO_DIR/minimax-headroom-token-refresher.sh"
fi

# Bootstrap the launchd services.
if launchctl print "gui/$(id -u)/$SERVICE_LABEL" >/dev/null 2>&1; then
  yellow "   • $SERVICE_LABEL already loaded — reloading"
  launchctl bootout "gui/$(id -u)/$SERVICE_LABEL" 2>/dev/null || true
  sleep 1
fi
if launchctl bootstrap "gui/$(id -u)" "$LAUNCH_AGENTS_DIR/$SERVICE_LABEL.plist" 2>&1 | grep -q "failed"; then
  yellow "   ⚠ bootstrap $SERVICE_LABEL reported an error (often benign if already loaded)"
else
  green "   ✓ $SERVICE_LABEL bootstrapped"
fi

# ── 6. write token-refresher plist + bootstrap ────────────────────────
step "6/8  Writing token refresher LaunchAgent"
cat > "$LAUNCH_AGENTS_DIR/$REFRESHER_LABEL.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$REFRESHER_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$REPO_DIR/minimax-headroom-token-refresher.sh</string>
  </array>
  <key>StartInterval</key>
  <integer>$REFRESHER_INTERVAL_SECONDS</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$LOGS_DIR/token-refresher.log</string>
  <key>StandardErrorPath</key>
  <string>$LOGS_DIR/token-refresher.log</string>
  <key>ExitTimeOut</key>
  <integer>30</integer>
</dict>
</plist>
EOF
green "   ✓ $REFRESHER_LABEL.plist written"

if launchctl print "gui/$(id -u)/$REFRESHER_LABEL" >/dev/null 2>&1; then
  launchctl bootout "gui/$(id -u)/$REFRESHER_LABEL" 2>/dev/null || true
  sleep 1
fi
if launchctl bootstrap "gui/$(id -u)" "$LAUNCH_AGENTS_DIR/$REFRESHER_LABEL.plist" 2>&1 | grep -q "failed"; then
  yellow "   ⚠ bootstrap $REFRESHER_LABEL reported an error"
else
  green "   ✓ $REFRESHER_LABEL bootstrapped (runs every ${REFRESHER_INTERVAL_SECONDS}s)"
fi

# ── 7. refresh the Mavis Code session JWT into the keychain ──────────
step "7/8  Writing session JWT to keychain"
if security delete-generic-password -s "$KEYCHAIN_SERVICE" >/dev/null 2>&1; then :; fi
if ! security add-generic-password -s "$KEYCHAIN_SERVICE" -a "$USER" -w "$LATEST_TOKEN" -U >/dev/null 2>&1; then
  red "   ✗ failed to write JWT to keychain"
  exit 1
fi
green "   ✓ token written (expires $exp_iso)"

# ── 8. smoke test ─────────────────────────────────────────────────────
step "8/8  Smoke test (waits up to 30s for the proxy to come up)"
for i in $(seq 1 30); do
  if curl -sS --max-time 2 "http://127.0.0.1:$PROXY_PORT/health" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

HEALTH=$(curl -sS --max-time 5 "http://127.0.0.1:$PROXY_PORT/health" 2>/dev/null || echo "")
if [ -z "$HEALTH" ]; then
  red "   ✗ headroom proxy did not respond on :$PROXY_PORT within 30s"
  red "     check: tail -f $LOGS_DIR/proxy.log"
  exit 1
fi
green "   ✓ headroom proxy up"

# Send a real M3 request to verify the auth shim works.
RESP=$(curl -sS --max-time 30 -X POST "http://127.0.0.1:$PROXY_PORT/v1/messages" \
  -H "Content-Type: application/json" \
  -H "x-api-key: dummy" \
  -H "anthropic-version: 2023-06-01" \
  -H "User-Agent: MiniMax Code/installer-check" \
  -d '{"model":"MiniMax-M3","max_tokens":20,"messages":[{"role":"user","content":"Rispondi solo: OK_MINIMAX"}]}' \
  2>&1)
if echo "$RESP" | grep -q '"MiniMax-M3"' && echo "$RESP" | grep -q 'OK_MINIMAX'; then
  green "   ✓ MiniMax-M3 responded correctly through the proxy"
else
  red "   ✗ MiniMax M3 request failed: $RESP"
  exit 1
fi

# ── done ──────────────────────────────────────────────────────────────
echo ""
bold "✓ Headroom × MiniMax is installed and working."
echo ""
echo "  Dashboard:        http://127.0.0.1:$PROXY_PORT/dashboard"
echo "  Health:           http://127.0.0.1:$PROXY_PORT/health"
echo "  Token refresher:  every 6h via launchd (auto-reboot on token change)"
echo "  Logs:             $LOGS_DIR/proxy.log"
echo ""
echo "Point any Anthropic-compat client at http://127.0.0.1:$PROXY_PORT, e.g.:"
echo ""
echo "  ANTHROPIC_BASE_URL=http://127.0.0.1:$PROXY_PORT ANTHROPIC_MODEL=MiniMax-M3 claude"
echo ""
echo "Re-run this script any time — it is idempotent."
