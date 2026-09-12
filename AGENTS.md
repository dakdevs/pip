# Pip

Native Swift macOS 26 menu bar application. Read `docs/implementation.md` for the accepted interaction contract and current implementation status. Do not replace native Liquid Glass with a web UI.

Build and launch with `./script/build_and_run.sh --verify`; run `swift test` for protocol and state tests. Swift source lives in `Sources/Pip`. Never print authentication tokens or copy Codex credentials into this repository. Codex owns its authentication and agent tools; Pip owns presentation and request handling.

Maintain `docs/implementation.md` when a subsystem changes or an integration assumption is disproved. Do not mark an OS permission or live model integration verified based only on compilation. Background turns must never be canceled by hiding a window or starting a new conversation.
