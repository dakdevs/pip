#!/usr/bin/env bash
# Package without touching a running Pip process. Used by local builds and CI.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
APP_BUNDLE="${1:?usage: package_app.sh /output/Pip.app}"
BUILD_CONFIGURATION="${PIP_BUILD_CONFIGURATION:-debug}"
SIGNING_IDENTITY="${PIP_SIGNING_IDENTITY:--}"
case "$BUILD_CONFIGURATION" in debug|release) ;; *) echo "Invalid build configuration" >&2; exit 1 ;; esac
if [ -e "$APP_BUNDLE" ]; then echo "Output already exists: $APP_BUNDLE" >&2; exit 1; fi
swift build -c "$BUILD_CONFIGURATION" --arch arm64
BUILD_DIR="$(swift build -c "$BUILD_CONFIGURATION" --arch arm64 --show-bin-path)"
APP_CONTENTS="$APP_BUNDLE/Contents"
mkdir -p "$APP_CONTENTS/MacOS" "$APP_CONTENTS/Resources" "$APP_CONTENTS/Frameworks"
cp "$BUILD_DIR/Pip" "$APP_CONTENTS/MacOS/Pip"
for resource in "$BUILD_DIR"/*.bundle; do
  if [ -d "$resource" ]; then ditto "$resource" "$APP_CONTENTS/Resources/$(basename "$resource")"; fi
done
FRAMEWORK_SOURCE="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
ditto "$FRAMEWORK_SOURCE" "$APP_CONTENTS/Frameworks/Sparkle.framework"
mkdir -p "$APP_CONTENTS/Resources/ThirdPartyLicenses"
cp "$ROOT_DIR/.build/artifacts/sparkle/Sparkle/LICENSE" "$APP_CONTENTS/Resources/ThirdPartyLicenses/Sparkle.txt"
cp "$ROOT_DIR/.build/checkouts/FluidAudio/LICENSE" "$APP_CONTENTS/Resources/ThirdPartyLicenses/FluidAudio.txt"
python3 "$ROOT_DIR/script/write_bundle_info.py" "$APP_CONTENTS/Info.plist"

# Sign nested code from the inside out. Production signing enables hardened runtime.
SIGN_OPTIONS=(--force --sign "$SIGNING_IDENTITY")
if [ "$SIGNING_IDENTITY" != "-" ]; then SIGN_OPTIONS+=(--options runtime --timestamp); fi
FRAMEWORK="$APP_CONTENTS/Frameworks/Sparkle.framework/Versions/B"
for helper in "$FRAMEWORK"/XPCServices/*.xpc "$FRAMEWORK"/Updater.app "$FRAMEWORK"/Autoupdate; do
  if [ -e "$helper" ]; then codesign "${SIGN_OPTIONS[@]}" --preserve-metadata=entitlements "$helper"; fi
done
codesign "${SIGN_OPTIONS[@]}" "$APP_CONTENTS/Frameworks/Sparkle.framework"
codesign "${SIGN_OPTIONS[@]}" --identifier com.pip.mac --entitlements "$ROOT_DIR/config/Pip.entitlements" "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"
