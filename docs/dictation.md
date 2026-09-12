# Dictation

Pip uses local, on-device speech-to-text for hold-to-talk. The interaction
flow is: hold Command-Space or the configured Right Option key to start,
release to call `DictationService.finish()`, then submit the returned text when
the auto-submit preference is enabled. Escape calls `cancel()` and preserves
text already in the prompt.

## Backend

The concrete fallback is [FluidAudio](https://github.com/FluidInference/FluidAudio),
using its multilingual Parakeet v3 Core ML model. The app target links the `FluidAudio` product:

```swift
.package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.7")
```

This recommendation is pinned to the verified `v0.15.7` release. This source
uses `#if canImport(FluidAudio)` so a build without the dependency reports that
dictation is unavailable instead of silently falling back to a network service.


`prepare()` is an explicit guided-setup action. It asks macOS for microphone
permission and may download/load the model. `start()` never downloads a model.
Audio is captured with `AVAudioEngine`, converted through `AVAudioConverter` to
16 kHz mono Float32, and transcribed from those samples. Short or effectively
silent recordings return an empty string before model inference, which avoids
tap/cancel hallucinations. The transcription text is returned to the caller;
the service does not paste text into another app.

FluidAudio reports measured download fractions, file counts, and Core ML
compilation events. Pip displays those values during setup rather than inventing
a percentage. If the v3 bundle is already cached, `loadCachedModel()` restores
it at launch without a network request or microphone prompt.

On this Mac, the explicit `PIP_TEST_PARAKEET=1` integration test downloaded the
v3 model, transcribed FluidAudio's public 21.4-second speech fixture, and
completed in 61 seconds. It did not open a microphone input.

## Codex realtime status

The installed app-server schema contains experimental `thread/realtime/*`
methods, including audio append and transcript notifications. That schema does
not establish that a subscription-backed session will provide a stable,
standalone dictation service, nor does it specify availability or quota for
this application. Pip therefore does not depend on that experimental transport
for push-to-talk. A future adapter can prefer it only after an authenticated
end-to-end test proves it is reliable for this flow.

Microphone permission is a normal macOS TCC prompt and must be granted by the
person using the app in System Settings; Pip does not attempt to bypass it.
