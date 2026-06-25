# Cutting the CU-Agent Failure Rate — research + playbook (2026-06-24)

Synthesized from a deep-research workflow (`wf_0975dd0b-e08`): 5 search angles → 25
sources fetched → 121 claims → 24/25 survived 3-vote adversarial verification. Scoped to
techniques **beyond** what Cascade already ships (planner/grounder split, mixture-of-grounding,
no-effect detection, stall guards, Skyvern-style validator, Set-of-Marks push, fill-field
batching, transport retries, adaptive demo replay) and what `docs/RESEARCH_FINDINGS.md`
(2026-06-22) already mapped (UI-TARS, Agent-S/S2/S3, cua, OpenAdapt, AgentRR, Skyvern,
browser-use, Stagehand).

**License gate (from CLAUDE.md):** port MIT/Apache/BSD only; GPL/AGPL/BSL/source-available =
design inspiration only.

---

## The two framing facts

1. **External-signal verification works; intrinsic self-reflection doesn't.** Every reliable
   lever below is grounded in a tool / test / screenshot diff / schema, not the model
   second-guessing itself.
2. **Reliability compounds multiplicatively** — 99%-reliable steps → ~90% success at 10
   steps. The lever is fewer fragile steps + a verifier on each, not a bigger brain.

---

## Findings (all verified, with numbers)

### 1. Grounder upgrade — highest leverage-per-effort, port-friendly ⭐
Cascade grounds with hosted `bytedance/ui-tars-1.5-7b`. Two newer **Apache-2.0** open-weight
grounders beat it, and a grounder-only swap is the most causally-proven single lever in the field.

| Model | License | Size | ScreenSpot-Pro | Note |
|---|---|---|---|---|
| **UI-Venus-1.5** | Apache-2.0 (Qwen3-VL) | 2B/8B/30B-A3B | **69.6%** (OSWorld-G 70.6%) | SOTA open grounder; mlx-community MLX build exists |
| **Holo1.5-7B** | Apache-2.0 | 7B | **57.94%** | wins 5/6 grounding benchmarks size-matched |
| UI-TARS-1.5-7B *(current)* | Apache-2.0 | 7B | 39.0% | — |
| Jedi-7B | open | 3B/7B | 39.5% | causal proof ↓ |

**Causal evidence:** holding the planner fixed (o3), swapping the grounder to **Jedi-7B lifted
end-to-end OSWorld 23% → 51%** (2.2×). Grounding *is* the bottleneck (Cascade's own thesis).
**Catch:** Cascade went hosted because end users won't run a 7B on an 8GB M1 — so this needs a
host serving UI-Venus-1.5 / Holo1.5, or the 2B UI-Venus via MLX locally. Coordinate-space note:
UI-Venus is Qwen3-VL-based; re-verify the `smartResize` mapping (UI-TARS used Qwen2.5-VL).
Sources: [UI-Venus-1.5](https://huggingface.co/inclusionAI/UI-Venus-1.5-30B-A3B) ·
[Holo1.5](https://hcompany.ai/holo1-5-open-foundation-models-for-computer-use-agents) ·
[OSWorld-G/Jedi](https://osworld-grounding.github.io/)

### 2. Semantic post-action Actor-Critic — the most load-bearing verifier measured
After each action, a model compares before/after screenshots and judges whether the *intended
subtask outcome* occurred (not just "did pixels change"). In **GUI-Thinker / WorldGUI-Agent**,
ablating this one stage collapses success **26.0% → 9.7% (−16.3pp)** — larger than any other
module. This is the semantic upgrade to Cascade's perceptual-hash no-effect detector (which
answers "did the screen change," not "did the *right* thing happen"). Watch latency — it's an
extra round-trip per action; gate it to uncertain/important turns. Design-portable.
[paper](https://arxiv.org/pdf/2502.08047) · [repo](https://github.com/showlab/GUI-Thinker)

### 3. Pre-action outcome critic — "look before you leap"  ← (deterministic core shipped, see below)
A critic reasons about a candidate action's likely outcome **before** executing, to block
irreversible mistakes. **GUI-Critic-R1** (7B, open code) as a pre-critic raised **AndroidWorld
22.4% → 27.6% (+5.2pp)** and beat a GPT-4o post-critic. Port-friendly; mobile-validated.
[Look Before You Leap](https://arxiv.org/abs/2506.04614)

### 4. Small-N Behavior Best-of-N — biggest absolute lever, N× compute
Run N rollouts in parallel, summarize each as a "behavior narrative," judge comparatively.
**bBoN/BJudge** (Simular Agent S3) set **OSWorld 69.9% → 72.6%, beating the 72.36% human
baseline**. N-fold compute → wrong for the watched assist agent, **right for background /
scheduled / unattended agents** where no human waits. Gate to N=2–3 on high-value tasks.
[paper](https://arxiv.org/abs/2510.02250)

### 5–6. Lower priority (new but costly/narrow)
- **World-model look-ahead (WMA, ICLR 2025):** predict next-state per candidate action, score,
  pick best, policy frozen → WebArena **+29.7% rel**; oracle next-state lifts action selection
  **53% → 73%**. Port-friendly 8B, but web-validated — adapting next-state to screenshots/AX is
  real work. [paper](https://arxiv.org/abs/2410.13232)
- **Formal pre-action verification (VeriSafe, MobiCom 2025):** autoformalize intent → logic
  pre-check. Recovered **60–86% of failed tasks where LLM reflection recovered 0%** — but ~437
  LoC hand-written spec/app, mobile-only. Reserve for a few high-stakes irreversible Power-harness
  workflows. [paper](https://arxiv.org/pdf/2503.18492)

---

## Prioritized playbook (gain-per-effort, license-tagged)

1. **Swap grounder → UI-Venus-1.5 / Holo1.5-7B** — *port-friendly (Apache-2.0)*. Config-level;
   nearly-2× OSWorld evidence. **Gated on hosted availability + coordinate-mapping re-verify.**
2. **Gated semantic Actor-Critic** (intended-outcome check on uncertain/important turns) —
   *design-portable*. Upgrades the coarse no-effect detector; −16.3pp when absent. Mind latency.
3. **Pre-action outcome critic on risky actions** (prompted first, 7B later) — *port-friendly*.
   **← This PR ships the deterministic, structural core of this (see below).**
4. **Small-N Behavior Best-of-N on background/unattended agents only** — *design-portable*.
   Largest absolute lever where latency doesn't bite.
5. **World-model look-ahead** — *port-friendly 8B, higher build cost*. Later.
6. **Formal verification for the Power/unattended safety tier only** — *design-only, manual spec*.

---

## Shipped in this PR (`feat/action-risk-critic`)

The deterministic backbone of #3, in the structural form Cascade's hard-won law demands (the
runtime refuses; it doesn't merely prompt — the cmd+v prompt ban didn't hold, the paste gate did):

- **`ComputerUseAgent.isIrreversibleCombo`** — narrow classifier for keys cmd+z can't undo:
  `cmd+Q` (quit), `cmd+shift+Q` (log out), `cmd+option+esc` (force quit), `cmd+shift+Delete`
  (empty Trash). In-document deletes stay ungated → no false-fire on normal editing.
- **`irreversibleRefusal` / `actionRefusal`** — reuse the paste-gate plumbing
  (`toolResultOverrides` + `onActionRefused`): refuse the action, teach via the tool_result.
  Stand down when the goal's words sanction it (`goalMentionsDestruction`).
- **`guardIrreversibleActions`** — **OFF by default**; arm with
  `defaults write com.humain.cascade cascade.guardIrreversibleActions -bool YES` (best for
  unattended/scheduled runs). Set in `makeAssistAgent`, so it re-applies on Opus escalation.
- 403 tests (+3 `ActionGateTests` pins). Default-off = zero change to the shipped path until A/B'd.

**Why this slice first:** it's the one playbook item that is (a) fully unit-testable without a
live screen/keys, (b) reuses existing structural plumbing, (c) prevents a catastrophic, documented
failure class (task abandonment via a stray quit), and (d) ships dark behind a flag. The bigger
levers (grounder swap, Actor-Critic, best-of-N) all need live API keys + a real screen to verify,
so they're written up here rather than shipped blind.

**Follow-ups not in this PR:** extend the gate to the Scout (`ScoutAgent`) path; add the async
model-based pre-critic + semantic Actor-Critic behind their own flags; A/B the grounder swap once a
host serves UI-Venus/Holo1.5.

---

## Caveats (verified)
- **Platform mismatch:** GUI-Critic-R1, VeriSafe, WMA numbers are Android/web, not macOS — transfer
  is extrapolation. Grounding + Actor-Critic + bBoN are desktop, but **no macOS-AX-native harness
  score surfaced** (worth its own eval).
- **Moves fast:** by April 2026 the OSWorld-Verified board already shows Holo3-35B (~82.6%) and
  Claude Opus 4.6 (~72.7%) past the 72.6% bBoN figure — track GUI-OWL-1.5 / Holo3 next.
- **Self-reported:** UI-Venus-1.5, Holo1.5, bBoN headline numbers are vendor/author-reported; WMA,
  VeriSafe, GUI-Critic-R1, Jedi are peer-reviewed (ICLR/NeurIPS/MobiCom 2025).
- **Memory/experience reuse (AWM, Synapse)** produced no strongly-verified desktop gain this pass —
  Cascade's demo-replay already covers much of that ground.
