#!/usr/bin/env bash
# One-time maintainer setup: retain the private key in Keychain and GitHub Secrets.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
swift package resolve
SPARKLE_BIN="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/bin"
ACCOUNT=pip-dakdevs
umask 077
KEY_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/pip-update-key.XXXXXX")"
trap 'rm -rf "$KEY_DIRECTORY"' EXIT
"$SPARKLE_BIN/generate_keys" --account "$ACCOUNT"
"$SPARKLE_BIN/generate_keys" --account "$ACCOUNT" -p > "$KEY_DIRECTORY/public-key.txt"
if [ -f config/sparkle-public-key.txt ]; then
  cmp config/sparkle-public-key.txt "$KEY_DIRECTORY/public-key.txt" || {
    echo 'Public key differs. Do not rotate an existing update key accidentally.' >&2; exit 1;
  }
else
  mkdir -p config
  cp "$KEY_DIRECTORY/public-key.txt" config/sparkle-public-key.txt
fi
"$SPARKLE_BIN/generate_keys" --account "$ACCOUNT" -x "$KEY_DIRECTORY/private-key"
gh secret set SPARKLE_PRIVATE_KEY --repo dakdevs/pip < "$KEY_DIRECTORY/private-key"
echo 'Update signing configured. Private key retained in the pip-dakdevs Keychain account and GitHub Actions secret.'
