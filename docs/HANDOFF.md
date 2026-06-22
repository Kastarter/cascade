# Handoff — OCR efficiency + agent-pipeline intelligence (2026-06-22)

For the next Claude picking this up. Self-contained; read top to bottom. CLAUDE.md
is the source of truth for the whole product — this only covers THIS thread.

## The framing (why we're here)
Boss's directive (Arabic): customer **acceptance ("القبول") rises if we focus on three pillars** —
1. **OCR / "how you own context"** (the local recorder turning screen → searchable owned context),
2. **background agents + sandbox agents**,
3. **"clicky-alike"** (the on-screen computer-use agent).

User asked to audit the OCR against pillar #1. We did, then narrowed to **efficiency**
(user explicitly said "don't care about languages rn, focus on efficiency of work").

## ✅ DONE & SHIPPED this session — commit `b09194f` (branch `feat/manager-approval-pipeline`, NOT pushed)
"OCR efficiency: gate OCR on AX richness, fold the double downscale". The always-on
recorder was running the heaviest Vision OCR mode on **every** changed frame even when
the Accessibility channel already had the exact text, plus a redundant second downscale.

- `Sources/MacContextKit/ScreenTextRecognizer.swift` — added `level:` param (default `.accurate`, so the single-shot/`captureCursorScreenContext` path is unchanged). `usesLanguageCorrection` now only on `.accurate`.
- `Sources/MacContextKit/RewindRecorder.swift` (`RewindEngine.process`) — **AX-richness gate**: `axRich = axText.count >= sparseAXThreshold (200)`. AX rich (native apps) → cheap `.fast` insurance OCR pass (still catches image/canvas text). AX sparse (web/canvas, OCR is load-bearing) → `.accurate` + the native-res rescue (unchanged). Also now imports `Vision`.
- `Sources/MacContextKit/PerceptualHash.swift` — `combinedHash([UInt64])` folds the grid hashes (already computed for dedup) into the frame signature, replacing the separate `dHash` downscale in the stream delegate. **Safe because `frameHash` is stored-only, never compared** (verified by grep).
- Tests +3 (`fastLevelStillRecognizesText`, `combinedHashIsStableAndMovesWithContent`, `combinedHashDoesNotCollideOnRegionPosition`). **271 tests green.**
- Built via `./scripts/build-app.sh`, installed to `/Applications/Cascade.app`, relaunched — **pid 26840** at handoff time.
- ⚠️ **Runtime-unverified** — efficiency wins don't show in a glance. Live data confirmed OCR *is* running (audit `rewind.capture` rows show `ax N + ocr M chars`; e.g. iTerm2 `ax 1065 + ocr ~1500`). NOT pushed to origin.

## How OCR actually flows into the agent pipeline (the map — verify against code, don't trust memory)
**Detection is INPUT-EVENT driven, NOT OCR.** This is the key correction.
```
record ─┬─ input_event (clicks/keys) ─► WasteDetector.detect() ─► DetectedWaste(recipe)
        │                                (finds REPEATED action sequences)      │
        └─ recorded_context (OCR+AX text) ──┐                                    ▼
             OCR's jobs: (1) ocrAnchor each recipe step      WorkflowCurator.curate() ─► CuratedAgent(GOAL)
             (WasteDetector.swift:352) so replay re-finds            │
             elements; (2) title the card; (3) ground the           ▼
             deployed agent + power Ask-your-record Q&A      Cascades card → approve → CascadeAgent
                                                                     │
                                                                     ▼
                                                        deployAgent (CascadeAppModel.swift:2441)
```
- `refreshAll()` (`CascadeAppModel.swift:309`) calls `orchestrator.detectedWaste` → `curate`.
- `WorkflowCurator` (`Sources/AgentOrchestrator/WorkflowCurator.swift`) — Sonnet writes `CuratedAgent.goal` = "ONE imperative a computer-use agent can carry out **from intent — NOT a list of clicks**" (line 19-21). So deployed agents already run an **intent goal**, not raw clicks.
- **`deployAgent` SPLIT (`CascadeAppModel.swift:2441`):**
  - web/background apps → `createSandboxAgent(task: sandboxTask(...))` = **goal-driven, adaptive** ✅
  - on-screen → `runAgentRecipe` (`:2459`) = **LITERAL recipe replay** (re-anchored via OCR/AX, pauses on 2× unverified drift) ❌ — this is the brittle "just does what the user did" path.

## 🔧 OPEN DECISION — user's ask: "make agents understand context & adapt, not blindly replay"
User said "switch the trigger from clicks to OCR." **I pushed back and recommend NOT doing that literally** — OCR can't detect repetition (no action structure, changes every frame); switching the trigger breaks detection and gains nothing. The user's *real* goal is an **execution + grounding** improvement. Two changes deliver it (trigger stays on clicks):

- **(a) Feed OCR context into curation [SMALL, SAFE, do first].** `WorkflowCurator.userPrompt`/`userPromptOne` (`WorkflowCurator.swift:184` / `:129`) currently feed the LLM only app names + click tokens + timing — **never the OCR**. So goals come out shallow ("Reply to emails in Mail") instead of content-aware ("Reply to **refund-request** emails with the **policy link**"). Fix: pull the OCR text of the evidence moments (`DetectedWaste.evidence` → context ids → `ocr_text`) into the curator prompt. Helps BOTH agent types. This is literally "use the OCR so the agent knows what it's doing."
- **(b) Run on-screen agents goal-first (adaptive) [BIGGER, has a trade-off].** Replace literal `runAgentRecipe` with the existing `runAssistTask(goal:)` vision loop (recipe as hint/fallback). Real "smart enough to know it's different." Trade-off: recipe replay is fast/deterministic/cheap/no-LLM-per-step; goal-driven is adaptive but slower + costs tokens + less predictable. **Decide deliberately.**

**My recommendation: implement (a) now, deliberate on (b).** User had NOT greenlit either when this handoff was written — they chose to research first (below).

## 🔬 IN FLIGHT — deep-research workflow (running in background at handoff)
- **Run ID `wf_cb3b405b-627`**, task ID `w2zz6lrg5`. Watch with `/workflows`.
- Transcript dir: `~/.claude/projects/-Users-mohanadbahammam-Desktop-Cascade/123f9102-2d72-4edb-aa13-0421bed30acd/subagents/workflows/wf_cb3b405b-627`
- Script: `.../workflows/scripts/deep-research-wf_cb3b405b-627.js`
- **Goal:** find high-star OSS repos per pipeline stage, the single best "wedge/engine" to steal from each (license-flagged — we port MIT/Apache/BSD, AVOID copyleft/BSL), + a combined-engine recommendation. **Special focus: the demonstration→adaptive-replay engine** (OpenAdapt-class — how to turn a recorded demo into an intent the agent re-executes on a changed screen) because that's exactly change (b) above.
- Candidate repos under investigation: screenpipe, OpenRecall, rem, memos (recorders); **OpenAdapt** (demo→adaptive — most important); trycua/cua, Agent-S, UI-TARS, Skyvern, self-operating-computer (GUI agents); browser-use, stagehand (web agents).
- ⚠️ **This workflow is tied to THIS session** — a different session may NOT receive its completion notification. If you can't read the result from the transcript dir, **re-run** `Workflow({name:"deep-research", args: <the full args block from this session>})`. Ideally let it finish HERE and save the synthesized report to `docs/` before fully switching sessions.
- **Caveat to set expectations:** most of these repos are Python (screenpipe is Rust); Cascade is Swift/on-device. We're mostly stealing **architecture/algorithms, not code** — except clicky (already native) and trycua/cua (has Swift/MLX-local pieces). Report should flag code-port vs design-port per repo.

## Guardrails (from CLAUDE.md + memories — honor these)
- ⚠️ **CONCURRENT-SESSIONS HAZARD** (directly relevant — you may be a 2nd session in the same checkout): interloper commits from another live session can land on this branch. **Stage explicit paths**, never `git add -A` blindly, never force-push the shared branch. At handoff the tree is clean (b09194f committed, nothing staged).
- **STRUCTURAL > advisory** — runtime-applied scaffolding works; tool/prompt the model must *choose* to use gets ignored (proven 3×: find_element, AX read tool, pushed coords). Build (a)/(b) as structural.
- **Solve general, not the test case** — fix the root capability, never patch the one demo.
- **Agent stays on Opus.** `effort:low` and Sonnet-first BOTH reverted as "dumb." Speed must come from fewer turns, not a weaker brain.
- Build/verify loop: `swift test` → `./scripts/build-app.sh` → copy to `/Applications` → relaunch. Commit/push only when the user asks. Commit trailer: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- Test harness for the pipeline: `./scripts/demo-setup.sh` (fixtures in `~/CascadeDemo`) + `docs/DEMO.md` "Detection → agents" section (do a workflow 2× → Cascades card → approve → deploy).
- Inspect live OCR/owned-context directly: DB at `~/Library/Application Support/Cascade/Cascade.sqlite` (read-only): `audit_event` (action `rewind.capture`), `recorded_context.ocr_text`, `rewind_fts` (FTS5).

## Suggested next steps for the continuing session
1. Retrieve the deep-research result (or re-run it); skim the per-stage shortlist + the demo→adaptive-replay section.
2. Bring the user a recommendation: which engine to port for change (b), and confirm whether to do (a) now.
3. Implement (a) [OCR-grounded curation] — small, structural, helps both agent types — once user confirms.
4. Optionally: the offered-but-unbuilt **observability add** — tag the `rewind.capture` audit detail with the OCR level (`(fast)`/`(accurate)`) so the new gating is verifiable from the log.
