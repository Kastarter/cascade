# Sequence 7: Privacy, Security, PII Redaction, Encryption, Compliance

## Overview

Cascade's local-first architecture is the right starting point for enterprise trust, but the current implementation is not yet enterprise-ready for a product that records employee screens, OCR text, app/window context, and input events.

Current high-risk findings from source review:

- `Sources/CascadeMemory/PrivacyRules.swift` is a case-insensitive substring list (`bank`, `health`, `password`, etc.) checked against app, bundle, window title, and OCR text. It drops whole moments instead of redacting regions.
- `Sources/MacContextKit/RewindRecorder.swift` saves the JPEG frame to `FrameStore` before AX/OCR text is analyzed. If OCR later finds sensitive text, the file is deleted, but raw sensitive pixels have already touched disk.
- `Sources/CascadeMemory/CascadeMemory.swift` opens `Cascade.sqlite` with plain `sqlite3_open_v2`, enables WAL, and stores `recorded_context`, `input_event`, `audit_event`, FTS, embeddings, image paths, OCR text, recipe JSON, and audit detail in plaintext.
- `FrameStore` writes raw JPEGs under `~/Library/Application Support/Cascade/frames` without app-layer encryption.
- `appendAudit(_:)` stores mutable audit rows without hash chaining, signatures, or remote anchoring.
- `Sources/ProviderKit/AgentHarness.swift` uses useful protected-path checks and destructive regexes, but `run_command` still executes model/user text through `/bin/zsh -c`, and `write_file` uses standardized string-prefix containment. That leaves symlink/path traversal escape risk and deny-list bypass risk.
- `Sources/MacContextKit/ScreenCapture.swift` correctly fails closed without Screen Recording and excludes Cascade's own windows, but it has no enterprise policy layer for app/category exclusion, region redaction, or DLP-driven suppression.

The hardening direction should be: collect less, redact before persistence, encrypt all local artifacts, make harness authority structured rather than shell-shaped, make audit tampering evident, and expose enterprise controls for notice, retention, access, export, deletion, and policy enforcement.

## OSS Repos & Standards

| Area | URL | License / status | Technique | Cascade adoption |
|---|---|---|---|---|
| Microsoft Presidio | https://microsoft.github.io/presidio/ and https://github.com/microsoft/presidio | MIT | PII recognition and anonymization for text, images, and structured data. Recognizers combine NER, regex, rules, checksums, and context. | Use the architecture: recognizer registry, confidence scores, entity taxonomy, anonymizer operators. Do not assume perfect detection; Presidio explicitly warns no automated detector catches everything. |
| Presidio Image Redactor | https://microsoft.github.io/presidio/image-redactor/ | MIT, beta / not production-ready per docs | OCR image text, detect PII, redact image regions; includes `redact_and_return_bbox` style bounding boxes. | Copy the pattern, not the beta package: Vision OCR boxes already exist in `ScreenTextRecognizer.recognizeBoxes`; add Cascade-native redaction before `FrameStore.save`. |
| Presidio supported entities | https://microsoft.github.io/presidio/supported_entities/ | MIT docs | Entity taxonomy includes email, phone, URL, IP, credit card, IBAN, crypto, date/time, location, person, medical license, and country-specific identifiers. | Seed Cascade's `PrivacyEntityType` set and enterprise policy UI from this taxonomy. |
| GLiNER | https://github.com/urchade/GLiNER | Apache-2.0 | Generalist and zero-shot named entity recognition; can detect custom labels from a prompt-like label list and run on CPU/ONNX/INT8 variants. | Larger bet for an on-device local PII recognizer sidecar when Apple detectors and regex are too thin. |
| GLiNER PII model | https://huggingface.co/urchade/gliner_multi_pii-v1 | Apache-2.0 | Multilingual synthetic-PII trained detector for broad PII labels. | Candidate model for offline evaluation and possible Core ML / ONNX packaging after license and accuracy review. |
| GLiNER2-PII | https://arxiv.org/abs/2605.09973 | Research paper | Small multilingual PII NER model for dozens of PII types. | Track as a benchmark direction; not immediate product dependency. |
| spaCy | https://github.com/explosion/spaCy | MIT | Production NLP library with NER pipelines and Presidio analyzer integration options. | Useful reference/backend for experiments; less native to a Swift-first app unless run as a local helper. |
| scrubadub | https://github.com/LeapBeyond/scrubadub | Apache-2.0 | Detector/postprocessor framework for scrubbing emails, phones, names, addresses, and optional NLP detectors. | Good lightweight fallback/reference for deterministic scrubbers and test fixtures. |
| Piiranha | https://huggingface.co/iiiorg/piiranha-v1-detect-personal-information | CC-BY-NC-ND-4.0 | DeBERTa token classifier for 17 PII types across 6 languages. | Research-only. License is not enterprise/commercial-friendly for embedding. |
| Apple Vision OCR boxes | https://developer.apple.com/documentation/vision/vnrecognizedtextobservation | Apple SDK docs | On-device OCR observations with text and bounding boxes. | Immediate quick win: Cascade already exposes `ScreenTextRecognizer.TextBox`; use it to map entities to screen rectangles. |
| Apple NSDataDetector | https://developer.apple.com/documentation/foundation/nsdatadetector | Apple SDK docs | Native detection for links, phone numbers, dates, addresses, and transit information. | Add a Swift `ApplePIIDetector` for deterministic, on-device PII spans without shipping Python. |
| Apple NaturalLanguage NLTagger | https://developer.apple.com/documentation/naturallanguage/nltagger and https://developer.apple.com/documentation/naturallanguage/nltagscheme/nameType | Apple SDK docs | On-device tagging for personal names, places, and organizations. | Add lower-confidence entity hints; combine with context and redaction policy instead of using alone. |
| SQLCipher | https://github.com/sqlcipher/sqlcipher and https://www.zetetic.net/sqlcipher/sqlcipher-api/ | BSD-3-Clause | SQLite fork with transparent 256-bit AES page encryption, `PRAGMA key`, KDF settings, and `sqlcipher_export` migration. | Preferred DB encryption path for `CascadeStore`; encrypt WAL/FTS/embeddings by construction. |
| Apple Keychain data protection | https://support.apple.com/guide/security/keychain-data-protection-secb0694df1a/web | Apple platform security docs | Keychain items use AES-256-GCM keys; secret keys require Secure Enclave round trips on supported hardware. | Store SQLCipher/app-layer master keys in Keychain with device-only accessibility. Do not store DB keys in settings or the DB. |
| Apple Data Protection / FileVault | https://support.apple.com/guide/security/data-protection-overview-secf6276da8a/web | Apple platform security docs | APFS per-file keys; macOS full protection depends on FileVault and class selection. | Set file protection attributes where available and require FileVault via enterprise posture checks for production deployments. |
| Apple Secure Enclave | https://support.apple.com/guide/security/the-secure-enclave-sec59b0b31ff/web | Apple platform security docs | Isolated hardware security subsystem with protected memory and crypto engines. | Use Secure Enclave-backed keys for audit-root signatures where available; use Keychain for data encryption key wrapping. |
| OWASP OS Command Injection Defense | https://cheatsheetseries.owasp.org/cheatsheets/OS_Command_Injection_Defense_Cheat_Sheet.html | CC BY-SA 4.0 | Prefer avoiding OS commands; otherwise parameterize, validate arguments, allowlist commands, use `--`, least privilege. | Replace raw `run_command` shell with structured tools or executable allowlists; deny-list regexes are not sufficient. |
| OWASP Path Traversal | https://owasp.org/www-community/attacks/Path_Traversal | CC BY-SA 4.0 | Normalize input, constrain user-controllable path parts, validate known-good paths, isolate with jail/chroot-style boundaries. | Fix `AgentHarness.writeFile` and read/list/search fences with canonical paths and symlink rejection. |
| CWE-22 Path Traversal | https://cwe.mitre.org/data/definitions/22.html | Public CWE | Decode/canonicalize before validation; use canonical path / realpath to remove `..` and symlinks; least privilege. | Add tests for `..`, symlink, case, and non-existing descendant paths before allowing file operations. |
| CWE-61 Symlink Following | https://cwe.mitre.org/data/definitions/61.html | Public CWE | Symlink following can bypass intended directories; restrict temp dirs, least privilege, compartmentalization. | Use `resolvingSymlinksInPath`, parent `realpath`, `O_NOFOLLOW`, and atomic writes inside canonical roots. |
| OWASP Logging Cheat Sheet | https://cheatsheetseries.owasp.org/cheatsheets/Logging_Cheat_Sheet.html | CC BY-SA 4.0 | Log security events, capture when/where/who/what, sanitize sensitive data, protect log integrity and access. | Add audit redaction, hash chaining, head anchoring, and verification tooling. |
| Sigstore Rekor | https://github.com/sigstore/rekor and https://docs.sigstore.dev/logging/overview/ | Apache-2.0 | Transparency log with inclusion proofs and integrity verification. | Pattern for remote audit-root anchoring; do not need full Rekor embedded in local app. |
| immudb | https://github.com/codenotary/immudb | Business Source License 1.1 | Tamper-evident database / Merkle-tree append log. | Useful architecture reference, but license is not a clean OSS embedding choice. |
| Harpocrates audit logs | https://arxiv.org/abs/2211.04741 | Research paper | Privacy-preserving immutable audit logs for sensitive-data operations. | Research reference for balancing auditability and PII minimization. |
| GDPR Article 5 | https://gdpr-info.eu/art-5-gdpr/ | Regulation text | Lawfulness, fairness, transparency, purpose limitation, data minimization, storage limitation, integrity/confidentiality, accountability. | Core product principles: default minimization, retention limits, demonstrable controls. |
| GDPR Article 25 | https://gdpr-info.eu/art-25-gdpr/ | Regulation text | Data protection by design and by default; pseudonymization; only necessary personal data by default across amount, extent, retention, and access. | Redaction-before-storage and default-off sensitive capture are product requirements, not optional settings. |
| GDPR Article 35 | https://gdpr-info.eu/art-35-gdpr/ | Regulation text | DPIA for high-risk processing, especially systematic monitoring or sensitive data. | Enterprise sale should ship a DPIA template and control evidence pack. |
| GDPR Article 88 | https://gdpr-info.eu/art-88-gdpr/ | Regulation text | Employment-context processing needs safeguards for dignity, legitimate interests, fundamental rights, transparency, and workplace monitoring systems. | Employee-screen recording needs explicit notice, policy controls, proportionality, access limits, and local labor-law review. |
| CCPA / CPRA | https://oag.ca.gov/privacy/ccpa | California DOJ guidance | Rights to know, delete, opt out of sale/share, correct, limit sensitive personal information; notices required. | Build export/delete and sensitive-data limitation controls across frames, OCR, input, embeddings, FTS, audit, and backups. |
| AICPA Trust Services Criteria | https://www.aicpa-cima.com/resources/download/2017-trust-services-criteria-with-revised-points-of-focus-2022 | AICPA criteria | SOC 2 control criteria for security, availability, processing integrity, confidentiality, and privacy. | Map Cascade controls and evidence to SOC 2 before pilots with regulated enterprises. |
| ISO/IEC 27001:2022 | https://www.iso.org/standard/27001 | International standard | ISMS requirements for risk management, confidentiality, integrity, availability, and continuous improvement. | Use as the security-management operating system: risk register, controls, audit evidence, incidents, suppliers, SDLC. |

## Concrete Hardening to Adopt

### P0 - Security must-fix before enterprise pilots

1. Redact regions before any frame reaches disk.

- Files/functions: `Sources/MacContextKit/RewindRecorder.swift` (`RewindEngine.process`, `FrameStore.save`), `Sources/MacContextKit/ScreenTextRecognizer.swift` (`recognizeBoxes`), `Sources/CascadeMemory/PrivacyRules.swift`.
- Current issue: `FrameStore.save(jpeg:)` runs before OCR/AX privacy checks. Sensitive pixels can be written to disk and only deleted later.
- Adopt: introduce `PrivacyDetector` and `FrameRedactor`.
  - Decode the in-memory JPEG into `CGImage`.
  - Run `ScreenTextRecognizer.recognizeBoxes(inImageData:)` before saving.
  - Run entity detection over each `TextBox.text`: deterministic regex/checksum recognizers, `NSDataDetector`, `NLTagger`, current `PrivacyRules`, and optional future GLiNER/Presidio sidecar.
  - Map detected entities back to OCR boxes and blur/fill those rectangles in memory.
  - Save only the redacted JPEG.
  - Store redacted OCR text with typed placeholders (`<EMAIL>`, `<PHONE>`, `<CREDIT_CARD>`, `<PERSON>`) instead of raw entity text.
  - Keep whole-frame drop only for high-risk surfaces where region redaction is insufficient: password managers, private browsing/incognito, banking apps/sites, health/medical, legal, crypto wallets, identity documents, and unknown high-confidence sensitive surfaces.
- Metadata: extend `metadataJSON` with `privacy.redaction_count`, `entity_types`, `detector_versions`, `whole_frame_drop_reason`, and `redacted_frame_hash`.
- Tests: add golden screenshots for email, phone, credit card, SSN/national IDs, passwords, bank balances, patient/health text, HR compensation, legal docs, and code secrets. Verify no raw entity remains in JPEG bytes, OCR text, FTS, embeddings, or audit details.

2. Encrypt every local persistence surface.

- Files/functions: `Sources/CascadeMemory/CascadeMemory.swift` (`CascadeStore.init`, `migrate`, FTS/embedding tables), `Sources/MacContextKit/RewindRecorder.swift` (`FrameStore`), package/build scripts.
- Current issue: `Cascade.sqlite`, WAL/SHM, FTS, embeddings, input events, audit rows, recipe JSON, and frame JPEGs are plaintext under Application Support.
- Preferred path: SQLCipher.
  - Link SQLCipher instead of system SQLite.
  - Generate a random 256-bit database key on first launch.
  - Store the key in Keychain as device-only, e.g. `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
  - Execute `PRAGMA key` before migration or any DB access.
  - Use SQLCipher migration via `sqlcipher_export` for existing plaintext DBs.
  - Verify `Cascade.sqlite`, WAL, SHM, FTS, and embeddings are unreadable without the key.
- Frame path: either move frames into encrypted DB BLOBs or add per-frame AES-GCM file encryption with keys wrapped by the DB master key / Keychain key.
- Enterprise posture: expose a FileVault requirement/check in Settings/admin diagnostics. macOS Data Protection helps, but FileVault/MDM posture is the enterprise control.
- Tests: assert plaintext strings from OCR and audit cannot be found by `strings` in DB, WAL, SHM, frame files, backups, or exported diagnostics.

3. Fix the harness symlink/path-fence escape.

- Files/functions: `Sources/ProviderKit/AgentHarness.swift` (`expand`, `writeFile`, `sensitivePathReason`, read/list/search paths).
- Current issue: `standardizedFileURL.path` plus `hasPrefix(root + "/")` does not prove containment. Symlinks and race conditions can escape a prefix fence.
- Adopt:
  - Canonicalize existing paths with `resolvingSymlinksInPath` or POSIX `realpath`.
  - For writes to non-existing files, canonicalize the existing parent directory first and reject if any path component is a symlink.
  - Restrict writes to an app-owned export/work directory plus session scratch, not the entire home directory. Whole-home write access is too broad for an autonomous harness.
  - Use atomic temp files created inside the canonical destination directory.
  - Use `open`/`openat` flags such as `O_NOFOLLOW` and `O_CLOEXEC` where available, then write through file descriptors.
  - Verify the canonical destination is still inside an allowed root after write/rename.
- Tests: `~/allowed/link -> ~/.ssh`, `~/allowed/link/new.txt`, `../` traversal, case variants, Unicode normalization, `/tmp/link -> ~/Library/Keychains`, and symlink swaps between check and write.

4. Replace deny-list shell execution with structured authority.

- Files/functions: `Sources/ProviderKit/AgentHarness.swift` (`runCommand`, `runAppleScript`, `denialReason`, tool definitions in `definitions(powerEnabled:)`).
- Current issue: deny-list regexes are useful but not a security boundary, and `/bin/zsh -c` expands shell metacharacters, redirection, command substitution, aliases, and environment-dependent behavior.
- Adopt:
  - Prefer task-specific tools (`convert_doc`, `move_files`, `read_csv`, `write_export`, `open_url`, `create_folder`) over raw shell.
  - If a raw command remains, parse into executable plus argv without a shell and allowlist absolute executable paths.
  - Validate every argument by type and target path; insert `--` before user-controlled filenames where tools support it.
  - Add explicit blocks for exfiltration and persistence tools (`curl`, `wget`, `nc`, `scp`, `rsync`, `ssh`, `osascript` TCC escalation, `launchctl`, `chmod/chown` on protected paths), not just destructive disk commands.
  - Audit refused attempts as security events, but redact command arguments that contain secrets or PII.
- Product control: require per-enterprise policy to enable raw shell/AppleScript; keep default off.

5. Make audit logs tamper-evident and privacy-safe.

- Files/functions: `Sources/CascadeMemory/CascadeMemory.swift` (`AuditEvent`, `appendAudit`, `recentAudit`, `migrate`), audit call sites in `ComputerUseKit`, `ProviderKit`, `MacContextKit`, and `AppShell`.
- Current issue: `audit_event` rows are mutable plaintext with no integrity relation. A local attacker or compromised process can delete or rewrite history.
- Adopt:
  - Add columns: `prev_hash`, `event_hash`, `key_id`, `signature`, and `redaction_version`.
  - Canonicalize event fields and compute `event_hash = SHA256(prev_hash || canonical_event_json)`.
  - Store the latest head hash in Keychain and optionally sign daily roots with a Secure Enclave-backed private key.
  - Anchor daily/hourly root hashes to an enterprise collector or Rekor-like transparency log for managed deployments.
  - Add `verifyAuditChain()` and a visible "audit integrity" health check.
  - Redact audit `detail` before storage. OWASP logging guidance is explicit: logs should not directly store secrets, tokens, keys, or unnecessary personal data.

### P1 - High-value hardening after P0

1. Make input recording privacy-first.

- Files/functions: `Sources/MacContextKit/InputRecorder.swift`, `Sources/CascadeMemory/CascadeMemory.swift` (`input_event`).
- Current issue: typed text can persist as raw text when surrounding app/window passes `PrivacyRules`.
- Adopt: default to action-shape storage (`typed 12 chars`, `pressed Enter`, `clicked Reply`) unless the user explicitly teaches a workflow requiring literal text. Apply the same entity placeholder pipeline to `InputEvent.text`.

2. Add enterprise policy controls for capture.

- Files/functions: `Sources/MacContextKit/ScreenCapture.swift`, `Sources/MacContextKit/RewindRecorder.swift`, `Sources/AppShell` Settings.
- Adopt: managed app/bundle/domain/category allow/deny lists, DLP-triggered pause, "private mode" hotkey, visible recording indicator, configurable retention by data class, and tenant policy import/export.

3. Prevent privacy leaks through derived indexes.

- Files/functions: `CascadeStore.indexEmbedding`, `rewind_fts` triggers, `context_embedding` table.
- Adopt: run redaction before FTS and embedding generation; never embed raw PII; store entity placeholders or skip embeddings for high-risk contexts. Purge FTS/embedding rows on deletion and verify with tests.

4. Add a privacy/security regression suite.

- Use golden screenshot and input-event fixtures.
- Assert no sensitive strings in DB/WAL/SHM/FTS/embedding/audit/frame outputs.
- Assert redaction bounding boxes cover detected OCR entities with padding.
- Assert path-fence and command-fence bypass attempts fail closed and emit redacted audit events.

5. Add local access controls.

- Add an app unlock requirement for Reel, Ask, audit export, and Settings when enterprise policy requires it.
- Use Keychain/LocalAuthentication for unlock, not a Cascade-only password stored in app settings.

### P2 - Larger enterprise bets

1. Local PII model sidecar.

- Evaluate GLiNER / GLiNER PII / Presidio-compatible models in an offline benchmark.
- Package via ONNX Runtime, Core ML, or a signed local helper; keep network off by default.
- Treat model output as a recall layer, not sole authority.

2. Enterprise audit anchoring and SIEM export.

- Send signed audit roots and selected sanitized security events to Splunk/Datadog/SIEM.
- Keep raw screen content local unless explicit enterprise policy enables escrow/export.

3. Formal compliance pack.

- DPIA template, SOC 2 control matrix, ISO/IEC 27001 risk register, data-flow diagrams, subprocessors, retention/deletion evidence, and admin policy docs.

4. MDM and posture integration.

- Require FileVault, screen recording entitlement posture, app version, hardened runtime/notarization, update channel, and policy signature checks before enabling enterprise recording.

## Quick Wins vs Larger Bets

### Quick wins

- Move `FrameStore.save(jpeg:)` until after OCR/PII detection and in-memory redaction.
- Use `ScreenTextRecognizer.recognizeBoxes` for bounding boxes; add blur/fill with padding around detected text boxes.
- Add native Swift detectors: regex/checksum for emails, phones, SSN/national IDs, credit cards/Luhn, IBAN, API keys/tokens; `NSDataDetector` for links/phones/addresses/dates; `NLTagger` for names/orgs/places.
- Add redaction metadata and a `PrivacyFinding` model.
- Redact or tokenize `ocr_text`, `input_event.text`, `audit_event.detail`, FTS, and embeddings.
- Canonicalize harness paths with realpath, reject symlinks, narrow allowed write roots, and add symlink escape tests.
- Redact audit details and add hash-chain columns to `audit_event`.
- Add a FileVault/encryption posture warning to Settings for enterprise builds.
- Document current plaintext storage as a blocker in sales/security review materials until encryption lands.

### Larger bets

- SQLCipher migration and encrypted frame store.
- Core ML / ONNX local PII detector with measured recall across enterprise screenshots.
- Secure Enclave-signed audit roots and remote transparency anchoring.
- Enterprise policy console: app/domain allowlists, sensitive category rules, retention by class, DLP connector, SIEM export, legal hold.
- SOC 2 Type II / ISO/IEC 27001 implementation program with evidence automation.

## Enterprise Compliance Checklist

### Data inventory and data flow

- Inventory every data class: screenshots/JPEGs, OCR text, AX text, input events, click targets, app/window metadata, FTS, embeddings, audit events, agent recipes, provider requests, exports, diagnostics, logs, crash reports, and backups.
- Document where each class is stored, encrypted, retained, exported, and deleted.
- Record whether raw data, redacted data, placeholders, embeddings, or aggregates are used for each feature.

### Privacy by design and default

- Default to minimal collection and visible recording status.
- Redact before persistence.
- Use whole-frame drop for high-risk surfaces and region redaction for routine PII.
- Provide employee-controlled pause/private mode.
- Disable raw typed-text storage by default.
- Never use recorded context for automated employment decisions without explicit, reviewed product scope and human oversight.

### Lawful basis, notice, and employment safeguards

- Provide clear employee notices: what is captured, why, retention, who can access it, when agents act, and how to pause or delete.
- Require customer legal review for jurisdiction-specific workplace monitoring, works councils, unions, sector rules, and consent limitations.
- Complete a DPIA for EU/UK deployments; systematic workplace monitoring is high-risk.
- Map GDPR Article 5, 25, 35, and 88 controls to product behavior and admin policy.

### Security controls

- Encrypt DB, WAL/SHM, FTS, embeddings, frames, exports, and diagnostics.
- Store keys in Keychain with device-only accessibility; support key rotation and recovery policy.
- Require FileVault/MDM posture for managed enterprise deployments.
- Harden app signing, notarization, sandbox/hardened runtime, update integrity, and dependency SBOM/license review.
- Run third-party penetration tests focused on local data extraction, prompt/tool abuse, path traversal, command injection, and audit tampering.

### Access control

- Gate sensitive local views behind local authentication when enterprise policy requires it.
- Add role-based access for any team/manager view.
- Keep raw screen content employee-local by default; managers should receive summaries or employee-shared excerpts, not ambient surveillance feeds.
- Audit every access, export, deletion, policy change, agent action, and refused harness action.

### Retention, deletion, export, and DSAR

- Make retention configurable by data class and tenant policy.
- Deletion must purge frames, DB rows, WAL remnants after checkpoint/vacuum, FTS rows, embeddings, audit references where legally permitted, exports, diagnostics, and backups according to policy.
- Provide employee/admin export with redacted defaults and access logs.
- Implement legal hold separately from normal retention.

### Audit and evidence

- Hash-chain `audit_event`.
- Sign/anchor audit roots for enterprise deployments.
- Provide an audit verifier and integrity health status.
- Keep audit details sanitized; store enough to prove action/actor/time/outcome without leaking secrets.
- Export SOC 2 / ISO evidence: control owner, control description, evidence link, last test, exceptions, remediation.

### Vendor and contractual readiness

- DPA, subprocessors, data residency posture, model-provider data-use terms, breach notification process, incident response SLAs, deletion commitments, and no-training assurances.
- Document OSS licenses: MIT/BSD/Apache acceptable candidates; Piiranha and immudb have license constraints for embedding.
- Provide customer security packet: architecture, threat model, encryption design, privacy controls, pen-test summary, SOC 2 roadmap, ISO/IEC 27001 alignment, and compliance mapping.

### Monitoring and misuse prevention

- Detect excessive collection, unusual exports, policy downgrades, repeated access to sensitive moments, and harness refusals.
- Add admin alerts for disabled redaction/encryption, audit-chain breakage, FileVault disabled, or unapproved raw shell use.
- Maintain an employee-visible activity/audit view so workplace monitoring is transparent and contestable.
