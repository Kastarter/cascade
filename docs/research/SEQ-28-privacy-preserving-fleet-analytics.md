# SEQ-28 Privacy-Preserving Enterprise Fleet Analytics

## Overview

Cascade's enterprise analytics story should not be "upload local work history to a manager dashboard." The product already records rich employee context locally: screenshots, OCR, AX labels, input events, audit rows, agent recipes, and `AgentTrace` spans. Those objects are too sensitive to centralize. Fleet analytics should instead be a derived, local-first measurement layer that answers enterprise questions from bounded aggregates only:

- How much time was actually saved by completed agents?
- Which broad workflow categories are common enough to deserve investment?
- Which agent failures, apps, surfaces, or permissions block adoption?
- Which teams have healthy usage without exposing any employee's screen, prompts, keystrokes, documents, URLs, or exact workflow text?

The design target: every Mac computes a daily or weekly metric vector locally from `CascadeStore`, `AgentTrace`, `audit_event`, `agents`, and `WasteDetector` outputs; clips per-user contribution; removes unsafe fields; applies differential privacy or secret sharing; exports only aggregate-eligible measurements with a privacy manifest and the local audit-chain head. Raw `recorded_context`, OCR, images, target descriptors, prompts, tool arguments, and unredacted audit details never leave the device in the default fleet path.

This complements SEQ-14's trace export and SEQ-26's event-store engineering. SEQ-28's distinct optimization is the privacy layer between local trace/audit data and any enterprise-wide analytics product.

## OSS Repos & Papers

Repository stars were checked through the GitHub API on 2026-06-26.

| name | url | stars/venue | license | technique |
|---|---:|---:|---|---|
| OpenDP | https://github.com/opendp/opendp | 422 stars | MIT | Rust core for differentially private transformations and measurements. Technique to copy: typed measurement pipelines, contribution bounds before mechanisms, explicit privacy maps/accounting. Useful as a design reference for a Swift `FleetPrivacyAccountant`, not a direct dependency unless Cascade adds a Rust bridge. |
| Google Differential Privacy | https://github.com/google/differential-privacy | 3,325 stars | Apache-2.0 | Production-oriented DP libraries in C++, Go, Java plus Beam/PipelineDP patterns. Technique to copy: bounded sum/count/mean, noise mechanisms, public partition selection, stochastic/statistical tests for mechanisms. Strongest direct OSS reference for Cascade's aggregate counters and histograms. |
| Google RAPPOR | https://github.com/google/rappor | 870 stars | Apache-2.0 | Local differential privacy for strings using randomized response and Bloom filters. Technique to copy: common app/workflow discovery without uploading raw workflow names or per-user categorical values. |
| TensorFlow Federated | https://github.com/google-parfait/tensorflow-federated | 2,440 stars | Apache-2.0 | Framework for computations on decentralized data. Technique to copy: separate query definition, client computation, aggregation, and release. Cascade can use this as a mental model for fleet analytics queries over local SQLite, not as a runtime dependency. |
| PySyft | https://github.com/OpenMined/PySyft | 9,914 stars | Apache-2.0 | Data science over remote/private data. Technique to copy: policy-gated remote execution and result release. Useful product pattern for admin-defined analytics jobs that run locally and return only approved outputs. |
| FATE | https://github.com/FederatedAI/FATE | 6,077 stars | Apache-2.0 | Industrial federated learning platform. Technique to copy: multi-party job orchestration, role separation, auditability of distributed privacy jobs. Heavyweight, but its governance model maps to enterprise fleet analytics. |
| OpenFL | https://github.com/securefederatedai/openfederatedlearning | 839 stars | Apache-2.0 | Federated learning framework. Technique to copy: federation plans, collaborator identity, secure transport, and local task execution. Cascade's equivalent is a signed fleet-query plan executed by the local app. |
| Opacus | https://github.com/meta-pytorch/opacus | 1,935 stars | Apache-2.0 | Differential privacy for ML training with privacy accounting. Technique to copy: clear accounting APIs and testable privacy budget spend records, even though Cascade's first use is analytics, not training. |
| IBM diffprivlib | https://github.com/IBM/differential-privacy-library | 914 stars | MIT | General DP mechanisms and models. Technique to copy: simple mechanism APIs, DP-aware statistics, and utility testing. Good reference for Swift unit tests around Laplace/Gaussian/geometric mechanisms. |
| SmartNoise Core | https://github.com/opendp/smartnoise-core | 293 stars | MIT | Differential privacy validator and runtime. Technique to copy: validate that a query is DP-safe before execution, and separate query analysis from execution. |
| libprio-rs | https://github.com/divviup/libprio-rs | 120 stars | MPL-2.0 | Rust implementation of Prio/VDAF-style private aggregation. Technique to copy or optionally bridge: Prio3 count/sum/histogram shares for multi-aggregator fleet metrics. MPL is file-level copyleft, so keep attribution and isolate if vendored. |
| Apple pfl-research | https://github.com/apple/pfl-research | 356 stars | Apache-2.0 | Private federated learning simulation. Technique to copy: local training/analytics simulation harnesses before deploying privacy math to a real fleet. |
| RAPPOR: Randomized Aggregatable Privacy-Preserving Ordinal Response | https://arxiv.org/abs/1407.6981 | ACM CCS 2014 | Paper | Local DP for client-side strings. Apply to workflow signatures, app categories, and repeated-action labels where Cascade needs heavy hitters without exact values. |
| Prio: Private, Robust, and Scalable Computation of Aggregate Statistics | https://arxiv.org/abs/1703.06255 | NSDI 2017 | Paper | Secret-shared private aggregation with validation. Use for enterprise metrics where the server should see only sums/histograms and at least one aggregator is honest. |
| Practical Secure Aggregation for Federated Learning on User-Held Data | https://arxiv.org/abs/1611.04482 | CCS 2017 | Paper | Dropout-tolerant secure aggregation. Useful for high-dimensional metric vectors across many Macs, especially if laptops are offline or intermittent. |
| Prochlo: Strong Privacy for Analytics in the Crowd | https://arxiv.org/abs/1710.00901 | SOSP 2017 | Paper | Encode, Shuffle, Analyze architecture. Cascade can mirror this as Encode locally, optionally shuffle/proxy through tenant relay, then analyze only aggregate batches. |
| Federated Analytics: A Survey | https://arxiv.org/abs/2302.01326 | arXiv 2023 | Paper | Defines federated analytics as analytics over remote/local data without sharing raw data. Gives the conceptual basis for query types Cascade should support: counts, histograms, heavy hitters, sketches, and monitoring. |
| Federated Analytics in Practice | https://arxiv.org/abs/2412.02340 | arXiv 2024 | Paper | Cross-device FA engineering with privacy, scalability, and practicality. Important because it focuses on analytics, not model training. Use its split between on-device computation, privacy safeguards, and fleet scale as the north star. |
| Learning with Privacy at Scale | https://machinelearning.apple.com/2017/12/06/learning-with-privacy-at-scale.html | Apple ML Research 2017 | Apple web article | Production LDP pattern on Apple platforms: local randomization before upload, resource overhead constraints, and non-centralized raw data. Directly relevant to Swift/macOS product positioning. |
| Practical Locally Private Heavy Hitters | https://arxiv.org/abs/1707.04982 | NeurIPS 2017 | Paper | Efficient LDP algorithms for discovering frequent strings. Use when Cascade wants common workflow names/categories without raw workflow upload. |
| Distributed Aggregation Protocol for Privacy Preserving Measurement | https://datatracker.ietf.org/doc/draft-ietf-ppm-dap/ | IETF Internet-Draft, last updated 2026-05-11 | IETF Trust; code components Revised BSD | Multi-party protocol for collecting aggregate measurements without revealing individual contributions. Good target for future standards-aligned fleet telemetry. |
| Verifiable Distributed Aggregation Functions | https://datatracker.ietf.org/doc/draft-irtf-cfrg-vdaf/ | IRTF Internet-Draft | IETF Trust; code components Revised BSD | Defines VDAFs such as Prio-style verifiable aggregation. Use for typed count/sum/histogram vectors with client-side validity proofs. |

## Concrete Techniques to Adopt

- Add a dedicated fleet-safe event model in `Sources/AgentOrchestrator/AgentTrace.swift`. Keep `otelJSON()`, `siemJSONL()`, and `csv()` as local/export tools, but add `FleetMetricEvent` and `fleetMetrics(period:policy:)` that emit only low-cardinality counters and histograms: model call count, token buckets, duration buckets, tool class, failure kind, completed run count, reclaimed seconds clipped to a cap, and permission state. Do not include `traceID`, `goal`, span `name`, raw attributes, prompt text, OCR, URL, or tool payloads in fleet metrics.

- Make metric export allowlist-based, not denylist-based. Add `Sources/CascadeMemory/AnalyticsPrivacyPolicy.swift` with allowed fields such as `period`, `tenant_metric_key`, `bucket`, `count`, `sum`, `epsilon`, `delta`, `mechanism`, `min_cohort`, and `audit_head_hash`. Unit-test that forbidden fields from `RecordedContext`, `InputEvent`, `RecipeStep`, and `TraceSpan` cannot serialize: `ocrText`, `imagePath`, `text`, `windowTitle`, `targetDescriptor`, `goal`, tool arguments, file paths, and URLs.

- Add a local `fleet_metric_daily` projection table in `Sources/CascadeMemory/CascadeMemory.swift` rather than querying raw rows during upload. Suggested schema: `period_start TEXT`, `metric_key TEXT`, `bucket TEXT`, `clipped_value INTEGER`, `privacy_unit TEXT`, `epsilon REAL`, `delta REAL`, `mechanism TEXT`, `source_audit_head TEXT`, `exported_at TEXT`. Populate it from `markAgentRun(id:at:)`, `appendAudit(_:)`, and a daily rollup job over local `agents` and `AgentTrace` data.

- Enforce contribution bounding before any privacy mechanism. In `CascadeStore.markAgentRun(id:at:)`, cap exported `seconds_reclaimed` per agent and per user per day, for example `min(seconds_per_run, 1800)` and `max 20 completed runs/workflow/day`. In the daily rollup, cap `tool_call_count`, `failure_count`, and `model_token_count` per privacy unit. This is the difference between usable DP and a metric where one power user dominates the aggregate.

- Export audit provenance, not audit detail. In `appendAudit(_:)`, the local chain already PII-redacts and stores `prev_hash`/`event_hash`. For fleet metrics, export only `latestAuditHash()`, chained row count, app version, policy version, and metric period. This lets an admin prove a metric came from an intact local ledger without centralizing `audit_event.detail`.

- Convert workflow detection outputs into stable private categories. In `Sources/WasteDetection/WasteDetector.swift`, `makeWaste(...)` currently creates `DetectedWaste.title`, `signature`, `recipe`, `evidence`, and human labels. Fleet analytics should never upload title, recipe, evidence ids, labels, coordinates, or target descriptors. Add `DetectedWaste.fleetCategory(policy:)` that returns a bounded tuple: `workflow_kind` (`copy_paste_cross_app`, `browser_form`, `scheduled_agent`, `document_edit`, `other`), `app_category`, step-count bucket, and an HMAC of the normalized signature with a tenant-local rotating key. Use the HMAC only inside secure aggregation or k-anonymous cohorts.

- Use local DP for heavy hitters when there is only one server-side aggregator. Implement RAPPOR/optimized local hashing in a small Swift module, for example `Sources/CascadeMemory/LocalDP.swift`. Use it for app/workflow popularity, not for exact time-saved sums. Inputs: a dictionary-limited category or salted signature. Output: randomized Bloom/hashed reports. Server estimates common categories after enough clients submit; no raw workflow string is visible.

- Use central DP only after secure aggregation or trusted tenant aggregation. For numeric metrics such as total runs, reclaimed minutes, failure counts, and token costs, prefer secure aggregation first, then add Gaussian/Laplace/geometric noise at release time. If Cascade Cloud is the only aggregator, use local DP instead. This distinction should be explicit in admin policy: `mode = local_dp_single_aggregator | secure_aggregation_plus_central_dp | no_export`.

- Add a privacy budget ledger. Create `FleetPrivacyBudget` in `Sources/CascadeMemory`, keyed by tenant, metric family, period, epsilon, delta, and mechanism. Each export reserves budget before serialization and writes an audit row such as `fleet.export.dp_budget_spent`. Use OpenDP/Google DP as reference designs for composition. A simple first version can use per-metric epsilon caps and monthly reset; later versions can move to zCDP/RDP accounting.

- Add DP-safe mechanism tests under `Tests/CascadeMemoryTests/FleetPrivacyTests.swift`. Borrow the testing posture from Google DP and diffprivlib: deterministic clipping tests, randomized distribution sanity tests, privacy budget composition tests, and serialization tests that fail if a raw sensitive field appears in metric JSON.

- Use integer/discrete noise where possible. For count and bounded integer sums, implement discrete Laplace or two-sided geometric noise using `CryptoKit`/`SystemRandomNumberGenerator` backed by secure randomness, and avoid fragile floating-point comparisons in privacy-critical code. Floating point can still be used for analytics display after the noisy integer release.

- Add k-anonymity and cohort thresholds as product guardrails even when DP is enabled. In the fleet release service or local export planner, suppress metric buckets until `min_devices >= 50` or tenant policy threshold. DP protects individuals mathematically, but enterprise UX should not show "1 person in Legal ran workflow X" even if noised.

- Convert `ManagerScreen` in `Sources/AppShell/CascadeRootView.swift` into a local preview of the same aggregate metric schema. Today it calculates `minutesReclaimed`, `minutesOnTheTable`, `appsObserved`, and `appUsage` directly from local `model.contexts` and `model.agents`. Keep that local UI, but add labels and export preview from `fleet_metric_daily` so managers see the exact metric families that fleet analytics can release.

- Add an admin-visible `FleetExportManifest`. Store alongside each export: app build, tenant id hash, metric schema version, privacy mode, epsilon/delta, clipping bounds, min cohort, source audit head, and omitted-field list. This should be generated next to `AgentTrace` exports and audited. It becomes the enterprise answer to "what did Cascade send?".

- Split raw diagnostic export from fleet metrics. In `AgentTrace.otelJSON()` and `siemJSONL()`, add a parameter or sibling method that requires an explicit diagnostic policy before exporting span names/attributes. Fleet metrics should call only the aggregate method. This prevents a future UI from accidentally using the SIEM export path as fleet telemetry.

- Add a signed fleet-query plan. Inspired by TFF/PySyft/FATE/OpenFL, define an admin query as a versioned JSON plan: metric keys, period, clipping bounds, DP mode, min cohort, and destination. The Mac verifies the signature and policy, computes locally, then exports only approved metrics. Map this to `CascadeAppModel` as an opt-in background job, never as a remote SQL query over employee data.

- Build secure aggregation as the first large bet, not the first quick win. Use DAP/VDAF/Prio semantics: each Mac secret-shares a fixed metric vector to two non-colluding aggregators, for example customer-hosted plus Cascade-hosted. The aggregators learn only the sum after threshold. A Swift implementation can start with count/sum/histogram vectors and later bridge a Rust VDAF library if licensing and binary distribution are acceptable.

- Add an offline simulation harness before real fleet launch. Use `Tests/CascadeMemoryTests` fixtures to synthesize 10k devices with skewed workflow counts, offline/dropout behavior, and privacy budgets. Measure error bars for reclaimed-minutes, adoption, failure-rate, and heavy-hitter workflow categories at cohort sizes 25/50/100/1000. This is necessary to set honest enterprise defaults.

## Quick Wins vs Larger Bets

Quick wins:

- Add `AnalyticsPrivacyPolicy` allowlist and serialization tests so no fleet export can contain raw OCR, screenshots, prompt text, tool payloads, file paths, URLs, target descriptors, or exact workflow titles.
- Add `fleet_metric_daily` as a local projection table populated from `markAgentRun(id:at:)`, `appendAudit(_:)`, and daily `AgentTrace` rollups.
- Add clipped aggregate counters for completed runs, reclaimed seconds, agent approvals, failure kinds, permission blocks, model/token buckets, and app categories.
- Add `FleetExportManifest` with source audit head, schema version, omitted fields, clipping bounds, and privacy parameters.
- Add local DP randomized response for a small set of categorical metrics: feature adoption, permission states, broad workflow kind, and app category.

Larger bets:

- Implement DAP/VDAF/Prio-style secure aggregation for fixed vectors so the enterprise backend never sees per-device metric values.
- Build a federated analytics query planner: signed admin plans run on each Mac against local SQLite projections and return only approved aggregate reports.
- Implement private heavy-hitter discovery for workflow signatures using RAPPOR/OLH/TreeHist, plus cohort thresholds and rotating HMAC keys.
- Add a formal privacy accountant with monthly budgets, metric-family composition, and admin-visible spend.
- Add customer-hosted aggregator support so regulated enterprises can run one aggregator themselves while Cascade runs the other.

## License/Attribution notes

- MIT and Apache-2.0 sources (`opendp`, Google DP, RAPPOR, TFF, PySyft, FATE, OpenFL, Opacus, diffprivlib, SmartNoise, Apple pfl-research) are compatible as references, but copying code still requires preserving copyright/license notices.
- `libprio-rs` is MPL-2.0. If Cascade ever vendors or modifies it, isolate it as a separate module/binary and comply with file-level source availability obligations. The safer near-term path is to use the Prio/VDAF papers and IETF drafts as protocol references and write a minimal Swift client for count/sum/histogram shares.
- Academic papers and IETF drafts should be cited as design sources, not copied as code. IETF code components have Revised BSD terms, but draft status means the protocol can still change.
- Do not copy Apple production implementation details beyond what is published in the public article. Use it for product posture: local randomization, resource overhead control, and clear privacy guarantees.
- For any DP library brought into production, include statistical tests and privacy-parameter documentation in the repo. A DP mechanism without visible epsilon/delta, clipping, cohort, and budget policy is not enterprise-grade.
