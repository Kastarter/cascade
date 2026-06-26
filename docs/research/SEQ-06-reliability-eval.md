# SEQ-06 - Agent Reliability, Evaluation Harnesses, Self-Healing Replay, Verification

## Overview

Cascade already has several production-grade replay safeguards: recipe replay starts with a frontmost-app state gate, pauses on unexpected modals, resolves targets through AX descriptors before OCR/vision/recorded coordinates, verifies click effects with UI fingerprints, escalates after repeated unverified clicks, and refuses stale live-value typing steps. Assist and background-web paths also have stall/no-effect detection and completion verification.

The missing layer is measurement. Current tests cover many primitives (`AXElementResolver`, action gates, no-effect detection, Scout safe batches, recipe action mapping, web transport failures), but there is no end-to-end reliability eval harness that can answer: "What percent of replay/assist tasks succeed, why did failures happen, and did this change improve the rate?"

The research consensus is clear:

- Benchmarks such as OSWorld, WindowsAgentArena, WebArena, VisualWebArena, AndroidWorld, and BrowserGym use executable tasks, deterministic environments, trajectories, and explicit success checks.
- Self-reflection alone is weak; verifier-grounded repair, state assertions, and external reward/check functions are stronger.
- RPA self-healing systems keep multiple locators and repair by similarity/ranked fallback, not by one brittle selector.
- LLM-as-judge trajectory evaluation is useful, but must be calibrated and audited against expert/rule checks because judges miss side effects and repeated/no-op behavior.
- Confidence should be tracked as an empirical metric, not trusted as a model feeling.

## OSS Repos & Papers

| Work | URL | License / reuse note | Technique | What it measures |
|---|---|---:|---|---|
| OSWorld | [GitHub](https://github.com/xlang-ai/OSWorld), [paper](https://arxiv.org/abs/2404.07972) | Apache-2.0 | VM desktop tasks with setup configs, screenshots/actions/video, custom execution evaluators, per-domain reporting. | Desktop task success rate, domain/category success, trajectory evidence. |
| WindowsAgentArena | [GitHub](https://github.com/microsoft/WindowsAgentArena), [paper](https://arxiv.org/abs/2409.08264) | MIT | Parallel Windows desktop benchmark with Azure orchestration and realistic OS tasks. | Windows GUI task success, agent-vs-human gap, scale/latency. |
| WebArena | [GitHub](https://github.com/web-arena-x/webarena), [paper](https://arxiv.org/abs/2307.13854) | Apache-2.0 | Self-hosted reproducible web apps with functional correctness checks. | Web task success against executable goals. |
| VisualWebArena | [GitHub](https://github.com/web-arena-x/visualwebarena), [paper](https://arxiv.org/abs/2401.13649) | MIT | WebArena-style tasks requiring visual grounding; releases GPT-4V+SoM trajectories. | Multimodal web task success and visual grounding failures. |
| AndroidWorld | [GitHub](https://github.com/google-research/android_world), [paper](https://arxiv.org/abs/2405.14573) | Apache-2.0 | Live Android emulator, 116 hand-authored tasks, dynamic parameters, durable reward signals. | Mobile GUI success/reward across apps and parameter variations. |
| AgentBench | [GitHub](https://github.com/THUDM/AgentBench), [paper](https://arxiv.org/abs/2308.03688) | Apache-2.0 | Multi-environment benchmark: OS interaction, web shopping, DB, KG, ALFWorld. | Multi-turn agent reasoning and decision-making success/failures. |
| GAIA | [Dataset](https://huggingface.co/datasets/gaia-benchmark/GAIA), [paper](https://arxiv.org/abs/2311.12983) | Gated dataset, contamination restrictions | Real-world assistant questions with unambiguous answers and tool use. | Final answer accuracy across 3 difficulty levels. |
| BrowserGym / AgentLab | [BrowserGym](https://github.com/ServiceNow/BrowserGym), [AgentLab](https://github.com/ServiceNow/AgentLab) | Apache-2.0 | Gym-style browser task loop with `obs, reward, terminated, truncated`; trace collection/analysis. | Web-agent reward, termination, trajectory diagnostics. |
| AgentRewardBench | [site](https://agent-reward-bench.github.io/), [paper](https://arxiv.org/abs/2504.08942) | License unclear, verify before code reuse | Expert-reviewed 1,302 agent trajectories; evaluates LLM judges for success, side effects, repetitiveness. | Judge accuracy for trajectory-level outcomes and failure modes. |
| DiagEval | [paper](https://arxiv.org/abs/2605.17439), [GitHub](https://github.com/scutGit/DiagEval) | License not verified | Post-failure diagnostic probes reuse failed trajectory to distinguish evaluator false negatives from true failures. | False-negative recovery and trajectory evaluator accuracy. |
| Healenium | [GitHub](https://github.com/healenium/healenium) | Apache-2.0 | Selenium proxy stores selectors, detects broken locators, heals by backend/imitator similarity, reports healing. | Selector repair rate and test pass recovery. |
| Erratum | [paper](https://arxiv.org/abs/2106.04916) | Paper/design | Repairs broken web locators with flexible tree matching after DOM changes. | Locator repair accuracy after UI evolution. |
| Similo | [paper](https://arxiv.org/abs/2208.00677) | Paper/design | Weighted similarity across locator attributes to rediscover elements. | Robust element localization under DOM/layout churn. |
| Reflexion | [GitHub](https://github.com/noahshinn/reflexion), [paper](https://arxiv.org/abs/2303.11366) | MIT | Verbal reflection from explicit task feedback stored in episodic memory for later attempts. | Pass rate improvement across trials when feedback is reliable. |
| NeMo Guardrails | [GitHub](https://github.com/NVIDIA-NeMo/Guardrails) | Apache-2.0 components | Programmable input, dialog, retrieval, execution, and output rails. | Policy conformance and blocked unsafe flows. |
| Guardrails AI | [GitHub](https://github.com/guardrails-ai/guardrails) | Apache-2.0 | Validators and structured input/output guards for LLM apps. | Schema validity, risk detection, mitigation outcomes. |
| Agentic Confidence Calibration | [paper](https://arxiv.org/abs/2601.15778) | Paper/design | Holistic Trajectory Calibration extracts macro/micro trajectory features and fits interpretable calibrators. | Expected calibration error, failure discrimination, confidence reliability. |
| Uncertainty in Action | [paper](https://arxiv.org/abs/2503.10628) | Paper/design | Confidence elicitation policies for embodied agents under inductive/deductive/abductive uncertainty. | Whether confidence tracks actual GUI success. |

## Concrete Techniques to Adopt

### 1. Add an offline reliability benchmark, not just more unit tests

Map to:

- `Tests/AgentOrchestratorTests/`
- `Tests/AppShellTests/`
- `Tests/SandboxKitTests/`
- new `Tests/ReliabilityEvalTests/`
- eventual extracted `Sources/AgentOrchestrator/RecipeReplayRunner.swift`

Adopt the OSWorld/WebArena pattern at Cascade scale: executable scenario fixtures, deterministic setup, a trajectory log, and explicit success checks. Start offline with fake state machines so CI can run the suite without Screen Recording, Accessibility, or live apps.

Each fixture should declare:

- `id`, `surface`: `recipeReplay`, `assist`, or `backgroundWeb`
- `goal`
- `initialState`: frontmost app/window, AX tree, OCR boxes, fingerprint, optional modal, optional DOM text
- `recipe` or mocked planner steps
- `expectedActions`
- `assertions`: visible text, target exists, fingerprint changed, modal absent/present, completion verifier result
- `allowedFailureKinds`

### 2. Convert replay verification into per-step assertions

Map to:

- `Sources/AppShell/CascadeAppModel.swift` around `runAgentRecipe`
- `Sources/CascadeMemory/CascadeMemory.swift` `RecipeStep`
- `Tests/AgentOrchestratorTests/RecipeReplayEvalTests.swift`

Cascade already checks a generic UI fingerprint after clicks. Add explicit expected effects:

- `frontmostApp(bundleOrName)`
- `elementVisible(label/role/container)`
- `textVisible(string)`
- `windowTitleContains(string)`
- `fingerprintChanged(regionOrGlobal)`
- `urlContains(string)` for sandbox
- `noUnexpectedModal`
- `artifactExists(path)` for harness-created files

These can live as eval sidecars first, then become optional `RecipeStep.expectedEffect` once stable.

### 3. Add a structured failure taxonomy

Map to:

- `Sources/AgentOrchestrator/`
- `Sources/AppShell/CascadeAppModel.swift`
- `Sources/CascadeMemory/CascadeMemory.swift` audit metadata
- `Tests/AppShellTests/NoEffectDetectionTests.swift`
- `Tests/SandboxKitTests/BackgroundWebAgentTests.swift`

Create `AgentFailureKind` and emit it in audit JSON plus eval JSONL:

- `wrongStartState`
- `permissionMissing`
- `secureInput`
- `targetNotFound`
- `groundingMiss`
- `noEffect`
- `staleFrameBatch`
- `unexpectedModal`
- `verificationUnavailable`
- `validatorIncomplete`
- `transportFailure`
- `unsafeActionRefused`
- `parameterNeedsLiveValue`
- `stepLimit`
- `timeout`
- `userStop`
- `artifactWrongLane`

Existing audit events already map naturally: `recipe.pause.wrongstate`, `recipe.pause.modal`, `recipe.unverified`, `assist.stalled`, `assist.noeffect`, `sandbox.verify`, `agent.action.refused`, `agent.ground.miss`.

### 4. Use verifier-grounded Reflexion memory

Map to:

- `Sources/CascadeMemory/`
- `Sources/ProviderKit/AssistMemory.swift`
- `Sources/AppShell/CascadeAppModel.swift`
- `Tests/ProviderKitTests/AssistMemoryTests.swift` or new `FailureMemoryTests.swift`

Reflexion works when feedback is external and explicit. Do not store free-form "the model thinks it failed" notes. Store compact failure memories only when a verifier/assertion/audit event proves the failure:

```json
{
  "app": "Microsoft Word",
  "goalPattern": "create document then highlight text",
  "failureKind": "noEffect",
  "stateSummary": "frontmost Word, blank document, target text absent",
  "repairHint": "verify document text exists before issuing highlight command",
  "lastSeenAt": "2026-06-26T..."
}
```

Inject memories only on matching `(app, failureKind, goalPattern)` and expire or down-rank stale ones.

### 5. Replace hard-coded retry behavior with a recovery policy table

Map to:

- `Sources/AgentOrchestrator/AgentRecoveryPolicy.swift`
- `Sources/AppShell/CascadeAppModel.swift` assist/replay loops
- `Tests/AgentOrchestratorTests/AgentRecoveryPolicyTests.swift`

Recommended policy:

| Failure | First retry | Second retry | Terminal action |
|---|---|---|---|
| `targetNotFound` | Re-harvest AX and re-rank descriptors | OCR/vision re-ground | Escalate to assist or pause |
| `groundingMiss` | Try next ranked AX candidate | Try OCR/vision candidate | Pause with evidence |
| `noEffect` | Late-render recapture | Alternate target/action if available | Escalate |
| `unexpectedModal` | Known safe dismiss only | None | Pause for user |
| `validatorIncomplete` | Targeted diagnostic probe | Re-run verifier with focused evidence | Fail with reason |
| `transportFailure` | Exponential backoff + jitter | One retry | Fail, never mark complete |
| `unsafeActionRefused` | None | None | Refuse with audit |

### 6. Calibrate confidence from outcomes

Map to:

- `Sources/CascadeMemory/` metrics/audit tables
- `Sources/ProviderKit/ComputerUseAgent.swift`
- reliability eval JSONL

If a planner/verifier emits confidence, bucket it and compare against actual eval outcomes. Track ECE/Brier-style metrics later; for now, emit bucketed rates:

- `confidence_bucket`: `0.0-0.2`, `0.2-0.4`, etc.
- `actual_success`
- `surface`
- `failureKind`

Do not expose high-confidence UI unless the historical bucket is actually reliable.

## Eval Harness Design for Cascade

Build this now as an offline XCTest-backed harness.

### Proposed files

- `Tests/ReliabilityEvalTests/ReplayScenario.swift`
- `Tests/ReliabilityEvalTests/ReplayScenarioRunner.swift`
- `Tests/ReliabilityEvalTests/ReplayScenarioFixtures.swift`
- `Tests/ReliabilityEvalTests/RecipeReplayReliabilityTests.swift`
- `Tests/ReliabilityEvalTests/AssistReliabilityTests.swift`
- `Tests/ReliabilityEvalTests/BackgroundWebReliabilityTests.swift`
- `Tests/Fixtures/Reliability/*.json`
- optional extraction: `Sources/AgentOrchestrator/RecipeReplayRunner.swift`
- optional extraction: `Sources/AgentOrchestrator/AgentRecoveryPolicy.swift`

### Minimal fixture schema

```json
{
  "id": "word-highlight-text-001",
  "surface": "recipeReplay",
  "goal": "Open Word document, select the title, apply highlight",
  "initialState": {
    "frontmostApp": "Microsoft Word",
    "windowTitle": "Cascade Demo",
    "axElements": [
      {
        "label": "Cascade Demo",
        "role": "AXStaticText",
        "frame": [120, 140, 320, 40],
        "container": "document"
      }
    ],
    "ocrLines": [
      {
        "text": "Cascade Demo",
        "rect": [0.12, 0.18, 0.20, 0.03]
      }
    ],
    "fingerprint": "aabbcc"
  },
  "recipe": [
    {
      "kind": "click",
      "target": {
        "label": "Cascade Demo",
        "role": "AXStaticText",
        "container": "document"
      }
    },
    {
      "kind": "hotkey",
      "keys": ["cmd", "shift", "h"]
    }
  ],
  "assertions": [
    { "afterStep": 1, "type": "targetResolvedTier", "value": "ax" },
    { "afterStep": 1, "type": "fingerprintChanged", "value": true },
    { "afterStep": 2, "type": "textHighlighted", "value": "Cascade Demo" }
  ]
}
```

### Runner shape

The runner should be deterministic and no-permission:

1. Load fixture.
2. Build `FakeStateProbe` from frontmost app, AX tree, OCR boxes, DOM text, modal state, fingerprints.
3. Build `FakeComputerUseActuator` that records actions and mutates fixture state through a tiny reducer.
4. Run one of:
   - pure `AgentAction(recipeStep:)` mapping and target resolution,
   - extracted `RecipeReplayRunner`,
   - `BackgroundWebAgent` with fake transport,
   - assist loop with scripted `CUStep` responses.
5. Evaluate assertions after every step.
6. Write JSONL result to `.build/reliability-eval/results.jsonl`.
7. Assert suite-level budgets in XCTest.

### First 12 scenarios

Start with a small suite that exercises known high-risk paths:

1. AX label moved but still present.
2. AX label changed, OCR still matches.
3. OCR noisy, vision fallback required.
4. Wrong frontmost app blocks replay.
5. Unexpected modal pauses replay.
6. Click no-effect triggers retry then escalation.
7. Parameter `.type` step refuses stale typed value.
8. Unsafe irreversible combo is refused.
9. Background web transport failure is not success.
10. Background web verifier says incomplete and fails.
11. Assist returns no actions twice and trips stall guard.
12. Scout batch drops unsafe suffix and keeps safe prefix.

### Metrics emitted per run

- `scenario_id`
- `surface`
- `status`: `success`, `failed`, `escalated`, `refused`, `userStop`
- `failure_kind`
- `steps_attempted`
- `actions_posted`
- `target_tiers`: counts for `ax`, `ocr`, `vision`, `recorded`
- `retries`
- `modal_pauses`
- `no_effect_count`
- `verification_failures`
- `validator_incomplete`
- `model_turns`
- `tokens_in`, `tokens_out`, `cache_read`, `estimated_cost_usd` when live model calls are enabled
- `wall_ms`, `model_ms`, `action_ms`

### Success thresholds

Use budgets so reliability becomes a regression gate:

- Offline replay smoke: `success_rate >= 0.90`
- Safety scenarios: `unsafe_refusal_rate == 1.0`
- Transport failures: `false_completion_rate == 0.0`
- Modal scenarios: `pause_rate == 1.0`
- No-effect scenarios: `escalation_or_recovery_rate == 1.0`

Live/manual eval can be a second tier gated behind explicit local permissions and a real demo fixture directory.

## Quick Wins vs Larger Bets

### Quick wins

- Add `AgentFailureKind` and emit it in existing audit metadata.
- Add offline JSONL metrics for replay/assist/background-web tests.
- Add `ReliabilityEvalTests` with 12 deterministic scenarios above.
- Add per-step assertion sidecars without changing `RecipeStep` schema yet.
- Add tests that verify `wrongStartState`, `unexpectedModal`, `noEffect`, `validatorIncomplete`, and `unsafeActionRefused` produce distinct failure kinds.
- Add a small command or test flag that prints aggregate success rate by surface and failure kind.

### Larger bets

- Extract `RecipeReplayRunner` from `CascadeAppModel` so replay is testable outside the UI model.
- Add verifier-grounded failure memory with expiry and app/goal matching.
- Add `AgentRecoveryPolicy` with typed retry budgets and diagnostic probes.
- Add live eval tier using `scripts/demo-setup.sh` fixtures plus opt-in macOS permissions.
- Add confidence calibration dashboards once enough eval/live outcomes exist.
- Add trajectory judge comparisons only after rule/check-function ground truth exists; judge-only scoring should not be the primary reliability number.
