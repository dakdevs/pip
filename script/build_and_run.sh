#!/usr/bin/env bash
set -euo pipefail
MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
APP_BUNDLE="$ROOT_DIR/dist/Pip.app"
STAGING_BUNDLE="$(mktemp -d "$ROOT_DIR/dist-stage.XXXXXX")/Pip.app"
APP_CONTENTS="$STAGING_BUNDLE/Contents"
trap 'rm -rf "${STAGING_BUNDLE%/Pip.app}"' EXIT
swift build
BUILD_DIR="$(swift build --show-bin-path)"
mkdir -p "$APP_CONTENTS/MacOS" "$APP_CONTENTS/Resources"
cp "$BUILD_DIR/Pip" "$APP_CONTENTS/MacOS/Pip"
for resource in "$BUILD_DIR"/*.bundle; do
  if [ -d "$resource" ]; then
    cp -R "$resource" "$APP_CONTENTS/Resources/"
  fi
done
cat > "$APP_CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Pip</string>
<key>CFBundleIdentifier</key><string>com.pip.mac</string>
<key>CFBundleName</key><string>Pip</string>
<key>CFBundleDisplayName</key><string>Pip</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>LSUIElement</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSMicrophoneUsageDescription</key><string>Pip uses your microphone while you hold the dictation shortcut.</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --deep --sign - --identifier com.pip.mac "$STAGING_BUNDLE"
codesign --verify --deep --strict "$STAGING_BUNDLE"
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
