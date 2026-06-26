# Cascade — Production-Grade Plan

> Synthesis of the 10 research sequences in `docs/research/SEQ-01..10-*.md` into a
> prioritized, implementable backlog toward production-grade reliability, security,
> and enterprise market fit. Authored on `feat/production-grade`.

## How to read this

Each research sequence (`docs/research/SEQ-0N-*.md`) surveyed open-source repos and
papers for one production-grade dimension and mapped concrete techniques onto real
Cascade files. This document consolidates them, **marks what `main` already ships**
(so we don't reinvent it), and defines the Phase B implementation sequences
(plan → impl → audit → fix) executed on this branch.

## What `main` already ships (verified in source/tests)

Cascade is more mature than a first read of `CLAUDE.md` suggests. Already landed:

- **Hybrid retrieval + rank fusion** — `Tests/CascadeMemoryTests/HybridSearchTests.swift`,
  `RankFusionTests.swift`, `SemanticIndexTests.swift`. (SEQ-04's RRF/hybrid spine exists.)
- **Irreversible-action gate** — `feat/action-risk-critic`, `Tests/ProviderKitTests/ActionGateTests.swift`
  (refuses `cmd+Q`/log-out/force-quit/empty-Trash unless the goal sanctions it). (SEQ-02/06 pre-action critic.)
- **WasteDetector hardening** — noise filtering, repeatable-token filter, idle-gap checks,
  variant merge, same-position typed params, composite ranking (`feat/waste-h1..h6`). (SEQ-08 base.)
- **OCR set-of-marks scaffolding** — `Tests/AppShellTests/OcrSetOfMarksTests.swift`,
  `MixtureGrounderTests.swift` (AX/OCR/vision routing exists). (SEQ-03 partial.)
- **Scout agent / MixtureGrounder / AgentDateContext** — `feat/background-scout-brain`.
- **Replay safeguards** — frontmost-app state gate, modal pause, AX→OCR→vision→recorded
  target tiers, fingerprint verification, no-effect detection, escalation (SEQ-06 primitives).
- **Harness guardrails** — protected-path checks, destructive deny-list, privacy gate
  (`Tests/ProviderKitTests/AgentHarnessTests.swift`). (SEQ-07 base — but containment is escapable; see B1.)

So Phase B targets the **genuinely missing** production gaps, weighted by enterprise stakes.

## Phase B backlog (implemented on this branch)

Ordered by (enterprise stakes × tractability × verifiability). Every item must keep the
build clean and the full test suite green, and adds tests proving the new behavior.

### B1 — Harness security: symlink-safe containment + exfiltration deny-list  `[SEQ-07 P0 #3,#4]`
**Problem.** `AgentHarness.writeFile` proves containment with `expand()` (= `standardizedFileURL`,
which does **not** resolve symlinks) + `hasPrefix(root)`. A symlink inside an allowed root can
redirect a write outside it (CWE-61). The command deny-list also blocks destructive disk ops but
not data **exfiltration/persistence** (`curl|wget|nc|scp|rsync|ssh|launchctl|chmod`).
**Change.** Add `canonicalContainment(_:roots:)` that resolves the real path (existing path, or
existing parent for new files) via `realpath`, rejects symlinked components, and verifies the
canonical path is inside an allowed root. Route `writeFile` (and read/list/search scopes) through it.
Extend `denyPatterns` with an exfiltration/persistence set. Tests: symlink escape, `..` traversal,
canonical re-check, exfil command refusals.
**Files.** `Sources/ProviderKit/AgentHarness.swift`, `Tests/ProviderKitTests/AgentHarnessTests.swift`.

### B2 — Tamper-evident audit chain  `[SEQ-07 P0 #5]`
**Problem.** `audit_event` rows are mutable plaintext with no integrity relation; a local process
can rewrite history. For an audit-first product this is existential.
**Change.** Add `prev_hash`/`event_hash` columns (best-effort `ALTER TABLE`). On append compute
`event_hash = SHA256(prev_hash || canonical_event_json)` (CryptoKit). Add `verifyAuditChain()` →
typed result (intact / broken-at-id) and surface an integrity health check. Tests: chain links,
tamper detection, empty/legacy rows.
**Files.** `Sources/CascadeMemory/CascadeMemory.swift`, `Sources/CascadeMemory/AuditChain.swift` (new),
`Tests/CascadeMemoryTests/AuditChainTests.swift` (new).

### B3 — Native on-device PII detection + redaction  `[SEQ-07 P0 #1, P1]`
**Problem.** `PrivacyRules` is a keyword **drop** list — no entity-level detection, no redaction,
no tokenization. Raw PII can persist in OCR text, audit detail, and harness output.
**Change.** Add a Swift `PIIDetector` (deterministic regex + Luhn for cards, SSN, IBAN, API
keys/tokens, emails; `NSDataDetector` for phones/links/addresses; `NLTagger` for names/orgs) that
returns typed spans, and `redact(_:) -> (text, findings)` replacing spans with `<EMAIL>` etc.
Wire high-confidence redaction into audit-detail storage and harness file output. (Full
frame-pixel redaction on the recorder hot path is scoped as a documented larger bet — it needs a
live screen to verify safely.) Tests: golden strings per entity, no raw entity survives redaction.
**Files.** `Sources/CascadeMemory/PIIDetector.swift` (new), `PrivacyRules.swift`,
`Sources/ProviderKit/AgentHarness.swift`, `Tests/CascadeMemoryTests/PIIDetectorTests.swift` (new).

### B4 — Reliability spine: failure taxonomy + recovery policy + metrics gate  `[SEQ-06]`
**Problem.** 400+ tests cover primitives but there is **no measurable reliability** — no failure
taxonomy, no typed recovery policy, no success-rate/threshold gate. Reliability is the enterprise moat.
**Change.** Add `AgentFailureKind` (typed taxonomy), `AgentRecoveryPolicy` (first/second/terminal
action per failure, per SEQ-06's table), and `ReliabilityReport`/threshold gates (success_rate,
unsafe_refusal_rate==1, false_completion_rate==0). Map existing audit events
(`recipe.pause.modal`, `assist.noeffect`, `agent.action.refused`, …) to failure kinds. New
`ReliabilityEvalTests` target runs deterministic scenarios over the policy/taxonomy and asserts budgets.
**Files.** `Sources/AgentOrchestrator/AgentFailureKind.swift`, `AgentRecoveryPolicy.swift`,
`ReliabilityReport.swift` (new), `Tests/ReliabilityEvalTests/*` (new target).

### B5 — Prompt-cache stability + structured-output robustness  `[SEQ-05]`
**Problem.** `RecordSearchAnswerer.systemPrompt()` embeds `Date()` in the cacheable system prefix,
defeating prompt-cache reuse across turns (every call is a cache miss).
**Change.** Move volatile date/window/environment notes out of the cached system prefix into a
non-cached context message; assert the system prefix is stable across calls. Harden brittle JSON
extraction where present. Tests: stable-prefix assertion, date appears only in the volatile note.
**Files.** `Sources/ProviderKit/RecordSearchAnswerer.swift` (+ peers), `Tests/ProviderKitTests/*`.

### B6 — Secure Input refusal + grapheme-safe text synthesis  `[SEQ-09]`
**Problem.** When macOS Secure Input is active (password fields), synthetic keystrokes silently
no-op — the agent "types but nothing appears." Unicode typing can also split graphemes.
**Change.** Add a pure `SecureInputGuard.isActive()` wrapper around `IsSecureEventInputEnabled()`
and refuse `.type`/`.key` with a clear message when active; make unicode chunking grapheme-safe.
Tests: guard semantics, grapheme-safe chunking.
**Files.** `Sources/ComputerUseKit/*` (actuator), `Tests/ComputerUseKitTests/*`.

## Larger bets (documented, not attempted blind on this branch)

These need a live screen, a bundled model, or large infra to verify safely; doing them blind would
be worse than documenting them precisely. Captured in the SEQ docs and `docs/PRODUCTION_GRADE_REMAINING.md`:

- **Encryption at rest (SQLCipher)** — the single biggest enterprise blocker (SEQ-07 P0 #2). Requires
  swapping the SQLite link + key management + migration; high blast radius, must be done with a real DB.
- **Frame-pixel redaction on the recorder hot path** (SEQ-07 P0 #1) — needs live OCR boxes + visual QA.
- **Bundled CoreML sentence embedder + sqlite-vec ANN** (SEQ-04) — replace NLEmbedding word-averaging;
  needs model packaging + benchmark.
- **Local CoreML icon detector / OmniParser-style set-of-marks** (SEQ-03) — needs a trained model + ScreenSpot eval.
- **Live OSWorld-style eval tier** (SEQ-06) — needs opt-in permissions + real apps.
- **Enterprise platform** (SEQ-10): SSO/SCIM, admin console, MDM deployment, SIEM audit export, DPA/SOC2 pack.

## Tracking

Phase B sequences land as focused commits with green build + tests. Final state, the
production-readiness assessment, and remaining gaps are documented in
`docs/PRODUCTION_GRADE_SUMMARY.md` and `docs/PRODUCTION_GRADE_REMAINING.md`.
