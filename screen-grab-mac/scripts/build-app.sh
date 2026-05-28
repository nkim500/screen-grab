#!/usr/bin/env bash
# SwiftPM build → wrap binary in screen-grab.app bundle.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG="${1:-debug}"

cd "${PKG_DIR}"
swift build -c "${CONFIG}"

BIN_PATH="$(swift build -c "${CONFIG}" --show-bin-path)/screen-grab-mac"
APP_DIR="${PKG_DIR}/build/screen-grab.app"
APP_MACOS="${APP_DIR}/Contents/MacOS"
APP_RESOURCES="${APP_DIR}/Contents/Resources"

rm -rf "${APP_DIR}"
mkdir -p "${APP_MACOS}" "${APP_RESOURCES}"
cp "${BIN_PATH}" "${APP_MACOS}/screen-grab-mac"
cp "${PKG_DIR}/Resources/Info.plist" "${APP_DIR}/Contents/Info.plist"

# Ad-hoc codesign with the bundle identifier bound. The default linker-signed
# signature has Info.plist=not bound and no designated requirement, which
# Sequoia's TCC can't reliably match — Accessibility / Input Monitoring grants
# silently fail. Re-signing produces a stable identity TCC tracks by bundle ID.
codesign --sign - --force --deep \
    --identifier "com.nkim.screen-grab" \
    "${APP_DIR}"

echo "Built ${APP_DIR}"
echo "Run with: open ${APP_DIR}  # background"
echo "Or:       ${APP_MACOS}/screen-grab-mac  # foreground (logs to terminal)"
