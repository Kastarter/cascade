# SEQ-25 - Test-Time Verification and Self-Consistency for Agents

Date: 2026-06-26

## Overview

Cascade already has the right architectural base for test-time verification: structural target tools in `ProviderKit/ComputerUseAgent.swift`, a mixed AX/OCR/visual grounder in `AppShell/MixtureGrounder.swift`, no-effect checks and completion validators in `AppShell/CascadeAppModel.swift` and `SandboxKit/BackgroundWebAgent.swift`, plus typed failure/recovery in `AgentOrchestrator/AgentFailureKind.swift` and `AgentOrchestrator/AgentRecoveryPolicy.swift`.

The next optimization is to move from binary fallback behavior to calibrated verifier decisions at inference time. The goal is not another advisory tool. The goal is runtime-owned verification that the planner cannot ignore: rank multiple grounding candidates before a click, run a cheap pre-action verifier before high-risk actions, use majority vote only when uncertainty is high, and feed verifier outcomes into the existing `AgentFailureKind` / `AgentRecoveryPolicy` ladder.

The practical Cascade pattern is:

1. Generate or collect multiple candidates only at uncertainty points.
2. Verify candidates against independent evidence: AX role/label, OCR text, visual point/box, pre/post UI diff, and risk metadata.
3. Execute only when confidence clears a calibrated threshold.
4. Abstain, re-ground, escalate, or pause through the existing recovery policy when confidence is low.

## OSS Repos & Papers

| name | url | stars/venue | license | technique |
| --- | --- | --- | --- | --- |
| Microsoft AutoGen | https://github.com/microsoft/autogen | 59.3k stars, GitHub checked 2026-06-26 | MIT for code, CC-BY-4.0 for docs | Multi-agent critic/reviewer pattern: separate planner, specialist, and reviewer agents; useful as a design reference for a verifier actor that returns structured pass/fail/rationale rather than free-form advice. |
| LangGraph | https://github.com/langchain-ai/langgraph | 35.8k stars, GitHub checked 2026-06-26 | MIT | Stateful graph execution with explicit conditional edges, durable state, and human-in-the-loop interrupts; map verifier verdicts to deterministic graph transitions instead of prompt-only retry logic. |
| DSPy | https://github.com/stanfordnlp/dspy | 35.4k stars, GitHub checked 2026-06-26; DSPy paper ICLR 2024 | MIT | Declarative metrics/assertions optimize prompts and runtime constraints; relevant for compiling verifier prompts against Cascade trace/eval data. |
| promptfoo | https://github.com/promptfoo/promptfoo | 22.6k stars, GitHub checked 2026-06-26 | MIT | Local eval matrix for prompts, agents, and RAG; useful for regression-testing verifier prompts and calibrating confidence thresholds from recorded agent traces. |
| OpenAI Evals | https://github.com/openai/evals | 18.8k stars, GitHub checked 2026-06-26 | MIT-style repository license noted in README disclaimer | Custom eval/completion-function protocol; useful model for an offline `VerifierEvalRunner` over Cascade action traces, not for runtime dependency. |
| DeepEval | https://github.com/confident-ai/deepeval | 16.5k stars, GitHub checked 2026-06-26 | Apache-2.0 | G-Eval, DAG custom metrics, trace evaluation; useful for designing multi-criterion verifier scorecards: grounding, precondition, effect, safety, and completion. |
| Guardrails AI | https://github.com/guardrails-ai/guardrails | 7.1k stars, GitHub checked 2026-06-26 | Apache-2.0 | Validators plus fail actions/re-asking; portable idea is typed verifier schemas and fail actions, not the Python runtime. |
| PRM800K | https://github.com/openai/prm800k | 2.1k stars, archived 2026-05-29; dataset for `Let's Verify Step by Step` | MIT | Step-level correctness labels and best-of-N PRM evaluation; map to Cascade step-level labels: correct target, wrong target, no effect, stale frame, unsafe, verifier unavailable. |
| ThinkPRM | https://github.com/mukhal/thinkprm | 89 stars; `Process Reward Models That Think`, TMLR/arXiv 2025 | No license shown on GitHub page; treat as paper/reference only unless license is clarified | Generative process verifier with parallel/sequential verifier compute; use as design inspiration for a textual `ActionVerifier` that explains and scores each candidate action. |
| Self-Consistency Improves Chain of Thought Reasoning | https://arxiv.org/abs/2203.11171 | ICLR 2023 | Paper | Sample diverse reasoning paths and marginalize/vote over answers; for Cascade, vote over target candidates or precondition verdicts only when ambiguity is detected. |
| Training Verifiers to Solve Math Word Problems | https://arxiv.org/abs/2110.14168 | arXiv 2021 | Paper | Generate many candidates and select by verifier score; Cascade analogue: generate N grounding candidates from AX/OCR/visual/semantic variants, then select one by a verifier score. |
| Let's Verify Step by Step | https://arxiv.org/abs/2305.20050 | arXiv 2023; released PRM800K | Paper/dataset | Process supervision outperforms outcome-only supervision; Cascade should verify action steps, not just final `DONE`. |
| Generative Verifiers: Reward Modeling as Next-Token Prediction | https://arxiv.org/abs/2408.15240 | arXiv 2024 | Paper | Generative verifier outputs rationales/scores and can use majority voting for verification; portable as small structured verifier prompts over screenshots/OCR/AX summaries. |
| Process Reward Models That Think | https://arxiv.org/abs/2504.16828 | TMLR/arXiv 2025 | Paper | Long-CoT generative PRMs outperform LLM-as-judge and discriminative PRMs under best-of-N; for Cascade, use longer verifier compute only on high-risk or repeatedly failing steps. |
| Verifiable Process Rewards for Agentic Reasoning | https://arxiv.org/abs/2605.10325 | arXiv 2026 | Paper | Dense turn-level rewards from objective oracles; Cascade already has objective oracles: AX fingerprint, OCR diff, page text diff, audit failure kind, and STOP/safety gates. |
| Judging LLM-as-a-Judge with MT-Bench and Chatbot Arena | https://arxiv.org/abs/2306.05685 | NeurIPS 2023 / arXiv | Paper | Strong LLM judges can approximate humans but have position, verbosity, and self-enhancement bias; Cascade verifier prompts should use shuffled candidates, terse schemas, and not trust same-model self-ratings for risky actions. |
| SelfCheckGPT | https://arxiv.org/abs/2303.08896 | EMNLP 2023 / arXiv | Paper | Black-box sampling detects uncertainty via disagreement; Cascade analogue: disagreement between AX, OCR, visual grounder, and planner wording is a confidence signal. |
| Tree of Thoughts | https://arxiv.org/abs/2305.10601 | NeurIPS 2023 / arXiv | Paper | Search over intermediate decisions with self-evaluation and backtracking; use narrowly for target choice or recovery choice, not full task planning. |
| Reflexion | https://arxiv.org/abs/2303.11366 | NeurIPS 2023 / arXiv | Paper | Store verbal feedback from failures for future attempts; Cascade should store verifier-labelled failure memories by `AgentFailureKind` and app/target signature. |
| Self-Refine | https://arxiv.org/abs/2303.17651 | NeurIPS 2023 / arXiv | Paper | Iterative feedback/refinement without training; useful for verifier-driven re-description after a miss: refine target description once, then re-ground. |

## Concrete Techniques to Adopt

- Add a typed grounding result instead of `CGPoint?` only.
  - File/function: `Sources/ProviderKit/VisualGrounder.swift`, `VisualGrounder.ground(...)` and implementations in `ClaudeVisualGrounder`, `UITARSGrounder`, plus `Sources/AppShell/MixtureGrounder.swift`.
  - Change: introduce `GroundingCandidate { point, source, score, evidence, rect?, role?, label?, targetText }` and `GroundingVerdict { selected, candidates, confidence, reason }`. Keep the existing `CGPoint?` API as a compatibility wrapper at first. This unlocks verifier/ranking without changing every callsite in one patch.

- Implement best-of-N grounding only when ambiguity is present.
  - File/function: `Sources/AppShell/MixtureGrounder.swift`, `ground(...)`, `axGround(...)`, `ocrTextRegion(...)`; `Sources/ProviderKit/ComputerUseAgent.swift`, `groundCached(...)`, `pregroundTargets(...)`.
  - Change: collect candidate points from AX, OCR text boxes, visual grounder, and optional paraphrased target names. Run N only when there are competing candidates within a small screen radius, generic target names (`button`, `field`, `submit`, `next`), prior `agent.ground.miss`, or target/source disagreement. Default remains single-pass for latency.

- Add a `GroundingVerifier` that scores candidates using independent evidence.
  - File/function: new `Sources/ProviderKit/GroundingVerifier.swift`; call from `MixtureGrounder.ground(...)` before returning a point.
  - Change: deterministic first: role is actionable, on active display, label similarity, OCR proximity, canvas-skip rules, and target words present near candidate. LLM/VLM verifier second only if deterministic score is in a gray band. Output schema: `{verdict: accept|reject|abstain, confidence: 0...1, failureKind?: groundingMiss|targetNotFound, reason}`.

- Use majority vote over verifier outputs, not planner outputs.
  - File/function: `ComputerUseAgent.pregroundTargets(in:)` and `MixtureGrounder.ground(...)`.
  - Change: if AX/OCR/visual produce different candidates, ask 3 cheap verifier prompts over the candidate list with randomized order and aggregate by point cluster. This applies the Self-Consistency and GenRM lesson while avoiding full multi-planner sampling.

- Add a pre-action verifier before high-risk actions.
  - File/function: `Sources/ProviderKit/ComputerUseAgent.swift`, where `click_target`, `fill_target`, `press_key`, `type_text`, and `open_url` tool uses become `CUAction`s; `Sources/AppShell/CascadeAppModel.swift`, action execution loop around `executeCU`.
  - Change: define `ActionRisk` for destructive/irreversible/submitting actions: send, submit, delete, replace all, external URL, file write, AppleScript, shell, purchase/payment, permissions, privacy-sensitive forms. Before execution, check `PreActionVerifier.verify(preState, action, targetEvidence)`; if reject, audit `agent.action.refused` with `unsafeActionRefused`; if abstain, route to `RecoveryAction.diagnosticProbe` or `pauseForUser` depending risk.

- Turn the existing completion validators into process validators.
  - File/function: `CascadeAppModel.validateAssistCompletion(...)` and `BackgroundWebAgent.verifyCompletion(...)`.
  - Change: keep final completion verification, but add `validateActionEffect(goal, action, before, after, expectedEffect)` after high-risk or high-uncertainty actions. Use objective checks first: AX fingerprint change, OCR/page-text delta, focused app/window unchanged or expected, URL/form state, and dHash grid diff. Only call LLM verifier when objective checks are inconclusive.

- Calibrate confidence thresholds from Cascade traces.
  - File/function: new `Sources/AgentOrchestrator/VerifierCalibration.swift`; extend `AgentTrace` or reliability eval JSONL in `Sources/AgentOrchestrator`.
  - Change: log `candidateCount`, `selectedSource`, `confidence`, `verifierVerdict`, `failureKind`, and `postEffect` for every grounded action. Build a reliability report that bins confidence into calibration buckets. Start thresholds: accept >=0.78, re-ground 0.45...0.78, pause/escalate <0.45 for high-risk actions; tune from traces.

- Feed verifier failures into `AgentRecoveryPolicy` instead of bespoke strings.
  - File/function: `Sources/AgentOrchestrator/AgentFailureKind.swift`, `AgentRecoveryPolicy.plan(for:)`, and audit parsing in `init?(auditAction:detail:)`.
  - Change: add or reuse failure kinds: `lowConfidenceGrounding`, `preconditionFailed`, `effectMismatch`, `verifierDisagreement`. Map them to existing actions: `reharvestAX`, `regroundVisual`, `diagnosticProbe`, `rerunVerifier`, `pauseForUser`. This makes verifier behavior visible in reliability evals.

- Add verifier-aware safe batching.
  - File/function: `Sources/ProviderKit/ComputerUseAgent.swift`, `safeBatchPrefix` callsites and batch assembly around lines where structural actions are appended.
  - Change: truncate a batch not only after navigation/submitting fill, but also before any action whose verifier says precondition depends on the result of a previous action. Example: click `New Document`, then wait/re-capture before filling title placeholder.

- Add one-step target re-description on verifier rejection.
  - File/function: `ComputerUseAgent.groundedClick(...)`, `expandFillTarget(...)`, and miss tool-result strings.
  - Change: on `reject/abstain`, ask the planner for exactly one refined target description using the verifier reason and current AX/OCR summary, then re-ground once. This ports Self-Refine without opening unbounded loops.

- Use a verifier jury only for high-cost/high-risk steps.
  - File/function: new `VerifierBudgetPolicy` in `ProviderKit` or `AgentOrchestrator`.
  - Change: cheap deterministic verifier always; one LLM verifier for ambiguous target; 3-vote jury only when the next action is high-risk or two failures have happened in the same episode. Track token/time cost in `assist.timing` / `harness.slow` style audits.

- Make verifier prompts position-bias resistant.
  - File/function: new verifier prompt builders in `ProviderKit`.
  - Change: randomize candidate order, require JSON keyed by stable candidate IDs, forbid preference for longer rationales, and ask for `abstain` when evidence is insufficient. Do not compare candidate A/B in fixed order.

- Create an offline SEQ-25 eval fixture from real failures.
  - File/function: `Tests/...` new target or existing `ReliabilityEvalTests`; data under a small fixture folder, not full screenshots in source if large.
  - Change: encode 25-50 cases: Cascade-own-UI AX hijack, Keynote placeholder vs Format-panel title, contenteditable Notion field, stale frame after submit, no-effect false positive, secure input, modal interruption. Assert verifier verdict and recovery action, not just final UI result.

- Use verifier labels as training data for learned skills and recovery memories.
  - File/function: `AppShell/CascadeAppModel.swift` learned skill approval flow; `ProviderKit/AssistMemory.swift`; `CascadeMemory` audit tables.
  - Change: when a verifier catches a recurring miss, store a compact memory: app, target phrase, rejected source, accepted source, failure kind, and recovery. Surface only aggregated learnings, not raw private content.

- Add user-visible confidence only at pause boundaries.
  - File/function: `ComputerUseKit/GuidanceOverlay`, `AppShell` dock/notch messaging.
  - Change: do not clutter normal runs. If verifier pauses before a risky click, show concise evidence: target name, candidate label/role, confidence, and why it paused. This improves trust without turning every click into a modal.

## Quick Wins vs Larger Bets

### Quick wins

- Extend `VisualGrounder` internally with candidate metadata while preserving the current `CGPoint?` wrapper.
- Add deterministic candidate scoring in `MixtureGrounder`: actionable role, on-display, AX label score, OCR proximity, canvas concept exclusion, source agreement.
- Add `agent.ground.verify` audit rows with selected source, confidence, candidate count, and reason.
- Gate LLM verifier calls behind a UserDefault such as `cascade.groundingVerifier` and risk/ambiguity checks.
- Add pre-action checks for obvious high-risk labels: `Delete`, `Send`, `Submit`, `Pay`, `Replace`, `Erase`, `Run`, `Allow`, `Grant`, shell/AppleScript/write harness calls.
- Turn `validateAssistCompletion` prompt format into a reusable `VerifierVerdict` parser shared with `BackgroundWebAgent.verifyCompletion`.
- Add offline tests for `parseVerifierVerdict`, candidate order randomization, confidence bucket routing, and RecoveryPolicy mapping.

### Larger bets

- Build a local Apple Silicon verifier service using a small VLM or Qwen-derived verifier to score candidate screenshots/regions without cloud cost. Start behind the same `GroundingVerifier` protocol.
- Train a Cascade-specific PRM/ranker from audit rows and human pause decisions. Use PRM800K/ThinkPRM as process-label design inspiration, not as code dependency.
- Add verifier-guided beam search for recovery only: after two misses, propose 2-3 alternate target descriptions and choose via verifier. Avoid full Tree-of-Thought planning for ordinary tasks.
- Add confidence calibration dashboards to the reliability runner: expected calibration error, abstention precision, false accept rate for high-risk actions, and token/latency cost per avoided failure.
- Add active learning: when the verifier abstains and the user manually completes the action, store that as a high-value label for future target/risk calibration.

## License/Attribution Notes

- AutoGen has MIT code and CC-BY-4.0 docs. Reuse ideas, not code, unless preserving the code/documentation license split.
- LangGraph, DSPy, promptfoo, and PRM800K are MIT-compatible for reference use, but Cascade should port concepts in Swift rather than vendoring Python.
- DeepEval and Guardrails are Apache-2.0. Porting concepts is straightforward; copying code would require NOTICE/license compliance.
- OpenAI Evals appears MIT licensed per its README disclaimer, but verify `LICENSE.md` before copying any code.
- ThinkPRM's GitHub page did not expose a license in the checked page. Treat as paper/reference only until a license is confirmed.
- Academic papers can be cited as design references. Do not copy benchmark data, prompts, or code snippets into Cascade without checking each repo/dataset license.
- For Cascade docs, cite source URLs in implementation PRs when a verifier pattern is directly inspired by a paper or repo.
