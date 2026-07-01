# Sequence 15 - Continual Skill Learning and Consolidation

## Overview

Cascade already has the first loop of the compounding moat: `WasteDetector` mines repeated work into `AgentRecipe`, `WorkflowCurator` turns mechanical detections into user-facing agents, `CascadeAppModel.maybeDistillSkill` drafts app `SKILL.md` files after concentrated successful runs, and `AppSkillRegistry` exposes skills through the pull-on-demand `use_skill` path. The missing layer is lifecycle management: what gets retained, merged, rewritten, down-ranked, forgotten, or turned into a reusable procedure after many successes and failures.

The strongest pattern across lifelong-agent work is not "remember everything." It is verifier-gated abstraction:

- Store raw episodes only as evidence.
- Promote only verified success trajectories into reusable procedures.
- Promote only proven failures into scoped avoid-rules.
- Consolidate overlapping cases into parameterized skills.
- Retrieve fewer, better memories based on task context, reliability, recency, and risk.

For Cascade, this means adding an experience ledger and a skill consolidator between audit/history and the live skill library. The live `SKILL.md` surface should remain human-reviewable; the system can draft, rank, and propose revisions, but it should not silently mutate trusted automation behavior.

## OSS/Papers Table

| Source | URL | Availability | Technique | Cascade Mapping |
|---|---|---:|---|---|
| Voyager | https://voyager.minedojo.org/ and https://arxiv.org/abs/2305.16291 | Project site links code | Lifelong agent with automatic curriculum, embedding-indexed executable skill library, environment feedback, execution errors, and self-verification before skill improvement. | Treat approved Cascade skills as composable procedures with verifier-backed promotion. Add a curriculum that asks "which missing skill would unlock more user value?" rather than drafting only when an app has no skill. |
| Generative Agents | https://arxiv.org/abs/2304.03442 and https://github.com/joonspk-research/generative_agents | Apache-2.0 repo | Memory stream scored by recency, importance, and relevance; periodic reflection compacts raw memories into higher-level beliefs used for planning. | Use recency/importance/relevance for skill surfacing. Compact many audit rows into "skill reflections" while preserving evidence IDs. |
| Reflexion | https://arxiv.org/abs/2303.11366 | Paper | Agents learn through verbal reflections stored in episodic memory from explicit task feedback. No model fine-tuning required. | Store failure memories only from `AgentFailureKind` plus verifier/audit evidence. Inject matching repair hints into assist/replay, not generic self-critique. |
| ExpeL | https://arxiv.org/abs/2308.10144 | Paper | Autonomous experience gathering, natural-language insight extraction, and retrieval of insights plus experiences at inference time. | Add an offline distiller over successful and failed Cascade runs that emits concise, scoped app/workflow insights for review. |
| AutoGuide | https://arxiv.org/abs/2403.08978 | Paper | Generates conditional, context-aware natural-language guidelines from offline experiences and selects relevant guidelines during decision-making. | Extend learned skills with `when:` conditions and `avoidWhen:` clauses derived from verifier evidence. Select clauses by app, goal, UI state, and failure kind. |
| Agent Workflow Memory (AWM) | https://arxiv.org/abs/2409.07429 | Paper | Induces reusable workflows from offline or online task trajectories and selectively provides them to agents; improves long-horizon web navigation success. | Consolidate repeated `AgentRecipe`/assist trajectories into parameterized workflows. Use the current recipe signature as a seed, but merge variants before writing a new skill. |
| Skill-of-Mind / Thanos | https://arxiv.org/abs/2411.04496 | Paper | Predicts which conversational skill applies in a context before responding. The useful abstraction is skill selection, not the social-dialogue domain. | Add a small skill-router over `AppSkillRegistry.indexText`: choose a skill because the situation matches, not only because the frontmost app matches. |
| Case-Based Reasoning (CBR) | https://en.wikipedia.org/wiki/Case-based_reasoning and https://arxiv.org/abs/2606.05250 | Foundational method; recent agent CBR paper | Retrieve, reuse, revise, retain; recent CBR-agent work adds quality-controlled structured cases and reuse detection. | Introduce `ExperienceCase`: problem context, recipe/skill used, verifier result, failure kind, repair, evidence. Retain only after quality gates. |
| MemGPT | https://arxiv.org/abs/2310.08560 and https://memgpt.ai | Project/code linked | Virtual context management across memory tiers; agents move data between active context and archival memory. | Split Cascade learning into hot skill index, warm consolidated cases, cold raw audit/record evidence. Keep prompt payload bounded. |
| Agentic Memory / memory operations as tools | https://arxiv.org/abs/2601.01885 | Paper | Memory store/retrieve/update/summarize/discard as explicit agent actions trained/optimized for long-horizon tasks. | Do not let the computer-use agent mutate skills directly yet, but model consolidation as explicit operations with audit events: `proposeSkillRevision`, `archiveSkill`, `retainFailureRule`. |
| Re-ReST | https://arxiv.org/abs/2406.01495 | Code released per paper | Reflection-reinforced self-training uses environment feedback to refine low-quality trajectories into better supervision. | For offline eval only: turn failed Cascade trajectories into candidate repairs, then validate in reliability scenarios before any skill change. |
| SkillGen | https://arxiv.org/abs/2605.10999 | Paper | Synthesizes auditable skills from successful and failed trajectories using contrastive induction; verifies net effect by comparing with/without skill. | Best larger bet for Cascade: require held-out replay/eval improvement before promoting a consolidated skill revision. |
| SkillAdaptor | https://arxiv.org/abs/2606.01311 | Code announced | Step-level failure attribution updates only the responsible skill under acceptance checks. | Map `AgentFailureKind` plus step/audit evidence to the exact skill clause or recipe step that caused the failure; avoid broad rewrites. |
| SKILL-DISCO | https://arxiv.org/abs/2606.26669 | Paper | Distills successful traces into parameterized control-flow subgraphs, then compiles callable, executable, verifiable procedural skills. | Long-term replacement for free-form skill bullets: compile common UI paths into parameterized `AgentRecipe` subgraphs with pre/postconditions. |
| Risk-sensitive memory retrieval for coding agents | https://arxiv.org/abs/2604.27283 | Paper | Treats memory injection as a contextual bandit with abstention; penalizes false-positive memory use more than missed reuse. | Skill surfacing should be allowed to abstain. A misleading skill can be worse than no skill in a real Mac UI. |

## Concrete Upgrades

### 1. Add an experience ledger before skill learning

Map to:

- `Sources/CascadeMemory/CascadeMemory.swift`
- `Sources/AgentOrchestrator/AgentFailureKind.swift`
- `Sources/AppShell/CascadeAppModel.swift`
- `Sources/AgentOrchestrator/ReliabilityReport.swift`

Add a durable table for experience cases, separate from raw `audit_event` and `agents`:

```sql
CREATE TABLE agent_experience_case (
  id INTEGER PRIMARY KEY,
  agent_id INTEGER,
  skill_slug TEXT,
  app_name TEXT NOT NULL,
  goal_pattern TEXT NOT NULL,
  recipe_signature TEXT,
  outcome TEXT NOT NULL,
  failure_kind TEXT,
  verifier_detail TEXT,
  evidence_context_ids TEXT,
  action_count INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  retained_score REAL NOT NULL DEFAULT 0
);
```

Use it as the canonical input to learning. `audit_event` remains the immutable ground truth; `agent_experience_case` is the compact, queryable case bank for skill improvement.

Retention gates:

- `success`: only if completion verifier says `verified:` or `markAgentRun` happens after a completed deploy.
- `failure`: only if mapped to `AgentFailureKind` by audit action/detail and supported by verifier or state evidence.
- `refusal`: store separately as a safety success, not a failure.
- `userStop`: do not learn an automation rule unless the user adds feedback.

### 2. Build a verifier-gated skill consolidator

Map to:

- `Sources/ComputerUseKit/AppSkill.swift`
- `Sources/AppShell/CascadeAppModel.swift` (`pendingLearnedSkills`, `approveLearnedSkill`)
- `Sources/CascadeMemory/CascadeMemory.swift`
- `Sources/AgentOrchestrator/WorkflowCurator.swift`

Current learning drafts a new skill only when one app dominates a successful run and no skill already exists. Add a second path: consolidate or revise existing skills when enough verified cases accumulate.

Proposed object:

```swift
struct SkillConsolidationCandidate {
    let targetSlug: String?
    let appName: String
    let sourceCaseIDs: [Int64]
    let proposedMarkdown: String
    let mergeReason: String
    let predictedRisk: SkillRisk
    let requiredEvidence: [Int64]
}
```

Merge rules:

- Same app or same web surface.
- Similar `goal_pattern` and overlapping `AgentRecipe.humanSteps`.
- Shared parameters such as recipient, file, row, amount, date, or selected item.
- No unresolved `unsafeActionRefused`, `secureInput`, or `permissionMissing` cases in the source set.
- At least one held-out verified success after the proposed procedure is applied in shadow/eval mode.

The output should stay in the existing review lane: a draft skill revision appears in Cascades with source cases, diff, success/failure counts, and a "why this merge" note. Approval still writes `SKILL.md`; no silent mutation.

### 3. Distill successful trajectories into parameterized procedures

Map to:

- `Sources/CascadeMemory/CascadeMemory.swift` (`AgentRecipe`, `RecipeStep`, `humanSteps`)
- `Sources/WasteDetection/WasteDetector.swift`
- `Sources/AgentOrchestrator/WorkflowCurator.swift`
- `Sources/AppShell/CascadeAppModel.swift` (`distillSkill`)

Move from "5-9 bullets that worked" to a structured skill body:

```markdown
## Procedure

- Preconditions:
  - Frontmost app is <app>.
  - The target record/list/document is visible.
- Parameters:
  - `{recipient}` from the selected email header.
  - `{amount}` from the visible invoice total.
- Steps:
  1. Open the detail row matching `{recipient}`.
  2. Copy `{amount}` into the tracker field.
  3. Verify the tracker row shows `{amount}` before submitting.
- Postconditions:
  - The tracker contains `{amount}`.
- Avoid:
  - If a modal blocks the target field, pause instead of dismissing unknown dialogs.
```

The distiller should use:

- Successful `AgentRecipe` steps and action observations.
- Typed/copy-paste variation positions from `WasteDetector`.
- Evidence context IDs for OCR/AX snippets.
- Failure memories scoped to the same app and goal pattern.

Do not emit a parameter if the source value looks like a secret, credential, medical/banking data, or unique personal identifier. Keep literal examples out of the live skill unless privacy rules permit them.

### 4. Learn failure-avoidance rules from `AgentFailureKind`

Map to:

- `Sources/AgentOrchestrator/AgentFailureKind.swift`
- `Sources/AgentOrchestrator/AgentRecoveryPolicy.swift`
- `Sources/AppShell/CascadeAppModel.swift`
- `Sources/CascadeMemory/CascadeMemory.swift`
- `docs/research/SEQ-06-reliability-eval.md`

Extend the SEQ-06 verifier-grounded Reflexion idea into durable negative knowledge:

```json
{
  "scope": {"app": "Microsoft Word", "goalPattern": "create document then highlight text"},
  "failureKind": "noEffect",
  "provenBy": ["assist.noeffect", "assist.validate: INCOMPLETE"],
  "avoidRule": "Do not issue highlight before verifier confirms the target text exists.",
  "repairHint": "Create or locate the text first, then re-read the document before highlighting.",
  "expiresAfterSuccesses": 5
}
```

Rules should be:

- Verifier-gated.
- Narrowly scoped by app/surface, goal pattern, UI state, and failure kind.
- TTL or counterexample based, so one old failure does not permanently poison a skill.
- Never learned from model self-doubt alone.
- Never allowed to override explicit safety refusals.

### 5. Rank skills by utility, reliability, and risk

Map to:

- `Sources/ComputerUseKit/AppSkill.swift`
- `Sources/ProviderKit/ComputerUseAgent.swift`
- `Sources/AppShell/CascadeAppModel.swift`
- `Sources/AgentOrchestrator/WorkflowCurator.swift`

`AppSkillRegistry` currently gives the agent an index; add a ranker before index injection and before Cascades surfaces suggestions.

Scoring features:

- Relevance: app/surface match, goal embedding/text similarity, required tool/harness lane.
- Reliability: verified successes, held-out success rate, recent failures by `AgentFailureKind`.
- Utility: time saved per run, run count, user approvals, repeated manual recurrence.
- Risk: destructive actions, external writes, sensitive surfaces, history of `unsafeActionRefused`, need for live values.
- Freshness: recency of use and whether the UI/app version changed.
- Specificity: prefer a narrow procedure over a broad app skill when both match.

The ranker must support abstention. If top skills are low-confidence or high-risk, the agent should proceed without them or ask for a demonstration/review.

### 6. Bound skill-library growth with consolidation, archival, and lineage

Map to:

- `Sources/ComputerUseKit/AppSkill.swift`
- `Sources/AppShell/CascadeAppModel.swift`
- `Sources/CascadeMemory/CascadeMemory.swift`

Add skill metadata, either in frontmatter or a sidecar table:

```yaml
version: 3
parentSkills: [learned-mail-1, learned-mail-2]
sourceCases: [101, 118, 129]
lastVerifiedAt: 2026-06-26T12:00:00Z
successes: 12
failures:
  noEffect: 1
  unexpectedModal: 2
riskClass: external-write
status: active
```

Lifecycle:

- Active: surfaced in the skill index.
- Draft revision: visible in Cascades review.
- Shadow: used only in eval/simulation, not live actuation.
- Archived: not surfaced, evidence retained.
- Quarantined: hidden due to regression, safety issue, or user rejection.

This prevents catastrophic forgetting by preserving old versions and evidence while keeping the active index small.

### 7. Add a curriculum for which skills to form next

Map to:

- `Sources/WasteDetection/WasteDetector.swift`
- `Sources/AgentOrchestrator/WorkflowCurator.swift`
- `Sources/AppShell/CascadeRootView.swift`
- `Sources/AppShell/CascadeAppModel.swift`

Voyager's lesson is that skill growth needs a curriculum. For Cascade, the curriculum is not open-ended exploration; it is user-value exploration.

Surface "learning opportunities" when:

- The user repeats a workflow often but no approved skill exists.
- A skill has high run count but recurring scoped failures.
- Multiple drafts overlap and should be consolidated.
- A high-value workflow requires a missing parameter label.
- The agent repeatedly abstains because confidence is low.

UI copy should be concrete:

- "Cascade has seen three versions of this invoice update. Review a merged skill."
- "This Mail skill works except when a modal appears. Add a pause rule from two proven failures."
- "This workflow needs one label: which field is the due date?"

## Quick Wins vs Larger Bets

### Quick Wins

1. Add `agent_experience_case` and write cases from completed agent runs, `assist.validate`, `sandbox.verify`, and mapped `AgentFailureKind` audit events.
2. Extend learned skill drafts with source evidence IDs, success count, and a generated `Avoid` section populated only from proven failures.
3. Add a duplicate-skill detector over app name, `useWhen`, `appMatchers`, and `AgentRecipe.humanSteps`; route matches to "revise existing skill" instead of "create new skill."
4. Add skill index ranking using simple local features: app match, approved status, success count, last failure kind, and explicit-ask-only.
5. Add skill lifecycle statuses: `active`, `draft`, `archived`, `quarantined`; only `active` enters `use_skill`.
6. Add a Cascades review card for "merge these learned skills" with a markdown diff and evidence chips.
7. Store failure memories with TTL/counterexamples and inject only when `(app, goalPattern, failureKind)` match.

### Larger Bets

1. Contrastive skill induction: compare successful and failed trajectories for the same goal, then extract what success does differently.
2. Held-out skill verification: before approving a revision, replay or simulate on reliability fixtures and compare with/without the skill.
3. Parameterized recipe compiler: compile common successful traces into callable `AgentRecipe` subgraphs with preconditions and postconditions.
4. Risk-sensitive memory controller: learn when to inject no skill, a narrow skill, a broad app skill, or a failure rule.
5. Local skill embedding/index service: semantic similarity for skill consolidation and retrieval, without sending the whole library to the model.
6. UI-state-aware skill routing: choose skills from app, OCR/AX state, modal state, and action lane, not only app name.
7. Active learning prompts: ask the user for one missing label or a single confirmation when that unlocks a durable skill.

## Keeping It Safe

Cascade's learning loop must be more conservative than a game or web benchmark because it acts on the user's real Mac.

- No silent activation: generated or revised skills stay draft-only until reviewed.
- No learning from unproven outcomes: successes require completion verification; failures require mapped `AgentFailureKind` plus audit/verifier evidence.
- No destructive skill promotion: routines containing irreversible actions, external writes, credential access, or protected paths require higher review and should default to non-learning.
- No credential or sensitive-data retention: pass all examples through `PrivacyRules`/PII redaction before skill text or case summaries.
- No broad negative rules: failure rules must be scoped and expire after counterexamples or enough verified successes.
- Preserve lineage: every active skill revision points to source cases, evidence IDs, prior version, approver, and audit event.
- Support rollback: if a skill revision causes regressions, quarantine it and restore the prior active version.
- Rank for abstention: a low-confidence or high-risk memory should be omitted, not forced into context.
- Keep raw evidence immutable: learned summaries can change; audit events and recorded evidence should remain append-only and tamper-evident.
- Separate "refused safely" from "failed": `unsafeActionRefused` and `userStop` should not train the system to bypass controls.

## Recommended Architecture

The practical shape is a four-layer memory hierarchy:

1. Raw evidence: `audit_event`, recorded contexts, input events, reliability JSONL.
2. Experience cases: compact, verifier-gated records of successes, failures, refusals, and repairs.
3. Consolidated knowledge: skill clauses, avoid-rules, parameter schemas, pre/postconditions, lineage.
4. Active prompt surface: the small ranked `use_skill` index plus one or two pulled skills.

Implementation order:

1. Case ledger and failure-memory table.
2. Draft skill revisions instead of only new app skills.
3. Local ranker and abstention.
4. Consolidation UI in Cascades.
5. Held-out verifier/eval gate.
6. Parameterized procedure compiler.

The north star: Cascade should compound from experience without becoming a self-modifying automation system. It should get better because it has more verified cases, tighter skill selection, and more accurate failure avoidance, while the user remains the approver of durable behavior changes.
