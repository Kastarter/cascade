# Cascade — Production-Grade Round 2 Summary

> Branch: `feat/production-grade` (same PR — no new branch). Round 2 was executed
> entirely through the **Workflow tool**, strictly sequential (no parallel stages),
> as two background workflows.

## How it ran

- **Workflow R (research)** — 10 research sequences (`SEQ-21..30`) run one at a time,
  then a synthesis step producing `docs/PRODUCTION_GRADE_PLAN_ROUND2.md` with a
  prioritized 16-item backlog. 9/10 sequences succeeded inline; SEQ-30's doc was
  still written.
- **Workflow I (implementation)** — 16 sequential **plan → impl → audit → fix**
  sequences. For each item: an implementation agent built + ran the full test
  suite and committed *only* on green (reverting itself otherwise, so the tree
  never went red), an audit agent reviewed the commit, and a fix agent applied any
  high-confidence findings. **16/16 items landed.**

## What landed (P2-01 … P2-16)

| Item | Change | Source | Audit→fix |
|---|---|---|---|
| P2-01 | InjectionGuard nonce-wrapped envelopes (per-call UUID nonce on BEGIN/END markers; sanitize source to one line) | SEQ-12 | fixed (test assertion gap) |
| P2-02 | InjectionGuard override-variant regex (current/existing/original/developer/system) | SEQ-12 | clean |
| P2-03 | `AgentTrace.succeeded` requires every span `.ok` (`.refused` no longer counts as success) | SEQ-14 | clean |
| P2-04 | AgentTrace CSV formula-injection escaping (`= + - @`, plus tab/CR after fix) | SEQ-14 | fixed (tab/CR prefixes) |
| P2-05 | `GroundingResult`/`GroundingCandidate` structured grounding evidence + compat wrapper | SEQ-21 | clean |
| P2-06 | Exact grounding cache (state-fingerprinted) + short-TTL negative-miss cache | SEQ-22 | clean |
| P2-07 | Local voice-activity turn gate (fixed-frame PCM, prefix ring, hangover, commit/clear) | SEQ-23 | clean |
| P2-08 | `UIStateSnapshot`/`UIStateDelta` Merkle core + delta classifier | SEQ-24 | fixed (non-finite frame guard) |
| P2-09 | `PerceptualHash` changed-region grid diff (for cropped OCR) | SEQ-24 | clean |
| P2-10 | Deterministic rule-based grounding verifier scorer (accept/reject/abstain) | SEQ-25 | clean |
| P2-11 | SQLite batch-insert primitives for the recorder hot path (statement reuse) | SEQ-26 | clean |
| P2-12 | Visual vector index (exact L2/cosine scan store) | SEQ-27 | clean |
| P2-13 | Fleet-analytics allowlist policy + export manifest (no raw screen/OCR leaves) | SEQ-28 | clean |
| P2-14 | `AXTargetDescriptorV2` + Similo-style ranked candidate API (self-healing locators) | SEQ-29 | clean |
| P2-15 | In-memory exact model-call cache + canonical request hash + in-flight dedup | SEQ-30 | clean |
| P2-16 | Deterministic pure-call options (temperature 0) + prompt/schema version constants | SEQ-30 | clean |

Items P2-01..04 are the security-review fixes carried over from round 1's audit;
P2-05..16 are new optimization modules (almost all pure, additive, unit-tested).

## Verification

- Independent `swift build` — clean.
- Independent `swift test` — **548 tests in 27 suites, all passing** (was 487 → **+61**).
- Working tree clean; 16 focused commits, one per item.

## Note on scope

These are mostly **pure, tested foundations** (value types, caches, scorers,
gates, snapshots) deliberately built additively so they land reliably and don't
destabilize the running recorder/agent loops. The *wiring* of several into the
live hot paths (e.g. plugging `GroundingResult`/`GroundingCache`/`GroundingVerifier`
into `MixtureGrounder`, `UIStateSnapshot` into no-effect checks, batch inserts into
the recorder, the visual index into Reel/Ask, the model-call cache into
`AnthropicClient`) is the next integration step — tracked alongside the round-1
larger bets in `docs/PRODUCTION_GRADE_REMAINING.md`.
