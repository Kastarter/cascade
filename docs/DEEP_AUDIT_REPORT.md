# Cascade — Deep Audit & Wiring Report

> Branch: `feat/production-grade`. A read-only audit (5 dimensions) traced whether the
> ~37 modules added over 9 rounds are actually wired and working — then fixed what
> wasn't, and verified end-to-end. The core finding the audit confirmed: **many
> modules built green-and-tested in isolation were dormant/orphaned or wired behind
> flags whose ON-path was a no-op.** That gap is now closed.

## Audit dimensions & headline findings

1. **Wiring & reachability (23 findings).** Genuinely LIVE before this audit:
   `AuditChain`, `AuditIdentity`, `EventStoreLayout`, `PIIDetector`, `AnchorDriftScorer`,
   `InputSafety`, `GroundingVerifier` (types), `InjectionGuard`, `AnthropicCompletionOptions`,
   `ActionEpisodeSegmenter`/`PrefixSpanMiner` (types), `NextActionPredictor`, `SuggestionRanker`.
   DORMANT/orphaned: `AgentExperienceLedger`, `WorkGraph`, `ScreenContentStructurer`/
   `StructuredContentExporter`, model-call cache path, reliability/eval-from-traces,
   voice endpointing, fleet/DP, semantic/visual indexing, UI-state, screen-element index,
   grounding cache, web-state signature.
2. **Default-off correctness (12).** Flags defaulted OFF correctly (good), but **integration
   reach was the problem**: many ON-paths were pure/tested in isolation yet never reachable
   from the shipping app, or wrote data nothing consumed.
3. **Security re-audit (1).** Harness containment, deny-list, hashed audit descriptors,
   PII redaction, injection spotlighting, and DP export all healthy — **except** the app
   never *verified* the tamper-evident audit chain before trusting/displaying audit rows.
4. **Dead code / build integrity (4).** Builds clean, no warnings; no `TODO`/`fatalError`/
   `as!` in new files; a few Package.swift test-dep mismatches; voice/web-state tested but
   not live.
5. **Cross-module composition (9).** Grounding had result/verifier/cache types but the app
   used a non-verifying, non-caching grounder; trace assembly was assist-only; reliability
   reports were offline/test-only; the experience ledger couldn't ingest reliability failures;
   episode mining + next-action prediction weren't reachable; WorkGraph/VisualIndex/embeddings
   had no producer.

## Fixes landed (D-01 … D-14)

| # | Fix | Closes |
|---|---|---|
| D-01 | **Verify audit-chain integrity before trusting audit rows** — app verifies the chain, records `auditIntegrityStatus`, fail-closes agent/harness/trace paths when broken; new `.unchained` status marks untrusted-only rows | A3 security gap |
| D-02 | Model-call cache is a **real default-off production path** (removed fake discarded `cacheRequest` work) | A1/A2 no-op ON-path |
| D-03 | Typed `WebStateSignature` for sandbox no-effect detection | A1 dormant |
| D-04 | Episode mining threaded through a default-off app flag | A5 unreachable |
| D-05 | Unify structured capture + structured recall behind one flag | A1/A5 dormant |
| D-06 | Enable grounding **verifier** in the runtime grounder behind a flag | A5 composition |
| D-07 | Opt-in **GroundingCache** on repeated grounding | A5 composition |
| D-08 | Expose **WorkGraph** indexing via a default-off recorder option | A1 no producer |
| D-09 | Teach `AgentTraceBuilder` real sandbox + recipe run boundaries | A5 assist-only |
| D-10 | `ReliabilityReport.fromTraces(...)` adapter from live traces | A5 offline-only |
| D-11 | Record runtime failure cases into the **experience ledger** | A5 can't-ingest |
| D-12 | Surface proactive **next-action predictions** when ranking is enabled | A5 unreachable |
| D-13 | Wire local **voice endpoint policy** behind a default-off flag | A1 dormant |
| D-14 | Clean up fragile test manifest + `try!` diagnostics | A4 build integrity |

Every new wiring is **default-OFF** (shipped behavior unchanged) with a test for the ON
path, so the modules are now genuinely reachable and exercised — not orphaned — without
changing default behavior until each flag is enabled.

## End-to-end verification (independent)

- `swift build` — **green** (0 warnings).
- `swift test` — **759 tests in 38 suites, all passing** (was 724 → +35).
- `./scripts/build-app.sh` — **`Cascade.app` bundles and ad-hoc-signs**;
  `.build/Cascade.app/Contents/MacOS/Cascade` present.

## Still out of scope (unchanged from the final report)

The audit reconfirmed that the remaining items need a human/artifact/infra and can't be
verified by an autonomous agent: SQLCipher encryption-at-rest, frame-pixel redaction
(live screen), bundled CoreML/MLX weights, live AXObserver waits, turning the default-off
flags ON for shipped behavior (needs live A/B), and the enterprise platform (SSO/SOC2/MDM).
See `docs/PRODUCTION_GRADE_REMAINING.md`.

## Bottom line

The "does it build and pass tests" question and the harder "is it actually wired and
working" question are now both answered: the dormant modules are integrated behind
default-off flags with exercised ON-paths, the one real security gap (unverified audit
chain) is fixed fail-closed, and the app builds, tests green (759), and bundles end-to-end.
