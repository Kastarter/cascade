# SEQ-23 Voice / Realtime Pipeline Optimization

## Overview

Cascade's current voice path is intentionally simple: `PushToTalkMonitor` starts capture on Right Command press, `RealtimeVoice` streams PCM16/24 kHz frames to OpenAI Realtime over WebSocket, `endTalking()` commits the `input_audio_buffer`, and `CascadeAppModel.teach(question:)` decides whether the completed cloud transcript is a command, stop request, acknowledgment, duplicate, or fragment. The app already prewarms screen capture and Anthropic TLS on PTT press, handles barge-in by stopping playback plus `response.cancel`, and gates obvious transcript fragments through `VoiceFragmentGate`.

The remaining optimization surface is mostly before and around the cloud transcript:

- Do not upload or commit silence, key taps, breathing, or background speech fragments.
- Make endpointing deterministic even with early/late PTT release.
- Make barge-in semantically correct by truncating unheard assistant audio, not only canceling future audio.
- Use transcript deltas and local ASR only for routing, warmup, and fragment suppression until confidence is high.
- Keep the default product PTT-first, with wake word / always-listening as a larger optional mode.

The best portable pattern is a local audio front-end in Swift: small fixed PCM frames, optional noise suppression, WebRTC VAD for cheap first-pass gating, Silero VAD for robust neural gating, a speech-prefix ring, a turn-state machine, and optional `whisper.cpp`/sherpa-onnx local ASR for command routing before or alongside OpenAI Realtime.

## OSS Repos & Papers

| name | url | stars/venue | license | technique |
|---|---:|---:|---|---|
| whisper.cpp | https://github.com/ggml-org/whisper.cpp | 51.1k GitHub stars | MIT | C/C++ Whisper inference with C API, Apple Silicon NEON/Accelerate/Metal/Core ML support, quantization, runtime allocation discipline, and built-in VAD hooks. Best fit for local speculative ASR on PTT audio. |
| sherpa-onnx | https://github.com/k2-fsa/sherpa-onnx | 13.2k GitHub stars | Apache-2.0 | ONNX Runtime speech stack for local VAD, streaming ASR, keyword spotting, speaker tasks, and iOS/macOS/embedded deployments. Useful if Cascade wants one local speech runtime instead of separate VAD + ASR libraries. |
| Vosk API | https://github.com/alphacep/vosk-api | 14.9k GitHub stars | Apache-2.0 | Offline streaming ASR with small models, low-latency partial results, vocabulary constraints, and C++/iOS bindings. Good fallback for command-routing prototypes, less Apple-Silicon-specialized than whisper.cpp. |
| Silero VAD | https://github.com/snakers4/silero-vad | 9.4k GitHub stars | MIT | Neural VAD with ONNX support, 8/16 kHz input, roughly sub-millisecond 30 ms chunk processing on CPU, multilingual/noisy-domain robustness. Best robust speech gate before Realtime append/commit. |
| py-webrtcvad / WebRTC VAD | https://github.com/wiseman/py-webrtcvad | 2.5k GitHub stars | MIT wrapper + WebRTC BSD-style code | Classic C VAD accepting 10/20/30 ms mono PCM frames at 8/16/32/48 kHz. Very small, deterministic, easy to port/vendor for first-pass gating and hysteresis. |
| RNNoise | https://github.com/xiph/rnnoise | 5.7k GitHub stars; IEEE MMSP 2018 paper | BSD-3-Clause | Real-time RNN noise suppression in C. Use before VAD/transcription on laptop mics, especially for steady background noise, but keep a bypass because suppression can distort speech. |
| openWakeWord | https://github.com/dscripka/openWakeWord | 2.4k GitHub stars | Apache-2.0 | Wake phrase framework with ONNX/TFLite models, 80 ms streaming frames, Silero VAD gating, threshold calibration, and synthetic-data training. Candidate for optional "Hey Cascade" mode, not default PTT. |
| Howl | https://github.com/castorini/howl | 215 GitHub stars; ACL NLP-OSS 2020 | MPL-2.0 | Firefox Voice wake-word toolkit with Common Voice / Speech Commands training flow and reproducible wake-word experiments. Useful as a training/evaluation reference; MPL makes direct code porting less attractive. |
| Voice Activity Projection | https://github.com/ErikEkstedt/VoiceActivityProjection | 103 GitHub stars; Interspeech 2022 | MIT | Self-supervised turn-taking projection model that predicts future voice activity/turn shifts. Treat as a larger bet for predictive endpointing; too heavy for immediate PTT path. |
| TurnGPT | https://arxiv.org/abs/2010.10874 | arXiv 2020 | paper; code available separately | Uses lexical/pragmatic completeness to predict turn completion. Implement the idea cheaply first: use transcript delta completeness to avoid committing on "and then..." / "can you..." pauses. |
| Emformer | https://arxiv.org/abs/2010.10759 | ICASSP 2021 | paper | Efficient memory transformer for low-latency streaming ASR with cached left context and 80 ms low-latency scenarios. Relevant if Cascade later trains/ships a streaming local ASR model. |
| Whisper paper | https://arxiv.org/abs/2212.04356 | ICML 2023 / arXiv 2022 | paper; OpenAI Whisper code is MIT | Robust ASR from 680k hours weak supervision. Supports using Whisper-family local ASR as a tolerant command router, while still guarding hallucinations with fragment and confidence checks. |
| OpenAI Realtime API docs | https://developers.openai.com/api/docs/guides/realtime | official docs | proprietary API | Current docs expose transcript deltas, transcription logprobs, `input_audio_noise_reduction`, server VAD knobs, and `conversation.item.truncate` for barge-in synchronization. |

## Concrete Techniques to Adopt

- Add a local VAD front-end in `Sources/AppShell/RealtimeVoice.swift`, inside `installCaptureTap(...)`.
  Change the tap path from "convert every 4096-frame buffer and append" to "convert/rechunk into fixed 20 or 30 ms PCM16 frames, run local VAD, and append only gated speech plus prefix padding." At 48 kHz, `bufferSize: 4096` is about 85 ms before conversion; WebRTC VAD expects 10/20/30 ms frames, and Silero examples are built around short chunks. Start with a new `LocalVoiceActivityGate` that keeps a 300 ms prefix ring, `minSpeechMs` around 180-250 ms, and hangover around 200-300 ms.

- Use a two-tier VAD strategy: WebRTC first, Silero second.
  Put the tiny C/WebRTC path behind a Swift wrapper in a new `Sources/ProviderKit/LocalVAD.swift` or `Sources/AppShell/LocalVAD.swift`, then add Silero ONNX/Core ML as the robust path once the frame plumbing is stable. WebRTC gives deterministic low overhead for every frame; Silero should handle noisy laptop-mic conditions and non-English/background cases better. The final gate can be `speech = webrtcSpeech || sileroScore >= threshold`, with thresholds tunable in Settings later.

- Do not commit non-speech turns in `RealtimeVoice.endTalking()`.
  Today `endTalking()` always sends `input_audio_buffer.commit` after capture stops. Track per-turn speech state in `RealtimeVoice` (`speechStartedAt`, `lastSpeechAt`, `uploadedSpeechMs`, `localRejectedReason`). If no local speech passed the gate, send `input_audio_buffer.clear`, set `state = .idle`, and do not call the cloud transcript path. This prevents "Iii", "Hi", keyboard taps, breathing, and silent PTT holds from ever reaching `VoiceFragmentGate`.

- Make PTT release endpoint-aware instead of a hard commit edge.
  In `endTalking()`, if VAD says speech was active in the last 150-250 ms, continue capture briefly until either local silence exceeds 250-400 ms or a max tail of about 500 ms elapses, then commit. If silence already settled before release, commit immediately. This catches clipped final syllables while keeping the "release means finish" feel.

- Add client-side endpoint metrics and audit rows.
  Add a `voice.turn.timing` audit detail from `RealtimeVoice` or `CascadeAppModel`: key-down, socket-ready, first audio append, local speech start, key-up, commit, first transcript delta, transcript completed, teach started, first Claude action, first spoken response audio. This is voice-specific instrumentation, separate from generic AgentTrace, and will reveal whether PTT latency is capture, Realtime transcript, Claude, or playback.

- Enable Realtime input noise reduction in `RealtimeVoice.sessionUpdate()`.
  The current session config sets input format, disables turn detection, and locks English transcription, but does not request server-side input noise reduction. Add the GA field for `input_audio_noise_reduction` with a default of `near_field` for headset/close mic and a future setting for `far_field` on laptop mic. OpenAI documents this as filtering audio before VAD/model perception and improving false positives. Keep local RNNoise optional; use OpenAI noise reduction as the quickest low-risk server-side improvement.

- Request transcription logprobs and reject low-confidence fragments.
  The Realtime reference supports `include: ["item.input_audio_transcription.logprobs"]` for transcription deltas/completions. Add parsing in `RealtimeVoice.handle(_:)`, pass confidence metadata into `onUtterance`, and extend `VoiceFragmentGate.classify` or a wrapper in `CascadeAppModel.teach(question:)` to reject short commands with low average token confidence. This should reduce supersession from hallucinated fragments without making normal commands slower.

- Use `conversation.item.truncate` on barge-in, not only `response.cancel`.
  `RealtimeVoice.beginTalking()` currently stops `playerNode`, sends `response.cancel`, and calls `onInterrupt`. OpenAI's Realtime reference says `conversation.item.truncate` synchronizes server state with the audio the user actually heard and removes unheard assistant transcript. Track the current assistant audio item id and played duration in `response.output_audio.delta` handling; on barge-in, send `conversation.item.truncate` with `audio_end_ms` before or alongside `response.cancel`.

- Fix `RealtimeVoice.speak(_:)` to be single-flight.
  Project memory says this was fixed before, but current code sends a new `response.create` without first canceling any active response. That can recreate the old "Realtime rejects concurrent responses; narration silently drops" failure. In `speak(_:)`, send `response.cancel` before `response.create` when a response is in flight, or queue narration clauses and drop duplicates via `lastNarratedLine` at the caller.

- Use transcript deltas for warmup and UI, not for execution.
  `RealtimeVoice.handle(_:)` already appends `conversation.item.input_audio_transcription.delta` to `transcript` while listening. Add `onPartialUtterance` and let `CascadeAppModel` use stable partials to update the notch, detect likely app names, and prewarm likely app/capture paths. Do not call `teach(question:)` until completed unless a future local confidence gate proves the delta is final enough.

- Add local ASR as a speculative router, not the command source of truth.
  Add a `LocalASRKit` wrapping `whisper.cpp` tiny.en/base.en with Metal/Core ML enabled. Feed it the same speech ring after local VAD starts. Use its partial/final text to classify obvious `stop`, acknowledgments, and duplicate same-goal retries before cloud completion, and to prewarm `CascadeAppModel` routes. For full commands, still wait for OpenAI Realtime completion unless local and cloud agree or the user opts into local-only mode.

- Add a privacy/cost "local-first PTT" mode.
  In the default low-latency mode, stream gated speech to Realtime as soon as VAD starts. In local-first mode, buffer locally until WebRTC/Silero confirms speech and whisper.cpp sees command-shaped text, then flush the prefix ring to Realtime. If the local classifier says the turn is silence/filler/ack, clear the Realtime input buffer without committing. This trades a few hundred milliseconds for fewer cloud seconds and better enterprise privacy posture.

- Keep wake word as an optional larger bet.
  Do not replace Right Command PTT. If adding hands-free activation later, map it to `PushToTalkMonitor` as a separate `WakeWordMonitor` that only arms when the app is allowed to listen, uses openWakeWord or sherpa-onnx KWS, requires simultaneous Silero speech score, and creates an auditable `voice.wake.detected` event before calling `RealtimeVoice.beginTalking()`.

- Use VAP/TurnGPT ideas as heuristics before models.
  Full Voice Activity Projection is research-heavy and assumes turn-taking data; PTT Cascade can get most value from a simple lexical/prosodic endpoint heuristic. In `RealtimeVoice.endTalking()` / `VoiceFragmentGate`, delay commit if transcript partial ends with unfinished lead-ins ("and", "then", "can you", "please") or if local prosody shows no final silence. Treat VAP as a later evaluation target if Cascade moves to full duplex hands-free mode.

- Add a small voice fixture test suite.
  Extend `Tests/ProviderKitTests/VoiceFragmentGateTests.swift` or add `RealtimeVoiceGateTests.swift` with synthetic PCM fixtures: silence, keyboard click burst, 150 ms cough, 250 ms "stop", normal command with 300 ms leading silence, and early release with trailing phoneme. Pin decisions (`clear`, `append+commit`, `tail-wait`) without needing OpenAI credentials.

## Quick Wins vs Larger Bets

Quick wins:

- Add `input_audio_noise_reduction` and transcription logprob include fields in `RealtimeVoice.sessionUpdate()`.
- Add `response.cancel` single-flight behavior inside `RealtimeVoice.speak(_:)`.
- Track assistant output item/duration and send `conversation.item.truncate` on barge-in in `beginTalking()`.
- Add a local turn-state object that refuses to commit if no speech-like energy crossed a minimum duration.
- Reduce capture frame size and add a prefix ring, even before neural VAD is integrated.
- Add `voice.turn.timing` audit rows to separate capture, transcript, Claude, and playback latency.

Larger bets:

- Vendor WebRTC VAD C and later add Silero ONNX/Core ML as a second-stage gate.
- Wrap `whisper.cpp` as `LocalASRKit` for speculative local routing and local-only enterprise mode.
- Add optional openWakeWord/sherpa-onnx wake phrase mode with explicit permission UI and audit.
- Evaluate RNNoise or SpeexDSP prefiltering for laptop microphones; keep a bypass because denoising can hurt ASR on close-talk mics.
- Prototype VAP-style predictive endpointing only if Cascade moves from PTT to continuous full-duplex conversation.

## License/Attribution notes

- `whisper.cpp`, Silero VAD, py-webrtcvad wrapper, and VoiceActivityProjection are MIT-friendly for direct integration with attribution. WebRTC VAD code inside py-webrtcvad carries the WebRTC BSD-style notice; retain it if vendoring C code.
- `sherpa-onnx`, Vosk API, and openWakeWord are Apache-2.0; preserve NOTICE/license files and track model-specific licenses separately.
- RNNoise is BSD-3-Clause; retain copyright and disclaimer.
- Howl is MPL-2.0; prefer learning from its training/evaluation workflow rather than copying code into Cascade unless file-level MPL obligations are acceptable.
- Wake-word and ASR model weights often have separate licenses from code. Treat every bundled model as a shipped third-party artifact with an entry in `docs/PORT_MAP.md`, a license file in the app bundle, and a Settings/About attribution surface.
- For OpenAI Realtime changes, keep the implementation aligned to the GA docs: current docs distinguish WebRTC for browser/mobile direct media and WebSocket for server/raw-media pipelines, support transcript deltas/logprobs, server VAD parameters, input noise reduction, and assistant-audio truncation for interruption sync.
