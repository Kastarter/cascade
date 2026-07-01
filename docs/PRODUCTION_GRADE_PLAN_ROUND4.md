# Cascade Production-Grade Plan - Round 4

Date: 2026-06-26

## Overview

Rounds 1-3 added many deterministic modules with focused tests. Round 4 should
wire the safest of those modules into the live seams that already exist, but only
behind default-off flags or explicit parameters. Shipped behavior must remain
unchanged until a caller opts in.

Do not include work that needs bundled model weights, SQLCipher or other
dependency swaps, live Screen Recording or Accessibility access for tests, audio
hardware, network/API calls, or organization infrastructure. Large live files may
only receive small additive hooks, such as one guarded call beside an existing
store write or completion path.

Verification target for each item:

```bash
swift test
```

## Numbered Backlog

### P4-01 - Integer Time-Key Query Path

- Files: `/Users/khalidsh/Humain/cascade/Sources/CascadeMemory/EventStoreLayout.swift`; `/Users/khalidsh/Humain/cascade/Sources/CascadeMemory/CascadeMemory.swift`; `/Users/khalidsh/Humain/cascade/Tests/CascadeMemoryTests/EventStoreLayoutStoreTests.swift`
- Build: Add nullable `captured_ms` columns and indexes for `recorded_context` and `input_event`, populate them on new writes with `EventStoreLayout.capturedMilliseconds`, and add explicit opt-in helpers such as `contexts(capturedMilliseconds:limit:)` / `inputEvents(capturedMilliseconds:limit:)`. Existing date-string queries remain the default path.
- Test: In-memory migrations add the columns, new inserts populate stable millisecond keys, integer-range helpers return the same rows as date-range helpers, and the default existing query methods still work without using the new helpers.
- Risk: low
- Seq: SEQ-26

### P4-02 - Default-Off Work Graph Capture Indexing

- Files: `/Users/khalidsh/Humain/cascade/Sources/CascadeMemory/WorkGraph.swift`; `/Users/khalidsh/Humain/cascade/Sources/CascadeMemory/CascadeMemory.swift`; `/Users/khalidsh/Humain/cascade/Sources/MacContextKit/MacContextKit.swift`; `/Users/khalidsh/Humain/cascade/Sources/MacContextKit/RewindRecorder.swift`; `/Users/khalidsh/Humain/cascade/Tests/CascadeMemoryTests/WorkGraphCaptureIntegrationTests.swift`
- Build: Add an explicit default-off recorder/store option, for example `ContextRecorder.Options(indexWorkGraph: false)` or `CascadeStore.insertContexts(_: indexWorkGraph: false)`. When enabled, each persisted `RecordedContext` calls `linkWorkGraphEntities(for:)` after insert. The normal recorder and tests keep the flag false.
- Test: Default inserts do not populate `graph_entity` or `context_entity_link`; opt-in inserts link app/window/url/file/date/person mentions; sensitive contexts still produce no graph entries; batch insert rollback does not leave partial graph links.
- Risk: med
- Seq: SEQ-17

### P4-03 - Agent Trace Builder From Audit Events

- Files: `/Users/khalidsh/Humain/cascade/Sources/AgentOrchestrator/AgentTrace.swift`; `/Users/khalidsh/Humain/cascade/Sources/CascadeMemory/CascadeMemory.swift`; `/Users/khalidsh/Humain/cascade/Tests/ReliabilityEvalTests/AgentTraceAuditBuilderTests.swift`
- Build: Add a pure `AgentTraceBuilder.fromAuditEvents(...)` that converts existing `AuditEvent` rows into run/tool/model/retrieval spans using action prefixes such as `assist.task`, `harness.*`, `agent.recall`, `agent.ground`, `assist.timing`, and `agent.run.completed`. Add an explicit store read helper for audit windows; no UI or live loop uses the builder unless a caller passes `enableTraceAssembly: true`.
- Test: Synthetic audit rows assemble into a stable span tree with redacted details only as safe attributes, duration ordering is deterministic, incomplete runs are marked error/refused, and existing `recentAudit` behavior is unchanged.
- Risk: low
- Seq: SEQ-14

### P4-04 - Exact ModelCallCache Wrapper For Pure Planners

- Files: `/Users/khalidsh/Humain/cascade/Sources/ProviderKit/ModelCallCache.swift`; `/Users/khalidsh/Humain/cascade/Sources/ProviderKit/AnthropicClient.swift`; `/Users/khalidsh/Humain/cascade/Sources/ProviderKit/Planner.swift`; `/Users/khalidsh/Humain/cascade/Sources/AgentOrchestrator/WorkflowCurator.swift`; `/Users/khalidsh/Humain/cascade/Sources/SandboxKit/AgentTaskPlanner.swift`; `/Users/khalidsh/Humain/cascade/Tests/ProviderKitTests/CachedMessageCompleterTests.swift`; `/Users/khalidsh/Humain/cascade/Tests/AgentOrchestratorTests/WorkflowCuratorCacheTests.swift`; `/Users/khalidsh/Humain/cascade/Tests/SandboxKitTests/AgentTaskPlannerCacheTests.swift`
- Build: Add a `CachedMessageCompleter` or optional `ModelCallCache?` constructor parameter, default nil/off, that wraps deterministic pure calls using `AnthropicCompletionOptions.cacheRequest`. Wire only `ClaudeSingleStepPlanner`, `WorkflowCurator`, and `AgentTaskPlanner`; do not touch the adaptive `ComputerUseAgent` loop.
- Test: With cache nil, fake clients are called every time; with cache enabled, identical planner/curator/task-planner requests call the fake completer once, prompt/schema/model changes miss, parse failures are not cached as valid DTOs, and concurrent identical calls share one in-flight load.
- Risk: med
- Seq: SEQ-30

### P4-05 - Experience Ledger Hook Beside Completed Runs

- Files: `/Users/khalidsh/Humain/cascade/Sources/CascadeMemory/AgentExperienceLedger.swift`; `/Users/khalidsh/Humain/cascade/Sources/AppShell/CascadeAppModel.swift`; `/Users/khalidsh/Humain/cascade/Tests/AppShellTests/AgentExperienceIntegrationTests.swift`
- Build: Add a tiny default-off hook beside the existing `markAgentRun` calls in on-screen replay and `recordSandboxCompletion`, for example `cascade.experimentalExperienceLedger`. When enabled and completion is genuine, record `AgentExperienceCase(outcome: .success, verificationSignal: .completed, recipeSignature: agent.signature, evidenceIDs: ...)`; stopped or failed runs stay unrecorded unless a later explicit failure hook is added.
- Test: With the flag false, completed runs only increment `runCount`; with the flag true, on-screen and sandbox completions create one success ledger row; stopped/failed runs create none; reclaimed-time math remains driven solely by `markAgentRun`.
- Risk: med
- Seq: SEQ-15

### P4-06 - Episode/PrefixSpan Waste Detector Alternate Path

- Files: `/Users/khalidsh/Humain/cascade/Sources/WasteDetection/WasteDetector.swift`; `/Users/khalidsh/Humain/cascade/Sources/WasteDetection/ActionEpisodeSegmenter.swift`; `/Users/khalidsh/Humain/cascade/Sources/WasteDetection/PrefixSpanMiner.swift`; `/Users/khalidsh/Humain/cascade/Sources/AgentOrchestrator/AgentOrchestrator.swift`; `/Users/khalidsh/Humain/cascade/Tests/WasteDetectionTests/WasteDetectorEpisodeMiningTests.swift`
- Build: Add `WasteDetector.detect(..., useEpisodeMining: false)` or a separate `detectWithEpisodeMining(...)` helper. The opt-in path segments events into task-shaped episodes, mines gapped patterns with `PrefixSpanMiner`, and converts accepted spans through the existing recipe/waste construction rules. `CascadeOrchestrator.detectedWaste` forwards a default false parameter.
- Test: The default path returns byte-for-byte equivalent candidates to today; the opt-in path recovers interrupted repeated routines that the contiguous miner misses; sensitive/noisy surfaces are still excluded; candidate ordering and signatures are deterministic.
- Risk: med
- Seq: SEQ-08

### P4-07 - Personalization And Next-Action Suggestion Ranking

- Files: `/Users/khalidsh/Humain/cascade/Sources/WasteDetection/SuggestionRanker.swift`; `/Users/khalidsh/Humain/cascade/Sources/WasteDetection/NextActionPredictor.swift`; `/Users/khalidsh/Humain/cascade/Sources/AppShell/CascadeAppModel.swift`; `/Users/khalidsh/Humain/cascade/Tests/WasteDetectionTests/SuggestionRankingIntegrationTests.swift`; `/Users/khalidsh/Humain/cascade/Tests/AppShellTests/CascadeAppModelSuggestionRankingTests.swift`
- Build: Add a pure helper that ranks `DetectedWaste` or `CuratedAgent` keys using `PreferenceModel` and `SuggestionRanker`, plus an optional `NextActionPredictor` proactive-offer decision through `InterruptibilityGate`. In `refreshAll`, call it only when `cascade.experimentalSuggestionRanking` is true; default queue order stays unchanged.
- Test: Default-off refresh preserves current ordering; opt-in ranking promotes accepted keys and demotes declined keys without suppressing candidates; next-action offers require confidence/cooldown/not-typing gates; tie ordering is stable.
- Risk: med
- Seq: SEQ-18/SEQ-20

### P4-08 - Verified Grounding Candidate Selection Helper

- Files: `/Users/khalidsh/Humain/cascade/Sources/AppShell/MixtureGrounder.swift`; `/Users/khalidsh/Humain/cascade/Sources/ProviderKit/GroundingVerifier.swift`; `/Users/khalidsh/Humain/cascade/Sources/ComputerUseKit/AnchorDriftScorer.swift`; `/Users/khalidsh/Humain/cascade/Tests/AppShellTests/MixtureGrounderVerifierTests.swift`
- Build: Add a default-off initializer parameter such as `verifyCandidates: false`. When enabled, convert AX and base-grounder `GroundingResult` candidates into `GroundingVerifierCandidate`s, accept only verifier-approved candidates, and use `AnchorDriftScorer` for previous-anchor comparisons when supplied. Existing `ground(...) -> CGPoint?` behavior remains unchanged when false.
- Test: With verification disabled, the helper returns the legacy selected point; with verification enabled, offscreen/passive/ambiguous candidates abstain or fall back, high-evidence candidates accept, and drift-scored repeated failures select retry/demote outcomes without needing live Accessibility.
- Risk: med
- Seq: SEQ-25/SEQ-29

### P4-09 - Structured Content Metadata And Recall Tool

- Files: `/Users/khalidsh/Humain/cascade/Sources/MacContextKit/ScreenContentStructurer.swift`; `/Users/khalidsh/Humain/cascade/Sources/MacContextKit/StructuredContentExporter.swift`; `/Users/khalidsh/Humain/cascade/Sources/MacContextKit/RewindRecorder.swift`; `/Users/khalidsh/Humain/cascade/Sources/ProviderKit/RecordRecall.swift`; `/Users/khalidsh/Humain/cascade/Tests/MacContextKitTests/RewindStructuredContentTests.swift`; `/Users/khalidsh/Humain/cascade/Tests/ProviderKitTests/RecordRecallStructuredTests.swift`
- Build: Add `ContextRecorder.Options(structuredContent: false)`. When enabled, the recorder uses `recognizeBoxes`, `ScreenContentStructurer.structure(..., topLeftOrigin: false)`, and `StructuredContentExporter.summary/markdownTables` to write bounded structured metadata. Add a `RecordRecall` opt-in tool such as `inspect_structure` that reads only that metadata; default recall tools keep flat OCR behavior.
- Test: Default captures do not add structured metadata; opt-in synthetic boxes produce reading-order, key-value, and table metadata; `inspect_structure` returns bounded markdown/CSV-safe table text for a stored fixture; missing metadata degrades with a clear message.
- Risk: med
- Seq: SEQ-16

### P4-10 - Learned Skill Consolidation In Review UI

- Files: `/Users/khalidsh/Humain/cascade/Sources/ComputerUseKit/SkillConsolidator.swift`; `/Users/khalidsh/Humain/cascade/Sources/AppShell/CascadeAppModel.swift`; `/Users/khalidsh/Humain/cascade/Sources/AppShell/CascadeRootView.swift`; `/Users/khalidsh/Humain/cascade/Tests/AppShellTests/LearnedSkillConsolidationTests.swift`
- Build: Add a default-off `cascade.experimentalSkillConsolidation` path that evaluates a newly drafted `LearnedSkill` against loaded user skills and annotates the review card with `new`, `revise existing`, `archive candidate`, or `quarantine`. Do not mutate existing skill files automatically; approvals continue to write only when the user clicks.
- Test: With the flag false, pending learned skills render and approve exactly as today; with it true, near-duplicate drafts show a revise hint, failure-dominated drafts show quarantine, unrelated drafts remain new, and approval still writes a `SKILL.md` only after the explicit button.
- Risk: med
- Seq: SEQ-15

### P4-11 - RetryBackoff For Pure Model Calls Only

- Files: `/Users/khalidsh/Humain/cascade/Sources/ProviderKit/ActionIdempotency.swift`; `/Users/khalidsh/Humain/cascade/Sources/ProviderKit/AnthropicClient.swift`; `/Users/khalidsh/Humain/cascade/Sources/ProviderKit/Planner.swift`; `/Users/khalidsh/Humain/cascade/Sources/AgentOrchestrator/WorkflowCurator.swift`; `/Users/khalidsh/Humain/cascade/Sources/SandboxKit/AgentTaskPlanner.swift`; `/Users/khalidsh/Humain/cascade/Tests/ProviderKitTests/PureModelRetryTests.swift`
- Build: Add an optional `RetryBackoffPolicy?`, default nil/off, to the same pure planner/curator/task-planner wrapper used by the cache item. Retry only transport/transient failures classified by `ActionIdempotency`; never retry non-idempotent computer actions or file writes.
- Test: A flaky fake completer that fails transiently once then succeeds is retried when policy is enabled; nil policy preserves single-attempt behavior; nontransient errors do not retry; seeded jitter keeps test delays deterministic.
- Risk: low
- Seq: SEQ-30

