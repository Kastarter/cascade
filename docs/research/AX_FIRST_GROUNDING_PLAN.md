# AX-First Grounding — sequenced implementation plan

## Context
Decided 2026-07-02 after a live A/B: Cascade's computer-use failure rate is dominated by **grounding + the macOS environment**, not the agent loop. Agent S3 (70% OSWorld SOTA) *also* failed "open Notes and type hello" on this Mac — UI-TARS coords `(894,120)` executed as `(670,99)` (a resolution-mapping miss) and its own terminal stole focus. Cascade's structural **edge** is the macOS **AX tree**: exact coordinates + semantic actions for labeled controls, which pure-vision engines can't use. So the strategy is **AX-first grounding**. See [[cascade-ax-first-grounding-strategy]].

Backed by a parallel research pass (`wf_fda960d1-58c`): A11y-Compressor (compress AX → 22% tokens, +5.1pp OSWorld), Screen2AX (only ~33% of macOS apps have full AX; synthesize AX-like nodes from vision, +2.2×), GUIrilla/macapptree (native macOS AX crawler + corpus), Set-of-Mark, ScreenSpot-Pro / DRS-GUI (crop-and-refine, don't ground full-screen), Agent-S mixture-of-grounding, UI-Venus-1.5 (canvas fallback).

## Architecture — three-layer grounding stack
1. **Native AX** (default): `AXUIElement` authoritative (identifier/role/subrole/title/description/value/frame/actions/state). Execute by preference: **semantic AX action** (`AXPress`/`AXSetValue`/`AXRaise`) → **exact AX-frame click** → verified coordinate click (last resort). Verify after every action (AX re-read + `elementAtPosition`).
2. **Event-driven AX cache + compressed planner view**: observer-invalidated per-window snapshots; the planner sees *grouped, task-relevant candidates with stable ids* (A11y-Compressor), never the raw tree.
3. **Synthetic AX from vision** (fallback only): canvas / custom / Electron / missing-AX → crop-and-refine vision (UI-Venus) → **synthetic AX-like nodes** (Screen2AX), never raw pixels. Native AX always outranks synthetic unless verification proves AX wrong.

**Coordinates are typed values, never `{x,y}`.** Persisted chain per visual action: logical points → owning `NSScreen` → backing pixels → screenshot crop px → model smart-resized input → model output → inverse-resize → crop→backing → backing→logical. Never assume 1920×1080; never multiply by a guessed scale; use AppKit conversion APIs tied to the real `NSScreen`.

## Build on what exists (don't greenfield)
Cascade already has: `AXElementResolver` (find/interactables/frontmostState), `MixtureGrounder` (AX-first + visual + verifier + best-of-N), `VisualGrounder`/`UITARSGrounder` + `GrounderRegistry`, `GroundingVerifier`, `LocalRegionNarrower` (crop), `GroundingBench`, `executeCU`. Every task below **extends** these.

---

## SEQUENCES (each task = one commit+push on `feat/ax-first-grounding`)

### S1 — Retina-safe typed coordinates *(foundation — the tonight miss)*
- **d01** New `CoordinateTransform` type: logical-points ↔ backing-pixels ↔ crop-pixels ↔ model-coords, using `NSScreen`/AppKit conversions (no guessed scale). One authoritative mapping helper.
- **d02** Golden calibration tests: 1440×900 Retina, 1080p external, mixed Retina+non-Retina, negative-origin secondary display, window spanning displays. These are the regression guardrail.
- **d03** Route `MixtureGrounder` + `UITARSGrounder` coordinate mapping through `CoordinateTransform` (replace ad-hoc smartResize math); persist the full typed chain in the `agent.ground` audit.
- **d04** Live-verify: a grounded click lands pixel-exact on a known control (menu bar item, Dock icon) — read `agent.ground` + confirm the hit.

### S2 — Native AX query/action hardening
- **d05** Extend `AXElementResolver`: richer actionable-node capture (AXIdentifier, subrole, description, value, supported-actions, enabled/focused/selected) + a stable per-node id.
- **d06** Semantic AX actions in `executeCU`: prefer `AXPress`/`AXSetValue`/`AXRaise` over coordinate clicks; coord-click only when no AX action applies or it fails. Audit which path was taken.
- **d07** AX error taxonomy (timeout / unsupported-attr / stale-node / permission-denied) + explicit handling + audit — no silent AX failures.
- **d08** Post-action verification + focus discipline: re-read target/window after acting, `elementAtPosition` sanity check, and **raise/focus the target app before acting** (the Agent-S terminal-focus failure).

### S3 — AX observer cache + compressed planner view
- **d09** Event-driven AX observer cache: per-app/window snapshots, invalidation on focus/window/value/children changes, stale-node detection (replaces fresh full-tree scrape per turn).
- **d10** Compressed planner observation (A11y-Compressor style): grouped, task-relevant candidates with stable ids + role/name/value/frame/actions/modality/hierarchy — not the raw tree. Audit token + candidate counts.

### S4 — AX Set-of-Marks grounding *(the core lever)*
- **d11** Surface the AX-SoM candidate list to the planner (stable id + label + exact frame) in the assist/scout note — the model picks a real control, never invents a description.
- **d12** Picker execution: planner returns a mark id → execute via the exact AX frame + semantic action; gate `MixtureGrounder` to try AX-SoM **first**, VLM only if no AX candidate. No model-generated coords for AX-covered targets.
- **d13** Disagreement/confidence gate: when AX / OCR / vision candidates disagree, resolve by trust order (native AX > synthetic) + confidence, audit the decision.
- **d14** Live-verify on tonight's failures: Notes → "New Note", System Settings → "Privacy & Security", Keynote start screen → a template. Confirm the click lands + the task advances.

### S5 — Synthetic-AX vision fallback *(canvas only)*
- **d15** Routing gate: AX-first; vision **only** for canvas / non-AX / stale (formalize `namesCanvasConcept` + `axUnreliable` + sparse-AX into one router with an audit reason).
- **d16** Crop-and-refine (extend `LocalRegionNarrower`, per ScreenSpot-Pro/DRS-GUI): crop to the uncertain region, ground at higher effective resolution — never full-screen.
- **d17** Convert vision output → synthetic AX-like nodes (Screen2AX): `{source:vision, role, label, frame, confidence, actions}` — same structural interface; native AX outranks.
- **d18** UI-Venus-1.5 as canvas grounder: add the `GrounderRegistry` preset + a narrow self-host endpoint contract (crop+query → bbox/point/confidence via vLLM/SGLang); keep UI-TARS-7B as baseline. *(No reliable OpenRouter path for these — document the self-host step.)*

### S6 — Eval harness + regression corpus + ablations
- **d19** Extend `GroundingBench` into an **AX-grounding eval**: per-app/target — does AX expose it, does the click land — scored by execution/final-state, not click-count. (Solves the privacy-hashed-target gap by generating targets from a live AX crawl, not recorded frames.)
- **d20** Regression corpus via macapptree-style AX crawl of target apps (Notes, System Settings, Keynote, Safari) → grounded tasks + semantic action traces.
- **d21** Ablation: AX-only vs vision-only vs hybrid on the corpus → prove the AX-first hybrid wins; this is the number that tracks the failure rate.
- **d22** *(stretch)* Wrap Cascade for MacAgentBench for external checkpoint-level scoring.

---

## Repos/papers to reuse (not reinvent)
Hammerspoon `hs.axuielement` + AXSwift/Swindler (Swift AX patterns), MacPaw `macapptree` (AX JSON schema + corpus), microsoft/OmniParser (vision-fallback schema), inclusionAI/UI-Venus (canvas grounder), microsoft/UFO2 (OS-native action-layer architecture), simular-ai/Agent-S (mixture-of-grounding router). Papers: A11y-Compressor, Screen2AX, ScreenSpot-Pro, Set-of-Mark, SeeAct, GUIrilla, DRS-GUI, OSWorld.

## Working discipline
- One commit+push per **d0x** task on `feat/ax-first-grounding`; small, attributable, reviewable.
- **Verify by running** ([[cascade-verify-by-running]]) — build + install + read `audit_event`/`log show`, not `swift build` alone. Coordinate + AX changes especially need the live check.
- Land behind flags where behavior changes; keep the current path working until the ablation (d21) proves the new one.
