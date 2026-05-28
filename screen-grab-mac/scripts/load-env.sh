#!/usr/bin/env bash
# Forward env vars into launchd so the .app — when launched via Finder /
# Dock / `open` — inherits them. Run once per login session.
#
# - PATH is taken from the current interactive shell so the daemon can find
#   `node` (which lives under your Homebrew/asdf/etc. install).
# - ANTHROPIC_API_KEY is read from <repo-root>/.env.local. That file in turn
#   sources another .env (e.g. census-chat/.env) so the key has one home.
#
# Usage: ./scripts/load-env.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# 1. PATH from the current shell. Brain bin script uses /usr/bin/env node
#    via the shebang, which needs node on launchd's PATH.
launchctl setenv PATH "$PATH"
echo "[load-env.sh] launchctl setenv PATH (len=${#PATH})"

# 2. ANTHROPIC_API_KEY (and anything else exported by .env.local) → launchd.
if [[ ! -f "${REPO_ROOT}/.env.local" ]]; then
    echo "[load-env.sh] warning: ${REPO_ROOT}/.env.local not found — skipping API key" >&2
    exit 0
fi

set -a
# shellcheck disable=SC1091
source "${REPO_ROOT}/.env.local"
set +a

if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    launchctl setenv ANTHROPIC_API_KEY "$ANTHROPIC_API_KEY"
    echo "[load-env.sh] launchctl setenv ANTHROPIC_API_KEY (len=${#ANTHROPIC_API_KEY})"
else
    echo "[load-env.sh] warning: ANTHROPIC_API_KEY not set after sourcing .env.local" >&2
fi

echo "[load-env.sh] done. Re-run after logout / reboot."
