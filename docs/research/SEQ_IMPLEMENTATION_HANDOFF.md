# SEQ Partial-Implementation — Handoff

Last updated: 2026-06-29. Branch: `feat/production-grade`.

## TL;DR

A background **dynamic workflow** is driving the 31 research docs (`docs/research/SEQ-01…31`)
into the codebase by **finishing the techniques the audit marked 🟡 partial** — one SEQ at a time,
through **Plan → Implement → Audit → Fix**, committing each build-green result.

- **Status report (source of truth for what's done):** `docs/research/IMPLEMENTATION_STATUS.md`
- **Baseline audit (371 techniques):** 15 ✅ implemented · 233 🟡 partial · 123 ❌ not implemented.
  This run targets the **233 partial** only. The **123 greenfield** items are a deferred later pass.
- **Scope decisions (locked with the user):** finish *partial* items only · all 31 SEQs sequential ·
  build-gated commits · report at end · WIP checkpointed first.

## Continuation log (latest first)

### 2026-06-29 — session 4: ran SEQ-16→20, paused at user request (codex quota low)
- **Re-launched** the script as run `wf_b8cec9ae-6dd` (task `w5t27fbmv`) after the morning usage-limit
  reset. Skipped SEQ-01–15, then **committed + pushed SEQ-16, 17, 18, 19, 20** (build-green each):
  - `c71cef5` seq-16 document-understanding (reading order, tables, retrieval)
  - `07e9498` seq-17 temporal-knowledge-graph (deterministic edges, graph tests)
  - `32f308d` seq-18 proactive-intelligence (live repetition detector, trust controls)
  - `e6c5f0a` seq-19 performance-efficiency (cadence, ROI OCR, memory, SQLite, maintenance) + `6300de5` fix (ImageIO JPEG encoding)
  - `5ac88c4` seq-20 personalization (event log, ranking, thresholds, routines, cold start, controls)
  HEAD is now `5ac88c4`, in sync with `origin/feat/production-grade` (0/0).
- **Paused by the user** (~14:48) because the codex/inference-gateway quota was down to ~7% — stopped
  cleanly via `TaskStop w5t27fbmv` rather than crashing mid-SEQ. The run was mid-**SEQ-21**
  (vlm-screen-action-models); its uncommitted Implement-stage edits (new GrounderRegistry /
  GroundingActionRouter / GroundingCropRefinement / GroundingEval / GroundingSampling /
  RegionBudgetedScreenshot / ComputerUseVerifier / GroundingCorpusExporter + edits) were discarded with
  `git stash -u && git stash drop`. Tree is clean at `5ac88c4`. **Nothing past SEQ-20 is committed.**
- **Remaining work: SEQ-21 → SEQ-31 (11 SEQs).** Resume = a fresh re-launch of the same script once
  quota refreshes: `Workflow({ scriptPath: "…/seq-finish-partials-wf_630c4e96-75f.js" })`. The Plan
  skip-check was tightened this session to match only real `feat(seq-NN <slug>):` commits (not docs/
  handoff commits that merely mention a tag), so SEQ-21→31 will be picked up correctly.

### 2026-06-29 — session 3: ran SEQ-05/13/14/15, then hit usage limit
- **Relaunched** the self-contained script as run `wf_844b5f93-b9d` (task `wqy88noyy`). It skipped the
  already-committed SEQs and **committed + pushed SEQ-05, 13, 14, 15** (build-green each):
  `9905f44` (seq-05), `a730e06` (seq-13), `ff2f6f4` (seq-14), `3e5b488` (seq-15). HEAD is now `3e5b488`,
  in sync with `origin/feat/production-grade` (0/0).
  - SEQ-14's Fix stage reported `pushed=false` (transient DNS failure resolving github.com) but SEQ-15's
    push carried its commits to origin — nothing is local-only.
  - Note for agents: in the managed sandbox plain `swift build` is blocked by sandbox-exec; the Fix
    stage verified the gate with `swift build --disable-sandbox`. HEAD is still genuinely green.
- **Hard stop at SEQ-16:** the inference gateway started returning `502 You've hit your usage limit …
  try again at 10:58 AM`. SEQ-16 failed at the Audit stage; **SEQ-17→31 all failed at Plan.** No commits
  past SEQ-15. **Remaining work: SEQ-16 → SEQ-31 (16 SEQs).**
- **Cleanup done:** SEQ-16's Implement stage had left the tree dirty (audit_failed does NOT auto-revert).
  Discarded those uncommitted edits with `git stash -u && git stash drop`. Tree is clean at `3e5b488`.
- **Next:** after the limit resets (~10:58 AM 2026-06-29) re-launch the same script — it will skip
  SEQ-01–15 via the Plan git-log pre-check and resume at SEQ-16. A one-shot relaunch was scheduled in
  the Claude Code session for ~11:02 AM (fires only if that session stays open; otherwise re-launch
  manually with `Workflow({ scriptPath: "…/seq-finish-partials-wf_630c4e96-75f.js" })`).

### 2026-06-29 — session 2: push-as-you-go + self-contained script
- **Session 1 closed mid-SEQ-13.** The previous Claude Code process exited while working SEQ-13; its
  half-done working-tree edits were discarded (`git reset --hard HEAD`). Committed SEQs were intact.
  This handoff was first written at that point.
- **The 15 local commits were pushed** to `origin/feat/production-grade` (`e6e5275..0220857`). The
  remote is now current with local — nothing is local-only anymore.
- **Per-SEQ pushing added.** The Fix stage now runs `git push origin feat/production-grade` after each
  green commit (best-effort: a push failure does NOT fail the SEQ — the commit is safe locally). The
  run now **commits AND pushes** each SEQ as it lands.
- **Script is now self-contained.** The 31-SEQ list is hardcoded as `const SEQS` inside the script (an
  earlier relaunch crashed because `args` arrived as a string and the loop iterated its characters).
  Launch with just `{ scriptPath }` — no `args` needed.
- **Current run:** `wf_4454a193-007` (task `w7s1zi6d6`). Skips SEQ-01–12 (already committed), retries
  SEQ-05, runs SEQ-13 → 31, committing + pushing each build-green result.

## Snapshot as of this handoff

The workflow is **still running**. Committed so far on `feat/production-grade`:

```
SEQ-01 … 20   ← committed + pushed (build-green); HEAD = 5ac88c4 (seq-20)
SEQ-21 … 31   ← pending (paused at SEQ-21 mid-implement; codex quota low — resumes on fresh re-launch after refresh)
```

- HEAD advances as each SEQ lands (latest `feat(seq-NN …)` / docs commit); the commit gate guarantees
  HEAD always `swift build`s green.
- Checkpoint before the run: `0bf61d2 checkpoint: WIP before SEQ partial-implementation pass`
  (this captured the user's prior uncommitted WIP — do not lose it).
- A dirty working tree during the run is normal: it's the in-flight SEQ between its Implement and
  Fix stages. Each SEQ ends either committed or reverted, leaving the tree clean.

Get the live truth at any time:
```bash
cd ~/Desktop/Cascade
git log --oneline 0bf61d2..HEAD | grep -iE 'seq-[0-9]+'      # which SEQs have landed
git log --oneline 0bf61d2..HEAD | grep -oiE 'seq-[0-9]+' | sort -u   # distinct SEQs done
swift build                                                   # confirm branch is green
```
In Claude Code: `/workflows` shows live stage-by-stage progress.

## The workflow (how it operates)

Single background workflow, **sequential** loop SEQ-01 → SEQ-31. Per SEQ, four awaited agent stages
(only one agent runs at a time, so the shared git tree + build state stay coherent):

1. **Plan** (sonnet) — pre-check `git log` for an existing `seq-NN` commit → skip if present
   (idempotent/resumable). Else read the SEQ doc + `IMPLEMENTATION_STATUS.md`, list that SEQ's 🟡
   partial techniques, open the cited evidence files, and write a concrete finish-it plan. Anything
   that's secretly greenfield is moved to `deferred[]` with a reason, not faked.
2. **Implement** (opus) — applies the edits to finish those partial items.
3. **Audit** (sonnet) — runs `swift build`, re-reads the code, honestly re-classifies each target
   (implemented / partial / not_implemented), records compiler errors.
4. **Fix** (opus) — resolves build/test errors (≤~6 build attempts), runs touched-module tests
   best-effort, then the **commit gate**:
   - `swift build` green → `git add -A && git commit -m "feat(seq-NN <slug>): finish partial techniques — …"`.
   - still red → revert this SEQ (`git stash -u && git stash drop`), mark failed. **Branch never goes red.**

### Guardrails (non-negotiable)
- Never commit a red build. · Sequential only (no parallel repo edits). · Each SEQ is an independent,
  reviewable commit. · Only *partial* items targeted; greenfield deferred, never stubbed to look done.

## Artifacts & locations

| What | Path / ID |
| --- | --- |
| Implementation workflow run ID (current) | `wf_4454a193-007` (task `w7s1zi6d6`); prior: `wf_630c4e96-75f`, `wf_593b668a-6fc` |
| Implementation workflow script | `…/cd1ecc14-…/workflows/scripts/seq-finish-partials-wf_630c4e96-75f.js` |
| Status report (regenerated each audit) | `docs/research/IMPLEMENTATION_STATUS.md` |
| Baseline audit raw data (per-technique) | `…/cd1ecc14-…/tasks/w261idjvs.output` |
| Audit workflow script (re-runnable) | `…/cd1ecc14-…/workflows/scripts/seq-implementation-audit-wf_6e574c8b-4b5.js` |
| Plan file | `~/.claude/plans/swirling-snuggling-teapot.md` |

(Project session dir root: `/Users/mohanadbahammam/.claude/projects/-Users-mohanadbahammam-Desktop-Cascade/cd1ecc14-d4f0-4081-892c-6d72e26c9d14/`.)

## If the run dies — resume

The script is **self-contained** (31-SEQ list hardcoded as `SEQS`; no `args`). Both options are
idempotent because the Plan stage skips any SEQ that already has a `seq-NN` commit, and each green
SEQ is committed **and pushed**.

1. **Re-launch (simplest)** — skips committed SEQs via the Plan `git log` pre-check, picks up at the
   first unfinished one:
   ```
   Workflow({ scriptPath: "…/seq-finish-partials-wf_630c4e96-75f.js" })
   ```
2. **Resume the run** (replays cached stages, continues live):
   ```
   Workflow({ scriptPath: "…/seq-finish-partials-wf_630c4e96-75f.js", resumeFromRunId: "wf_4454a193-007" })
   ```
   Do NOT resume if you've reset the tree out from under an in-flight SEQ — re-launch fresh instead.

If a stop leaves a dirty tree mid-SEQ, clean it first: `git reset --hard HEAD` (discards only the
aborted SEQ's machine-generated edits; committed SEQs and the user's WIP at `0bf61d2` are safe).

## Roll back

- Undo one SEQ: `git revert <sha>` (each SEQ is isolated).
- Undo the whole run: `git reset --hard 0bf61d2` (returns to the WIP checkpoint — keeps the user's WIP).
- The user's pre-run WIP is preserved in commit `0bf61d2`; never hard-reset past it without intent.

## Remaining work (next passes)

1. **Finish this run** — let SEQ-13…31 complete. Revisit any SEQ reported `reverted` (build gate
   failed) or `skipped`/`no_targets` (e.g. SEQ-05) and decide whether to retry or defer.
2. **Refresh the audit** — re-run the audit workflow to regenerate `IMPLEMENTATION_STATUS.md` and
   measure partial→implemented movement; run a full `swift test` on the final branch.
3. **Greenfield pass (deferred)** — the 123 ❌ `not_implemented` items + everything pushed to
   `deferred[]` (genuine subprojects: e.g. on-device LLM weights, screen-content video codec,
   external OCR sidecar, full encryption-at-rest). These were intentionally out of scope here.

## Verify

```bash
cd ~/Desktop/Cascade
swift build                       # must be green (commit gate guarantees HEAD is)
swift test                        # full suite on the final branch
./scripts/build-app.sh            # → .build/Cascade.app (ad hoc signed)
git log --oneline 0bf61d2..HEAD   # review every feat(seq-NN) commit individually
```
