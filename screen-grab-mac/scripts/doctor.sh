#!/usr/bin/env bash
# screen-grab doctor — preflight check.
#
# Prints which minimum preconditions for running screen-grab on this machine
# are satisfied and which still need fixing. Designed for the "I cloned this,
# built, and nothing happens when I press Right Cmd" case — covers the
# bring-up paths we've actually tripped over, nothing more.
#
# Run from anywhere; the script resolves its own location.

set -u

PASS=0
FAIL=0

ok()   { printf '  [ok]   %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf '  [FAIL] %s\n' "$*"; FAIL=$((FAIL + 1)); }
hint() { printf '         %s\n' "$*"; }

echo "screen-grab doctor"
echo

# (1) ANTHROPIC_API_KEY visible to launchd. The .app is launched via
# `open`, which inherits launchd's environment — NOT the calling shell's.
# If the brain spawns without this, generation hangs / errors at runtime.
key_chars=$(launchctl getenv ANTHROPIC_API_KEY 2>/dev/null | tr -d '\n' | wc -c | tr -d ' ')
if [ "$key_chars" -gt 0 ]; then
  ok "ANTHROPIC_API_KEY in launchd env (${key_chars} chars)"
else
  fail "ANTHROPIC_API_KEY missing from launchd env"
  hint "Fix: ./scripts/load-env.sh   (sources .env.local and forwards to launchctl setenv)"
fi

# (2) PATH visible to launchd. Without this, the brain subprocess can't
# resolve `node` and crashes immediately on spawn.
path_val=$(launchctl getenv PATH 2>/dev/null)
if [ -n "$path_val" ]; then
  ok "PATH in launchd env"
else
  fail "PATH missing from launchd env (brain subprocess won't find node)"
  hint "Fix: ./scripts/load-env.sh"
fi

# (3) node ≥ 18 (brain runtime uses tsx + ES module imports that need 18+).
if command -v node >/dev/null 2>&1; then
  node_ver=$(node --version 2>/dev/null | sed 's/^v//')
  node_major=${node_ver%%.*}
  if [ "$node_major" -ge 18 ] 2>/dev/null; then
    ok "node v${node_ver} (≥18 required)"
  else
    fail "node v${node_ver} is below 18"
    hint "Install a newer node (nvm, brew, etc.); the brain won't start otherwise"
  fi
else
  fail "node not on PATH"
  hint "Install node ≥18"
fi

# (4) Daemon config file exists and parses. The daemon refuses to launch
# without it (applicationDidFinishLaunching catches and calls terminate).
cfg="$HOME/.config/screen-grab/config.json"
cfg_ok=0
if [ -f "$cfg" ]; then
  if python3 -c "import json,sys; json.load(open('$cfg'))" 2>/dev/null; then
    ok "${cfg} parses as JSON"
    cfg_ok=1
  else
    fail "${cfg} exists but isn't valid JSON"
    hint "Edit it; the daemon will refuse to start otherwise"
  fi
else
  fail "${cfg} missing"
  hint "Minimum contents: {\"hotkey\": \"RightCommand\"}"
fi

# (5) Brain bin (path read from config when possible). Daemon spawns this
# at startup; if it's missing or non-executable the brain never comes up.
default_bin="$HOME/Documents/GitHub/screen-grab/screen-grab-brain/bin/screen-grab-brain-ipc"
brain_bin=$default_bin
if [ "$cfg_ok" -eq 1 ]; then
  cfg_bin=$(python3 -c "import json; print(json.load(open('$cfg')).get('brainBinPath', ''))" 2>/dev/null || true)
  [ -n "$cfg_bin" ] && brain_bin="$cfg_bin"
fi
if [ -x "$brain_bin" ]; then
  ok "brain bin exists & executable: ${brain_bin}"
else
  fail "brain bin not found / not executable: ${brain_bin}"
  hint "Check brainBinPath in $cfg, or: chmod +x \"${brain_bin}\""
fi

# (6) Brain dependencies installed. Without node_modules, the brain spawns
# but crashes with "Cannot find package 'tsx'" or similar a beat later.
brain_dir=$(dirname "$(dirname "$brain_bin")")
if [ -d "$brain_dir/node_modules" ]; then
  ok "screen-grab-brain/node_modules present"
else
  fail "screen-grab-brain/node_modules missing"
  hint "Fix: (cd ${brain_dir} && npm install)"
fi

# (7) Built .app at the expected location. The doctor doesn't build for you
# — it just flags that there's nothing to launch yet.
script_dir=$(cd "$(dirname "$0")" && pwd)
app_path="$(cd "$script_dir/.." && pwd)/build/screen-grab.app"
if [ -d "$app_path" ]; then
  ok ".app present at ${app_path}"
else
  fail ".app missing at ${app_path}"
  hint "Fix: ./scripts/build-app.sh release"
fi

# Permissions can't be queried from a shell for an arbitrary binary — TCC
# doesn't expose a stable API for that and tccutil only resets. The .app
# already self-checks on launch and logs the result, so direct the user there.
echo
echo "macOS permissions (not queryable from a script; check after launch):"
echo "  1. open -n ${app_path}"
echo "  2. log stream --process screen-grab-mac --style compact | grep '\\[perm\\]'"
echo "     → expect: accessibility=granted inputMonitoring=granted"
echo "  3. If either is DENIED:"
echo "     - tccutil reset Accessibility com.nkim.screen-grab"
echo "     - tccutil reset ListenEvent com.nkim.screen-grab"
echo "     - System Settings → Privacy & Security → Accessibility AND Input"
echo "       Monitoring → + add the .app and toggle on"
echo "  Note: TCC drops grants on every rebuild because the .app is ad-hoc"
echo "  signed (CDHash changes; bundle-ID tracking only works with a real"
echo "  signing identity). Re-grant after each ./scripts/build-app.sh run."

# Microphone
echo
echo "== Microphone TCC =="
if [[ -e /usr/bin/sqlite3 && -r ~/Library/Application\ Support/com.apple.TCC/TCC.db ]]; then
    mic_status=$(sqlite3 ~/Library/Application\ Support/com.apple.TCC/TCC.db \
        "SELECT auth_value FROM access WHERE service='kTCCServiceMicrophone' AND client='com.nkim.screen-grab';" 2>/dev/null)
    case "$mic_status" in
        2) echo "OK   microphone granted (auth_value=2)" ;;
        0) echo "FAIL microphone DENIED — System Settings → Privacy & Security → Microphone, enable screen-grab" ;;
        "") echo "WARN microphone not yet prompted (run the app once and press Right Cmd)" ;;
        *) echo "WARN microphone TCC value=$mic_status (unexpected — check manually)" ;;
    esac
else
    echo "WARN cannot read TCC.db; check System Settings → Privacy & Security → Microphone manually"
fi

# Speech Recognition
echo
echo "== Speech Recognition TCC =="
if [[ -e /usr/bin/sqlite3 && -r ~/Library/Application\ Support/com.apple.TCC/TCC.db ]]; then
    speech_status=$(sqlite3 ~/Library/Application\ Support/com.apple.TCC/TCC.db \
        "SELECT auth_value FROM access WHERE service='kTCCServiceSpeechRecognition' AND client='com.nkim.screen-grab';" 2>/dev/null)
    case "$speech_status" in
        2) echo "OK   speech recognition granted (auth_value=2)" ;;
        0) echo "FAIL speech recognition DENIED — System Settings → Privacy & Security → Speech Recognition, enable screen-grab" ;;
        "") echo "WARN speech recognition not yet prompted (run the app once and press Right Cmd)" ;;
        *) echo "WARN speech recognition TCC value=$speech_status (unexpected — check manually)" ;;
    esac
else
    echo "WARN cannot read TCC.db; check System Settings → Privacy & Security → Speech Recognition manually"
fi

echo
total=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
  echo "${PASS} of ${total} preflight checks passed. Verify permissions per above, then launch."
  exit 0
else
  echo "${FAIL} of ${total} preflight checks FAILED — fix the items above before launching."
  exit 1
fi
