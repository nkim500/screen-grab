#!/usr/bin/env bash
# Build + run in foreground (terminal logs visible). For dev only;
# real usage is `open build/screen-grab.app`.
#
# Usage: ./scripts/run.sh [debug|release]   (default: debug)
#
# If <repo-root>/.env.local exists, all KEY=VALUE pairs in it are exported
# into the daemon's environment before launch. Use this to set
# ANTHROPIC_API_KEY without re-running launchctl setenv every session.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG="${1:-debug}"

if [[ -f "${REPO_ROOT}/.env.local" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "${REPO_ROOT}/.env.local"
    set +a
    echo "[run.sh] sourced ${REPO_ROOT}/.env.local"
fi

"${SCRIPT_DIR}/build-app.sh" "${CONFIG}"
exec "${SCRIPT_DIR}/../build/screen-grab.app/Contents/MacOS/screen-grab-mac"
