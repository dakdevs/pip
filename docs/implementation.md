# Pip implementation plan

## Purpose and accepted design

Build an ambient native Swift assistant for this Mac (Apple Silicon, macOS 26.5.2), with later distribution in mind. No Dock icon. Codex subscription sign-in supplies the selectable main model and its agent capabilities. Pip is the UI harness, not a replacement tool router.

Tap Command-Space to open/restore a centered immediately editable panel, or collapse it when already open; hold it to dictate. Right Option also dictates while input is focused. Release finalizes and submits by default, configurable. Escape during recording cancels recording and keeps preexisting text. Escape while running minimizes; after completion ends the active conversation while preserving history. Escape is local to the focused panel. Clicking outside minimizes at any stage. The minimized active thread occupies a bottom-right Liquid Glass surface, expanding for completed responses or questions without stealing focus.

Command-N makes a new active conversation; prior work continues in the menu bar list. A second prompt during a run steers that turn. Up from an empty input opens recent history; arrows preview and Enter resumes. The centered panel displays scrollable history and a fixed composer. Background completion marks unread; background requests mark needs-attention. Selecting a background thread promotes it.

Global persistent settings: main model, reasoning, Fast mode, shortcuts, voice behavior. Command-left/right changes supported reasoning levels; Command-F toggles Fast mode while composing. Optional first-turn completion classifier defaults enabled; use the selected available classifier model (currently Luna with low reasoning and Fast support) to dismiss only successful action completions without useful output. Uncertain outcomes, answers, errors, pending requests, and any conversation with a second user message remain visible. Dismissed conversations remain recoverable.

Guided setup covers Codex installation/sign-in, model choices, global hotkey conflicts, microphone, local dictation model, and computer-use readiness. Date-versioned GitHub releases and signed Sparkle updates are supported; Apple notarization is optional until distribution credentials are configured.

## Implementation sequence

1. Native SwiftPM executable staged as `dist/Pip.app`; establish AppKit nonactivating panel, SwiftUI glass, menu bar, Settings/onboarding, hotkey handling, state persistence. Main agent owns these.
2. `CodexClient.swift` implements request/notification/server-request transport over `codex app-server` standard input/output. Dedicated worker owns transport. Runtime receives real model inventory, account state, thread lifecycle, streamed items, approvals and questions. Tools remain available through Codex configuration.
3. `Dictation.swift` implements microphone capture and on-device Parakeet if Codex's voice API cannot provide reliable standalone dictation. Worker investigates and implements; model installation occurs through setup, not covertly on app launch.
4. Verify real Codex metadata and a benign model turn, state-machine tests, compiler/build, .app launch and UI. TCC prompts require the user; never fabricate granted access. Review failure, cancellation, multiple threads, and keyboard behavior.

## Boundaries and recovery

Pip keeps conversation metadata, drafts, and a transcript cache under Application Support/Pip, plus UserDefaults settings. Codex owns the canonical transcript and credentials; resumed history refreshes from Codex. Pip never copies auth tokens. On process exit, pending RPCs fail; interrupted turns recover as stopped/retryable, never successful. On app quit warn about active turns before stopping owned subprocess. Do not alter global Codex config or macOS shortcuts without explicit user action. Build script replaces only this project's `dist/Pip.app` and stops only Pip.

## Acceptance

`swift test` exercises state/approval/protocol behavior. `./script/build_and_run.sh --verify` builds and starts an LSUIElement application. The app exposes setup and reachable menu controls, lists models/account from real Codex, submits/streams/resumes/steers independent threads, handles backend questions, changes app-wide settings, and presents native glass surfaces. Actual microphone and computer-use actions require granted permissions and must be distinguished from wiring checks. Inspect UI with available native automation.

## Progress

- [x] 2026-09-11: User confirmed product design; empty workspace inspected; Git initialized; Swift 6.3.3 and macOS26 SDK available.
- [x] Generated local Codex 0.154 protocol schema for implementation research.
- [x] Native application and UI, with direct model/reasoning menus and Hugeicons SVGs; `ai-chat-01` is the persistent menu bar icon.
- [x] Codex transport, subscription model inventory, streamed turns, approvals, and first-turn classifier.
- [x] Local Parakeet v3 dictation and guided setup with measured download progress.
- [x] Unit/protocol/state checks, real full AppStore submission, classifier turns, native app launch, SVG appearance, and cached dictation readiness.
- [ ] Hardware microphone capture and full computer-use permission flow require a live check; native menu automation timed out and is not claimed visually verified.

## Discoveries and decisions

- Codex app-server protocol exists locally; native runtime is a separate binary. Application/UI code remains Swift.
- SwiftPM is appropriate for this empty local app; package app resources explicitly into .app.
- Realtime audio methods are experimental and not evidence of pure dictation access. Investigate before claiming support.
- Codex 0.154.0 is the verified backend. Experimental realtime audio does not provide a verified dictation contract, so Pip uses FluidAudio 0.15.7 and local Parakeet v3.
- The first-turn classifier runs in a separate ephemeral process with configured tools/plugins disabled and conservative structured output; failures keep the response visible.
- Model installation exposes actual FluidAudio progress, then preparation/loading, then ready. Cached models load at launch without another download.

## Release and updater boundary

`AppUpdater.swift` owns Sparkle lifecycle, Settings bindings, and idle installation deferral. `script/package_app.sh` is shared by local and CI packaging; `build_release.sh` generates signed archives and feeds. Date allocation and publication live in `.github/workflows/release.yml`. Development bundles opt out of updates. Private update keys remain in Keychain/GitHub Secrets, with only the public key checked in. See `docs/releases.md` for bootstrap, versions, signing prerequisites, and verification limits.

## Outcomes

The native app builds and launches with no Dock icon. Unit/protocol/state checks pass. A real prompt passed through AppStore and streamed its expected response. Real subscription classification turns pass, and Parakeet v3 successfully transcribed a public 21.4-second audio fixture. Model download, Core ML compilation, and cached reload have been exercised. Microphone input and every configured computer-use plugin are not claimed end-to-end verified.
