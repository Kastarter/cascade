# Plan — Rewind → Agent (intentional grounding)

Status: proposed · Author: audit follow-up · Date: 2026-06-14
Scope: turn *what the user actually did* into an agent through user-initiated front doors —
**(1) Agent from a Reel selection** (retrospective) and **(2) Teach-once** (prospective) — by
collapsing every agent-creation entry point onto one shared spine. Includes **(3)** retiring the
vestigial heuristic "suggestion pipeline."
Companion: `docs/AGENT_PARITY_AND_INTELLIGENCE_PLAN.md` (the *automatic* curator, Feature 4).

## The core idea this serves

> Cascade's main loop: **Rewind records what you did → Cascade turns *that* into an agent.**

Today the only path into an agent is **automatic** — `WasteDetector.detect`
(`WasteDetector.swift:63`) mines `input_event` for verbatim-repeated sequences, the curator ranks
them, the manager approves. The user **cannot point at their own history and say "make that an
agent."** This plan adds the intentional half of the loop — and, while doing so, unifies the
creation backend instead of adding a parallel one.

## The unifying insight: one backend, N front doors

Every way of creating an agent reduces to the same line:

```
  a time range of recorded input  →  build a DetectedWaste (recipe + apps + evidence + signature)
        →  curate (name + why + goal)  →  CuratedAgent  →  orchestrator.createAgent(from:)
```

- **Auto-detect** (exists) picks the range by *repetition*.
- **Feature 1** picks it **retrospectively** (drag on the Reel).
- **Feature 2** marks it **prospectively** (start/stop a demonstration).

Everything after "a time range" is **already built** (`AgentOrchestrator.swift:308` `createAgent`,
`deployAgent`, `runsInBackground`). The only new backend is *getting a `DetectedWaste` from an
arbitrary range* and *curating a single one*. Build that spine once (§A); the front doors are thin
(§B, §C); then delete the thing that pretends to be a third pipeline (§D).

**Efficiency rule for this plan: reuse, don't add.** No new creation path, no new card-model type,
no new on-screen/background target field — the range produces a `DetectedWaste` like the detector's,
and the deploy-time `runsInBackground(apps:)` (`CascadeAppModel.swift:2021`) already routes
on-screen vs sandbox. The intentional paths are what finally exercise the on-screen `runAgentRecipe`
replay (`CascadeAppModel.swift:2140`), today near-dead because `isAutomatable` keeps auto-detected
agents browser-only.

---

## A. Shared spine (build first — pure backend, fully testable)

### A1. Fetch input by time range — `CascadeMemory`
- **New:** `func inputEvents(between start: Date, and end: Date, limit: Int = 2000) -> [InputEvent]`,
  a `captured_at`-bounded mirror of `recentInputEvents(limit:)` (`CascadeMemory.swift:660`).
- `contexts(between:and:)` already exists (`CascadeMemory.swift:489`) for the OCR/AX anchors — reuse.

### A2. `DetectedWaste` from a range — factor out of `WasteDetector`
- `makeWaste(instance:occurrences:contexts:surface:)` (`WasteDetector.swift:158`) already turns a
  list of `InputEvent` + contexts into a full `DetectedWaste` (app-activation steps, AX `ocrAnchor`,
  window-title hints, timing, `apps`, `evidence`, `signature`, title). **Promote it to a reusable
  entry point** — `func waste(fromInstance events: [InputEvent], contexts:, occurrences: Int = 1)` —
  with the default `surface` (the app itself; pass `CascadeAppModel.webAppIdentity` from callers that
  want web-surface naming). Auto-detect keeps calling its own path; **no behavior change**.
- Apply the detector's **intent-marker / ≥2-structural guard** (`WasteDetector.swift:134`) here too,
  surfaced as a thrown/optional result, so a range with only scrolling/typing returns *nothing*
  rather than a junk recipe. One rule, one place.

### A3. Curate a single recipe — `WorkflowCurator`
- **New:** `func curateOne(_ waste: DetectedWaste, statedIntent: String? = nil) async -> CuratedAgent?`
  that reuses the existing `parse` + `fallback` (`WorkflowCurator.swift:132`,`:159`) with a prompt
  variant: judge **one** recipe (occurrences may be 1; on-screen is allowed — drop the "repeats 3×,
  browser-only" preamble), fold in the user's `statedIntent` when present as the strongest naming
  signal, and emit `name` / `why` / `goal`. Grounded only; **falls back to `WasteDetector.title(...)`
  naming** when the key/network is down — never worse than the auto path.
- The single-element list could *almost* go through the existing `curate([waste])`
  (`AgentOrchestrator.swift:281`); it doesn't, only because that prompt assumes repetition + browser.
  `curateOne` is that one prompt difference, nothing more.

### A4. Provenance (light)
- Carry the source `[start, end]` + `evidence` ids on the preview so the card reads **"built from your
  recording, 9:12–9:15"** with clickable proof chips (`jumpToMoment`, `CascadeAppModel.swift:358`).
  `DetectedWaste.evidence` already holds the moment ids — no new persistence needed for v1.

**A — Definition of done:** given any `(start, end)`, Cascade yields a named, grounded `CuratedAgent`
via the *existing* `createAgent(from:)`, with provenance back to the rewind. Backend-only; no UI.

---

## B. Feature 1 — "Make this an agent" from the Reel  *(marquee; ship-able alone)*

The Reel scrubs by `Date` and asks (agentic Q&A) but has **no range selection and no creation
affordance**.

- **B1** Range selection on the timeline: shift-drag marks `[start, end]`, with an end-frame thumbnail
  so the user sees exactly what they grabbed.
- **B2** "Make this an agent" → A1 + `contexts(between:and:)` → A2 → A3 → **preview sheet** (curator's
  name + goal + the numbered when-deployed steps, the same `humanSteps` preview the `WasteCard` uses).
  A range with no structural actions shows "nothing repeatable here yet" (A2's guard), not a junk agent.
- **B3** **Create** calls the existing `createAgent(from:)`; the agent lands in **Your agents** with
  provenance chips; deploy path unchanged.

**Tests:** `inputEvents(between:and:)` bounds; a known range yields the same recipe the detector would
for that instance; a no-intent range is refused, not created.

---

## C. Feature 2 — Teach-once ("watch me do it")  *(reuses the entire spine)*

Recording is already always-on (`InputRecorder`, `input_event`, contexts); it's just never bracketed.
Cascade already distills a *skill* from the **agent's own** runs (`distillSkill`,
`CascadeAppModel.swift:2477`) — this is the user-demonstration analogue, producing an **agent**.

- **C1** Demonstration bracket: a hotkey / notch button stamps `[start, end]`. Notch shows
  "Teaching — do the task, press ⌥⌃T to finish" (consistent with the STOP/visible-control ethos).
  Nothing new is captured — only bracketed.
- **C2** On stop: A1 + `contexts(between:and:)` → A2 → A3 → preview → create. If the user narrated
  while demonstrating ("pulling the weekly numbers into the report"), pass that `RealtimeVoice`
  transcript as A3's `statedIntent` — the best naming/generalizing signal. Silent demo still names via
  curator inference / fallback.
- **C3** *(optional)* also distill a `SKILL.md` for the dominant app (reuse `distillSkill`) so the
  deployed agent pulls its own playbook.

**Tests:** bracket captures exactly the events in `[start, end]`; spoken intent reaches the curator and
shapes the name/goal; a silent demo still produces a named agent (fallback).

---

## D. Retire the heuristic "suggestion pipeline"  *(deletion, not addition)*

`SuggestionEngine.suggest()` (`SuggestionEngine.swift:53`) is no longer a pipeline — it's a constant:
guard on ≥2 contexts, return one hardcoded "daily recap" card. The `SuggestionKind` enum (3 cases,
only `dailyRecap` ever emitted), the `AgentSuggestion` model, the orchestrator method, and the
3-branch `deploySuggestion` (`CascadeAppModel.swift:1934`, two dead branches) are ceremony around one
button — and a recap is a **deliverable**, not an agent, so it never belonged with the curator anyway.

- Collapse it to a single static quick-action ("Draft today's recap") wired directly to the Reel
  `ask(...)` it already fires — no `SuggestionEngine`, no `AgentSuggestion`, no `suggestions()` round
  trip in `refreshAll` (`CascadeAppModel.swift:266`).
- This shrinks the proposal-model surface from **four types** (`AgentSuggestion`, `DetectedWaste`,
  `CuratedAgent`, `ManagerCascade`) toward the **one** that matters for agents (`CuratedAgent`), and
  removes the only card that masquerades as record intelligence without doing any.

**D — Definition of done:** the recap survives as a labelled quick-action; `SuggestionEngine` /
`AgentSuggestion` / `SuggestionKind` are gone or reduced to a trivial constant; no UI regression.

---

## Sequencing

1. **§A** shared spine + **§D** cleanup — pure backend, test-covered, nothing user-visible breaks.
   (§D can land first; it only removes code and de-risks the model surface §A unifies onto.)
2. **§B** Reel selection — the marquee: *"my recording became my agent,"* with the user's own hands.
3. **§C** Teach-once — the bracket + optional voice intent over the same spine.

All three ride the existing creation/deploy path, so they inherit the parity refactor's runtime
improvements (`AGENT_PARITY_AND_INTELLIGENCE_PLAN.md`) for free once that lands.

## Risks / non-goals

- **Garbage-in:** a sloppy demo / over-broad selection → weak recipe. Mitigation: A2's intent-marker
  guard + A3 curator + **preview-before-create** (the user always sees what they'll get).
- **Over-literal recipes:** raw pixels don't generalize — A3 curates to intent; once the parity plan's
  hybrid replay lands, the deployed agent adapts rather than blind-replaying.
- **Non-goals:** step-by-step recipe editing in a GUI, multi-range stitching. Preview is
  review-and-accept, not an editor.
