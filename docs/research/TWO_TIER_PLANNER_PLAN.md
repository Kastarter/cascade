# Two-Tier On-Screen Agent — Cheap Qwen Planner + AX-First Grounding, Sonnet Native CU as Fallback

**Goal:** minimize Sonnet spend by routing MOST on-screen work to a CHEAP tier (a Qwen structural planner that *names* targets + AX-first grounding that resolves exact coords for free), and using Sonnet **native computer-use** (coordinate mode) ONLY as the fallback for canvas / AX-empty surfaces or when the cheap tier repeatedly fails. Ships default-OFF behind flags, A/B'd against the current native-Sonnet path so the accuracy floor is never regressed.

_Produced by the `two-tier-planner-plan` multi-model workflow (Opus mapped the code, Sonnet+web researched, Opus synthesized). 7/8 agents succeeded (grounder-router mapper hit the structured-output cap; its content is covered by S2 + the ax-first-branch agent)._

## Headline: ~70% already exists

The cheap tier IS the existing `ScoutAgent` (structural planner, withholds the coordinate tool, emits named `click_target`/`fill_target`) + `MixtureGrounder` (AX-first grounding, default-on). Pointing the planner at Qwen/GLM on OpenRouter is **config-only today** via `ScoutPlannerBackend.resolve` (`GroqClient.swift:47-68`) reusing `GroqVisionClient`'s OpenAI-compatible init. The genuinely new build work is: (1) a real default model + gate/wording fixes, (2) the AX Set-of-Marks planner note on its own flag, and (3) the **tier router + escalation**.

## Planner choice: Qwen

- **Default cheap planner: `qwen/qwen3-vl-235b-a22b-instruct`** — $0.20/M in, $0.88/M out, 262K ctx, image multimodal (satisfies GroqVisionClient's always-attached image block). Top open-source on **OSWorld 0.667**, **ScreenSpot-Pro 0.620** — clearly ahead of every GLM vision model at comparable/lower price.
- **Latency-retry rung:** `qwen/qwen3-vl-30b-a3b-instruct` (~$0.13/M in).
- **GLM = provider-diversity backup only:** `z-ai/glm-4.6v` ($0.30/$0.90) is weaker (OSWorld 0.372); GLM-5V-Turbo (OSWorld 0.623, $1.20/$4) is too pricey to be the cheap default — keep only as an optional mid-cost escalation rung.
- **⚠️ CRITICAL:** the current default `qwen/qwen3.6-plus` (`GroqClient.swift:55`) is a **placeholder that 404s** — replace it. Never use a text-only id (an image is sent every turn → silent fail). Re-verify id/price on openrouter.ai at implementation time (ids drift within weeks).

## Architecture

Per-subgoal router in front of `runAssistEpisode`:
- **CHEAP TIER** = Qwen3-VL structural planner (names targets, never emits coords) + `MixtureGrounder` AX-first grounding (macOS AX tree → exact coords, free/local; native AX outranks UI-TARS). Planner is fed a compressed **AX Set-of-Marks** note (`AXCompressedObservation.render`) and cites stable `[ax:id]` tokens; the picker resolves each id against a fresh `interactables()` harvest and maps the frame center via `CoordinateTransform`.
- **STRONG TIER** = Sonnet **native** computer-use (`computer_20251124`, `GroundingMode.coordinate`) — the restored accuracy floor, reserved for real canvas / AX-empty / repeated cheap-tier failure.
- The router is **STRUCTURAL** (withholds one tier entirely — the 3×-proven lesson that optional scaffolding the model can ignore fails). Escalation **rebuilds a fresh agent** on the current screenshot (`makeAssistAgent`/`wire`/`begin`) rather than switching the live conversation's model (cross-model thinking-block signatures can't replay — the documented revert reason).

## Model routing — 3 structural gates + escalation

- **GATE 1 — pre-flight start-tier** (before the Scout guard, `CascadeAppModel.swift:3442`): probe `runtimeProfileForFrontmost().isSparse` + `skill.axUnreliable` + `namesCanvasConcept(goal)` + an **AX-coverage signal** (`actionable_count` = nodes with an actionable role AND a non-empty name, minus 3 window-chrome controls → ABSENT ≤0 / SPARSE below a calibrated floor / RICH). Canvas/AX-empty → START strong; AX-rich → START cheap. Require 2 samples after settle (like `sparseAXEvidenceMemo minimumSamples:2`) so a slow first frame doesn't over-escalate.
- **GATE 2 — grounding-confidence** (inside cheap tier): AX resolution returns a typed outcome `FOUND_EXACT / FOUND_AMBIGUOUS / NOT_FOUND / AX_EMPTY`; only `FOUND_EXACT` proceeds cheap — the rest escalate. **This is exactly what prevents the UI-TARS pixel-guess regression.**
- **GATE 3 — runtime drift**: cheap tier returns `AssistEpisodeOutcome.escalate(reason:)` instead of terminal `.stalled` on ≥2 consecutive no-effect turns, a ground-miss (`ScoutAgent.lastGroundMiss`), or a risky-gate block.
- **Escalation handler:** rebuild via `makeAssistAgent` with `cascade.onScreenFallbackModel` (default **sonnet** — haiku lacks the CU beta) and `groundingMode` FORCED to `.coordinate`; `wire()` → `begin()` fresh on the current screenshot; bump `assistGeneration`, honor STOP/supersession; thread cheap-tier findings into the strong-tier goal.
- **Anti-thrash:** cap **one escalation per subgoal**, then terminal `.stalled`; min-dwell on strong tier. Audit `assist.escalate {subgoal, from_tier, to_tier, reason_code, grounder_outcome}`.

## Sequences

### S1 — Point the structural planner at Qwen3-VL on OpenRouter
- **d01** Replace placeholder `qwen/qwen3.6-plus` → `qwen/qwen3-vl-235b-a22b-instruct` (`GroqClient.swift:55`); add optional `cascade.scoutPlanner.endpoint` threaded into `GroqVisionClient(endpoint:…)`. Purely additive.
- **d02** Fix misleading `GroqError.missingKey` wording on the OpenRouter branch (tell OpenRouter-only operators the right key).
- **d03** Relax `onScreenBackendIsScout()` (`:3089`): default gate requires BOTH Groq+OpenRouter keys → make OpenRouter-key-alone satisfy it when `scoutPlanner.backend==openrouter`. Don't touch the background gate.
- **d04** Unit test pinning `ScoutPlannerBackend.resolve` (endpoint/keystore/model per branch + override).
- **d05** _(LIVE)_ Save OpenRouter key, run Notes + System Settings on the Qwen planner, confirm well-formed `ScoutAction` JSON naming real targets + `lastGroundLog` resolves them. Watch Qwen "thinking" variants garbling `parseRawActions`.

### S2 — AX-first-preferred grounding + surface the AX Set-of-Marks
- **d01** Land the PR #81 AX-first substrate (rebase onto repaired `origin/main`, reconcile with PR #82 FIRST, or cherry-pick `CoordinateTransform`/`GroundingRouter`/`AXCompressedObservation`/mark-picker). Confirm the d13 trust-order gate makes native AX outrank visual.
- **d02** Wire the compressed AX SoM note to the Scout planner on a **dedicated** `cascade.scoutPlanner.axSetOfMarks` flag (decoupled from the 6-subsystem `experimentalCompressedObservation` cluster so it's regression-isolable).
- **d03** Update the ScoutAgent prompt so Qwen reliably emits `[ax:id]` inside `click_target` (picker only engages when cited); keep the strip-and-fuzzy fallback.
- **d04** Decouple semantic AX actions (AXPress/AXSetValue/AXShowMenu) onto `cascade.scoutPlanner.semanticAXActions`, off the verifier flag.
- **d05** _(LIVE)_ Confirm grounded clicks land pixel-exact on Notes/Settings (`ax_som_mark_pick`, conf ~0.97 + post-action `elementAtPosition`); confirm the planner cited `[ax:id]` on a high fraction of turns.

### S3 — Tier router + escalation to Sonnet native CU
- **d01** Add `AssistEpisodeOutcome.escalate(reason:)` + thread through the parts loop (`:2236-2401`).
- **d02** AX-coverage signal computed inside the existing tree walk (nearly free) + canvas heuristic (dominant AXGroup/AXUnknown spanning the window, descend one level to avoid false-positiving big list apps).
- **d03** Pre-flight start-tier gate (`:3442`), 2-sample.
- **d04** Cheap tier returns `.escalate` on no-effect/ground-miss/risky-gate; per-subgoal escalation counter.
- **d05** Escalation handler (`makeAssistAgent` → `.coordinate` forced → `wire` → `begin`; STOP-safe; thread findings; one-shot).
- **d06** `cascade.onScreenFallbackModel` (default sonnet, guard against haiku).
- **d07** `assist.escalate` telemetry.
- **d08** _(LIVE)_ Notes/Settings stays cheap the whole time; Keynote gallery pre-flights or drifts to Sonnet native CU and completes; no oscillation; STOP mid-escalation stands down.

### S4 — Cost + accuracy eval harness with hard gates
- **d01** Extend GroundingBench AX ablation (AX-only vs vision-only vs hybrid) on live-AX-crawl corpus, scored by exposure + landing hit-test.
- **d02** Per-tier cost audit (Qwen $0.20/$0.88 planner tokens + grounder + Sonnet-when-escalated) into `assist.capture`.
- **d03** Per-app Cascade eval suite: AX-rich tasks MUST complete cheap; canvas tasks MUST escalate + complete.
- **d04** _(LIVE)_ Run the suite, record AX-only vs hybrid hit rate, cheap-tier share, Keynote escalation success, cost-per-task vs native-Sonnet baseline. Go/no-go inputs.

### S5 — Flags + safe rollout
- **d01** Master `cascade.tierRouter.enabled` (default OFF; off = today's binary path). Inventory all flags in one place.
- **d02** Settings UI: model-id field + router mode picker (Auto / Force Claude / Force Scout) replacing the hard binary; clarify the one OpenRouter key funds planner + grounder.
- **d03** A/B harness (alternate task-set through router vs native-Sonnet, per-arm success + cost).
- **d04** _(LIVE)_ Staged rollout; only flip the default after the evalGates pass.

## Eval gates (all must pass before default-on)
1. **No accuracy-floor regression** — router success ≥ native-Sonnet baseline on AX-rich suite (A/B).
2. **AX-first ablation** — AX/hybrid hit rate ≥ native coordinate grounding on labeled controls (PR #81 d21).
3. **Pixel-exact** — grounded clicks land on Notes/Settings (audit grounding rows + `elementAtPosition`).
4. **Cheap-tier step share > 85%** on AX-rich apps (from `assist.escalate` telemetry).
5. **Canvas correctness** — Keynote escalates to Sonnet native CU and completes at parity.
6. **Cost reduction** — measurable Sonnet-spend cut per task, zero success regression.
7. **No oscillation / STOP-safe** — one escalation per subgoal, honors STOP/supersession, never switches the live model.
8. **Planner actually uses marks** — Qwen cites `[ax:id]` on a high fraction of turns (else it silently degrades to fuzzy matching).

## Flags
`cascade.scoutPlanner.backend=openrouter` · `.model=qwen/qwen3-vl-235b-a22b-instruct` · `.endpoint` (NEW) · `.axSetOfMarks` (NEW) · `.semanticAXActions` (NEW) · `cascade.onScreenBackend=scout` · `cascade.onScreenFallbackModel` (NEW, default sonnet) · `cascade.tierRouter.enabled` (NEW master, default OFF) · `cascade.tierRouter.escalateAfterNoEffect` (NEW, default 2) · existing: `experimentalCompressedObservation`, `mixtureGrounding` (ON), `onScreenGrounding`, `visualGrounder.*`.

## Open questions
1. **Qwen3-VL-235B latency on OpenRouter is unpublished** — must benchmark against real screenshots; may need to pin a provider/routing mode or drop to qwen3-vl-30b for latency-sensitive turns.
2. **Qwen "thinking" variants** may emit reasoning traces that mis-slice `parseRawActions` — is the instruct id enough, or is stricter parsing needed?
3. **Real hit rate on Cascade's AX-serialized "name a mark" format is unverified** — all cited scores are ScreenSpot-Pro/OSWorld, not this format. Needs the S4 internal eval.
4. **AX-coverage thresholds have no literature precedent** — calibrate empirically.
5. **PR #81 is unmerged on top of a main with an open regression-fix PR #82** — merge/rebase order must be resolved before S2-d01.
6. **One OpenRouter key funds planner + grounder** (commingled billing) — per-tier key separation?
7. **Synthetic-AX-from-vision caching** (reuse one AX-shaped tree per canvas state to cap Sonnet calls) — attractive but staleness unevaluated; defer.
8. **GLM-5V-Turbo as a mid-cost rung** between Qwen and Sonnet, or is two-rung Qwen→Sonnet simpler and sufficient?
