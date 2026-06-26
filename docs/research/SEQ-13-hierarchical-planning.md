# SEQ-13 - Hierarchical Planning and Search for GUI Agents

## Overview

Cascade already shipped the safety-critical floor: one-step supervised planning, the assist episode loop with stall/no-effect guards, typed `AgentFailureKind`, `AgentRecoveryPolicy`, action-risk gates, and recipe replay. The remaining gap is not "let the model plan forever." It is selective hierarchy: decompose complex multi-app goals, execute one bounded subtask at a time, verify state before trusting completion, and replan from typed failure evidence.

The codebase already has the right starting points:

- `Sources/SandboxKit/AgentTaskPlanner.swift` splits jobs into up to five subtasks for `webSandbox` and `onScreen`.
- `Sources/AppShell/CascadeAppModel.swift` already routes `runAssistTask` through that planner, opens each subtask's app/URL, runs `runAssistEpisode`, and carries forward findings.
- `Sources/SandboxKit/BackgroundWebAgent.swift` verifies each completed web subtask against page text before trusting the model's "done."
- `Sources/AppShell/CascadeAppModel.swift` has an on-screen `validateAssistCompletion(...)` port, but it is gated off by `cascade.assistValidator`.
- `Sources/AgentOrchestrator/AgentFailureKind.swift` and `AgentRecoveryPolicy.swift` already provide the failure vocabulary and recovery rungs needed for replanning.

The research consensus: GUI task success improves when planning is split across time scales and roles. The practical Cascade version is a lightweight planner -> executor -> verifier loop, not a wholesale agent framework. Use hierarchy for multi-app goals; use a critic only before risky or ambiguous actions; use best-of-N only for ambiguous grounding or plan choice.

## OSS / Papers Table

| Work | URL | Specific architecture | Benchmark delta | Cascade implication |
|---|---|---|---|---|
| Agent S2 | [paper](https://arxiv.org/abs/2504.00906), [code](https://github.com/simular-ai/Agent-S) | Compositional generalist-specialist computer-use agent. Delegates cognition across models, uses Mixture-of-Grounding for localization, and Proactive Hierarchical Planning to refine plans at multiple temporal scales as observations change. | Reports 18.9% and 32.7% relative improvement over leading Claude Computer Use / UI-TARS baselines on OSWorld 15-step and 50-step; 52.8% relative improvement on WindowsAgentArena; 16.52% relative improvement on AndroidWorld. | Keep Cascade's current executor, but make `AgentTaskPlanner` produce a persistent plan state with subgoal checkpoints and allow mid-run refinement after failures. |
| GUI-Critic-R1 / "Look Before You Leap" | [paper](https://arxiv.org/abs/2506.04614) | Pre-operative critic: before executing candidate action `a`, critic reads current GUI state and action, predicts likely result, scores correctness, and suggests a correction. The paper trains a 7B critic with suggestion-aware GRPO. | Dynamic AndroidWorld example improves baseline success from 22.4% to 27.6% (+5.2 points, about +23% relative). Static GUI-Critic-Test also improves critic accuracy over current MLLMs. | Add a cheap `PreActionCritic` before medium/high-risk actions and ambiguous grounding retries, tied to `AgentFailureKind.unsafeActionRefused`, `.groundingMiss`, `.noEffect`, and `.parameterNeedsLiveValue`. |
| WorldGUI / GUI-Thinker | [paper](https://arxiv.org/abs/2502.08047), [code](https://github.com/showlab/WorldGUI) | Desktop GUI benchmark with varied initial states; GUI-Thinker/WorldGUI-Agent uses critique stages around planning and execution to adapt when the app is not in the canonical state. | Search abstract reports GUI-Thinker outperforming Claude-3.5 Computer Use by 14.9% success rate on WorldGUI. Current arXiv abstract emphasizes non-default initial state degradation and three critique stages. | Cascade should treat "wrong start state" as a replanning input, not just a pause. Feed `wrongStartState` plus fresh app/window evidence into a subtask replanner. |
| Language Agent Tree Search (LATS) | [paper](https://arxiv.org/abs/2310.04406), [code](https://github.com/lapisrocks/LanguageAgentTreeSearch) | Monte Carlo Tree Search over language-agent states. Uses LM-generated actions, LM value functions, self-reflection, and environment feedback to explore and choose action paths. | Reports 92.7% pass@1 on HumanEval with GPT-4 and WebShop average score 75.9 with GPT-3.5, comparable to gradient-based fine-tuning. | Do not run full MCTS over live GUI clicks. Use a tiny tree over plan candidates or grounding candidates, then execute only the verifier-selected path. |
| Tree of Thoughts | [paper](https://arxiv.org/abs/2305.10601), [code](https://github.com/princeton-nlp/tree-of-thought-llm) | Searches over "thought" units rather than one left-to-right chain; generates alternatives, self-evaluates them, and backtracks when needed. | Game of 24 improves from GPT-4 chain-of-thought 4% success to 74%. | Use for plan selection before acting: ask for 3 decompositions, score them by risk/observability/directness, execute the best one. Avoid applying this to every UI step. |
| Reflexion | [paper](https://arxiv.org/abs/2303.11366), [code](https://github.com/noahshinn/reflexion) | Actor receives task feedback, writes a verbal reflection, stores it in episodic memory, and conditions the next trial on that memory without weight updates. | Reports 91% pass@1 on HumanEval, above then-SOTA GPT-4 at 80%, and broad gains across sequential decision-making, coding, and reasoning tasks. | Store structured recovery memos from verified failures, not open-ended self-judgment. Cascade already has `AgentFailureKind`; use that as the reflection schema. |
| ReAct | [paper](https://arxiv.org/abs/2210.03629), [project](https://react-lm.github.io/) | Interleaves reasoning traces, tool actions, and observations so plans update after environment feedback. | Reports +34 percentage points success on ALFWorld and +10 points on WebShop over imitation/RL methods with only one or two examples. | Cascade's assist loop is already ReAct-like. The upgrade is to make observations feed a persistent subgoal state and verifier, not just the next prompt. |
| Plan-and-Solve Prompting | [paper](https://arxiv.org/abs/2305.04091), [code](https://github.com/AGI-Edgerunners/Plan-and-Solve-Prompting) | First produce a plan that divides a problem into smaller subtasks, then solve each according to the plan; PS+ adds detailed instructions to reduce calculation errors. | Evaluated on ten datasets; abstract reports consistent large-margin gains over Zero-shot-CoT and comparable math performance to 8-shot CoT. | `AgentTaskPlanner` is the right local analogue. Strengthen it with success predicates and replanning hooks instead of adding a second planner. |
| Anthropic "Building Effective Agents" | [engineering note](https://www.anthropic.com/engineering/building-effective-agents) | Simple composable patterns: prompt chaining with gates, routing, parallelization/voting, orchestrator-workers, evaluator-optimizer, and autonomous agents with ground-truth environment feedback. | No benchmark delta; production guidance emphasizes adding complexity only when it improves measured outcomes. | Use orchestrator-workers for multi-app goals and evaluator-optimizer for verifier loops. Keep the implementation explicit in Swift, not hidden behind a framework. |
| MMBench-GUI | [paper](https://arxiv.org/abs/2507.19478), [code](https://github.com/open-compass/MMBench-GUI) | Hierarchical GUI benchmark across content understanding, element grounding, task automation, and task collaboration; introduces efficiency-quality area. | Benchmark, not an agent delta. It identifies grounding, planning, long-context memory, and early stopping as major determinants of success and efficiency. | Add Cascade evals that score subgoal success and redundant-step count, not just final "done." |

## Concrete Architecture Upgrades

### 1. Promote `AgentTaskPlanner` into a plan-state layer

Map to:

- `Sources/SandboxKit/AgentTaskPlanner.swift`
- `Sources/AppShell/CascadeAppModel.swift` around `runAssistTask`
- `Sources/ProviderKit/Planner.swift`
- `Tests/SandboxKitTests/AgentTaskPlannerTests.swift`

Current `AgentTaskPlanner` returns ordered `AgentSubtask` values. Extend that shape rather than replacing it:

```swift
public struct AgentSubtask {
    public let task: String
    public let startURL: String
    public let app: String
    public let web: Bool
    public let note: String
    public let expectedEffects: [ExpectedEffect]
    public let risk: ActionRiskLevel
}

public enum ExpectedEffect {
    case frontmostApp(String)
    case windowTitleContains(String)
    case visibleText(String)
    case urlContains(String)
    case artifactExists(String)
    case noUnexpectedModal
}
```

Keep the planner conservative:

- Default to one subtask.
- Split only on different apps/sites, find-then-use, or output handoff.
- Produce at most five subtasks.
- Add effects only when they are observable from screen text, AX, URL, or filesystem.
- Fall back to today's single subtask if parsing fails.

This is Agent S2's proactive hierarchical planning in Cascade's idiom: one text-only planning call, bounded subtasks, and fresh observations before each part.

### 2. Make on-screen assist a planner -> executor -> verifier loop

Map to:

- `Sources/AppShell/CascadeAppModel.swift` `runAssistTask(...)`
- `Sources/AppShell/CascadeAppModel.swift` `validateAssistCompletion(...)`
- `Sources/SandboxKit/BackgroundWebAgent.swift` `verifyCompletion(...)`
- `Sources/AgentOrchestrator/AgentFailureKind.swift`
- `Sources/AgentOrchestrator/AgentRecoveryPolicy.swift`

The background web agent already does the right thing: run one part, then verify it against actual page state. Port that behavior to on-screen runs selectively:

1. Planner emits `AgentSubtask(expectedEffects:)`.
2. Executor runs `runAssistEpisode(...)`.
3. Verifier checks deterministic effects first: app/window/URL/visible text/no modal/artifact.
4. If deterministic checks are thin, call `validateAssistCompletion(...)`.
5. If verifier returns incomplete, classify as `.validatorIncomplete` or a more specific `AgentFailureKind`.
6. Apply `AgentRecoveryPolicy.plan(for:)`.
7. For recoverable rungs, call a small replanner with the failed subtask, failure kind, current evidence, and completed findings.

Audit rows to add:

- `assist.plan` with compact subtask count and app/site route.
- `assist.subgoal.start`
- `assist.subgoal.verify`
- `assist.subgoal.replan`
- `assist.subgoal.fail` with `AgentFailureKind`.

This gives the Manager/Cascades surfaces a real trajectory: planned, acted, verified, replanned, paused.

### 3. Add a pre-action critic only for risky or uncertain actions

Map to:

- `Sources/AppShell/CascadeAppModel.swift` `executeCU(...)`
- `Sources/ProviderKit/ComputerUseAgent.swift`
- `Sources/ProviderKit/Planner.swift`
- `Sources/AgentOrchestrator/AgentFailureKind.swift`
- `Tests/ProviderKitTests/ActionGateTests.swift`

Do not put a critic before every click. Use it when the existing gate says risk or uncertainty is high:

- destructive keys: quit, force quit, delete/trash, empty trash, irreversible close without save;
- external side effects: send, submit, pay, post, invite, delete remote record;
- harness power-tier calls: `run_command`, `run_applescript`, `write_file`;
- live-value typing where replay says `.parameterNeedsLiveValue`;
- repeated `groundingMiss` / `noEffect`;
- low-confidence structural grounding or multiple plausible targets.

Suggested interface:

```swift
public struct ActionCritique: Sendable, Equatable {
    public let verdict: Verdict
    public let failureKind: AgentFailureKind?
    public let reason: String
    public let saferInstruction: String?

    public enum Verdict: String, Sendable, Codable {
        case approve
        case revise
        case refuse
        case askUser
    }
}
```

The critic prompt should use GUI-Critic-R1's structure: observation, possible result, correctness, suggestion. The runtime outcome should stay deterministic:

- `approve`: execute.
- `revise`: feed `saferInstruction` to the next model turn or replanner.
- `refuse`: audit `agent.action.refused`, map to `.unsafeActionRefused`, do not retry.
- `askUser`: pause with evidence.

This complements the shipped action-risk gate; it should not replace it.

### 4. Add best-of-N for ambiguous grounding, not for normal execution

Map to:

- `Sources/AppShell/MixtureGrounder.swift`
- `Sources/ProviderKit/VisualGrounder.swift`
- `Sources/ProviderKit/ComputerUseAgent.swift`
- `Sources/ComputerUseKit/AXElementResolver.swift`
- `Sources/AgentOrchestrator/AgentRecoveryPolicy.swift`

Tree search is too slow and dangerous if it explores by clicking. The safe version explores candidates offline:

1. Build candidate targets from AX, OCR, visual grounder, and snap candidates.
2. When ambiguity is high, ask for N=3 target choices or plan choices.
3. Score candidates with a verifier: semantic match, distance to requested role/label, expected effect, risk.
4. Execute only the winner.
5. If execution no-effects, classify `.groundingMiss` or `.noEffect` and invoke the existing recovery rung (`reharvestAX`, `regroundVisual`, `alternateTarget`).

The immediate hook is structural grounding: `ComputerUseAgent` names a target, while the runtime grounds it. Add best-of-N at the runtime boundary when there are multiple plausible `click_target` / `fill_target` candidates.

### 5. Replan from typed failures instead of retrying from prose

Map to:

- `Sources/AgentOrchestrator/AgentFailureKind.swift`
- `Sources/AgentOrchestrator/AgentRecoveryPolicy.swift`
- `Sources/AppShell/CascadeAppModel.swift`
- `Sources/SandboxKit/BackgroundWebAgent.swift`
- `Tests/ReliabilityEvalTests/ReliabilityEvalTests.swift`

Reflexion is useful only when feedback is reliable. Cascade should not store free-form "I think I failed because..." memories. Store typed recovery facts:

```text
subtask: "Paste the invoice total into Numbers"
failureKind: groundingMiss
evidence: "clicked B2 but no cell focus changed"
recoveryTried: regroundVisual
outcome: recovered
```

Then feed the next replanner a compact failure memo:

```text
The previous attempt failed with groundingMiss. Do not repeat the same target.
Fresh evidence: Numbers is frontmost; OCR sees "Total" column; no selected cell.
Choose one recovery subtask or pause.
```

This directly reuses the reliability taxonomy and avoids Reflexion's main risk: confident but wrong self-diagnosis.

### 6. Build a subgoal / skill graph from existing app skills and recipes

Map to:

- `Sources/ComputerUseKit/AppSkill.swift`
- `Sources/ComputerUseKit/Skills/*/SKILL.md`
- `Sources/AppShell/CascadeAppModel.swift` `assistSkillProvider(...)`
- `Sources/AgentOrchestrator/WorkflowCurator.swift`
- `Sources/CascadeMemory/CascadeMemory.swift` agent recipes

Cascade already has pull-based skills and recorded recipes. Convert them into a small graph:

- nodes: app, website, skill, recipe, subgoal type, expected effect;
- edges: "opens", "fills", "exports", "sends", "creates artifact", "requires login", "dangerous";
- weights: success count, median action count, last failure kind, last app version/window title.

The planner can then prefer known paths:

- if `task` matches a skill `useWhen`, attach that skill name to the subtask;
- if a recipe has succeeded for the same app/effect, prefer replay;
- if a path repeatedly fails with `.groundingMiss`, route to structural target naming or pause.

This is a larger bet, but it turns repeated work mining into a planning prior.

## Quick Wins vs Larger Bets

### Quick wins

1. Auto-enable on-screen completion validation for multi-part plans, high-risk actions, and downgraded Scout runs. Keep it off for simple one-step watched tasks.
2. Add `expectedEffects` to `AgentSubtask` and parser tests. Start with deterministic checks: frontmost app, window title, visible text, URL, no modal.
3. Add `assist.subgoal.*` audit events so failures can be aggregated by subtask and `AgentFailureKind`.
4. Add a high-risk `PreActionCritic` before irreversible or external-side-effect actions. Return `approve/revise/refuse/askUser`.
5. Add best-of-3 grounding only when structural grounding is ambiguous or a previous action no-effected.
6. Add a replanner call for `.validatorIncomplete`, `.groundingMiss`, and `.noEffect`, seeded with `AgentRecoveryPolicy.plan(for:)`.

### Larger bets

1. Full LATS-style search over plan candidates for long-horizon tasks, with a strict no-live-click exploration rule.
2. Persistent subgoal/skill graph from `AppSkill` metadata, approved recipes, and reliability outcomes.
3. Local or hosted dedicated critic model for pre-action GUI diagnosis; start with a prompt-based critic first.
4. WorldGUI-style eval fixtures where the same goal starts from multiple app states, to test replanning and wrong-start recovery.
5. Efficiency-quality metric in the reliability eval: success is not enough if the agent burns 80 turns or repeats steps.

## Risks / Cost

- Latency: hierarchy adds planner, verifier, and possible critic calls. Mitigation: trigger selectively; skip for simple commands; use `TextHelperModel.resolve()` for text-only planning/verifying.
- Overblocking: critics can block valid actions. Mitigation: deterministic gates remain authoritative; critic only revises/refuses inside declared risk classes.
- False verification: OCR may miss canvas or sparse UI state. Mitigation: deterministic checks first, LLM verifier only when evidence is sufficient, doubt leans accept for non-risk tasks.
- Prompt bloat: plan state can become another long hidden prompt. Mitigation: carry only completed findings, current subtask, failure kind, and fresh evidence.
- Reflexion confabulation: self-generated memories can reinforce wrong beliefs. Mitigation: store typed failure facts from audit/verifier evidence, not model introspection.
- Search explosion: ToT/LATS can multiply calls. Mitigation: N=3 maximum for plan/grounding ambiguity; never explore by executing alternative GUI actions.
- User trust: more autonomy can feel opaque. Mitigation: audit `assist.plan`, show subtask progress in the dock, and keep STOP and high-risk pause behavior unchanged.
- Privacy: verifier/critic prompts may include screen text. Mitigation: apply existing privacy drops and keep the same local/OCR evidence caps used by recall and validation.

## Recommended Sequence

1. Extend `AgentSubtask` with `expectedEffects` and add parser tests.
2. In `runAssistTask`, verify every multi-part subtask after `runAssistEpisode`.
3. Classify verifier failures into `AgentFailureKind` and apply `AgentRecoveryPolicy`.
4. Add a small replanner for failed subtasks.
5. Add selective pre-action critic for high-risk actions.
6. Add best-of-N grounding for low-confidence target resolution.
7. Only after evals show value, add LATS/ToT-style search over plan candidates.
