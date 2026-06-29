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

## Snapshot as of this handoff

The workflow is **still running**. Committed so far on `feat/production-grade`:

```
SEQ-01 02 03 04 06 07 08 09 10 11 12   ← committed (build-green)
SEQ-05                                  ← NOT committed (skipped / no targets / reverted — see final report)
SEQ-13…31                               ← pending / in progress
```

- HEAD: `c3deb1b feat(seq-12 …)` — `swift build` → **Build complete!** (green).
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
| Implementation workflow run ID | `wf_630c4e96-75f` (task `wgjli0t3f`) |
| Implementation workflow script | `…/cd1ecc14-…/workflows/scripts/seq-finish-partials-wf_630c4e96-75f.js` |
| Status report (regenerated each audit) | `docs/research/IMPLEMENTATION_STATUS.md` |
| Baseline audit raw data (per-technique) | `…/cd1ecc14-…/tasks/w261idjvs.output` |
| Audit workflow script (re-runnable) | `…/cd1ecc14-…/workflows/scripts/seq-implementation-audit-wf_6e574c8b-4b5.js` |
| Plan file | `~/.claude/plans/swirling-snuggling-teapot.md` |

(Project session dir root: `/Users/mohanadbahammam/.claude/projects/-Users-mohanadbahammam-Desktop-Cascade/cd1ecc14-d4f0-4081-892c-6d72e26c9d14/`.)

## If the run dies — resume

Two safe options (both idempotent because Plan skips already-committed SEQs):

1. **Re-launch the same script** (simplest) — committed SEQs are skipped by the Plan pre-check; it
   picks up at the first SEQ without a `seq-NN` commit.
   ```
   Workflow({ scriptPath: "…/seq-finish-partials-wf_630c4e96-75f.js", args: <same 31-entry array> })
   ```
2. **Resume the run** (replays cached agent results for finished stages, continues live):
   ```
   Workflow({ scriptPath: "…/seq-finish-partials-wf_630c4e96-75f.js", resumeFromRunId: "wf_630c4e96-75f" })
   ```
The `args` array (31 × `{seq, file, slug}`) is in the script's original launch and in the plan file.

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
