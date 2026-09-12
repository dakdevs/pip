#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
export PIP_VERSION="${1:?usage: build_release.sh YYYYMMDD.N output-directory}"
OUTPUT_DIR="${2:?An empty output directory is required}"
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
if [ -n "$(ls -A "$OUTPUT_DIR")" ]; then echo "Release output must be empty" >&2; exit 1; fi
export PIP_BUILD_CONFIGURATION=release PIP_UPDATE_CHANNEL=release
"$ROOT_DIR/script/package_app.sh" "$OUTPUT_DIR/Pip.app"

if [ "${PIP_NOTARIZE:-false}" = true ]; then
  : "${APPLE_ID:?}" "${APPLE_TEAM_ID:?}" "${APPLE_APP_SPECIFIC_PASSWORD:?}"
  if [ "${PIP_SIGNING_IDENTITY:--}" = "-" ]; then echo "Notarization requires Developer ID signing" >&2; exit 1; fi
  ditto -c -k --sequesterRsrc --keepParent "$OUTPUT_DIR/Pip.app" "$OUTPUT_DIR/notarize.zip"
  xcrun notarytool submit "$OUTPUT_DIR/notarize.zip" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" --wait
  xcrun stapler staple "$OUTPUT_DIR/Pip.app"
  xcrun stapler validate "$OUTPUT_DIR/Pip.app"
  spctl --assess --type execute "$OUTPUT_DIR/Pip.app"
  rm "$OUTPUT_DIR/notarize.zip"
fi

ARCHIVE="$OUTPUT_DIR/Pip-$PIP_VERSION-arm64.zip"
ditto -c -k --sequesterRsrc --keepParent "$OUTPUT_DIR/Pip.app" "$ARCHIVE"
SPARKLE_BIN="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/bin"
SIGN_ARGS=(--account pip-dakdevs)
if [ -n "${SPARKLE_PRIVATE_KEY_FILE:-}" ]; then SIGN_ARGS=(--ed-key-file "$SPARKLE_PRIVATE_KEY_FILE"); fi
"$SPARKLE_BIN/generate_appcast" "${SIGN_ARGS[@]}" --download-url-prefix "https://github.com/dakdevs/pip/releases/download/$PIP_VERSION/" "$OUTPUT_DIR"
"$SPARKLE_BIN/sign_update" "${SIGN_ARGS[@]}" --verify "$OUTPUT_DIR/appcast.xml"
python3 "$ROOT_DIR/script/verify_release.py" "$OUTPUT_DIR" "$PIP_VERSION"
ARCHIVE_SIGNATURE="$(python3 -c 'import sys,xml.etree.ElementTree as E; print(E.parse(sys.argv[1]).find("channel/item/enclosure").attrib["{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature"])' "$OUTPUT_DIR/appcast.xml")"
"$SPARKLE_BIN/sign_update" "${SIGN_ARGS[@]}" --verify "$ARCHIVE" "$ARCHIVE_SIGNATURE"
(cd "$OUTPUT_DIR" && shasum -a 256 "Pip-$PIP_VERSION-arm64.zip" appcast.xml > SHA256SUMS)
echo "Release prepared: $PIP_VERSION"
