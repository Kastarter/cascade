# Research Sequence 11: On-Device Inference

## Overview

Cascade is positioned as a local-first enterprise work-memory and computer-use product, but its intelligence path is still cloud-heavy: `ProviderKit/ComputerUseAgent.swift`, `ProviderKit/ElementLocator.swift`, `ProviderKit/RecordSearchAnswerer.swift`, `ProviderKit/ClaudeAnswerer.swift`, `ProviderKit/Planner.swift`, `AgentOrchestrator/WorkflowCurator.swift`, and `SandboxKit/AgentTaskPlanner.swift` all contain paths that send user goals, OCR/AX context, or screenshots to hosted models. That is expensive, adds round-trip latency, and is the hardest trust story for buyers whose screens include customer data, HR data, finance systems, credentials, or regulated records.

The right architecture is not to replace the high-capability computer-use loop with a tiny local model immediately. It is to add a local inference tier that handles low-risk, high-frequency text tasks and deterministic prefilters first, then gradually move vision grounding behind eval-gated local VLMs. The main product promise should become: screenshots and work memory stay local by default; cloud is reserved for approved high-complexity agent steps, with a visible policy reason.

A practical target split:

- **Local-first now:** intent routing, task splitting, workflow naming/curation, JSON classification, short record Q&A over retrieved snippets, local embeddings, local speech transcription, and OCR/AX-based region narrowing.
- **Hybrid:** visual target grounding where AX/OCR can produce candidates locally and Claude only resolves ambiguous misses.
- **Cloud-gated:** full real-screen computer-use planning, multi-step vision reasoning, unfamiliar app manipulation, and any action that crosses Cascade's risk gate.

## OSS/Frameworks Table

| Name | URL | License | Capability | Apple-Silicon feasibility |
|---|---|---|---|---|
| Apple MLX | https://github.com/ml-explore/mlx | MIT | Native array framework for Apple silicon; CPU/GPU unified memory, lazy computation, dynamic graphs, Python/C/C++/Swift APIs. Useful as the base for local LLM/VLM inference and model experiments. | Excellent on Apple silicon. MLX is explicitly designed for Apple silicon and uses unified memory, which fits Mac desktop deployment. |
| MLX Swift | https://github.com/ml-explore/mlx-swift | MIT | Swift API for MLX. Can be added to `Package.swift` and linked as `MLX`, `MLXNN`, `MLXOptimizers`; examples use Metal GPU by default on macOS. | Strong fit for Cascade's SwiftPM root. Requires Xcode builds for Metal shader support; still the cleanest Swift-native path. |
| MLX Swift LM | https://github.com/ml-explore/mlx-swift-lm | MIT | Swift package for LLMs and VLMs with MLX Swift. Best candidate for an in-process `LocalTextModel` and later `LocalVLMGrounder`. | Strong fit if Cascade accepts model bundle/download management. Good for small instruct models and local JSON generation. |
| MLX Swift Examples | https://github.com/ml-explore/mlx-swift-examples | MIT | Reference apps including `LLMEval`, which downloads an LLM/tokenizer from Hugging Face and runs text generation on iOS/macOS, plus chat examples with LLM/VLM support. | Useful implementation template, not a runtime by itself. Port patterns into a `LocalInferenceKit` target. |
| MLX LM | https://github.com/ml-explore/mlx-lm | MIT | Python CLI/API for MLX LLM generation, streaming, model conversion, 4-bit quantization, prompt caching, and Hugging Face integration. | Good conversion and benchmarking tool. Do not ship Python in the app unless needed; use it to produce MLX model artifacts for Swift. |
| llama.cpp / Swift interop | https://github.com/ggml-org/llama.cpp | MIT | C/C++ local LLM runtime with GGUF, Metal, ARM NEON, Accelerate, OpenAI-compatible server, embeddings, reranking, grammar-constrained JSON, speculative decoding, and quantization. `llama.swift` should be treated as a pattern around the C API or an audited wrapper, not a single canonical upstream. | Very feasible. Easiest production fallback is a bundled helper process or local `llama-server`; tighter Swift integration can use Swift C/C++ interop after ABI/build work. |
| Core ML + Core ML Tools | https://github.com/apple/coremltools | BSD-3-Clause for coremltools; Core ML is Apple proprietary SDK | Convert PyTorch/TensorFlow/scikit models to Core ML, optimize/compress them, and run on-device with CPU/GPU/Neural Engine scheduling. Core ML is best for compact encoders/classifiers, not rapidly changing LLM architectures. | Excellent for MiniLM embeddings, routing classifiers, OCR adjunct classifiers, and small NER/PII classifiers. Strong enterprise story because it is native, offline, and MDM-friendly. |
| Apple Foundation Models framework | https://developer.apple.com/documentation/foundationmodels | Apple proprietary SDK/framework | macOS 26/iOS 26 API for Apple's on-device Apple Intelligence model, with Swift integration, structured generation, and tool-style workflows. Not OSS and not available on older macOS. | Very attractive for future macOS 26+ installs: no model distribution, private/offline, native Swift. Must be feature-gated because Apple Intelligence availability depends on OS, region, device, user/admin settings, and policy. |
| whisper.cpp | https://github.com/ggml-org/whisper.cpp | MIT | Offline Whisper inference in C/C++; Apple Silicon optimized via ARM NEON, Accelerate, Metal, and Core ML; supports quantization and C API. | Strong fit for local PTT transcription. It can reduce OpenAI Realtime audio exposure if Cascade separates transcription from TTS/conversation. |
| Qwen2.5 0.5B/1.5B Instruct | https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct | Apache-2.0 for 0.5B/1.5B instruct variants | Small multilingual instruct LLMs with good JSON/structured-output behavior. Good for intent routing, workflow naming, task splitting, and short grounded answers. | Very feasible in 4-bit MLX or GGUF. 0.5B is quick enough for warm interactive classifiers; 1.5B is a better accuracy/latency midpoint on 16GB+ Macs. |
| Phi-3 Mini 4K Instruct | https://huggingface.co/microsoft/Phi-3-mini-4k-instruct | MIT | 3.8B instruct model with local-device focus and available GGUF/ONNX paths. Better reasoning than sub-1B models for short Q&A and planning summaries. | Feasible on Apple Silicon with 4-bit GGUF/MLX, but heavier than Qwen 0.5B/1.5B. Use when answer quality matters more than instant routing latency. |
| SmolLM2 135M/360M/1.7B Instruct | https://huggingface.co/HuggingFaceTB/SmolLM2-135M-Instruct | Apache-2.0 | Very small instruction models for cheap classification, command routing, and schema extraction. | Excellent for always-on routing if accuracy is sufficient. 135M is likely too weak for nuanced Q&A but useful as a first-pass classifier. |
| all-MiniLM-L6-v2 | https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2 | Apache-2.0 | Sentence embeddings, 384-dimensional vectors, widely used for semantic search. | Good Core ML candidate. It should replace or augment current `NLEmbedding` word-vector averaging in `CascadeMemory/SemanticIndex.swift`. |
| Qwen2.5-VL 7B Instruct | https://huggingface.co/Qwen/Qwen2.5-VL-7B-Instruct | Apache-2.0 | Vision-language model with visual localization, JSON outputs, OCR/chart/layout capability, and GUI-agent benchmarks. | Plausible larger bet on 32GB+ Apple Silicon with quantization. Use only behind an eval gate for `ElementLocator`/visual grounding; not a quick default for all users. |

## Concrete Offload Opportunities

### 1. Workflow curation and naming

- **Cascade call site:** `AgentOrchestrator/WorkflowCurator.swift` calls `client.complete` in `curate(_:)` and `curateOne(_:)` to judge repeated workflows, name them, explain why they matter, and write an executable goal.
- **Local model:** Qwen2.5-1.5B-Instruct or Phi-3-mini-4k-instruct through MLX Swift LM; SmolLM2 1.7B for a lighter first pass.
- **Integration path:** Add a `LocalTextCompleting` protocol mirroring `MessageCompleting`, then create `LocalWorkflowCurator(client: LocalTextCompleting)` or make `WorkflowCurator` accept a `CompletionProvider` that chooses local first and cloud fallback on parse failure. Use JSON grammar or schema validation; keep existing fallback behavior.
- **Expected win:** High. This keeps OCR/AX snippets from demonstrated work local, eliminates repeated curation spend during refreshes, and should be fast after warm model load because the prompts are text-only and short.

### 2. Agent task splitting

- **Cascade call site:** `SandboxKit/AgentTaskPlanner.swift` calls hosted `AnthropicClient` to split a job into up to five subtasks for web sandbox and on-screen episodes.
- **Local model:** Qwen2.5-1.5B-Instruct 4-bit for JSON task splitting; Phi-3 Mini if the prompt needs stronger reasoning.
- **Integration path:** Add `LocalSubtaskPlanner` with the exact existing JSON schema and a strict parser. Use local result when it parses and stays within the same safety constraints; fall back to current hosted planner when local output is invalid or low confidence.
- **Expected win:** Medium/high. Saves a cloud call before many agent runs and avoids sending the user's raw task decomposition prompt off-device. Latency should drop after model warmup.

### 3. Ask-panel grounded answers over local record

- **Cascade call site:** `AgentOrchestrator.askRecord` first tries `RecordSearchAnswerer.answer`, which runs a hosted multi-hop tool loop over local SQLite. If that fails, `ClaudeGroundedAnswerer.answer` sends selected timeline/relevant/recent snippets to the cloud.
- **Local model:** Phi-3 Mini or Qwen2.5-1.5B/3B class local instruct model; MiniLM embeddings for better retrieval. For simple direct answers, Qwen2.5-0.5B can be an ultra-cheap first pass.
- **Integration path:** Keep `RecordRecall` and `CascadeStore.relevantContexts` local. Add `LocalRecordAnswerer` implementing `RecordAnswering`: retrieve deterministically, pass only top-N cited snippets to local model, require `SOURCES: [#id]` or structured citation JSON, and fall back to cloud only for explicit user opt-in or low-confidence answers.
- **Expected win:** Very high privacy win. Ask-panel questions are exactly where enterprise users expect local screen memory not to leave the machine. Cost win is also large because multi-hop hosted Q&A can burn several model turns per question.

### 4. Intent routing before screenshot capture

- **Cascade call site:** `AppShell/CascadeAppModel.swift` routes utterances with `isActionRequest`, `isReferential`, and `lastTeachRoute` before deciding whether to run `runAssistTask` or `locateRegionGrounded`.
- **Local model:** SmolLM2-135M/360M or a Core ML classifier fine-tuned/distilled on Cascade utterances. Foundation Models framework is an excellent macOS 26 adapter if available.
- **Integration path:** Add `LocalIntentRouter` returning `{route: ask|locate|act|stop|clickRemembered, confidence, reason}`. Only use it to override heuristics when confidence is high, and log route decisions to the existing audit stream. This can live in a new `LocalInferenceKit` target with no dependency on screenshot capture.
- **Expected win:** Medium. The current router is mostly heuristic, so this is less about replacing an existing cloud call and more about preventing unnecessary screenshot/cloud turns caused by bad route choices.

### 5. Region narrowing for "where is X" before any cloud vision call

- **Cascade call site:** `ProviderKit/ElementLocator.locateRegion` sends a screenshot to Haiku; `CascadeAppModel.locateRegionGrounded` currently tries the configured grounder first and falls back to Claude. `MacContextKit/ScreenTextRecognizer.swift` already exposes on-device OCR boxes and matching.
- **Local model:** First stage should be deterministic AX/OCR ranking, not an LLM. Second stage can be Qwen2.5-VL-7B-Instruct or a local UI-TARS-style model through MLX/llama.cpp once evals prove coordinate accuracy.
- **Integration path:** Add `LocalRegionNarrower`: collect AX controls + Vision OCR boxes + app/window metadata, score against the user phrase, and return candidate rects. If there is one strong candidate, draw the highlight locally. If ambiguous, send a cropped/marked image to the existing grounder or cloud fallback. For the VLM path, add `LocalVisualGrounder` behind the existing `VisualGrounder` abstraction.
- **Expected win:** Very high privacy win when it hits, because screenshots no longer leave the device for common visible-text targets. Latency is also much lower than a hosted vision round trip. Accuracy risk is real for icon-only/canvas targets.

### 6. Semantic retrieval quality

- **Cascade call site:** `CascadeMemory/SemanticIndex.swift` already uses on-device `NLEmbedding.wordEmbedding(for: .english)` and brute-force cosine scan.
- **Local model:** all-MiniLM-L6-v2 converted to Core ML, or an MLX embedding model served by llama.cpp's embedding endpoint.
- **Integration path:** Keep the existing SQLite `context_embedding` table but version vectors by model name/dimension. Add a migration path that can backfill MiniLM vectors lazily. Retain `NLEmbedding` fallback for minimal installs.
- **Expected win:** Not a cloud-cost win because embeddings are already local. It is still important because better local recall reduces cloud Q&A retries and lowers the need for a hosted model to compensate for weak retrieval.

### 7. Local PTT transcription

- **Cascade call site:** `AppShell/RealtimeVoice.swift` uses OpenAI Realtime for voice capture/playback. Even if Cascade keeps Realtime for spoken responses, command transcription can be split out.
- **Local model:** whisper.cpp `base.en` or `small.en` quantized model, with Core ML encoder on Apple Silicon when supported.
- **Integration path:** Add a `SpeechRecognizer` protocol and a `WhisperLocalRecognizer` helper process or C API wrapper. Keep Realtime TTS/conversation as optional, but allow enterprises to set "local transcription only" for PTT commands.
- **Expected win:** High privacy win for voice commands and lower recurring audio cost. Latency depends on chunking and model size; use PTT end-of-utterance transcription first, streaming later.

### 8. Local answer/verifier for low-risk tool results

- **Cascade call site:** `ProviderKit/ComputerUseAgent.swift` and `ProviderKit/ScoutAgent.swift` already route in-process harness and recall tool results back into hosted planning turns.
- **Local model:** Qwen2.5-0.5B/1.5B for short summarization/classification over tool output; SmolLM2 for binary checks.
- **Integration path:** When a turn consists only of read-only harness/recall results and no screenshot action, let a local model answer or classify whether another hosted screen turn is needed. If it can produce a final answer with citations, stop locally.
- **Expected win:** Medium. This reduces cloud turns in "read/tell/report" tasks while keeping real screen actions on the stronger agent path.

## Quick Wins vs Larger Bets

### Quick Wins

1. **Create `LocalInferenceKit`.** Add a Swift target with protocols: `LocalTextCompleting`, `LocalJSONClassifier`, `LocalEmbeddingProvider`, `LocalSpeechRecognizer`, and later `LocalVisualGrounder`. Keep provider selection policy-driven and auditable.
2. **MLX Swift LM local text adapter.** Add `mlx-swift`/`mlx-swift-lm` as optional SwiftPM dependencies and ship a developer flag for `Qwen2.5-0.5B-Instruct-4bit` or `Qwen2.5-1.5B-Instruct-4bit`. Start with `WorkflowCurator` and `AgentTaskPlanner` because both already parse JSON and already have safe fallbacks.
3. **Foundation Models adapter for macOS 26+.** Add `@available(macOS 26, *)` local completion provider. Treat it as a native no-download path for structured summaries/classification where Apple Intelligence is available. Keep MLX/llama.cpp fallback for macOS 14/15 and enterprise environments where Apple Intelligence is disabled.
4. **Core ML MiniLM embeddings.** Convert all-MiniLM-L6-v2 with coremltools, version the embedding table, and lazy-backfill. This improves record Q&A without adding a cloud dependency.
5. **OCR/AX local region prefilter.** Use `ScreenTextRecognizer.recognizeBoxes` and AX summaries before `ElementLocator.callRegion`. This is the fastest way to reduce screenshot egress for "where is" requests.
6. **whisper.cpp PTT recognizer.** Offer a local-transcription enterprise mode. It is orthogonal to the LLM path and has a clear privacy story.

### Larger Bets

1. **Local visual grounder.** Run Qwen2.5-VL-7B or a UI-TARS-style model locally through MLX/llama.cpp and plug it into `VisualGrounder`. Gate by evals on Cascade screenshots: target hit rate, coordinate error, JSON parse rate, latency, memory, thermal behavior.
2. **Local record Q&A agent.** Replace hosted `RecordSearchAnswerer` with a local model that can call the existing `RecordRecall` tools. This needs strong citation enforcement and a hallucination eval set.
3. **Speculative decoding for heavier local models.** For Phi/Qwen 3B+ tasks, test llama.cpp speculative decoding with a tiny draft model. Use only after measuring whether quantized target + draft actually improves Apple-Silicon latency for Cascade prompt shapes.
4. **Model lifecycle and admin policy.** Enterprise local inference requires model download provenance, checksum/signature verification, license inventory, disk budgets, MDM policies, and per-tenant approved model lists.
5. **Full local computer-use loop.** Do not make this a first milestone. Keep Claude/hosted frontier models for high-risk multi-step screen action until local VLM+planner evals match the reliability failure taxonomy.

## Risks

- **Accuracy cliffs from small models.** 135M-0.5B models are good classifiers, not reliable agents. Use them for routing and schema extraction, not unsupervised action planning.
- **Vision grounding is the hard part.** Text models can move quickly on-device; screenshots require VLMs, coordinate calibration, and app-specific evals. A wrong local click is worse than a slow cloud call.
- **Hardware variance.** 8GB Macs, 16GB Macs, and 32GB+ Macs will support different model tiers. Cascade needs a model capability profile, not one default local model.
- **Foundation Models availability.** It is not OSS, and availability can depend on OS version, Apple Intelligence eligibility, region, language, user settings, and enterprise policy. It should be a provider, not the only path.
- **Licensing/provenance.** Qwen text models named above are Apache-2.0, Phi is MIT, SmolLM2/MiniLM are Apache-2.0. Some VLM sizes and community quantizations can have different or missing licenses. Enterprise builds need a model bill of materials and legal review.
- **Model downloads are product surface.** Silent Hugging Face downloads are not acceptable for enterprise. Cache location, retention, checksum, offline install, and delete/export controls must be explicit.
- **Local does not mean safe.** Prompt injection, bad plans, and unsafe actions still matter when inference is local. Keep STOP, audit events, action-risk gates, and human review unchanged.
- **Thermals and battery.** Always-on local inference can make a Mac feel slow. Run large models only on demand, keep a warm small classifier, and expose resource policy controls.

## Recommended First Implementation Slice

1. Add `LocalInferenceKit` and a provider registry: `.foundationModels` when available, `.mlxSwiftLM`, `.llamaServer`, `.coreML`, `.disabled`.
2. Implement local JSON completion for `WorkflowCurator` and `AgentTaskPlanner` first. They are text-only, already schema-checked, and already degrade safely.
3. Add `LocalRecordAnswerer` for ask-panel short answers over top retrieved moments, with required citation IDs. Keep cloud fallback behind explicit policy.
4. Replace `SemanticIndex` vectors with versioned MiniLM Core ML embeddings while retaining `NLEmbedding` fallback.
5. Add AX/OCR candidate narrowing before `ElementLocator.callRegion`; send a cloud screenshot only on ambiguity or misses.

This slice reduces the number of hosted calls without weakening the real-screen agent. It also gives enterprise buyers a clear privacy control: routine memory and classification stay local; cloud is opt-in/escalation for complex visual action.

## Sources

- Apple MLX: https://github.com/ml-explore/mlx
- MLX Swift: https://github.com/ml-explore/mlx-swift
- MLX Swift LM: https://github.com/ml-explore/mlx-swift-lm
- MLX Swift Examples: https://github.com/ml-explore/mlx-swift-examples
- MLX LM: https://github.com/ml-explore/mlx-lm
- llama.cpp: https://github.com/ggml-org/llama.cpp
- Core ML Tools: https://github.com/apple/coremltools
- Apple Foundation Models: https://developer.apple.com/documentation/foundationmodels
- Apple WWDC25 Foundation Models session: https://developer.apple.com/videos/play/wwdc2025/286/
- whisper.cpp: https://github.com/ggml-org/whisper.cpp
- Qwen2.5 0.5B Instruct: https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct
- Qwen2.5-VL 7B Instruct: https://huggingface.co/Qwen/Qwen2.5-VL-7B-Instruct
- Phi-3 Mini 4K Instruct: https://huggingface.co/microsoft/Phi-3-mini-4k-instruct
- SmolLM2 135M Instruct: https://huggingface.co/HuggingFaceTB/SmolLM2-135M-Instruct
- all-MiniLM-L6-v2: https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2
