# Sequence 08 — Workflow Mining, Learning From Demonstration, and RPA Discovery

## Overview

Cascade is already past the first naive version described in `docs/WASTE_DETECTOR_HARDENING.md`. Current `Sources/WasteDetection/WasteDetector.swift` now uses AX-label-enriched tokens (`token`), noisy-app filtering, repeatable-token noise removal (`keepingRepeatableTokens`), idle-gap session checks (`isWithinOneSession`), variant merging (`mergeVariants`), parameter marking for varying typed positions (`variableTypePositions`), and composite ranking (`rankingScore`). `AgentRecipe` in `Sources/CascadeMemory/CascadeMemory.swift` carries anchored `RecipeStep`s, `targetDescriptor`, `isParameter`, and human-readable labels; `WorkflowCurator` in `Sources/AgentOrchestrator/WorkflowCurator.swift` is the LLM layer that names and prunes deterministic candidates.

The production-grade gap is now narrower and more specific: Cascade still mines exact contiguous sequences from a flat recent event window. The strongest next moves are:

- Segment the continuous input stream into task/routine episodes before mining.
- Mine closed, gap-constrained frequent sequences over those episodes instead of contiguous n-grams.
- Merge variants before the repetition threshold, not only after candidates are emitted.
- Generalize demonstrations into parameterized recipes using target/field identity and dataflow, not only same-index typed text.
- Score candidates by precision and utility: compactness, determinism, replayability, privacy risk, and expected time saved.

The operating principle from robotic process mining holds for Cascade: deterministic mining should propose, count, segment, and score; the LLM curator should only name, explain, and reject a small shortlist.

## OSS Repos & Papers

| Source | URL | License / Availability | Technique | Cascade Use |
|---|---|---:|---|---|
| PM4Py | https://github.com/process-intelligence-solutions/pm4py and https://arxiv.org/abs/1905.06169 | AGPL-3.0 current repo; paper describes architecture | Process mining library with Alpha Miner, Inductive Miner, DFGs, alignments, conformance, precision/generalization/simplicity metrics | Conceptual reference only. Do not import code. Use DFG metrics and process-quality vocabulary for internal candidate diagnostics. |
| ProM / Apromore ecosystem via PM4Py paper | https://arxiv.org/abs/1905.06169 | Mixed academic/open-source tooling | Process discovery, conformance checking, process model evaluation | Reference for separating event objects, algorithms, and visualizations; useful if Cascade later adds an internal "why this routine" graph view. |
| SPMF | https://www.philippe-fournier-viger.com/spmf/ | GPLv3 | Java pattern-mining library with PrefixSpan, BIDE+, GSP, SPADE, MINEPI, episode mining, high-utility patterns | Behavioral oracle and literature map only. No code reuse. Use algorithm names and sample outputs to design Swift tests. |
| Apache Spark PrefixSpan | https://spark.apache.org/docs/latest/ml-frequent-pattern-mining.html | Apache-2.0 | Prefix-projected sequential pattern mining with `minSupport`, `maxPatternLength`, projected DB sizing | Clean implementation reference for a Swift `PrefixSpanMiner`; adapt parameters to `minSupport`, `maxPatternLength`, `maxGapEvents`, `maxSpanSeconds`. |
| Seq2Pat | https://github.com/fidelity/seq2pat | Apache-2.0 | Constraint-based sequential pattern mining with max span, batch mining, gap/span/attribute constraints, MDD backend | Strong reference for Cascade's practical constraints: max span, gap limits, app/surface constraints, and later outcome-aware "accepted vs dismissed" pattern mining. |
| Leno et al., "Identifying Candidate Routines for RPA from Unsegmented UI Logs" | https://arxiv.org/abs/2008.05782 | Paper; open-source tool/datasets referenced | Normalized UI model; context parameters vs data parameters; CFG/back-edge segmentation; candidate selection by frequency, length, coverage, cohesion; LED/Jaccard evaluation | Most directly relevant. Cascade already adopted context/data token separation. Next: CFG/back-edge or episode segmentation before mining, and cohesion with real gap penalties. |
| Leno et al., "Discovering Executable Routine Specifications from UI Logs" | https://arxiv.org/abs/2106.13446 | Paper | Candidate routines -> automatable routine detection -> executable specification synthesis -> semantic-equivalent dedupe | Blueprint for the full Cascade loop after detection: determinism checks, executable recipe spec, non-redundant routine set. |
| Leno et al., "Automated Discovery of Data Transformations for RPA" | https://arxiv.org/abs/2001.01007 | Paper | Data transfer/data transformation discovery by example from UI logs; optimized token handling for alphabetic/numeric copied data | Upgrade `variableTypePositions` into dataflow parameter inference: copy/read value in one app, transform, type/paste in another. |
| Abb & Rehse, "A Reference Data Model for Process-Related UI Logs" | https://arxiv.org/abs/2207.12054 | Paper; XES extension described | Standard UI-log attributes and flexible case notion for task mining/RPA | Validate Cascade's `InputEvent` schema. Add case/episode IDs and richer target/data attributes before serious mining. |
| de Leoni, Khan & Agostinelli, "Accurate and Noise-Tolerant Extraction of Routine Logs in RPA" | https://arxiv.org/abs/2510.08118 | Paper | Clustering-based extraction of routine logs under inconsistent/noisy execution | Larger bet: cluster routine instances first, then mine process models over extracted routine logs. |
| Pegoraro et al., "Uncertain Case Identifiers in Process Mining" | https://arxiv.org/abs/2204.04164 | Paper | Case-correlation for click data when logs lack process-instance IDs | Useful later if Cascade needs learned case IDs beyond heuristic segmentation. |
| OpenAdapt | https://github.com/OpenAdaptAI/OpenAdapt | MIT | Demonstrate -> learn -> execute pipeline; capture actions/screenshots, privacy scrub, retrieval, grounding, evaluation | Good engineering reference for demo libraries, privacy scrubbing, policy/grounding separation, and evaluation loops. |
| WebRobot | https://arxiv.org/abs/2203.09993 | Paper | Interactive PBD for web RPA; trace semantics; speculative rewriting; loop synthesis; user authorizes predicted next actions | Inspiration for generalizing traces into loops and validating by simulated trace before execution. |
| PUMICE | https://arxiv.org/abs/1909.00031 | Paper | Combines natural-language programming with GUI demonstrations; recursively resolves vague concepts and conditionals | Use with Cascade's intentional `curateRange` path: ask for missing parameter/concept labels only when evidence is ambiguous. |
| Privacy-Preserving PBD Script Sharing | https://arxiv.org/abs/2004.08353 | Paper | Detects/obfuscates personal fields in GUI PBD scripts by uniqueness within GUI context | Extend parameter handling and card previews so recipe templates never expose private literal values. |
| UiPath Task Mining | https://docs.uipath.com/task-mining/automation-cloud/latest/user-guide/introduction | Proprietary product docs | Captures mouse clicks, keystrokes, hotkeys; collects variations; merges task graph; exports PDD/XAML automation assets | Product benchmark: Cascade should surface "seen N variations", merge variants, provide editable task graph/dry-run, and preserve consent/privacy controls. |
| Celonis Task Mining | https://docs.celonis.com/en/task-mining.html | Proprietary product docs | Captures software interactions, optional screenshots/web data, app/URL allow/deny lists, redaction/pseudonymization, consent controls | Product benchmark for privacy and governance around task mining. Cascade's local-first recorder is a strong differentiator; keep allow/deny controls visible. |

## Concrete Techniques to Adopt

### 1. Add an action-level episode segmenter before mining

Current mapping:

- `AgentOrchestrator.detectedWaste` fetches 400 contexts and 3000 input events, then calls `WasteDetector.detect`.
- `WasteDetector.detect` sorts a flat stream and rejects windows with a long internal gap, but still mines across the whole stream.
- `SessionSegmenter` groups `RecordedContext` moments by app/gap, but it does not segment `InputEvent`s into routine instances.

Implementable upgrade:

- Add `ActionEpisodeSegmenter` in `Sources/WasteDetection/`.
- Input: sorted `InputEvent`s plus `surface(event)` and optional nearest `RecordedContext`.
- Output: `[ActionEpisode]`, where each episode has `events`, `startedAt`, `endedAt`, `surfaceFlow`, `windowTitles`, `boundaryReasons`.
- Boundaries:
  - Hard boundary: idle gap > 2-3 minutes for input events.
  - Soft boundary: surface/window switch, unless there is dataflow continuity (`copy` then `paste`, same typed value appears, same file/name/date token).
  - Completion-control boundary: click/key label matching `send|save|submit|done|apply|create|export|download|upload|archive|move|confirm|ok`, then split if the next chunk shares no data value or target context.
  - Privacy/noise boundary: meeting apps, fullscreen media, sensitive windows.
- Feed `[[InputEvent]]` into mining, not one flat `[InputEvent]`.

Portable Swift algorithm:

```swift
for event in orderedEvents {
    let gap = event.capturedAt.timeIntervalSince(previous.capturedAt)
    let hard = gap > maxIdleGap
    let completion = previous.map(isCompletionEvent) == true && !sharesData(previousChunk, upcomingPrefix)
    let surfaceShift = surface(event) != surface(previous) && !hasDataBridge(previous, event)
    if hard || completion || surfaceShift { flush(reason) }
    append(event)
}
```

Why it matters:

Leno's UI-log work treats unsegmented logs as the central problem. Cascade should not ask PrefixSpan or n-grams to discover both boundaries and routines at the same time.

### 2. Replace exact contiguous n-grams with closed, gap-constrained sequence mining

Current mapping:

- `WasteDetector.detect`, lines around the longest-first `for length in stride(...)`, builds exact contiguous keys from `tokens[i..<i+length]`.
- `keepingRepeatableTokens` removes one-off interruptions, but that is still a pre-filter workaround rather than true gapped mining.

Implementable upgrade:

- Add `PrefixSpanMiner.swift` with:
  - `TokenID` integer compression.
  - `SequenceDB = [[TokenID]]`, one sequence per `ActionEpisode`.
  - Projected DB entries `(sequenceIndex, nextPosition, lastMatchedPosition, startedAt, endedAt)`.
  - `minSupportCount = 2` for recall, promotion threshold remains 3 in `CascadeAppModel`.
  - `maxPatternLength = 8` initially to match current product behavior.
  - `maxGapEvents = 2...4` and `maxGapSeconds = 60...120` to tolerate small interruptions but reject loose habits.
  - `maxSpanSeconds` to preserve compact routines.
- Mine subsequences, then filter to closed patterns:
  - Simple first pass: after candidates are generated, remove candidate `p` if a supersequence `q` has the same support and similar occurrence spans.
  - Later: BIDE-style back-scan pruning.
- Count non-overlapping occurrences from projected positions before building `DetectedWaste`.
- Pass occurrence event arrays into current `makeWaste(instance:occurrences:contexts:surface:allOccurrences:)` so parameter detection keeps working.

Why closed patterns:

Closed sequences avoid surfacing every fragment of a longer routine. This directly attacks "click Save" and "type -> click Submit" clutter without losing support counts.

### 3. Merge variants before the repetition bar

Current mapping:

- `mergeVariants(_:)` currently runs after `DetectedWaste` candidates exist.
- `CascadeAppModel.meetsRepetitionBar` still requires `waste.occurrences >= 3`.

Problem:

If a real routine occurs as two variants with support 2 + 1, neither variant becomes a high-value candidate early enough. Merging after candidate construction helps dedupe the feed, but it does not fully rescue split support.

Implementable upgrade:

- Introduce a `RoutineCandidate` layer before `DetectedWaste`:
  - `patternTokens`
  - `occurrences: [[InputEvent]]`
  - `support`
  - `coverage`
  - `medianGap`
  - `surfaces`
- Cluster candidates by normalized Levenshtein/Jaccard over token sequences at threshold 0.70-0.85.
- Sum support and evidence across cluster before promotion.
- Choose representative by medoid/longest cohesive pattern, not just longest signature.
- Keep `WasteDetector.mergeVariants` as a final UI dedupe pass.

Portable Swift:

- Reuse current `levenshtein(_:_:)`.
- Add `isSubsequence` and weighted Jaccard over token multiset.
- Single-link clustering is enough for <= hundreds of candidates; switch to locality-sensitive hashing only if needed.

### 4. Upgrade parameter detection from same-position typing to dataflow placeholders

Current mapping:

- `RecipeStep.isParameter` is a Boolean.
- `variableTypePositions(_:)` only marks a parameter when every occurrence has `.type` at the same index and values differ.
- `WorkflowCurator.userPrompt` only reports a count of changing values.

Implementable upgrade:

- Extend `RecipeStep` or add sidecar metadata:
  - `parameterKey`: stable field/target name (`invoice_number`, `candidate_name`, `date`)
  - `parameterKind`: `date`, `currency`, `number`, `email`, `url`, `personName`, `freeText`, `filePath`
  - `valueExamples`: privacy-filtered examples or shape-only examples
  - `sourceStepIDs`: steps where the value was selected/copied/read
  - `transform`: `trim`, `uppercase`, `split`, `join`, `dateFormat`, `numericNormalize`
- Detect parameters by target identity first:
  - Same `targetDescriptor` or same normalized AX/OCR label across occurrences.
  - Type values differ under that field.
- Detect cross-app dataflow:
  - Value copied/selected in app A appears typed/pasted in app B.
  - Use token normalization: trim, collapse whitespace, lower, strip punctuation, classify numeric/date/email.
  - For privacy, store shape and hashes alongside examples; do not display raw values in cards.
- Curator prompt should say: `parameter: "Invoice number" changes each run; copied from Mail, entered into Numbers`.

Why it matters:

This is the step from replaying traces to automating work. A workflow that fills a different order number each time is only useful if the agent knows that value is a parameter, not recorded text.

### 5. Add precision/utility scoring before the curator

Current mapping:

- `rankingScore` uses ROI, length, recency, and cross-app copy/paste.
- `isAutomatableInstance` requires >=2 structural actions plus an intent marker.
- `WorkflowCurator` receives already-shortlisted candidates and can drop low-value ones, but fallback keeps all candidates.

Implementable upgrade:

Add `RoutineQuality` computed in `WasteDetector`:

- `supportScore`: support after variant clustering.
- `compactnessScore`: `1 / (1 + medianGapSeconds / 30 + spanSeconds / 300)`.
- `determinismScore`: anchored clicks + shortcuts + stable target descriptors divided by meaningful steps.
- `parameterScore`: values vary in recognized fields/dataflow, not arbitrary text.
- `replayabilityScore`: app has AX targets, browser sandbox support, or skill coverage.
- `privacyPenalty`: sensitive labels, free-text bodies, protected apps/URLs.
- `interruptionPenalty`: meeting/media/chat noise, high idle variance, user cancellation.
- `utilityScore`: observed seconds/week, recurrence recency, manual error-prone data transfer boost.

Suggested formula:

```swift
score =
  utilityScore
  * compactnessScore
  * determinismScore
  * replayabilityScore
  * (1.0 + 0.25 * parameterScore)
  * (1.0 - privacyPenalty)
  * (1.0 - interruptionPenalty)
```

Promotion rule:

- Auto-review only if `support >= 3`, `score >= threshold`, `determinismScore >= 0.55`, `privacyPenalty < 0.4`.
- Keep lower-confidence candidates in a passive "More patterns observed" area, not the main agent queue.

### 6. Use directly-follows graphs for explanation and boundaries, not for full automation yet

Current mapping:

- Cascade has human labels and evidence images, but no compact graph summary of a routine.

Implementable upgrade:

- Build a small DFG per clustered routine from occurrence traces:
  - nodes = normalized tokens/human labels
  - edges = directly-follows counts
  - start/end node counts
  - edge confidence = edgeCount / support
- Use it to:
  - choose likely start/end events;
  - display "core path" vs optional variant steps;
  - detect loops and repeated subloops;
  - feed the curator with stable/optional step summaries.

Avoid full BPMN/Petri-net synthesis for now. It is overkill for the macOS agent wedge; DFG counts are enough for precision and trust.

### 7. Add an offline evaluation harness for mined routines

Current mapping:

- Tests exist for `WasteDetector`, `WorkflowCurator`, and `SessionSegmenter`.

Implementable upgrade:

- Add fixture UI logs with ground truth routines:
  - exact repeat;
  - repeat with one noisy event;
  - two variants that should merge;
  - repeated typing/editing that should not surface;
  - cross-app copy/paste with changing values;
  - meeting/chat noise.
- Metrics:
  - `precision@K` for review queue.
  - `recallKnownRoutines` for fixture routines.
  - normalized Levenshtein distance from ground-truth trace.
  - Jaccard over action sets for variant-tolerant matching.
  - accepted/dismissed feedback rate once product data exists.
  - dry-run replay success when available.

## Quick Wins vs Larger Bets

### Quick Wins

1. **ActionEpisodeSegmenter**: split input events by idle gap, surface/window switch, completion labels, and dataflow continuity before `WasteDetector.detect` mines tokens.
2. **Pre-threshold variant aggregation**: add a `RoutineCandidate` phase and cluster by edit distance before applying `minRepeatsToAutomate`.
3. **Real cohesion penalty**: update `rankingScore` to penalize median inter-step gap and span once occurrence spans are tracked.
4. **Parameter-by-target detection**: extend `variableTypePositions` to align varying `.type` values by `targetDescriptor` / AX label, not only array index.
5. **Review queue cap + diversity**: after curation, apply MMR-style diversity by signature similarity and show only the top 3-5 high-utility routines.
6. **Dry-run preview text**: for each candidate, summarize "what Cascade would have done in the last N occurrences" from evidence and human labels.

### Larger Bets

1. **Swift PrefixSpan + closed sequence filter**: replace exact n-grams with gap-constrained frequent subsequence mining.
2. **Routine-log extraction by clustering**: cluster noisy executions into routine logs before mining models, following the newer noise-tolerant routine-extraction line.
3. **Parameterized recipe model**: replace Boolean `isParameter` with typed parameter definitions, source/destination links, and transformations.
4. **Trace semantics / speculative rewriting**: generalize repeated slices into loops and validate by simulated trace before any live replay.
5. **User-feedback learning**: use accepted/dismissed/edited routines as labels for a lightweight ranking model or ruleset, keeping deterministic gates in front.
6. **DFG-backed UI**: show core path, optional branches, and variants in the agent review detail for trust and editability.

## License / Attribution

- **Do not import PM4Py or SPMF code** into Cascade. PM4Py is currently AGPL-3.0 and SPMF is GPLv3. Use them as algorithm references and test oracles only.
- **Apache-2.0 references** such as Spark PrefixSpan and Seq2Pat are safer for implementation study, but a Swift implementation should still be original and attributed if directly inspired.
- **MIT references** such as OpenAdapt are safe to study for architecture patterns, but Cascade should not copy code without adding attribution to `docs/THIRD_PARTY_NOTICES.md`.
- **Papers** can be implemented from the published algorithms/formulas, with citation in this research doc and future implementation comments only where useful.
- **Vendor task-mining docs** from UiPath and Celonis are proprietary product references. Use them for product expectations, privacy posture, and UX benchmarks, not implementation details.

## Proposed Implementation Order

1. Add `ActionEpisodeSegmenter` and route `WasteDetector.detect` through episodes.
2. Introduce `RoutineCandidate` so support, spans, gaps, and variant clusters exist before `DetectedWaste`.
3. Move variant aggregation before the review threshold and add cohesion/precision scoring.
4. Extend parameter detection by target identity and cross-app dataflow.
5. Port a small, bounded PrefixSpan miner with closed-pattern filtering.
6. Add DFG summaries and dry-run previews for review cards.
7. Evaluate against ground-truth fixture logs and acceptance/dismissal telemetry.
