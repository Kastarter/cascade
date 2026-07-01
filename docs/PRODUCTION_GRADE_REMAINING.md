# Cascade — Remaining Production-Grade Gaps (Roadmap)

> Honest accounting of what is **not** yet production-grade after the
> `feat/production-grade` work. These items were deliberately not attempted on this
> branch because they need a live database, a live screen, a bundled model, or
> large infrastructure to implement and verify safely — doing them blind would be
> worse than scoping them precisely. Each is grounded in a research sequence.

## Security & privacy (highest enterprise stakes)

1. **Encryption at rest (SQLCipher).** `Cascade.sqlite`, WAL/SHM, FTS, embeddings,
   input events, audit rows, and frame JPEGs are still plaintext under Application
   Support. This is the single biggest enterprise blocker. Requires swapping the
   SQLite link for SQLCipher, a Keychain-held device-only key, `PRAGMA key`, and a
   `sqlcipher_export` migration of existing DBs. High blast radius — must be done
   against a real DB with migration tests. *(SEQ-07 P0 #2.)*
2. **Frame-pixel redaction on the recorder hot path.** B3 added the PII *detector*
   and wired redaction into the audit log, but `RewindEngine.process` still writes
   raw JPEG frames before OCR/PII analysis. Production needs in-memory OCR-box →
   entity detection → blur/fill *before* `FrameStore.save`, plus whole-frame drop
   for high-risk surfaces. Needs live OCR boxes + visual QA. *(SEQ-07 P0 #1.)*
3. **Harness TOCTOU.** B1 closed the symlink-escape, but a same-user process could
   still race a parent directory into a symlink between validation and write. The
   gold-standard fix is fd-based `openat`/`O_NOFOLLOW` writes. Lower priority (a
   malicious local process can already write files directly), but documented.
4. **Audit anchor coverage.** B7 added a Keychain head anchor (truncation/rewrite
   detection). Remaining: signed daily roots via the Secure Enclave and optional
   remote/SIEM anchoring for managed deployments. *(SEQ-07 P0 #5, P2.)*
5. **Raw-shell power tier.** The deny-list is defense-in-depth, not a boundary
   (it says so). True isolation needs a sandboxed/network-denied helper or a strict
   executable allow-list replacing `/bin/zsh -c`. *(SEQ-07 P0 #4.)*

## Reliability (moat)

6. **Live eval tier.** B4 built the offline, deterministic reliability harness +
   budget gates. The live OSWorld-style tier (real apps, opt-in permissions,
   `scripts/demo-setup.sh` fixtures, model-call cost capture) is the next step.
   *(SEQ-06.)*
7. **Recovery-policy wiring.** `AgentRecoveryPolicy` is a typed table; the replay /
   assist loops in `CascadeAppModel` still use scattered hard-coded retries. Routing
   them through the policy (and emitting `AgentFailureKind` at every site) makes the
   reliability numbers real end-to-end. *(SEQ-06.)*
8. **Verifier-grounded failure memory.** Reflexion-style memory keyed on
   `(app, failureKind, goalPattern)`, written only when a verifier proves a failure.
   *(SEQ-06.)*

## Perception & automation

9. **AXObserver readiness waits.** Replace fixed post-action sleeps with
   `AXObserver`-backed "wait until ready" gating (focused window/element/title/value
   changes). Biggest single robustness win in SEQ-09; touches the actuator heavily,
   needs live AX to verify.
10. **On-device GUI grounding.** A CoreML icon/control detector + Set-of-Mark
    overlays to turn grounding into multiple-choice and cut LLM grounding calls.
    Needs a trained model + a ScreenSpot eval harness. *(SEQ-03.)*

## Retrieval

11. **Real on-device sentence embedder + ANN.** Replace `NLEmbedding` word-vector
    averaging with a bundled CoreML/MLX `gte-small`/`bge-small` model and a
    `sqlite-vec`/USearch ANN index; keep the existing BM25+dense RRF fusion. Needs
    model packaging + a quality benchmark. *(SEQ-04.)*
12. **Memory-stream scoring.** Recency + importance + relevance ranking over moments
    for surfacing. *(SEQ-04.)*

## Product / workflow mining

13. **PrefixSpan workflow mining.** Episode segmentation (idle-gap + app-switch
    boundaries) + gapped frequent-subsequence mining + trace clustering, replacing
    exact-n-gram repetition, to raise suggestion precision/utility. WasteDetector is
    already mature (noise filter, variant merge, ranking); this is a focused
    algorithm addition, scoped as growth not a production blocker. *(SEQ-08.)*

## Enterprise platform (the $1B GTM gaps)

14. From SEQ-10, the enterprise-adoption blockers beyond the app: SSO/SCIM + tenant
    model + RBAC + admin console; SOC 2 Type II / DPA / pen-test package; MDM
    (Jamf/Intune) deployment + managed permission policies; DLP/retention/export
    controls; SIEM-ready audit export + reliability SLAs. These are organizational
    + platform efforts, not single-PR code changes.

## Bottom line

This branch hardened the **local app's** security, reliability measurement, and
input correctness — the production-readiness *blockers* an enterprise security
review would raise first. The items above are the roadmap from "a security review
won't immediately fail it" to "deployed across a regulated enterprise fleet."
Encryption-at-rest (#1) and frame redaction (#2) are the next two to do, in that
order, against real data.
