# Plan — Smart Cascades + Deployed-Agent Parity (Features 4 & 5)

Status: proposed · Author: audit follow-up · Date: 2026-06-13
Scope: Feature 4 (Detected workflows → agents) and Feature 5 (Background web agents).
Companion: see `docs/FEATURES.md` §4–5 for the current surface; this plan is the upgrade path.

## The two rules this plan must satisfy

> **R1 — Smart, not mechanical.** "Agent has to be smart and know what the user would
> need — not just suggest or detect anything." Detection is a recall layer; the thing we
> show the user must be *judged useful*, named in their terms, and grounded in what they
> actually do.

> **R2 — Deployed = cursor-agent class.** "The deployed agent needs to be as fast and
> harnessed as the cursor agent." A workflow we deploy (on-screen replay or background
> web agent) must run on the **same fast, harnessed, intelligent runtime** as the assist
> agent — not a weaker, separate mechanism.

Everything below maps back to R1 or R2. A "Definition of Done" at the end checks both.

---

## 1. Where we are now (grounded)

### 1.1 The capability gap behind R2

The assist agent (`CascadeAppModel.runAssistEpisode`, ~line 942) builds a `ComputerUseAgent`
with the full kit. The two *deployed* surfaces do not:

| Capability | Assist (cursor) agent | Detected-workflow deploy (`runAgentRecipe`) | Background web agent (`BackgroundWebAgent`) |
|---|---|---|---|
| LLM in the loop | ✅ Computer-Use vision loop | ❌ **pixel replay only** | ✅ CU loop |
| Streaming execution (`streamSink`) | ✅ acts mid-generation (1008) | n/a | ❌ `begin`/`proceed`, no stream |
| App skills (`use_skill`) | ✅ `skillProvider` (950) | ❌ | ❌ |
| Harness (files / shell / AppleScript) | ✅ `harnessProvider`→`performHarness` (974/1197) | ❌ | ❌ (web-only, **no DOM tools**) |
| Conversation memory | ✅ `AssistMemory` | ❌ | ⚠️ findings memo only |
| Skill auto-learning | ✅ `episodeAppActions`→`distillSkill` (2253) | ❌ | ❌ |
| App pre-open from goal | ✅ `AppSkillRegistry.appNamed(inGoal:)` | partial (`activateApp` steps) | n/a |

Two different, weaker engines. `runAgentRecipe` is brittle (re-targets recorded pixels,
pauses after 2 unverified clicks) and can never use the harness — a "copy invoice totals
into Numbers" agent clicks cell-by-cell instead of running one AppleScript. `BackgroundWebAgent`
has the brain but not the speed (no streaming) or the reach (no DOM harness; it pokes
`document.elementFromPoint` from vision coordinates).

### 1.2 The intelligence gap behind R1

`WasteDetector` is purely mechanical: repeated token sequences with ≥2 structural actions +
an intent marker. It cannot tell a *valuable* repetition from a *boring* one, can't name the
task in human terms beyond a template, and **misses high-value work that isn't verbatim-repeated**
(the morning "check 3 dashboards and summarize" flow whose steps vary every day). `SuggestionEngine`
was reduced to a single daily-recap card. Nothing in the pipeline asks *"would the user actually
want an agent for this?"*

### 1.3 Foundation bugs found in the audit (must fix first — they undermine trust)

1. **Stopped/failed sandbox runs count as completed.** `applySandboxUpdate`
   (`CascadeAppModel.swift:518–553`) treats every `done:true` as success. `BackgroundWebAgent`
   emits `done:true` for `.stopped`, `.failed`, and `.stepLimit` too (`BackgroundWebAgent.swift:81–104,185`),
   so a stopped or failed deploy still calls `markAgentRun`, logs `agent.run.completed`, says
   *"Background agent done — Finished in the background,"* and **inflates the Manager's
   "Reclaimed (N runs)" metric** (`CascadeRootView.swift:1630`). The on-screen path gates this
   correctly on `!stoppedEarly` (2084); the sandbox path lacks the equivalent gate.
2. **`BackgroundAgentRun.snapshot` is a dead store** — written every step (513), read by no view.
3. **`backgroundAgents` entries are never removed**, only flagged `done` — unbounded growth.
4. **`WebSandbox.navigate` stale-timeout race** — a prior nav's 12s timer can resume a later
   nav's continuation early (`WebSandbox.swift:41–61`).
5. **No `AppShellTests` target** — the entire orchestration glue for both features (spawn,
   update handling, replay, scheduling, reclaimed math) has zero unit coverage. The one real
   bug lives exactly there.

---

## 2. North star

**One runtime, three faces.** Extract the assist episode engine into a reusable core that
every agent surface drives. The screen target and the tool surface become *injected* — the
real Mac, or the web sandbox — but streaming, skills, harness-inline-resolution, memory,
STOP/gen gating, and auto-learning are shared. Parity (R2) then stops being something we
copy and becomes something structural.

**Detection recalls; an LLM curator decides.** Keep `WasteDetector` cheap and mechanical as
the recall layer, but never show its raw output. A grounded curator turns candidates (plus
the broader record) into *judged, named, useful* proposals — and is allowed to drop noise and
promote value the detector can't see (R1).

---

## 3. Workstream A — Smart, need-aware Cascades (serves R1)

### A1. `WorkflowCurator` (new, ProviderKit — needs the model)
- **Input:** `WasteDetector` candidates + a privacy-filtered summary of the recent record
  (apps, recurring window titles, cross-app flows) + existing agents (dedupe) + declined
  signatures (don't re-pitch).
- **Output:** ranked `CuratedAgent` proposals, each carrying:
  - human name + one-line *"why this helps you"* (user's terms, not "Repeated steps in X"),
  - the **goal string** the deployed agent will actually run (intent, not pixels),
  - target: on-screen vs background-web (so Feature 5 gets first-class proposals),
  - value score + the evidence moment ids it's grounded in (reuse the citation chips).
- **Behavior:** allowed to **discard** mechanical candidates that aren't worth automating,
  **merge** near-duplicates, and **generalize** steps that are too literal. Grounded only —
  no agent proposed without observed evidence (mirror the `RecordSearchAnswerer` discipline).
- **Cadence:** runs in `refreshAll` behind a debounce; haiku-tier, cached; falls back to the
  raw `WasteDetector` list if the key/network is down (never worse than today).

### A2. Proactive "what would help" pass
- The curator also scans for **high-leverage web tasks the user does by hand** (recurring
  manual flows on the same sites) and proposes them as *background* agents — the single
  highest-value thing Cascade can offer, since they run while the user keeps working. This is
  the literal embodiment of "know what the user needs."

### A3. Card honesty
- Cards show the curator's name + why-it-helps + the grounded evidence thumbnail + the exact
  goal the agent will run (so "what will happen" is the truth, not a token soup). Keep the
  existing decline-persists + humanSteps preview.

**A — Definition of done:** the Cascades tab shows *useful, named, grounded* proposals (incl.
background-web ones), suppresses noise, and never invents an agent from nothing.

---

## 4. Workstream B — Deployed-agent parity (serves R2)

### B1. Extract `AgentRuntime` from `runAssistEpisode`
Pull the assist engine into one reusable unit (actor/class in ProviderKit or a new
`AgentRuntimeKit`) parameterized by:
- `goal`, `environment` (`.onScreenReal`, `.onScreenReplay(recipe)`, `.webSandbox`),
- an **`ActionExecutor`** (screen target — see B2),
- a **harness provider** (Mac harness, web harness, or none — see B3),
- `skillProvider`, `streamSink`, memory hooks, STOP/`assistGeneration` gates, auto-learn tally.
- **`onThinkingPulse` + the `assist.timing` audit** — owned by the runtime, not the call
  site, so BOTH surfaces inherit them. This is what makes §8's "measure with `assist.timing`"
  *real* for the sandbox (today it fires only on the assist path, `CascadeAppModel.swift:1063`,
  and `onThinkingPulse` is wired only at 1004) and gives the watch box a live "thinking…" tail
  instead of a frozen status during long model turns.

The assist hotkey/voice path keeps its exact behavior (it just calls the extracted runtime).

### B2. `ActionExecutor` abstraction (the key refactor)
One protocol, two impls, so the same CU loop drives either target:
- `RealScreenExecutor` — today's `executeCU` (CGEvent actuator, companion cursor, AX-snap).
- `WebSandboxExecutor` — today's `BackgroundWebAgent.apply(_:)` (JS click/type/scroll).
This is what makes parity structural rather than copied.

**B2 pacing amendment — fix the constants while porting, not "deferred forever."**
`WebSandboxExecutor` ports `apply(_:)` but rewrites its magic numbers in place: drop the
unconditional 350 ms loop gap (`BackgroundWebAgent.swift:179`) and gate it on `acted` — a
no-op/observation turn neither sleeps **nor re-snapshots** (the page didn't change, line 180).
Cut the per-action JS settles (click 150 / key 250 / scroll 150 ms) to measured minimums:
`dispatchEvent` is synchronous, so a settle only needs to cover the page's *async reaction*
(event handlers, fetch, re-render), not the dispatch — reduce, don't zero. Pairs with B5:
once DOM reads are inline, most turns don't touch the page and skip the gap entirely.

### B3. Harness on every surface
- **On-screen deploy** gets the same `harnessProvider`→`performHarness` the assist agent uses
  (files/shell/AppleScript, inline via `toolResultOverrides`, audited, deny-listed). A web/data
  workflow can now finish in one AppleScript instead of 20 clicks — *that* is "harnessed."
- **Background web agent** gets a new **`WebHarness`** — the DOM analog of the Mac harness
  (see B5). This is the biggest single speed + reliability win for Feature 5.

### B4. Background agent → streaming + skills + memory
- Set `streamSink` on `BackgroundWebAgent`'s `ComputerUseAgent` so it acts mid-generation
  (matches the assist agent's "cursor starts moving in ~2s" feel — directly serves "as fast").
- Pass `skillProvider` (web skills: webmail, calendar, docs, shopping) and wire its findings
  into the shared `AssistMemory` so chat/voice can answer "what did the background agent find?"
  (audit found completion is currently memory-only, never surfaced in chat).

### B5. `WebHarness` (new, SandboxKit) — the web analog of `AgentHarness`
Instant DOM tools resolved inline (zero screenshots), gated like `HarnessTier`:
- `read_page` → visible text + heading structure (replaces a vision round-trip),
- `list_interactives` → links/buttons/inputs with labels + stable selectors,
- `click_text` / `click_selector`, `fill_field(label|selector, value)`,
- `extract(instruction)` → structured data for the findings memo.
Semantic targeting beats `elementFromPoint` pixel-guessing → fewer steps, fewer misclicks,
much faster. Keep vision as the fallback when the DOM is opaque (canvas/SPA).

### B6. Hybrid replay for on-screen detected workflows (fast **and** smart)
Don't throw away the recorded recipe — use it as a **fast deterministic first attempt**, then
**escalate to the full `AgentRuntime`** (skills + harness + vision) the moment it drifts:
- UI matches → replay the recipe at near-zero latency (today's speed, kept).
- Fingerprint mismatch / unexpected modal / 2-unverified-clicks → instead of *pausing*, hand
  the goal to the intelligent runtime to finish from intent. The recipe seeds the goal; the
  CU agent adapts. Optionally distill the recipe into a learned SKILL.md on approve (reuse
  `distillSkill`), so the deployed agent pulls its own playbook.
This is the precise shape of "fast **and** harnessed": deterministic when it can be,
cursor-agent-class when it must be.

### B7. Outcome verification (trust + honest math)
The CU runtime already self-reports a concrete result line. On deploy, verify the *goal*
was achieved (deliverable exists / expected end-state), not just "the screen changed," and
only then count a reclaimed run. Closes bug #1 from the right end and raises trust.

### B8. Snapshot as JPEG at model resolution (verified win)
Today the sandbox renders at 900×560 and emits PNG; `ComputerUseAgent.begin/proceed` then
**upscales it to 1280×800 and re-encodes it to JPEG every turn** — `resize()` calls
`ImageConformance.isJPEG(data, 1280, 800)`, which is false on both format *and* size, so it
decodes→redraws→encodes (the exact round trip that check exists to avoid; `bestResolution`
picks 1280×800 for the sandbox's aspect). Fix both ends:
- Render the WebSandbox at **1280×800** and add `snapshotJPEG()` (compression ~0.7) so
  `isJPEG(data, 1280, 800)` passes and the frame rides through untouched — **zero per-turn
  re-encode**.
- The reliability half is the bigger one: rendering the *page* at 1280×800 gives the model
  real pixels of text (upscaling a 900-px frame adds none) → **sharper text → fewer misclicks**.
- Ripple: `SandboxBoxController` `viewW/viewH` + layout grow; the existing `scaler` already
  scales the view for the chip, so scale the expanded box down if 1280 is too wide. Land the
  layout change *with* B8.

### B9. Planner: cheaper and conditional
`BackgroundWebAgent.run` always pays a **sonnet** round-trip up front (`AgentTaskPlanner`,
default `AnthropicModel.sonnet`) before any visible action — pure front-loaded latency on the
"as fast as cursor" path.
- **Move the planner to haiku** as the floor: a 1–5 subtask split is structurally simple, and
  haiku still picks the smart `startURL` (the real service's site) — the quality you'd *lose*
  by skipping planning outright, since the no-plan fallback starts at a Google search.
- **Skip planning only when the start is already known** (the task names a URL, or it's a
  continuation), so single-part jobs that need no decomposition pay nothing. Conservative on
  the multi-part side: a misread just runs as one 80-step episode — degraded, not broken.

**B — Definition of done:** the deploy table in §1.1 has ✅ in every cell for both deployed
surfaces; a browser data task finishes via harness in one shot; the background agent streams.

---

## 5. Workstream C — Foundation fixes (the audit; do these first)

| # | Fix | Where |
|---|---|---|
| C1 | Distinguish completion from stop/fail/step-limit; only `markAgentRun` + "done" on a true finish. Add an outcome flag to `BackgroundWebAgent.Update` (or a `stoppedManually` flag set in `stopSandboxAgent`). | `applySandboxUpdate` 518–553; `BackgroundWebAgent.swift:81–104,185` |
| C2 | Remove the dead `snapshot` store, or actually render `backgroundAgents` somewhere. Decide one. | `CascadeAppModel.swift:513` |
| C3 | Remove `backgroundAgents` entries on completion/stop (cap the array). | `stopSandboxAgent`, `applySandboxUpdate` |
| C4 | Fix the `navigate` stale-timer (tag each navigation; the timer only resumes its own). | `WebSandbox.swift:41–61` |
| C5 | Concurrency cap + lifecycle for background agents (N max, queue or refuse beyond). | `createSandboxAgent` |
| C6 | First-snapshot retry before declaring `.failed`. | `BackgroundWebAgent.swift:147` |
| C7 | Stand up **`AppShellTests`**: spawn routes, `applySandboxUpdate` outcomes, reclaimed math, `fireDueSchedules`, hybrid replay escalation. | new test target in `Package.swift` |
| C8 | Doc fix: FEATURES.md "voice/chat" spawn (chat doesn't spawn) and "reuses your sign-ins" (box-only persistence). | `docs/FEATURES.md:78,75` |

---

## 6. Safety addition (genuinely helps — fits the STOP/audit ethos)

Deployed agents run with **less human supervision** than the assist agent — scheduled and
background runs may be fully unattended. So harness power must be gated accordingly:
- Scheduled/unattended runs default to **read-only harness**; the power tier
  (`run_command`/`run_applescript`/`write_file`) requires an explicit **per-agent** opt-in,
  not just the global toggle.
- The destructive deny-list + credential-path fence stay always-on (already true).
- Every deployed harness call audited verbatim (already true) — surface a post-run summary so
  an unattended run is reviewable after the fact.

---

## 7. Sequencing

1. **C1–C4, C7** — fix the trust bugs and put the safety net under the glue. Nothing smart
   matters if "Reclaimed" lies.
2. **B1–B2** — extract `AgentRuntime` + `ActionExecutor`. Pure refactor; assist behavior
   unchanged, covered by new tests.
3. **B5 + B4 + B8 + B9 + B2-pacing** — the sandbox-speed cluster: `WebHarness` + streaming +
   JPEG-at-resolution + cheaper planner + adaptive pacing. Biggest R2 win, isolated to the
   sandbox; `assist.timing` (now in the runtime via B1) proves each one actually helped.
4. **B3 + B6 + B7** — harness on-screen, hybrid replay→escalate, outcome verification.
5. **A1–A3** — the curator on top of the now-trustworthy, parity-class deploy.
6. **C5–C6, C8** — polish + docs.

Ship-able after each step; (1) and (3) each stand alone as user-visible wins.

## 8. Risks / non-goals
- **Latency vs. determinism:** the CU loop is slower per step than pixel replay — B6's hybrid
  (replay-first, escalate-on-drift) is the mitigation; keep replay as the happy path.
  Measurement is real, not aspirational: B1 puts the `assist.timing` audit in the shared
  runtime, so every surface emits per-turn model/action ms and B2/B8/B9 can be proven.
- **Refactor blast radius:** B1/B2 touch the hottest code in the app — gate behind C7 tests and
  land assist-unchanged first.
- **Curator hallucination:** strictly grounded + cited + degrade-to-raw-detector on failure.
- **Non-goals:** the manager remote platform, custom schedule times, LaunchAgent persistence —
  out of scope here.

## 9. Definition of Done — checked against the two rules
- **R1 (smart):** Cascades shows curator-judged, human-named, grounded proposals (incl.
  background-web), drops noise, and proposes high-value web tasks the mechanical detector
  would miss. No agent without evidence.
- **R2 (parity):** both deployed surfaces run on the shared `AgentRuntime` — streaming, skills,
  harness (Mac + Web), memory, auto-learning. The §1.1 table is all ✅. A browser data task
  finishes via harness in one shot; on-screen deploy escalates to the intelligent agent instead
  of pausing; "Reclaimed" only counts verified completions.
