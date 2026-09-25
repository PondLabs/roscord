# Noise suppression: audit checklist

The audit that started 2026-09-25: find every bug in client-side noise
suppression, and make the next regression fail a test or CI instead of
reaching users. The symptom: with suppression on, background noise reaches
the other participants as if it were off. A silent failure counts
(processor not attached, settings not reaching it, wasm missing and a
fallback nobody hears about). Where things stand now is in
docs/voice-audio-processing.md; this file is the record of the audit.

Status legend: `[ ]` open, `[x]` done.

## Paths mapped (user setting to the network)

- [x] Native voice room (Linux, Windows): preference → `prepareMicrophoneCaptureOptions` (WebRTC NS off when ours runs) → `CallManager` → `NativeAudioProcessingManager` → `commetSetExternalAudioProcessing` → `CommetExternalAudioProcessingHost` → APM capture post-processing (only while a sender is unmuted: `capture_output_used`) → `commet_dsp_capture_process` → Opus.
- [x] Native legacy 1:1: SDK constraints → `NoiseSuppressedMediaDevices` → same process-global hook.
- [x] Web voice room: preference → `ensureReady` (probe) → `CommetWebTrackProcessor` → `commetAudioDsp.create` → worklet + wasm → `processedTrack` on the sender.
- [x] Web legacy 1:1: SDK constraints → `NoiseSuppressedMediaDevices` → `processMicrophoneStream` → worklet.
- [x] Android: no Rust library, manager unsupported, preference off by default and hidden, WebRTC/hardware NS (`webrtcSuppressorFor` keeps it on; unit tested).
- [x] Settings microphone test (native loopback pair, web graph).
- [x] Vendored packages: 60 + 23 `COMMET` markers, none ever lost (every merge checked); unmarked local changes listed by the vendored-package audit.
- [x] History: 8 past regressions catalogued (below).

## Feedback loops

| Path | Loop | Status |
|------|------|--------|
| DSP core | `cargo test -p audio_dsp` (existing, 40 tests) | [x] |
| Native manager, Dart ↔ Rust | `unit_test/noise_suppression/native_dsp_test.dart` | [x] |
| Room microphone decisions | `unit_test/noise_suppression/microphone_noise_suppression_test.dart` | [x] |
| LiveKit track processor | `unit_test/noise_suppression/livekit_processor_restart_test.dart` | [x] |
| CallManager ↔ DSP | `unit_test/noise_suppression/call_manager_dsp_test.dart` | [x] |
| Legacy calls' capture | `unit_test/noise_suppression/legacy_call_microphone_test.dart` | [x] |
| Web glue + worklet + wasm in Chrome | `tools/voice_dsp/web_noise_loop.mjs` | [x] |
| Web app, Dart and vendored LiveKit included | `tools/voice_dsp/web_noise_loop.mjs --app` | [x] |
| Native end to end, real WebRTC (Linux) | `tools/voice_dsp/native_noise_loop.sh` | [x] |
| Windows | none: no Windows machine; shares the C++ hook, Dart and Rust with Linux, compiled by CI | manual |
| Android | none: no DSP on Android by design; the decision is unit tested | n/a |
| A call through a LiveKit server | none yet: needs a local `livekit-server --dev` | manual |

## Bugs

| # | Symptom | Cause | Status |
|---|---------|-------|--------|
| 1 | Web: after the preference flips, the watchdog or a mic switch, the raw microphone goes out with the browser's suppressor off | vendored `restartTrack` read `_processor` after `stop()` dropped it | fixed 3bb94af6 |
| 2 | Preference flipped while muted or before publishing never applied: neither suppressor, or both | only applied at the moment of the change | fixed f7c1e8a8 |
| 3 | After any legacy 1:1 call the DSP stays on, the mic test is hidden, mute/deafen hit the dead call | removal by identity; a new wrapper per event | fixed 05355d94 |
| 4 | Native: leave-then-join leaves the hook cleared while the manager thinks it is installed | install/uninstall not serialized | fixed dae2dd1a |
| 5 | Native: a missing callback symbol turns WebRTC NS off with nothing on the hook | symbols resolved lazily at install | fixed 03f84134 |
| 6 | Web: missing or broken wasm: browser NS off, raw microphone out, settings claim the DSP works | `isSupported` only checked browser APIs | fixed a56519ea |
| 7 | `build.yml` web artifacts had no wasm; `release.yml` lacked the wasm32 target | CI | fixed c01bef24 |
| 8 | Watchdog, restart and mute act on the DJ music or screen audio when the mic was not published first | `audioTrackPublications.firstOrNull` | fixed f7c1e8a8 |
| 9 | Legacy 1:1 ignores the preference: desktop runs both suppressors, the web never runs ours | SDK constraints straight to getUserMedia | fixed 69ab030c |
| 10 | Desktop: screen audio or DJ music switches WebRTC's NS/AEC off for the mic | per-sender options applied to the shared APM (confirmed in libwebrtc source) | open: needs a product decision, see Known gaps |
| 11 | Every fallback was a log line: the user never learned suppression was not ours | | fixed f7c1e8a8, a56519ea |
| 12 | `isProcessing` true for 0.5 s with no audio at every start and restart | frames 0 counted as progress | fixed 22131905 |
| 13 | After an app refresh, the old CallManager's late hang-up takes the DSP off the rejoined call | DSP relied on "a CallManager's list is empty" | fixed dae2dd1a |
| 14 | A microphone first published by an unmute gets LiveKit's defaults (no web DSP) | `_micOptions()` returned null | fixed f7c1e8a8 |
| 15 | Web: `create()` returns a graph whose worklet never started (passes audio through) | returned before the worklet was ready | fixed a56519ea |
| 16 | The web app does not compile since #127 | 64-bit int literals in `hashProfileKey` | fixed 7da2ff2f |
| 17 | Desktop mic test and legacy calls record from device 0, not the picked mic | `deviceId: {exact}`; flutter-webrtc reads `optional.sourceId` only | fixed 6401bd34 |
| 18 | Desktop mic test with "Hear myself" off: DSP gets nothing, meter dead | disabling the received track disabled the mic (same id) | fixed f5e3f629 |

Hypotheses dropped on the way, for the next person: "the native hook's
output never reaches the encoder" and "the hook only runs while WebRTC plays
something" were both the loop measuring itself (the playback's jitter
buffer, then bug 18).

## Historical regressions (catalog) and their guards

| Past break | Guard |
|------------|-------|
| A1 null processor crashed Windows on join (e316d80a) | `check_contracts.py` pins the proxy install and `Release() {}` |
| A2 vendored LiveKit did not compile (8befc996) | the web app loop builds it; `dart analyze` |
| A3 toggle mid-call left both/neither (c3f8fc67) | `microphone_noise_suppression_test.dart` |
| A4 speaker bleed once WebRTC NS was really off (775c405d) | `tests/speaker_bleed.rs` |
| A5 DSP "supported" but fed nothing (775c405d) | watchdog tests; `isProcessing` test; native loop |
| A6 late hang-up uninstalled the DSP (8dbd3191) | `call_manager_dsp_test.dart`, `native_dsp_test.dart` |
| A7 mute tore down the web processor (24f5669f) | `livekit_processor_restart_test.dart` |
| A8 `copyWith` dropped the processor (24f5669f) | `livekit_processor_restart_test.dart`, `check_contracts.py` |

## Hardening

- [x] CI: ci `test` (Dart + Rust), ci `voice-dsp` (contracts, web build, both web loops; `publish` waits for it), integration-test (native loop)
- [x] `// COMMET` marker floor and the vendored changes the DSP needs (`check_contracts.py`)
- [x] `audio_dsp.wasm` in the web build (`check_contracts.py --web-build`, in ci, build and release)
- [x] visible failure: toast when the DSP gives up or cannot run, the reason in Settings
- [x] docs/voice-audio-processing.md: "What the tests guard", "What still needs a person"
- [x] shown locally: the CI steps pass, and fail with a fix reverted (bug 1 → contracts and Dart tests; bug 15 → browser loop; bug 18 → native loop)
