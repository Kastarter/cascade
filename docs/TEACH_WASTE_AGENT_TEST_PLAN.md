# Test Plan — Teach-once · Waste Detector · Agent Creation

Last updated: 2026-07-07. These three are **one pipeline**: both front doors —
Teach-once (⌥⌃T demonstration) and automatic Waste detection — funnel through
`curate → orchestrator.createAgent(from:) → deploy/runAgentRecipe`.

## ⚠️ Critical finding (audit DB, 2026-07-07)

Queried the live `~/Library/Application Support/Cascade/Cascade.sqlite` (1.1 GB, actively recording). **These three pipelines have NEVER run end-to-end on this machine**, despite heavy on-screen-agent and rewind usage:

- `agents` table = **0 rows** → no agent has ever been created, taught, or deployed.
- **No `teach.started` / `teach.stopped` / `agent.taught`** rows ever → the Teach-once *demonstration* pipeline has never fired. (Only `teach.region` / `teach.reveal` fired twice on 2026-07-04 — that's the *pointing/guidance* path, a different feature.)
- **No `recipe.*` rows** ever → no recipe/agent has ever been deployed or replayed.

So "we tested on-screen + rewind chat" is real (`computer.act`, `assist.*`, `grounding.*`, `sandbox.act`, `rewind.capture` are all heavily populated), but the teach/waste/agent-creation half of the product is **completely unexercised at runtime.** This is exactly the [[cascade-verify-by-running]] risk. Treat everything below as a *first* run, not a regression check.

## Layer 1 — deterministic logic tests (run first)

```bash
swift test --filter WasteDetectionTests      # mining/ranking/abstraction logic
swift test --filter AgentOrchestratorTests   # curation → createAgent → mapping
```

### Result 2026-07-07 — WasteDetectionTests: 95/97 pass, 2 fail

Both failures are on the **experimental episode-mining path** (`cascade.experimentalEpisodeMining`, D-04, default-OFF). The shipped **default contiguous path passed every test.**

- ✘ `defaultEpisodeMiningPipelineMeetsOfflineFixtureThresholds()` — offline fixture precision/recall/F1 below threshold (2 issues).
- ✘ `defaultEpisodeMiningFlagUsesProductionEpisodePath()` — default flag not routing to the production episode path (1 issue).

**Interpretation:** the default waste detector you'd exercise in the app is green. The opt-in episode-mining upgrade has regressed against its own quality bar — do **not** flip `cascade.experimentalEpisodeMining` on for the demo until these two are fixed.

### Result 2026-07-07 — AgentOrchestratorTests: 47/49 pass, 2 fail

Both failures are in `WorkflowCuratorTests` — the **curator prompt** that turns a demonstration/detected recipe into a *parameterized* agent (the shared spine for Teach-once and waste-card creation):

- ✘ `curatorPromptUsesPrivacySafeFieldAwareParameterMetadata()` (WorkflowCuratorTests.swift:263–264) — the prompt's parameter metadata isn't privacy-safe / field-aware as expected (2 issues).
- ✘ `curatorPromptFlagsParametersThatChangeEachRun()` (WorkflowCuratorTests.swift:233) — the prompt isn't flagging run-varying parameters as expected (1 issue).

**Interpretation:** curation → `createAgent` → action-mapping logic passes; the **prompt construction** for parameterized agents has drifted from its spec. Agents built from a demonstration with per-run varying fields (dates, invoice IDs) may mis-parameterize. Fix before relying on the taught-agent replay for anything with variable fields.

## Layer 2 — in-app end-to-end (the real test)

Prereqs: `.build/Cascade.app` running, **recording ON** (`REC · LOCAL`), Screen Recording + Accessibility + Input Monitoring granted, Claude key `CONNECTED`. Run `./scripts/demo-setup.sh` for fixture files. Keep a SQLite shell open on the DB for verification:

```bash
DB=~/Library/Application\ Support/Cascade/Cascade.sqlite
watch_audit() { sqlite3 "$DB" "SELECT created_at,actor,action FROM audit_event ORDER BY id DESC LIMIT 15;"; }
```

### Test A — Teach-once (demonstrate → agent)

1. Press **⌥⌃T** → banner reads "Teaching — do the task…". *Verify:* `sqlite3 "$DB" "SELECT action,detail FROM audit_event WHERE action='teach.started' ORDER BY id DESC LIMIT 1;"` returns `teach.started` with `cadence=0.5s` (the demo capture burst armed — the rewind stream restarts at 2fps with a 0.5s persistence gap for the length of the demonstration). *Verify after step 3:* `sqlite3 "$DB" "SELECT COUNT(*) FROM recorded_context WHERE captured_ms BETWEEN <start_ms> AND <end_ms>;"` shows roughly 2 moments/second while the screen was changing (vs ~1/s normally).
2. Do a real, repeatable task by hand (e.g. open `~/CascadeDemo/Invoices/falcon-invoice…`, copy the amount, paste into Numbers). Narrate if you like.
3. Press **⌥⌃T** again → "Saving your demonstration…". *Verify:* `teach.stopped` row exists.
4. A **preview sheet** appears with the curated agent (name + numbered steps). *This is the pass/fail moment.* If it says "Nothing repeatable in that demonstration yet," curation found no signal — a real failure to log.
5. Click **Add to my agents**. *Verify:* `agent.taught` row exists **AND** `sqlite3 "$DB" "SELECT COUNT(*) FROM agents;"` is now ≥ 1. The agent appears under **Cascades**.

### Test B — Waste detector (automatic discovery)

1. Perform the **same short action loop ≥ 3 times** in one app/window (CLAUDE.md: repeated-work groups need ≥3 moments) — e.g. copy field from invoice → paste into Numbers, three invoices in a row, no long idle gap between them.
2. Trigger a refresh (the app calls `refreshAll()` on its cadence; reopening the **Cascades** tab forces the view). Wait one refresh cycle.
3. *Pass:* a **DetectedWaste card** appears in Cascades with a rewind thumbnail + numbered steps. *Known issue (docs/…KNOWN):* the card title is currently "Repeated steps in <app>" + token soup — expect it to look raw; that's a real demo blocker, not a test failure of detection itself.
4. *Verify detection independent of UI:* if no card shows, the input events may not have been mined — check `sqlite3 "$DB" "SELECT COUNT(*) FROM input_event WHERE created_at > datetime('now','-10 minutes');"` is non-zero (events recorded) before blaming the detector.

### Test C — Agent creation → deploy → replay

1. From the Cascades card (Test B) or the taught agent (Test A), click **Approve** then **Deploy**.
2. *Pass:* the companion cursor replays the workflow on the real screen; STOP dock visible. *Verify:* `sqlite3 "$DB" "SELECT action,detail FROM audit_event WHERE action LIKE 'recipe.%' ORDER BY id DESC LIMIT 20;"` shows `recipe.run.started` followed by `recipe.step` rows.
3. Hit **Esc** mid-replay → *Verify:* replay stops and a `Stopped.` / step-limit row lands.
4. Completion → `agent.run.completed` row.

## Known gotchas that WILL bite during this test (from Known Issues)

1. **`deploySuggestion` runs the suggestion TITLE as the goal**, not the mined recipe → a deployed *waste-card* agent may do the wrong thing. Test C via a **Teach-once** agent (Test A) first, which carries real recipe steps, before trusting the waste-card deploy path.
2. **Declines don't persist** (`dismissedWasteSignatures` in-memory only) — a dismissed card returns on relaunch. Don't treat reappearance as a detection bug.
3. **Do NOT enable `cascade.experimentalEpisodeMining`** for the demo — its tests fail (above). The default path is the tested one.
4. **`agents` table starts empty** — the first successful Test A is what proves the whole write path, so run A before B/C.

## Definition of done (all three "guaranteed")

- [ ] `agents` table ≥ 1 row after Test A.
- [ ] `teach.started` + `teach.stopped` + `agent.taught` all present (Test A).
- [ ] A DetectedWaste card renders from ≥3 real repetitions (Test B).
- [ ] `recipe.run.started` + `recipe.step` + `agent.run.completed` present (Test C).
- [ ] Esc during replay produces an immediate stop row.
- [ ] The two failing episode-mining tests fixed, OR episode mining confirmed OFF for the demo.
