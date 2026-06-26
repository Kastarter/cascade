# Research Sequence 03: GUI Grounding / Screen Parsing / Element Localization

## Overview

Cascade already has the right production shape for screen grounding: use cheap local structure first, escalate to visual models only when structure is thin, and audit every action. The current stack is:

- `Sources/ComputerUseKit/AXElementResolver.swift`: frontmost AX tree search, interactable summaries, labels, fingerprints.
- `Sources/MacContextKit/AXTextHarvester.swift`: bounded AX text extraction and AX-before-OCR text merge.
- `Sources/AppShell/MixtureGrounder.swift`: AX-first grounding, OCR region search, visual fallback.
- `Sources/ProviderKit/VisualGrounder.swift`: `VisualGrounder`, `ClaudeVisualGrounder`, and OpenAI-compatible `UITARSGrounder`.
- `Sources/ProviderKit/ElementLocator.swift`: Claude vision point/region grounding and haiku region narrowing.
- `Sources/ComputerUseKit/ComputerUseKit.swift`: `AXClickSnap`, which snaps model clicks onto small nearby AX controls.
- `Sources/ProviderKit/ComputerUseAgent.swift`: structural `click_target` / `fill_target` / `scroll` tools, `pregroundTargets`, and cached grounding.

The main opportunity is to stop treating "ground this text/icon" as open-ended coordinate generation. The strongest OSS work points to a candidate-first pipeline:

1. Build a local screen element inventory from AX, Vision OCR boxes, and a local icon/control detector.
2. Render a Set-of-Mark overlay with stable numeric IDs over candidate boxes.
3. Ask a cheap local or hosted GUI grounder to choose an ID, not freehand coordinates.
4. Snap and verify with AX/no-effect checks, then escalate to Claude only for ambiguous cases.

This should make grounding cheaper, faster, and more accurate without weakening Cascade's audit and STOP model.

## OSS Repos & Papers

| Project | Repo / Paper | License | Technique | ScreenSpot Accuracy |
|---|---|---:|---|---|
| OmniParser / OmniParser-v2 | [GitHub](https://github.com/microsoft/OmniParser), [paper](https://arxiv.org/abs/2408.00203), [v2 blog](https://www.microsoft.com/en-us/research/articles/omniparser-v2-turning-any-llm-into-a-computer-use-agent/) | Repo license is CC-BY-4.0; README badge says MIT; icon detector weights inherit AGPL from YOLO | Parses UI screenshots into structured elements: text regions, icon/control boxes, interactability, icon captions. V2 improves small-icon detection and caption latency. | OmniParser standard ScreenSpot avg 73.0 in UGround table. OmniParser-v2 + GPT-4o reports about 39.5-39.6 on ScreenSpot-Pro, versus GPT-4o baseline 0.8. |
| Set-of-Mark Prompting (SoM) | [GitHub](https://github.com/microsoft/SoM), [paper](https://arxiv.org/abs/2310.11441) | Verify repo license before code reuse | Overlays alphanumeric marks on segmented regions, turning visual grounding into region selection. Originally general VLM grounding, directly applicable to UI candidates. | No ScreenSpot score reported. Use as a prompting/interface technique. |
| UGround | [GitHub](https://github.com/OSU-NLP-Group/UGround), [project](https://osu-nlp-group.github.io/UGround/), [paper](https://arxiv.org/abs/2410.05243) | MIT | Pure-vision GUI grounding trained on 10M GUI elements from 1.3M screenshots. Outputs normalized coordinates. Strong small/open GUI grounding model. | Standard ScreenSpot avg: UGround-V1-2B 77.7, 7B 86.3, 72B 89.4. README reports ScreenSpot-Pro improvement from 18.9 to 31.1. |
| Ferret-UI / Ferret-UI-2 / Ferret-UI Lite | [Apple ml-ferret](https://github.com/apple/ml-ferret), [Ferret-UI paper](https://arxiv.org/abs/2404.05719), [Ferret-UI-2 paper](https://arxiv.org/abs/2410.18967), [Lite paper](https://arxiv.org/abs/2509.26539) | Apple sample/research terms; datasets/models include non-commercial research restrictions | UI-specialized MLLM. Any-resolution and adaptive sub-image scaling to magnify dense mobile/web UI. Ferret-UI-2 adds cross-platform UI data and SoM-generated training data. | Ferret-UI standard ScreenSpot avg 32.3 in UGround table. Ferret-UI Lite paper reports ScreenSpot-v2 91.6 and ScreenSpot-Pro 53.3, but it is not an immediate OSS production dependency. |
| Aria-UI | [GitHub](https://github.com/AriaUI/Aria-UI), [project](https://ariaui.github.io/), [model](https://huggingface.co/Aria-UI/Aria-UI-base), [paper](https://arxiv.org/abs/2412.16256) | HF model and dataset are Apache-2.0 | Context-aware pure-vision GUI grounding, with textual and text-image-interleaved action history. MoE with 3.9B active parameters and ultra-resolution support. | Standard ScreenSpot avg 81.1 in UGround table. |
| OS-Atlas | [GitHub](https://github.com/OS-Copilot/OS-Atlas), [paper](https://arxiv.org/abs/2410.23218) | Apache-2.0 | Cross-platform GUI grounding corpus with more than 13M GUI elements across Windows, Linux, macOS, Android, and web. 4B/7B models output normalized point or bbox. | Standard ScreenSpot avg: Base-4B 68.0, Base-7B 81.0 in UGround table. |
| ScreenSpot-Pro | [Leaderboard](https://gui-agent.github.io/grounding-leaderboard/), [GitHub](https://github.com/likaixin2000/ScreenSpot-Pro-GUI-Grounding), [paper](https://arxiv.org/abs/2504.07981) | MIT | High-resolution professional-app grounding benchmark across 23 apps, 5 industries, and 3 OSs. Exposes failures on dense desktop software. | Benchmark, not model. Paper reports best existing model initially 18.9; cascaded search ScreenSeekeR gets 48.1 without extra training. |
| ScreenSpot-v2 | [Dataset](https://huggingface.co/datasets/OS-Copilot/ScreenSpot-v2) | Apache-2.0 | Refined cross-platform GUI grounding dataset with text/icon split, bbox, instruction, and data source labels. | Benchmark, not model. Useful for local regression tests. |
| OSWorld-G / Jedi | [GitHub](https://github.com/xlang-ai/OSWorld-G), [project](https://osworld-grounding.github.io/), [paper](https://arxiv.org/abs/2505.13227) | Apache-2.0 | OS GUI grounding benchmark and Jedi models trained from UI decomposition/synthesis. Includes fine-grained manipulation and refusal categories. | UI-TARS-7B: ScreenSpot-v2 91.6, ScreenSpot-Pro 35.7, OSWorld-G 47.5. Jedi-7B: 91.7, 39.5, 54.1. |
| ScreenAI | [Paper](https://arxiv.org/abs/2402.04615) | No public production OSS model found | Screen annotation task: detect UI elements and their locations using a PaLI + pix2struct style VLM with flexible patching. | No ScreenSpot score found. Technique supports candidate inventory and layout parsing. |
| Screen2AX | [Paper](https://arxiv.org/abs/2507.16704) | Paper/dataset status should be verified before reuse | Vision-based synthetic macOS accessibility tree generation. Claims only 33% of apps have full AX support and uses VLM/object detection to infer tree-structured AX metadata. | Reports 77% F1 tree reconstruction and surpasses OmniParser-v2 on ScreenSpot; exact table should be checked before citing in product materials. |
| RegionFocus / DRS-style region search | [RegionFocus](https://arxiv.org/abs/2505.00684), [DRS-GUI](https://arxiv.org/abs/2605.15542) | Paper techniques; verify any repo/license | Test-time coarse-to-fine search: find a broad relevant region, crop/scale it, then ground again. Strong for high-resolution professional apps. | RegionFocus reports +28% on ScreenSpot-Pro and 61.6 with Qwen2.5-VL-72B. DRS-GUI reports +14% for Qwen2.5-VL-7B and UGround-V1-7B. |
| EasyOCR | [GitHub](https://github.com/JaidedAI/EasyOCR) | Apache-2.0 | PyTorch OCR with detector/recognizer, 80+ languages, bbox/text/confidence output. | No ScreenSpot score. Useful as a prototyping comparator, not ideal for Swift app bundling. |
| PaddleOCR | [GitHub](https://github.com/PaddlePaddle/PaddleOCR), [PaddleOCR 3.0 report](https://arxiv.org/abs/2507.05595) | Apache-2.0 | Full OCR/document parsing stack, 100+ languages, lightweight PP-OCR models, hardware acceleration. | No ScreenSpot score. Strong optional benchmark or sidecar OCR; higher Swift/CoreML integration cost than Apple Vision. |
| Apple Vision OCR | [Vision text recognition docs](https://developer.apple.com/documentation/vision/recognizing-text-in-images) | Apple platform API | Native on-device OCR, private, low integration cost, good default for macOS Swift. | No ScreenSpot score. Best default for Cascade because it is already native and does not add runtime dependencies. |

## Concrete Techniques to Adopt

### 1. Build a unified `ScreenElementIndex`

Add a candidate inventory layer that merges:

- AX interactables from `AXElementResolver.interactables(limit:)`.
- AX labels/fingerprints from `AXElementResolver.find(label:)` and `frontmostFingerprint()`.
- Vision OCR boxes from `ScreenTextRecognizer.recognizeBoxes(...)` as currently used by `MixtureGrounder.ocrTextRegion(...)`.
- Local icon/control detector boxes, when available.
- Existing snap candidates from `AXClickSnap.nearestInteractiveElement(...)`.

Each candidate should have:

- `id`: stable per screenshot.
- `bounds`: display-local rect plus image-space rect.
- `label`: AX text, OCR text, icon caption, or role label.
- `role`: button, text field, link, menu item, icon, text, unknown.
- `source`: AX, OCR, icon-detector, visual.
- `confidence`: source-specific score.
- `trust`: safe-to-click, label-only, needs-vision, needs-confirmation.

Cascade mapping:

- New file likely under `Sources/ProviderKit/ScreenElementIndex.swift` or `Sources/ComputerUseKit/ScreenElementIndex.swift`.
- Feed it from `MixtureGrounder.ground(...)`, `groundRegion(...)`, and `ComputerUseAgent.groundCached(...)`.
- Use it to replace duplicated AX/OCR candidate logic in `MixtureGrounder.axGround(...)`, `ocrTextRegion(...)`, and `AXClickSnap`.

CoreML feasibility: high. This is mostly Swift data plumbing and Vision/AX integration. It can ship before any model work.

### 2. Add Set-of-Mark overlays before LLM grounding

Instead of asking a model for raw `(x,y)`, render a copy of the screenshot with numbered marks over candidate boxes and ask for an ID:

```text
Choose the single mark number for: "click Export".
Return JSON: {"id": 17, "reason": "..."}.
```

Then Cascade maps `id -> candidate.bounds.center`.

Why it matters:

- SoM reduces coordinate hallucination.
- It makes the model choose among audited candidates.
- It makes visual grounding cheaper because the prompt becomes classification over visible IDs.
- It gives a natural uncertainty signal: no ID, multiple IDs, low confidence, or ID outside semantic match.

Cascade mapping:

- Wrap `VisualGrounder.ground(...)` with a `MarkedCandidateGrounder`.
- Add a mark-rendering helper near `ProviderKit` image utilities used by `UITARSGrounder`.
- Use the wrapper inside `MixtureGrounder` before falling back to `ClaudeVisualGrounder`.
- Extend `ElementLocator.guide(...)` and `ElementLocator.locateRegion(...)` to accept optional candidate marks for "where is X" and point-out flows.

CoreML feasibility: high. The overlay rendering is pure Swift/CoreGraphics. The chooser can be Claude, `UITARSGrounder`, Aria-UI/UGround via a local endpoint, or even a small text ranker for exact labels.

### 3. Make AX/OCR/vision trust explicit

Current `MixtureGrounder` already has the right order: AX first, OCR region, visual fallback. The next step is a confidence policy, not more model calls.

Recommended routing:

- Trust AX immediately when:
  - app is not Cascade,
  - skill is not `axUnreliable`,
  - role is actionable,
  - label match is exact or high-confidence fuzzy,
  - bounds are visible, non-zero, and not huge canvas-like regions,
  - candidate is within the active display/window.
- Trust OCR for literal text when:
  - user target is text-like,
  - OCR box text has high lexical similarity,
  - box is not inside a password/sensitive excluded context,
  - click target can be inferred from nearby AX/icon candidates.
- Use SoM visual selection when:
  - AX and OCR disagree,
  - multiple candidates match,
  - target is icon-only,
  - app is canvas-heavy or AX unreliable.
- Use Claude/free-form vision only when:
  - candidate index is thin,
  - target is relational ("the second chart tab", "the red warning icon"),
  - or previous action had no effect.

Cascade mapping:

- Refactor `MixtureGrounder.axGround(...)` to return a scored candidate, not only a point.
- Refactor `ocrTextRegion(...)` to emit candidates with text similarity and bounds.
- Move snap/verify thresholds from `AXClickSnap` into the shared policy so clicks, pointing, and filling share the same rules.
- Record the selected source and confidence in existing audit events around `ComputerUseAgent.groundedClick(...)` and `executeCU`.

CoreML feasibility: high. This is deterministic Swift plus existing Vision/AX.

### 4. Train or convert a local icon/control detector

The biggest missing local perception piece is icon/control detection. OmniParser shows why: many GUI targets are not text, and AX is frequently missing in canvas or Electron-heavy apps.

Recommended path:

- Do not ship OmniParser `icon_detect` weights without legal review: the README notes AGPL inheritance from YOLO.
- Reimplement the idea with Cascade-owned or permissively trained weights.
- Start with a YOLOv8n/YOLOv10n/RT-DETR-small style detector trained on permissive GUI datasets where license allows commercial use:
  - ScreenSpot-v2 Apache-2.0 boxes.
  - OS-Atlas Apache-2.0 data/model artifacts.
  - Aria-UI Apache-2.0 data.
  - OSWorld-G/Jedi Apache-2.0 data.
- Classes can be coarse: button/icon/control/text-field/checkbox/radio/menu/slider/tab.
- Optionally add a small icon captioner later. Detection alone is enough for SoM candidate IDs.

Cascade mapping:

- New `ScreenIconDetector` service in `MacContextKit` or `ProviderKit`.
- Use `VNCoreMLRequest` on current screenshot before visual fallback.
- Merge detector boxes into `ScreenElementIndex`.
- Let `AXClickSnap` snap to detector candidates when AX has no nearby interactive element, but require visual/SoM confirmation before acting.

CoreML feasibility: medium-high. Small YOLO-style detectors convert to CoreML and run via Vision. Training/conversion is a build pipeline task, but runtime integration is native Swift. Full multimodal grounders like UGround/Aria-UI are better served through the existing OpenAI-compatible `UITARSGrounder` endpoint or an MLX/vLLM sidecar, not embedded into the app immediately.

### 5. Add coarse-to-fine region search

ScreenSpot-Pro results make one thing clear: professional desktop screenshots are too dense for one-shot full-screen grounding. RegionFocus, DRS-GUI, and ScreenSeekeR all improve accuracy by narrowing the search area before final grounding.

Recommended flow:

1. Try AX/OCR exact match.
2. If not enough, ask a cheap region model or heuristic for the broad area: toolbar, sidebar, dialog, table, editor, top-right controls.
3. Crop and scale that region.
4. Rebuild `ScreenElementIndex` for the crop.
5. Run SoM selection or visual point grounding inside the crop.
6. Map back to display coordinates.

Cascade mapping:

- `ElementLocator.locateRegion(...)` already has a haiku region-narrowing pass; reuse this API as the coarse stage.
- `UITARSGrounder.groundRegion(...)` currently wraps a point in a box; extend it to support true crop retry.
- `ComputerUseAgent.groundCached(...)` is the right call site for a second-pass crop after a miss or low confidence.
- Reuse the existing native-resolution zoom capture path referenced in project memory for dense UI.

CoreML feasibility: high for the crop/orchestration. The coarse region chooser can start heuristic/Claude and later move to local model.

### 6. Add uncertainty, abstention, and no-effect feedback

Production grounding should know when not to click. SafeGround-style uncertainty is more useful than squeezing another few benchmark points out of a model.

Recommended signals:

- Multiple sources agree on nearby center: high confidence.
- AX label exact but visual candidate absent: medium confidence, click only if role/bounds safe.
- Visual model point not near any candidate: low confidence, run crop/SoM retry.
- Repeated model calls disagree by more than a threshold: abstain or ask user.
- Action posted but frontmost AX fingerprint and screenshot hash do not change: no-effect, retry via alternate source or pause.

Cascade mapping:

- Extend `ComputerUseAgent.groundCached(...)` result from `CGPoint` to `GroundingResult(point, source, confidence, candidateID, alternatives)`.
- Add audit metadata to `groundedClick(...)`, `expandFillTarget(...)`, and `groundedScroll(...)`.
- Tie no-effect feedback into existing recipe pause/no-effect verification work in `NativeComputerUseActuator` and `AXElementResolver.frontmostFingerprint()`.

CoreML feasibility: high. Mostly deterministic policy.

### 7. Build a grounding benchmark harness

Before changing default behavior, add a local harness that runs Cascade grounders against public benchmarks and a small Cascade macOS screenshot set.

Minimum metrics:

- Center-in-bbox accuracy.
- Text vs icon split.
- App/domain split.
- Full-screen vs crop retry.
- Source selected: AX, OCR, detector, SoM, visual.
- Latency and LLM call count.

Datasets:

- ScreenSpot-v2 for permissive, general regression.
- ScreenSpot-Pro for dense professional desktop stress tests.
- OSWorld-G for fine-grained OS tasks and refusal behavior.
- A private Cascade set from real macOS apps with expected bounding boxes.

Cascade mapping:

- Add test fixtures under a non-source fixture path or a script that downloads datasets into the scratch/cache area.
- Exercise `VisualGrounder`, `MixtureGrounder`, and future `ScreenElementIndex` as separate components.
- Use `UITARSGrounder` coordinate-space modes (`smartResize`, `sent`, `normalized`) to ensure mapping math stays correct.

CoreML feasibility: high. Evaluation harness can run locally and in CI with mocked/local grounders; model-heavy runs can be opt-in.

## Quick Wins vs Larger Bets

### Quick Wins

1. Return structured `GroundingResult` instead of bare `CGPoint`.
   - Files: `VisualGrounder.swift`, `MixtureGrounder.swift`, `ComputerUseAgent.swift`.
   - Impact: confidence, source attribution, better audits, safer escalation.

2. Introduce `ScreenElementIndex` from current AX and Vision OCR only.
   - Files: `AXElementResolver.swift`, `MixtureGrounder.swift`, `AXTextHarvester.swift`.
   - Impact: deduplicates logic and prepares for SoM/local detectors.

3. Add SoM overlay over AX/OCR candidates before Claude fallback.
   - Files: `VisualGrounder.swift`, `ElementLocator.swift`.
   - Impact: lower LLM error rate and lower cost by converting coordinate grounding to ID selection.

4. Add crop retry using `ElementLocator.locateRegion(...)`.
   - Files: `ElementLocator.swift`, `UITARSGrounder.groundRegion(...)`, `ComputerUseAgent.groundCached(...)`.
   - Impact: strong ScreenSpot-Pro-style gain on dense desktop apps.

5. Add benchmark harness for ScreenSpot-v2 text/icon split.
   - Files: tests around `ProviderKit`.
   - Impact: prevents regressions and gives a real target for model/provider decisions.

### Larger Bets

1. CoreML icon/control detector.
   - Build: train permissive detector, convert to CoreML, run with `VNCoreMLRequest`.
   - Impact: removes many icon-only Claude calls; enables SoM on canvas apps.
   - Risk: dataset/legal/training pipeline.

2. Hosted/local UGround/Aria/OS-Atlas endpoint behind `UITARSGrounder`.
   - Build: serve model through OpenAI-compatible endpoint or small adapter.
   - Impact: cheaper than Claude for routine grounding and good benchmark accuracy.
   - Risk: memory/latency, model ops, endpoint reliability.

3. Screen2AX-style synthetic accessibility tree.
   - Build: infer pseudo-AX for canvas/Electron apps from candidate index and detector boxes.
   - Impact: makes AX-like summaries available in AX-unreliable apps.
   - Risk: needs careful confidence and audit rules so pseudo-AX is not treated like native AX.

4. Learned app-specific grounding skills.
   - Build: collect repeated successful candidate selections and emit app skill hints.
   - Impact: cheap repeated grounding for common enterprise workflows.
   - Risk: drift when UI changes; must keep screenshots/audit source.

## License/Attribution

- OmniParser: repository license is CC-BY-4.0, while the README badge says MIT. Treat CC-BY-4.0 as authoritative until legal review. The README also says `icon_detect` weights inherit AGPL from YOLO. Do not ship those weights directly in Cascade without legal approval.
- SoM: use the prompting/overlay idea freely as an implementation pattern, but verify repository license before copying code.
- UGround: MIT according to the GitHub repository page. Suitable for attribution-backed integration or endpoint experimentation.
- OS-Atlas: Apache-2.0. Good candidate for commercial-friendly dataset/model experimentation.
- Aria-UI: Hugging Face model and dataset are Apache-2.0. Verify repo packaging before copying code.
- ScreenSpot-Pro: MIT. Suitable as an evaluation benchmark.
- ScreenSpot-v2: Apache-2.0. Suitable as an evaluation benchmark and possible detector-training input.
- OSWorld-G/Jedi: Apache-2.0. Suitable as a stress benchmark and possible training/evaluation source.
- EasyOCR: Apache-2.0. Good prototype comparator, but PyTorch runtime is not ideal for a Swift-first app.
- PaddleOCR: Apache-2.0. Strong OCR stack, but production use likely means a sidecar or conversion effort.
- Apple Ferret-UI: Apple sample/research terms and non-commercial dataset/model restrictions make it a technique reference, not a direct production dependency.
- ScreenAI: paper-only for this purpose; no production OSS model found.
