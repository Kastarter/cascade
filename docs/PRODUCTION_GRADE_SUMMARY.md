# Cascade — Production-Grade Work Summary

> Branch: `feat/production-grade`. This document records what was researched and
> implemented to move Cascade toward production-grade reliability, security, and
> enterprise market fit, with the verification evidence for each change.

## Method: two phases

**Phase A — Research (10 sequences).** Ten parallel research workflows each
surveyed open-source repos and academic papers for one production-grade dimension
and mapped concrete, portable techniques onto real Cascade files. Findings live in
`docs/research/SEQ-01..10-*.md` (2,700+ lines) and are synthesized into
`docs/PRODUCTION_GRADE_PLAN.md`.

| # | Dimension | Doc |
|---|---|---|
| 1 | Screen-context recording, storage efficiency, retrieval | `SEQ-01-recording-storage.md` |
| 2 | Computer-use / GUI agent architectures & reliability | `SEQ-02-computer-use-agents.md` |
| 3 | GUI grounding / screen parsing / element localization | `SEQ-03-gui-grounding.md` |
| 4 | Semantic retrieval, embeddings, agent memory | `SEQ-04-semantic-retrieval-memory.md` |
| 5 | Prompt / context engineering & agent-harness patterns | `SEQ-05-prompt-harness.md` |
| 6 | Agent reliability, evaluation, self-healing replay | `SEQ-06-reliability-eval.md` |
| 7 | Privacy, security, PII redaction, encryption, compliance | `SEQ-07-privacy-security.md` |
| 8 | Workflow / process mining, learning-from-demonstration | `SEQ-08-workflow-mining.md` |
| 9 | Native macOS automation & Accessibility robustness | `SEQ-09-macos-automation.md` |
| 10 | Enterprise productization, competitive landscape, $1B thesis | `SEQ-10-market-productization.md` |

**Phase B — Implementation (9 plan→impl→audit→fix sequences).** Each picked a
backlog item, implemented it in Swift, kept the build clean and the full test
suite green, and added tests proving the new behavior. After the first six
sequences, two adversarial code reviews (security + correctness) ran against the
cumulative diff; their high-confidence findings drove three more fix sequences
(B7–B9). Nothing shipped that wasn't compiled and tested.

## What landed (Phase B)

| Seq | Change | Source dim | Key files | Tests |
|---|---|---|---|---|
| B1 | Symlink-safe harness path containment (realpath on nearest existing ancestor; protected-path + write-fence checks run on the *canonical* path) + network-egress / persistence deny-list | SEQ-07 P0 #3,#4 | `AgentHarness.swift` | +4 |
| B2 | Tamper-evident audit hash chain — `event_hash = SHA256(prev_hash ‖ canonical)`, `verifyAuditChain()` | SEQ-07 P0 #5 | `AuditChain.swift`, `CascadeMemory.swift` | +5 |
| B3 | On-device PII detector (regex+Luhn / NSDataDetector / NLTagger), typed redaction, wired into audit storage | SEQ-07 P0 #1 | `PIIDetector.swift`, `CascadeMemory.swift` | +10 |
| B4 | Reliability spine — `AgentFailureKind` taxonomy, `AgentRecoveryPolicy`, `ReliabilityReport`/`Runner` + budget gates, JSONL metrics | SEQ-06 | `AgentFailureKind.swift`, `AgentRecoveryPolicy.swift`, `ReliabilityReport.swift` | +13 |
| B5 | Prompt-cache stability — split system into a stable cached prefix + a volatile time block (the tool loop's `Date()` was busting the cache every hop) | SEQ-05 | `RecordSearchAnswerer.swift` | +2 |
| B6 | Secure Input refusal (`IsSecureEventInputEnabled`) + grapheme-safe UTF-16 chunking (no split surrogate pairs) | SEQ-09 | `InputSafety.swift`, `ComputerUseKit.swift` | +5 |
| B7 | Audit-chain hardening (audit fix) — length-prefixed canonical form (no separator ambiguity), all-rows scan (forged null rows caught), out-of-band Keychain anchor (truncation/rewrite caught) | review #1 | `AuditChain.swift`, `CascadeMemory.swift`, `CascadeAppModel.swift` | +4 |
| B8 | Redaction & deny-list fixes (audit fix) — redact hyphenated provider keys incl. Cascade's own `sk-ant-…`; block inline-interpreter exfil (`python -c`, `node -e`, `ruby -e`) | review #1 | `PIIDetector.swift`, `AgentHarness.swift` | +2 |
| B9 | Typed `ComputerUseError.secureInput` (correct UI message + `agent.secure_input` audit) + detail-aware failure mapping (`assist.validate`/`sandbox.verify` `INCOMPLETE:` → `validatorIncomplete`) | review #2 | `ComputerUseKit.swift`, `CascadeAppModel.swift`, `AgentFailureKind.swift` | +2 |

**Net:** 18 files changed, ~1,630 insertions; **+47 tests** (415 → **461**), full
suite green; `./scripts/build-app.sh` assembles and ad-hoc-signs `Cascade.app`.

## Production-readiness assessment

**Materially stronger now:**

- **Local-data security.** The agent harness can no longer be tricked out of its
  write fence by a symlink, can't exfiltrate via named network tools or inline
  interpreters, and the audit log is tamper-evident (internal hash chain +
  out-of-band Keychain anchor) with secrets/PII redacted before they come to rest.
  These were the documented P0 security blockers for enterprise pilots in SEQ-07.
- **Measurable reliability.** Agent failures are now a typed, aggregatable taxonomy
  with a recovery-policy table and a deterministic, CI-gateable eval harness
  (success-rate / unsafe-refusal / false-completion / modal-pause budgets) — the
  measurement layer SEQ-06 identified as the missing moat.
- **Input correctness.** Secure Input is detected and reported honestly instead of
  silently dropping keystrokes; Unicode typing is grapheme-safe.
- **Cost.** The record-Q&A prompt cache actually hits across tool hops now.

**Not yet production-grade (honest):** see `docs/PRODUCTION_GRADE_REMAINING.md`.
The biggest remaining enterprise blocker is **encryption at rest** (SQLCipher) and
**frame-pixel redaction on the recorder hot path** — both require a live DB/screen
to implement and verify safely and were deliberately not attempted blind.

## On attribution

No third-party code was copied. The techniques are *adopted patterns* — e.g.
Presidio's recognizer/anonymizer architecture, RPA self-healing's ranked-fallback
recovery, the OSWorld/WebArena executable-scenario eval shape, Anthropic's
static-prefix/volatile-suffix caching guidance — reimplemented natively in Swift.
Sources are cited per technique in the `docs/research/SEQ-*` documents. No new
runtime dependencies were added (CryptoKit, NaturalLanguage, Security, Carbon are
system frameworks).
