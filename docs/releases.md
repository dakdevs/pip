# Releases and updates

## Release flow

App, dependency, packaging, or workflow changes pushed to `main` trigger `.github/workflows/release.yml`. Maintainers can also dispatch **Release** from GitHub Actions. Pull requests run `.github/workflows/ci.yml` without publishing or accessing release secrets.

Versions use the UTC build date and a positive daily sequence: `20260912.1`, `20260912.2`, then `20260913.1`. The workflow reads existing tags and releases (including drafts), increments the highest sequence numerically, and refuses to go backward in date. A concurrency group serializes releases. Both bundle version fields, the Git tag, archive name, and Sparkle feed carry the same version.

The workflow tests the code, builds an optimized arm64 app for macOS 26+, signs and verifies the update, uploads all assets to a draft, then publishes it as GitHub's latest release. A failure before publication cannot replace the live update feed. Failed drafts may be removed manually after inspection; published tags and assets should remain immutable.

Each release contains:

- `Pip-YYYYMMDD.N-arm64.zip`: the application, including Sparkle's framework and helpers.
- `appcast.xml`: Sparkle's signed update feed, pointing at that release's exact archive URL.
- `SHA256SUMS`: archive/feed checksums for manual verification.

## App behavior

Release builds check `https://github.com/dakdevs/pip/releases/latest/download/appcast.xml` automatically, normally every four hours. Sparkle verifies the feed and archive against the public Ed25519 key embedded in the app before extraction and installation. The repository only contains the public key.

**Check for Updates…** is available from the menu bar and Settings. Settings also control automatic checks and downloads. Automatic downloads install when the app quits; an explicit update restart waits for Codex work, pending requests, microphone recording/transcription, and model preparation to finish. Conversation drafts and history are persisted before installation. Sparkle handles download failures, installation, and relaunch.

Development builds use version `0.0.0` and disable the updater so a public release cannot overwrite a working development build. To package an update-enabled build locally, use `script/build_release.sh VERSION EMPTY_OUTPUT_DIRECTORY` or set `PIP_VERSION` and `PIP_UPDATE_CHANNEL=release` for the local build script.

## Update signing

The one-time maintainer bootstrap is:

```sh
./script/setup_update_signing.sh
```

It uses Sparkle's official `generate_keys`, stores the private key in the macOS login Keychain under account `pip-dakdevs`, checks it against `config/sparkle-public-key.txt`, and uploads it to the repository's **`SPARKLE_PRIVATE_KEY`** Actions secret. The temporary export is removed. It stops on a public-key mismatch rather than silently replacing the trusted key.

Retain a secure backup of the Keychain signing key. Do not commit private keys, paste them into workflow files, or regenerate the key for an already distributed app. Key rotation requires a deliberate migration.

## Apple signing and notarization

Without Apple signing credentials, releases are explicitly labeled **developer previews**: ad-hoc code-signed and Ed25519 update-signed, but not Apple-notarized. Initial macOS launch may require explicit approval. Ed25519 update signatures do not substitute for Apple's distribution identity.

To enable Developer ID signing and notarization, configure all five repository secrets:

| Secret | Value |
| --- | --- |
| `APPLE_DEVELOPER_ID_P12` | Base64-encoded Developer ID Application certificate and private key export |
| `APPLE_DEVELOPER_ID_PASSWORD` | Password protecting the P12 export |
| `APPLE_ID` | Apple account used for notarization |
| `APPLE_TEAM_ID` | Developer team ID |
| `APPLE_APP_SPECIFIC_PASSWORD` | App-specific password for notarization |

CI imports the identity into an isolated temporary keychain, signs nested code from the inside out with hardened runtime, submits the app to Apple's notary service, staples the ticket, and assesses it before archiving. If a certificate is configured but notarization fails or credentials are incomplete, publication fails; it does not fall back to a preview. The temporary certificate and keychain are cleaned up.

The Apple-signed path cannot be considered verified until those credentials are configured and a real notarized release succeeds.

## Maintainer checks

```sh
python3 -m unittest discover -s script/tests
swift test
script/build_release.sh 20260912.1 release-output/20260912.1
```

Use an unused output directory and the next correct version. `build_release.sh` does not publish or stop a running Pip process. Sparkle's `generate_appcast` and `sign_update --verify` sign/verify the release, and `verify_release.py` checks matching versions, pinned URLs, signatures, sizes, and public-key metadata.

Before claiming the complete update loop verified, run an older release build, check for a newer published release, and verify installation and relaunch. Unit tests establish idle deferral behavior; they do not replace this real installation check.

Sources: [Sparkle setup](https://sparkle-project.org/documentation/), [publishing updates](https://sparkle-project.org/documentation/publishing/), and [GitHub runner reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners).
