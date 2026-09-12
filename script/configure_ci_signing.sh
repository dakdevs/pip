#!/usr/bin/env bash
# Optional Developer ID signing. No Apple credentials means a documented preview.
set -euo pipefail
: "${RUNNER_TEMP:?This helper runs in GitHub Actions}" "${GITHUB_ENV:?}"
if [ -z "${APPLE_DEVELOPER_ID_P12:-}" ]; then
  echo 'PIP_SIGNING_IDENTITY=-' >> "$GITHUB_ENV"
  echo 'PIP_NOTARIZE=false' >> "$GITHUB_ENV"
  exit 0
fi
: "${APPLE_DEVELOPER_ID_PASSWORD:?Set the P12 password}"
umask 077
CERTIFICATE="$RUNNER_TEMP/pip-developer-id.p12"
KEYCHAIN="$RUNNER_TEMP/pip-signing.keychain-db"
KEYCHAIN_PASSWORD="$(openssl rand -hex 24)"
trap 'rm -f "$CERTIFICATE"' EXIT
python3 -c 'import base64,os,pathlib; pathlib.Path(os.environ["RUNNER_TEMP"],"pip-developer-id.p12").write_bytes(base64.b64decode(os.environ["APPLE_DEVELOPER_ID_P12"],validate=True))'
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$CERTIFICATE" -P "$APPLE_DEVELOPER_ID_PASSWORD" -A -t cert -f pkcs12 -k "$KEYCHAIN"
security set-key-partition-list -S apple-tool:,apple: -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
security list-keychains -d user -s "$KEYCHAIN"
IDENTITY="$(security find-identity -v -p codesigning "$KEYCHAIN" | sed -nE '/Developer ID Application/s/.* ([A-F0-9]{40}) .*/\1/p' | head -1)"
if [ -z "$IDENTITY" ]; then echo 'No valid Developer ID Application identity found' >&2; exit 1; fi
echo "PIP_SIGNING_IDENTITY=$IDENTITY" >> "$GITHUB_ENV"
echo 'PIP_NOTARIZE=true' >> "$GITHUB_ENV"
