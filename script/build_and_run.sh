#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
case "$MODE" in
  run|--verify|--debug|--logs|--telemetry) ;;
  *) echo "Usage: $0 [--verify|--debug|--logs|--telemetry]" >&2; exit 2 ;;
esac
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$ROOT_DIR/build/dd/Build/Products/Debug/UpdateBar.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/UpdateBar"
cd "$ROOT_DIR"

# Quit UpdateBar first. Do not use this script while installing an app/tool.
pkill -x UpdateBar >/dev/null 2>&1 || true
xcodebuild -project UpdateBar.xcodeproj -scheme UpdateBar -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build/dd \
  CODE_SIGNING_ALLOWED=NO build

case "$MODE" in
  --debug) exec lldb -- "$APP_BINARY" ;;
  *) /usr/bin/open -n "$APP_BUNDLE" ;;
esac
case "$MODE" in
  --verify)
    sleep 1
    pgrep -f "^${APP_BINARY}$" >/dev/null
    echo "Running: $APP_BUNDLE"
    ;;
  --logs) exec /usr/bin/log stream --info --style compact --predicate 'process == "UpdateBar"' ;;
  --telemetry) exec /usr/bin/log stream --info --style compact --predicate 'subsystem == "com.erole.UpdateBar"' ;;
esac
