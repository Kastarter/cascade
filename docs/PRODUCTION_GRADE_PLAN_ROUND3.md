# Cascade Production-Grade Plan - Round 3

Date: 2026-06-26

## Overview

Round 3 should harvest the highest-value production ideas that remain after the
security, grounding, tracing, cache, privacy-policy, and deterministic-call
passes already landed. The emphasis is on coding-agent-safe work: pure Swift
modules, deterministic fixtures, SQLite schema additions that do not change
shipped behavior by default, and verification with:

```bash
swift build
swift test
```

Do not spend this round on items that require bundled model weights, dependency
swaps, live Screen Recording or Accessibility access, network/API calls, audio
hardware, SSO/SOC2/MDM, or fleet infrastructure. Those stay larger bets.

## Numbered Backlog

### P3-01 - Action Episode Segmenter Before Mining

- Files: `/Users/khalidsh/Humain/cascade/Sources/WasteDetection/ActionEpisodeSegmenter.swift`; `/Users/khalidsh/Humain/cascade/Tests/WasteDetectionTests/ActionEpisodeSegmenterTests.swift`
- Build: Add a pure `ActionEpisodeSegmenter` that splits sorted `InputEvent`s by idle gap, surface/window switch, completion-control labels, noisy/sensitive surfaces, and copy/paste or same-token dataflow continuity. Return `ActionEpisode` with event IDs, start/end, surface flow, window titles, and boundary reasons.
- Test: Synthetic input streams cover idle boundaries, cross-app copy/paste continuity, save/send completion splits, noisy app exclusion, and stable episode ordering.
- Risk: low
- Seq: SEQ-08

### P3-02 - PrefixSpan-Style Gap-Constrained Sequence Miner

- Files: `/Users/khalidsh/Humain/cascade/Sources/WasteDetection/PrefixSpanMiner.swift`; `/Users/khalidsh/Humain/cascade/Tests/WasteDetectionTests/PrefixSpanMinerTests.swift`
- Build: Add an original bounded PrefixSpan-style miner over integer-compressed episode token sequences with `minSupport`, `maxPatternLength`, `maxGapEvents`, optional `maxSpanSeconds`, occurrence spans, and a closed-pattern filter. Keep it standalone first; do not replace `WasteDetector.detect` in this slice.
- Test: Fixtures prove gapped repeats are found, interrupted contiguous n-grams are recovered, low-support tokens are ignored, closed patterns suppress redundant subpatterns, and deterministic tie ordering is stable.
- Risk: med
- Seq: SEQ-08

### P3-03 - SQLite-Native Work Graph Skeleton

- Files: `/Users/khalidsh/Humain/cascade/Sources/CascadeMemory/WorkGraph.swift`; `/Users/khalidsh/Humain/cascade/Sources/CascadeMemory/CascadeMemory.swift`; `/Users/khalidsh/Humain/cascade/Tests/CascadeMemoryTests/WorkGraphTests.swift`
- Build: Add `graph_entity`, `graph_entity_alias`, `context_entity_link`, and `graph_edge` migrations plus a `WorkGraph` API for deterministic app/window/url/file/date/person extraction, alias upsert, moment linking, and entity timeline lookup. Store only redacted evidence snippets and bitemporal fields.
- Test: An in-memory store migration creates tables; repeated aliases upsert; URL/file/app/date entities link to moments; sensitive evidence is refused or redacted; entity timeline returns cited context IDs in time order.
- Risk: med
- Seq: SEQ-17

### P3-04 - Experience Ledger for Verified Agent Learning

- Files: `/Users/khalidsh/Humain/cascade/Sources/CascadeMemory/AgentExperienceLedger.swift`; `/Users/khalidsh/Humain/cascade/Sources/CascadeMemory/CascadeMemory.swift`; `/Users/khalidsh/Humain/cascade/Tests/CascadeMemoryTests/AgentExperienceLedgerTests.swift`
- Build: Add `agent_experience_case` storage and pure retention scoring for verified successes, verifier-backed failures, safe refusals, and user stops. Include app, goal pattern, recipe signature, skill slug, failure kind, evidence IDs, action count, and retained score.
- Test: Successes require a verified/completed signal, failures require `AgentFailureKind`, refusals are not treated as failures, user stops do not create avoid rules without feedback, and query APIs filter by app/goal/failure kind.
- Risk: med
- Seq: SEQ-15

### P3-05 - Skill Consolidation and Merge Scoring

- Files: `/Users/khalidsh/Humain/cascade/Sources/ComputerUseKit/SkillConsolidator.swift`; `/Users/khalidsh/Humain/cascade/Tests/ComputerUseKitTests/SkillConsolidatorTests.swift`
- Build: Add a pure consolidator that scores duplicate or overlapping learned skills by app matcher, `useWhen`, explicit-ask-only flag, human steps, approved status, success/failure counts, and evidence overlap. Output `newSkill`, `reviseExisting`, `quarantine`, or `archiveCandidate`; do not mutate skill files.
- Test: Near-duplicate skills route to revise, unrelated same-app skills stay separate, failed/quarantined skills abstain from active use, and scoring is stable across input order.
- Risk: low
- Seq: SEQ-15

### P3-06 - Event Store Time Keys and Side-Text Helpers

- Files: `/Users/khalidsh/Humain/cascade/Sources/CascadeMemory/EventStoreLayout.swift`; `/Users/khalidsh/Humain/cascade/Tests/CascadeMemoryTests/EventStoreLayoutTests.swift`
- Build: Add pure helpers for `captured_ms` integer keys, UTC day partition keys, `DayPartitionManifest` rollups, chunked retention ranges, and compressed context text blobs using Apple Compression with a deterministic fallback when compression is unavailable.
- Test: Date-to-ms/day conversion is stable, manifest aggregation tracks rows/bytes/first/last IDs, retention chunks are bounded and ordered, text compression round-trips, and excerpts avoid decompressing full text.
- Risk: low
- Seq: SEQ-26

### P3-07 - Semantic Embedding Provider Protocol and Deterministic Fallback

- Files: `/Users/khalidsh/Humain/cascade/Sources/CascadeMemory/SemanticEmbeddingProvider.swift`; `/Users/khalidsh/Humain/cascade/Tests/CascadeMemoryTests/SemanticEmbeddingProviderTests.swift`
- Build: Add `SemanticEmbeddingProvider`, `VectorDistanceMetric`, metadata (`modelID`, `dimension`, `distanceMetric`), and a deterministic hash/token fallback provider for tests and no-model operation. Leave CoreML/MLX providers out of scope.
- Test: Embeddings have fixed dimension, normalized text hashes are stable, cosine/dot/L2 distance helpers rank expected vectors, model metadata changes cache keys, and fallback output is deterministic across runs.
- Risk: low
- Seq: SEQ-04

### P3-08 - Verification Vote and Calibration Buckets

- Files: `/Users/khalidsh/Humain/cascade/Sources/AgentOrchestrator/VerifierCalibration.swift`; `/Users/khalidsh/Humain/cascade/Tests/AgentOrchestratorTests/VerifierCalibrationTests.swift`
- Build: Add a self-consistency vote helper over stable candidate IDs plus calibration buckets for verifier confidence, outcomes, false accepts, abstentions, and expected calibration error. Keep it pure and feedable from existing `AgentTrace` data later.
- Test: Candidate order randomization does not change aggregate winners, ties abstain by policy, bucket math is stable at boundaries, ECE is computed correctly, and high-risk thresholds route to accept/re-ground/pause bands.
- Risk: low
- Seq: SEQ-25

### P3-09 - Healed Anchor Drift Scoring

- Files: `/Users/khalidsh/Humain/cascade/Sources/ComputerUseKit/AnchorDriftScorer.swift`; `/Users/khalidsh/Humain/cascade/Tests/ComputerUseKitTests/AnchorDriftScorerTests.swift`
- Build: Add pure scoring that compares previous verified anchor score/source/hash to current ranked candidates and returns `stable`, `drifted`, `ambiguous`, `demote`, or `retryNextCandidate`. Use score drop, source change, top-two margin, failure count, and verification recency.
- Test: Moved controls with strong scores stay stable, score drops over threshold flag drift, close top candidates become ambiguous, repeated failed anchors demote, and retry-next only happens inside configured score margins.
- Risk: low
- Seq: SEQ-29

### P3-10 - Web State Signature Builder

- Files: `/Users/khalidsh/Humain/cascade/Sources/SandboxKit/WebStateSignature.swift`; `/Users/khalidsh/Humain/cascade/Tests/SandboxKitTests/WebStateSignatureTests.swift`
- Build: Add a deterministic Swift model plus JS snippet string for web state signatures: URL, title, active element, scroll, interactives hash, form values hash, checked/selected state, contenteditable text hash, ARIA text hash, and mutation sequence. Keep `BackgroundWebAgent` integration default-off in this slice.
- Test: Static fixture dictionaries produce stable signatures; form value, checkbox, focus, scroll, and text mutations change the right subhashes; sensitive field values are hashed, not serialized.
- Risk: low
- Seq: SEQ-24

### P3-11 - Voice Turn Endpoint Policy

- Files: `/Users/khalidsh/Humain/cascade/Sources/AppShell/VoiceTurnEndpointPolicy.swift`; `/Users/khalidsh/Humain/cascade/Tests/AppShellTests/VoiceTurnEndpointPolicyTests.swift`
- Build: Add a pure policy object over local VAD/energy timing that decides `clear`, `commitNow`, `tailWait`, or `appendOnly` from key-down/up, speech-start, last-speech, uploaded-speech-ms, min-speech, hangover, and max-tail settings. Do not touch audio hardware.
- Test: Silence and key taps clear; short coughs clear; valid speech commits; early PTT release tail-waits; stale tail caps at max duration; unfinished lexical fragments can request a short wait.
- Risk: low
- Seq: SEQ-23

### P3-12 - Action Idempotency Keys and Retry Backoff Types

- Files: `/Users/khalidsh/Humain/cascade/Sources/ProviderKit/ActionIdempotency.swift`; `/Users/khalidsh/Humain/cascade/Tests/ProviderKitTests/ActionIdempotencyTests.swift`
- Build: Add `ActionIdempotencyKey`, `RetryBackoffPolicy`, transient/nontransient error classification, deterministic seeded jitter for tests, and safe retry classes for pure model calls, grounding lookups, read-only tools, and non-idempotent actions.
- Test: Keys are stable across dictionary order, typed private text is excluded or hashed by policy, prompt/schema/model changes alter keys, transient classes schedule bounded retries, non-idempotent actions refuse automatic retry, and seeded jitter is deterministic.
- Risk: low
- Seq: SEQ-30

### P3-13 - Screen Element Index and Set-of-Mark Candidate Numbering

- Files: `/Users/khalidsh/Humain/cascade/Sources/ComputerUseKit/ScreenElementIndex.swift`; `/Users/khalidsh/Humain/cascade/Tests/ComputerUseKitTests/ScreenElementIndexTests.swift`
- Build: Add a pure candidate index model for AX/OCR/visual candidates with stable IDs, bounds, label, role, source, confidence, trust, overlap de-duplication, reading order, and Set-of-Mark numbering metadata. Do not render images or call models in this slice.
- Test: AX beats duplicate OCR text by trust, overlapping boxes merge predictably, IDs stay stable across input order when content is the same, mark labels are unique/readable, and unsafe/passive candidates are not marked as safe to click.
- Risk: low
- Seq: SEQ-03/16

### P3-14 - Structured Content Markdown and Table Export

- Files: `/Users/khalidsh/Humain/cascade/Sources/MacContextKit/StructuredContentExporter.swift`; `/Users/khalidsh/Humain/cascade/Tests/MacContextKitTests/StructuredContentExporterTests.swift`
- Build: Add exporters from existing `ScreenContentStructurer.Structured` to bounded Markdown, Markdown tables, CSV strings, and concise structure summaries suitable for a future `inspect_moment` record tool. Keep it pure; no Package dependency changes.
- Test: Reading-order text becomes Markdown paragraphs, key-values become a compact list, aligned table rows export valid Markdown/CSV with escaping, output truncates by byte/line budget, and empty structures produce an explicit empty summary.
- Risk: low
- Seq: SEQ-16

### P3-15 - Local DP and Clipping Helpers for Fleet Metrics

- Files: `/Users/khalidsh/Humain/cascade/Sources/CascadeMemory/LocalDifferentialPrivacy.swift`; `/Users/khalidsh/Humain/cascade/Tests/CascadeMemoryTests/LocalDifferentialPrivacyTests.swift`
- Build: Add clipped count/sum helpers, randomized response for bounded categorical metrics, deterministic test RNG injection, budget-spend records, and serialization that composes with existing `AnalyticsPrivacyPolicy` and `FleetExportManifest`.
- Test: Clipping happens before noise, randomized response probabilities are statistically sane with seeded tests, budget composition caps monthly spend, raw categories can be hashed or omitted by policy, and JSON contains epsilon/delta/mechanism but no raw OCR/URL/path fields.
- Risk: low
- Seq: SEQ-28

### P3-16 - Demo-Conditioned Trajectory Sketch Builder

- Files: `/Users/khalidsh/Humain/cascade/Sources/AgentOrchestrator/TrajectorySketch.swift`; `/Users/khalidsh/Humain/cascade/Tests/AgentOrchestratorTests/TrajectorySketchTests.swift`
- Build: Add a compact successful-trajectory sketch model from recipe steps and audit/eval evidence: app/window, normalized goal tokens, first actions, safe anchors, expected checks, failure corrections, and privacy-scrubbed labels. Output is prompt-ready text plus structured check functions, but no runtime injection yet.
- Test: Sketches omit private typed text, preserve action order and expected checks, collapse repeated equivalent steps, include only verified recoveries, and rank closer app/goal sketches above unrelated examples.
- Risk: low
- Seq: SEQ-02/22
