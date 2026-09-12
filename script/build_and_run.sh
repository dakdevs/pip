#!/usr/bin/env bash
set -euo pipefail
MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
APP_BUNDLE="$ROOT_DIR/dist/Pip.app"
STAGING_BUNDLE="$(mktemp -d "$ROOT_DIR/dist-stage.XXXXXX")/Pip.app"
APP_CONTENTS="$STAGING_BUNDLE/Contents"
trap 'rm -rf "${STAGING_BUNDLE%/Pip.app}"' EXIT
"$ROOT_DIR/script/package_app.sh" "$STAGING_BUNDLE"
# Only replace a running development build after the new bundle is ready.
for pip_pid in $(pgrep -x Pip || true); do
  pip_command="$(ps -p "$pip_pid" -o comm= || true)"
  if [ "$pip_command" = "$APP_BUNDLE/Contents/MacOS/Pip" ]; then kill "$pip_pid"; fi
done
mkdir -p "$ROOT_DIR/dist"
rm -rf "$APP_BUNDLE"
mv "$STAGING_BUNDLE" "$APP_BUNDLE"
APP_CONTENTS="$APP_BUNDLE/Contents"
case "$MODE" in
  --build) ;;
  run) /usr/bin/open -n "$APP_BUNDLE" ;;
  --verify) /usr/bin/open -n "$APP_BUNDLE" --args --show; sleep 1; pgrep -x Pip >/dev/null; echo "Pip built and launched." ;;
  --debug) lldb -- "$APP_CONTENTS/MacOS/Pip" ;;
  --logs|--telemetry) /usr/bin/open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'process == "Pip"' ;;
  *) echo "usage: $0 [run|--build|--verify|--debug|--logs|--telemetry]" >&2; exit 2 ;;
esac
