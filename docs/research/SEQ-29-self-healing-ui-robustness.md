# SEQ-29: Self-Healing UI Robustness

## Overview

Cascade already replays native recipes with a useful grounding cascade: `CascadeAppModel.runAgentRecipe(_:)` tries AX identity via `AXElementResolver.find(descriptor:near:)`, then on-device OCR, then Claude vision, then the recorded coordinate; it verifies clicks with `AXElementResolver.frontmostFingerprint()` and escalates to the full assist agent after repeated unverified steps. The current `AXTargetDescriptor` stores role, accessibility identifier, and parent container, and `InputRecorder` stores the clicked label in `InputEvent.text`.

The next optimization is not another single fallback. It is a self-healing locator ensemble: record more independent anchors at demonstration time, rank live candidates by weighted structural, visual, geometric, and semantic similarity, detect drift before blind clicking, and persist only repairs that are verified by post-action state change. This is portable to Swift and Apple Silicon because the core pieces are already available locally: AX tree walks, Vision OCR/feature prints, dHash/grid hashes, NLEmbedding, SQLite, and audit events.

## OSS Repos & Papers

| name | url | stars/venue | license | technique |
|---|---|---:|---|---|
| Microsoft OmniParser | https://github.com/microsoft/OmniParser | 25k stars | CC-BY-4.0 repo; model weights mixed, including AGPL inherited for icon detector | Parses screenshots into structured interactable regions and captions. Cascade should borrow the concept, not the weights initially: a visual-anchor detector for AX-sparse/canvas UI can produce candidate boxes that join the same ranking queue as AX/OCR candidates. |
| Skyvern | https://github.com/Skyvern-AI/skyvern | 22k stars | AGPL-3.0 | Uses browser automation plus LLM/computer vision instead of brittle XPath-only workflows; exposes selector-first plus AI fallback patterns. Cascade equivalent: deterministic replay first, then confidence-gated visual/semantic repair, then assist escalation. |
| Appium | https://github.com/appium/appium | 21.7k stars | Apache-2.0 | Cross-platform element abstraction with native/page-source locator strategies. The Mac2 driver documents a speed ranking: identifier/name/class/predicate/class-chain before XPath; useful as a Cascade priority order for AX identifiers, role/type, predicate-like attributes, path, then pixels. |
| Appium Images Plugin | https://github.com/appium/appium/tree/master/packages/images-plugin | Appium package | Apache-2.0 | Adds image comparison and "find element by image" to the same element-command flow. Cascade should add visual patch candidates as first-class `AXElementResolver.Match` alternatives rather than separate one-off OCR/vision branches. |
| CUA | https://github.com/trycua/cua | 19.1k stars | MIT | Desktop agent infrastructure for macOS/Windows/Linux with background computer-use, screenshots, clicks, typing, and benchmarks. Useful for replay robustness tests: run mutated UI fixtures in isolated sessions and measure locator survival. |
| Airtest | https://github.com/AirtestProject/Airtest | 9.4k stars | Apache-2.0 | Image-recognition automation for games/apps, with reports and Poco hierarchy access. Cascade should adopt its hierarchy-plus-visual duality: use AX/Poco-like structure when present, visual templates when not, and attach evidence to failures. |
| SikuliX / OculiX lineage | https://github.com/oculix-org/SikuliX1 and https://github.com/oculix-org/Oculix | SikuliX mirror 3.2k stars; OculiX active fork 93 stars | MIT | OpenCV template matching for anything visible on screen, with similarity tuning and cascaded matching strategies. Cascade should use small local visual fingerprints/crops as a bounded fallback, especially for apps with `axUnreliable`. |
| Healenium | https://github.com/healenium/healenium | 155 stars | Apache-2.0 | Selenium self-healing proxy with PostgreSQL-backed reference selectors, healing reports, selector imitator, and service split. Core idea: store historical locator state and report every repair. Cascade should persist verified healed anchors per recipe step. |
| Healenium Web | https://github.com/healenium/healenium-web | 199 stars | Apache-2.0 | `SelfHealingDriver`, `recovery-tries`, `score-cap`, `heal-enabled`, and healed locator proposals. Cascade should add a `scoreCap` threshold to `AXElementResolver.find`, return top-N candidates, and only auto-click above threshold. |
| SeeClick / ScreenSpot | https://github.com/njucckevin/SeeClick | 486 stars; ACL 2024 | Apache-2.0 | GUI grounding pre-training and ScreenSpot benchmark across iOS, Android, macOS, Windows, and web; outputs normalized points/bounds for text/icon targets. Cascade should use ScreenSpot-style tests for local visual locator evaluation before adopting any model. |
| Similo | https://arxiv.org/abs/2208.00677 | arXiv 2022 | Paper | Weighted similarity over multiple element locator parameters. It cut failures from 146 to 72 out of 598 cases versus the baseline. Direct fit for `AXElementResolver.rank`: combine identifier, label, role, container, path, frame, neighbors, and visual hash. |
| VON Similo | https://arxiv.org/abs/2301.03863 | arXiv 2023 | Paper | Uses visually overlapping nodes because a visible target may be composed of multiple DOM nodes. It reported 94.7% accuracy versus 83.8% for Similo on the same setting. Cascade equivalent: consider AX ancestors/descendants/siblings whose frames overlap the recorded click/crop, not only the hit-test node. |
| HybridSimilo replication | https://arxiv.org/abs/2505.16424 | arXiv 2025 | Paper | Replicates Similo/VON Similo, finds VON can produce false positives, tunes parameters, and reports 98.8% relocalization in realistic broken-locator scenarios. Takeaway: optimize weights and add false-positive gates; do not blindly expand visual overlap. |
| VON Similo LLM | https://arxiv.org/abs/2310.02046 | arXiv 2023 | Paper | Uses an LLM to rerank top VON Similo candidates and reduces failed localizations from 70 to 39 out of 804, at extra latency/cost. Cascade fit: use Claude only as a medium-confidence reranker after local scoring, not as the first locator. |
| Erratum | https://arxiv.org/abs/2106.04916 | arXiv 2021 | Paper | Flexible tree matching to repair broken locators by reducing search space before similarity scoring; reported 67% better accuracy than WATER. Cascade fit: match the recorded window/container subtree first, then expand to sibling/all-window search only if needed. |
| ReproBreak | https://arxiv.org/abs/2605.12158 | arXiv 2026; dataset at https://github.com/rub-sq/ReproBreak | Paper / dataset | Dataset of reproducible locator breaks in open-source Playwright/Cypress tests. Cascade should create an analogous native fixture set: renamed buttons, moved controls, reordered rows, localized labels, missing AX IDs, and canvas-only targets. |
| HILC | https://arxiv.org/abs/1611.03906 | arXiv 2016 | Paper | Programming by demonstration with screenshots/events plus follow-up questions. Useful product rule: ask the user only when top candidates are too close or the repair cannot be verified, and phrase it as "which of these two controls?" rather than dumping internals. |

## Concrete Techniques to Adopt

- Replace `AXTargetDescriptor`'s separator-packed locator with a backward-compatible versioned anchor bundle in `Sources/CascadeMemory/CascadeMemory.swift`. Keep `AXTargetDescriptor.decode(_:)` tolerant of legacy strings, but add `AXTargetDescriptorV2: Codable` encoded as JSON when `targetDescriptor` starts with `{`. Fields: `label`, `role`, `identifier`, `container`, `windowTitle`, `ancestorPath`, `siblingRoleIndex`, `neighborLabels`, `frameBucket`, `subtreeHash`, `visualPatchHash`, `semanticTextHash`, and `createdFrom`.

- Extend `InputRecorder.axClickTarget(atCG:)` in `Sources/MacContextKit/InputRecorder.swift` to capture the V2 structural ensemble. While climbing to the labeled actionable ancestor, also collect up to three ancestors as `role:normalizedTitle`, sibling index among same-role siblings, immediate neighbor labels under the parent, element frame bucket (for example 24 px grid), and a small subtree hash over child roles/titles. Keep privacy gating on parent/neighbor text with `PrivacyRules.isSensitiveText`.

- Add `AXElementResolver.Candidate` in `Sources/ComputerUseKit/AXElementResolver.swift` with `center`, `frame`, `descriptor`, `scores`, `totalScore`, and `source`. Replace `find(descriptor:near:) -> Match?` with a new `rank(descriptor:near:limit:) -> [Candidate]`; keep `find` as a wrapper returning the first candidate above the default automatic threshold.

- Change `AXElementResolver.rank(recorded:candidate:)` from integer text tiers to Similo-style weighted scoring. Starting weights: identifier exact `0.30`, label similarity `0.20`, role `0.10`, container/ancestor path `0.15`, neighbor labels `0.10`, frame proximity `0.05`, subtree hash `0.05`, semantic text hash `0.05`. Normalize to `0...1`, require `>=0.78` to auto-heal, `0.60...0.78` to rerank with OCR/vision/Claude, and `<0.60` to fall through without clicking.

- Add visual-overlap candidate expansion to `AXElementResolver.walk`. For a recorded click with a V2 anchor, include candidates whose frames overlap the recorded frame bucket or current best predicted region, plus their nearest labeled ancestors and actionable descendants. This ports VON Similo to AX: the visible target may be a text node inside a button, an image inside a toolbar item, or a row/cell pair.

- Add Erratum-style search narrowing in `AXElementResolver.find`: first search the focused window whose title/bundle matches `windowTitleHint`; within it, score the recorded container/ancestor subtree; only if no candidate clears `0.60`, expand to the focused window; only then expand to all windows. This reduces false positives from duplicate labels like "Save", "Done", and table cells.

- Update `CascadeAppModel.resolveByAX(step:recorded:)` to return `(point, confidence, source, candidates)` rather than `CGPoint?`. In `runAgentRecipe(_:)`, use confidence to decide: high confidence auto-click; medium confidence run `regroundedByOCR` and `regroundedTarget` as rerankers; low confidence skip direct click and escalate to assist. Audit as `recipe.target` with `via ax score=0.84 label=0.20 path=0.13`.

- Persist verified repairs Healenium-style. Add a lightweight `healed_anchors` table or `agents.recipe_json` sidecar in `Sources/CascadeMemory/CascadeMemory.swift` keyed by `agent_id`, `step_order`, `bundle_id`, and `anchor_hash`, with `score`, `source`, `verified_count`, `last_verified_at`, and `last_failed_at`. Only write after `uiChanged(after:)` confirms the action changed state. On future replays, merge historical successful anchors into the V2 ensemble before ranking.

- Add a `recipe.drift` audit event in `CascadeAppModel.runAgentRecipe(_:)` when the top AX score drops below the previous verified score by more than `0.15`, when the winning anchor source changes, or when two top candidates are within `0.05`. This gives the Manager/Cascades UI a clear "recipe may need review" signal before repeated failures.

- Add visual patch hashes without storing raw sensitive crops by default. In `Sources/WasteDetection/WasteDetector.swift`, when building `RecipeStep` from `InputEvent` plus `RecordedContext`, crop a small region around the click from the nearest evidence frame, compute a Vision feature print or dHash/edge hash, and store only the hash in V2 `visualPatchHash`. If the context is sensitive, omit it. For Apple Silicon, prefer `VNGenerateImageFeaturePrintRequest` for larger bets and keep dHash for quick tests.

- Add `VisualAnchorResolver` under `Sources/MacContextKit` or `Sources/ComputerUseKit`. It should first search a bounded region around the AX/OCR predicted point, then the recorded screen quadrant, then the whole current display. Return candidates with similarity and bounds, feeding the same `AXElementResolver.Candidate` queue. This is the Sikuli/Appium Images/Airtest fallback, but bounded and auditable.

- Use the existing `NLEmbedding` pattern from `CascadeMemory.SemanticIndex` for semantic text anchors. Build a short phrase from `{label, container, neighborLabels, windowTitle}` and store a compact embedding hash or normalized phrase. At replay, if "Submit" became "Continue", the semantic similarity can lift the renamed candidate without relying on text containment.

- Add top-N candidate review only at ambiguity boundaries. In `CascadeAppModel.escalateRecipeToAssist(_:)`, when local ranking returns two close candidates, pass a concise block: `ambiguous controls: 1. Continue button near Billing, score .69; 2. Continue link near Help, score .66`. If no model key is available, highlight both with `GuidanceOverlay` and pause for user choice.

- Update `AXElementResolver.interactables(limit:)` to reuse the richer candidate descriptor. The no-effect flail summary should list stable labels plus role/container and omit low-confidence passive elements. This keeps the live agent's recovery context aligned with deterministic recipe replay.

- Replace the single corrective retry at recorded coordinates in `CascadeAppModel.runAgentRecipe(_:)` with "retry next candidate" when the first candidate was high-enough but unverified. If candidate 1 fails `uiChanged`, try candidate 2 only if it is within `0.10` of candidate 1 and still above `0.72`; otherwise escalate. Do not retry stale coordinates unless all locator evidence is absent.

- Add a replay survival test fixture set under `Tests/ComputerUseKitTests` and `Tests/AppShellTests`: same control moved; label renamed; identifier removed; duplicate labels in two containers; row reordered; localized label with same identifier; parent container title changed; visual-only canvas target; wrong-app frontmost. Pin expected candidate order and confidence thresholds.

- Add an offline mutation harness inspired by ReproBreak: serialize a small synthetic AX tree format, mutate it, and run `AXElementResolver.rank` without real Accessibility permissions. This makes weight tuning deterministic and prevents regressions when changing score caps.

- Add a product-facing repair report in Cascades later: when `healed_anchors` changes, show "Updated anchor for step 3 after Keynote moved the Export button" with before/after evidence and an undo/re-record option. Keep raw scores in the audit detail, not the main HR/product surface.

## Quick Wins vs Larger Bets

Quick wins:

- Add `AXTargetDescriptorV2` JSON with ancestor path, sibling index, neighbor labels, frame bucket, and subtree hash; keep legacy decode.
- Return top-N ranked AX candidates with a `scoreCap` instead of a single `CGPoint?`.
- Gate auto-clicks by confidence and audit score components in `recipe.target`.
- Search the recorded container/window first, then expand outward, to reduce duplicate-label false positives.
- Persist verified healed anchors after `uiChanged(after:)`, and prefer them on the next run.
- Replace "retry recorded coordinate" with "retry next verified candidate" for high-confidence locator ambiguity.
- Add pure Swift unit tests for moved/renamed/reordered/duplicated AX fixtures.

Larger bets:

- Add Vision feature-print or OpenCV-like visual patch matching for AX-sparse apps, with sensitive-context crop suppression.
- Build an Erratum-style flexible tree matcher over AX snapshots to detect moved/renamed controls and compute repair candidates from subtrees.
- Train or embed a local GUI parser only after the deterministic ensemble has metrics; OmniParser/SeeClick are useful patterns but too heavy/license-sensitive for immediate bundling.
- Build a ReproBreak-like native replay benchmark that replays recipes across mutated synthetic apps and real app-version changes.
- Add an ambiguity UI that highlights the top two candidates and asks once, then stores the verified answer as a learned anchor.

## License/Attribution Notes

- Healenium and Healenium Web are Apache-2.0. Concepts are safe to reimplement; copying code requires notices.
- Appium and Appium Images Plugin are Apache-2.0. The locator priority model and image-fallback concept are safe to adapt with attribution if code is copied.
- Airtest is Apache-2.0. Its image recognition plus hierarchy model is useful conceptually; avoid importing Python/OpenCV code into the Swift app.
- SikuliX/OculiX are MIT lineage. Template matching ideas are permissive, but Cascade should implement a native Swift/Vision version rather than vendoring Java/Jython.
- Skyvern is AGPL-3.0. Do not copy code into Cascade. Use only architectural ideas: selector-first plus AI fallback, layout-change resistance, action validation.
- OmniParser repo is CC-BY-4.0 and model weights have mixed licenses, including AGPL inherited for the icon detector. Do not bundle weights without a separate license review.
- SeeClick is Apache-2.0, but checkpoints/datasets may carry their own terms. Use ScreenSpot-style evaluation ideas before considering any model dependency.
- Academic papers can be cited and reimplemented. Record citations in `docs/THIRD_PARTY_NOTICES.md` only if code, trained weights, or substantial pseudocode is copied.
