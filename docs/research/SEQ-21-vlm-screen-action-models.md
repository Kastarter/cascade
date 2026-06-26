# SEQ-21 - VLM Screen Action Models and Grounding Advances

## Overview

Cascade already has the right high-level architecture for the current GUI-agent literature: the planner can name targets, `VisualGrounder` localizes them, `MixtureGrounder` routes AX-first and visual-second, and `WebDOMGrounder` does the same DOM-first in the sandbox. The next optimization is not to replace Cascade with an end-to-end GUI agent. It is to make the grounding layer cheaper, more local, confidence-aware, and better at high-resolution professional apps where ScreenSpot-Pro shows full-frame screenshot grounding breaks down.

The strongest product shape is a routed grounder stack:

1. Structural sources first: AX, DOM, OCR boxes, recorded click labels, and `RecipeStep.ocrAnchor`.
2. Local or cheap specialist VLM only for AX/OCR-blind targets: UI-TARS-1.5 today; evaluate UI-Venus-1.5, GUI-AIMA, ShowUI, OS-Atlas, Holo, UGround, and Jedi through the same adapter.
3. Claude visual grounding only as fallback for low-confidence, high-risk, unsupported coordinate schemas, or natural-language "where is X" explanations that need a spoken region.

CoreML is not the practical short-term route for these GUI VLMs unless a converted package exists. MLX/local OpenAI-compatible serving is the realistic Apple Silicon path: run a quantized model with `mlx-vlm`, LM Studio, llama.cpp-style multimodal support where available, or vLLM/SGLang on a workstation; keep Swift talking over localhost. For an 8 GB M1-class machine, prioritize 2B-4B grounders and hosted specialists. Do not bundle weights until each model-card license is cleared.

## OSS Repos & Papers

| name | url | stars/venue | license | technique |
| --- | --- | --- | --- | --- |
| UI-TARS Desktop / UI-TARS 1.5 | https://github.com/bytedance/UI-TARS-desktop / https://arxiv.org/abs/2501.12326 | 37.3k stars; arXiv 2025 | Apache-2.0 repo | Native GUI-agent stack using screenshot/VLM control, local/remote computer/browser operators, and UI-TARS model integration. Cascade already has `UITARSGrounder`; keep it as baseline cheap/hosted/local visual grounder. |
| UI-TARS-2 / Seed-line successors | https://arxiv.org/abs/2603.20633 | arXiv 2026 model card for Seed1.8 agency; no public UI-TARS-2 repo verified in this pass | weights/license must be verified separately | Treat as a monitoring lane, not an implementation dependency. Relevant ideas: latency/cost-aware inference, configurable thinking, visual encoding optimization, and GUI interaction as one agentic interface. |
| ShowUI | https://github.com/showlab/ShowUI / https://arxiv.org/abs/2411.17465 | 1.9k stars; CVPR 2025 | Apache-2.0 repo | Lightweight 2B vision-language-action model. Relevant pieces: UI-guided visual token selection, iterative refinement, Qwen2.5-VL support, local/vLLM/Gradio serving, and a strong open codebase for a small Apple-Silicon grounder experiment. |
| ShowUI-pi | https://github.com/showlab/showui-pi / https://arxiv.org/abs/2512.24965 | CVPR 2026 | verify repo/model license before vendoring | Flow-based GUI dragging with discrete plus continuous actions. Cascade should port the action representation (`drag_target`) before adopting a model. |
| CogAgent | https://github.com/zai-org/CogAgent / https://arxiv.org/abs/2312.08914 | 1.2k stars; CVPR 2024 Highlight | Apache-2.0 code; model license separate | High-resolution text-rich GUI VLM and action-operation format. Not Apple-friendly for default local use: docs cite 29 GB BF16 VRAM, 15 GB INT8, and NVIDIA-only quantization comments. Useful for UI-VQA verifier/prompt format, not a local M1 grounder. |
| OS-Atlas | https://huggingface.co/OS-Copilot/OS-Atlas-Base-7B / https://arxiv.org/abs/2410.23218 | arXiv 2024; HF model likes 43 for Base-7B | Apache-2.0 model card | Cross-platform GUI grounding/action model. Outputs normalized 0-1000 coordinates or boxes and has 4B/7B Base/Pro variants. Good candidate for a `CoordSpace.normalized` adapter and a benchmark fixture. |
| Aguvis | https://github.com/xlang-ai/aguvis / https://arxiv.org/abs/2412.04454 | 391 stars; ICML 2025 | no GitHub license metadata observed | Pure-vision autonomous GUI agent with two-stage training: grounding first, then planning/reasoning trajectories. Supports Cascade's decision to keep grounding specialization separate from planner logic. |
| UI-Venus-1.5 | https://github.com/inclusionAI/UI-Venus / https://arxiv.org/abs/2602.09082 | 1k stars; arXiv 2026 | repo says research/educational only; verify `LEGAL.md` and model cards | 2B/8B/30B-A3B GUI model family. Reports ScreenSpot-Pro 69.6%, VenusBench-GD 75.0%, AndroidWorld 77.6. Highest-priority hosted specialist to evaluate, but not safe to vendor until license is cleared. |
| GUI-AIMA | https://github.com/sjz5202/GUI-AIMA / https://arxiv.org/abs/2511.00810 | arXiv 2025; GitHub repo | verify code/model license before vendoring | 3B attention-anchor grounder. Reports 53.8% ScreenSpot-Pro one-step, 61.5% with two-step zoom-in. The two-step crop/refine method is immediately portable to Cascade. |
| Holo / Holo1.5 | https://arxiv.org/abs/2506.02865 / https://hcompany.ai/holo1-5-open-foundation-models-for-computer-use-agents | arXiv 2025; open-weight family described by H Company | verify HF model license before redistribution | UI localization / UI-VQA family paired with Surfer-H. Use as hosted specialist or verifier candidate once coordinate schema and license are checked. |
| Jedi / OSWorld-G | https://github.com/xlang-ai/OSWorld-G / https://arxiv.org/abs/2505.13227 | 170 stars; NeurIPS 2025 Spotlight | Apache-2.0 repo | UI decomposition and synthesis pipeline with 4M Jedi examples; evaluation code covers Jedi, Aguvis, UGround, UI-TARS, OSWorld-G, ScreenSpot-v2, and ScreenSpot-Pro. Best blueprint for Cascade-private grounding eval/distillation data. |
| ScreenSpot-Pro / ScreenSeekeR | https://github.com/likaixin2000/ScreenSpot-Pro-GUI-Grounding / https://gui-agent.github.io/grounding-leaderboard / https://arxiv.org/abs/2504.07981 | 378 stars; benchmark last updated 2026-06-22 | MIT repo | High-resolution professional GUI benchmark across 23 apps and 3 OSes. Paper reports best existing model only 18.9%; planner-guided cascaded search reached 48.1 without training. Directly motivates crop-first grounding. |
| SafeGround | https://arxiv.org/abs/2602.02419 | arXiv 2026 | paper | Stochastic grounding calibration via spatial dispersion and false-discovery-rate control. Reports up to 5.38 percentage point system-level accuracy gain on ScreenSpot-Pro. Use as confidence gating around any `VisualGrounder`. |
| DRS-GUI | https://arxiv.org/abs/2605.15542 | arXiv 2026 | paper | Training-free dynamic region search with Focus, Shift, Scatter and MCTS region selection. Reports a 14% ScreenSpot-Pro improvement for Qwen2.5-VL-7B and UGround-V1-7B. Portable as a crop/refine wrapper around current grounders. |
| GUI-Cursor | https://arxiv.org/abs/2509.21552 | arXiv 2025 | paper | Turns grounding into cursor-guided visual search. Reports ScreenSpot-v2 88.8% to 93.9% and ScreenSpot-Pro 26.8% to 56.5%; 95% solved within two steps. Useful for Cascade's visible companion cursor and retry path. |
| GUI-AIMA / AQuaUI-style token reduction | https://arxiv.org/abs/2511.00810 / https://arxiv.org/abs/2605.19260 | arXiv 2025/2026 | papers | Attention-anchor grounding and adaptive visual-token/quadtree budgeting. Relevant for local models because it cuts image cost while preserving high-res target regions. |

## Concrete Techniques to Adopt

- Replace `VisualGrounder`'s `CGPoint?` with a structured `GroundingResult` in `Sources/ProviderKit/VisualGrounder.swift`: `point`, optional `region`, `confidence`, `source` (`ax`, `dom`, `ocr`, `uitars`, `uiVenus`, `holo`, `showUI`, `osAtlas`, `claude`), `coordSpace`, `rawModel`, `latencyMs`, and `dispersion`. Update `ComputerUseAgent.groundedClick`, `expandFillTarget`, `groundedScroll`, `MixtureGrounder.ground`, and `WebDOMGrounder.ground` to audit source/confidence/fallback reason before acting.
- Add SafeGround-style stochastic confidence to visual grounders. In `UITARSGrounder.ground`, allow `samples=3` for high-risk actions, canvas apps, or prior misses; cluster returned points and accept only if dispersion is below a calibrated pixel threshold. Low-confidence results should fall back to Claude or ask the planner to re-describe the target instead of clicking.
- Add ScreenSeekeR/DRS-GUI crop refinement around `MixtureGrounder`. Use `AXElementResolver.interactables`, `ScreenTextRecognizer.recognizeBoxes`, `ScreenTextRecognizer.bestMatch`, recorded click labels, and `RecipeStep.ocrAnchor` to produce candidate rectangles. If full-frame grounding misses or has low confidence, crop the top region, ground inside it, then map crop-local coordinates back to display-local AppKit points.
- Generalize `UITARSGrounder` into a `GrounderRegistry` with prompt templates and coordinate parsers for UI-TARS, UI-Venus, GUI-AIMA, Holo, ShowUI, UGround, OS-Atlas, and Jedi. Keep `cascade.visualGrounder.model`, `endpoint`, and `coordSpace`, but add `probeCoordSpace()` with a synthetic screenshot/known target so a swapped Qwen3/normalized model cannot silently use the wrong coordinate frame.
- Add an Apple-Silicon runtime matrix in Settings, backed by `CascadeAppModel.assistGrounder()`: selected model, local/hosted/Claude endpoint class, model size, quantization, latency, coordinate-probe status, license note, and last mini-eval score. Default recommendations: UI-TARS hosted/local for now; ShowUI-2B or OS-Atlas-4B for local experiments; UI-Venus/Holo as hosted only until license and MLX availability are verified; CogAgent as verifier-only.
- Add `drag_target` to `ComputerUseAgent` structural tools and `ScoutAgent.ScoutAction.Kind`. Inputs should be `source`, `destination` or `direction/amount`, optional `pathStyle`, and optional `holdMs`. Ground both endpoints through `groundCached` and execute existing `CUAction.drag`. This ports the ShowUI-pi lesson without waiting for a flow model.
- Add GUI-Cursor-style retry for visible cursor misses in `GuidanceOverlay` / `NativeComputerUseActuator`: after a visual miss or low-confidence point, render the companion cursor at the predicted location, crop around it plus target landmarks, and let the grounder emit a correction vector rather than a fresh global coordinate.
- Add AQuaUI-style region budgeting before local VLM calls. In the `UITARSGrounder` preprocessing path and capture helpers, preserve high resolution around cursor, OCR boxes, AX interactables, changed `PerceptualHash.gridHashes`, and focused windows; downsample empty quadrants. Keep hosted calls simple with crop retry first.
- Build `GroundingEvalTests` under `Tests/ProviderKitTests` using synthetic fixtures plus optional external ScreenSpot-Pro samples. Track hit rate by source (`AX`, `OCR`, visual), median latency, dispersion, miss type, and coordinate-space correctness for `UITARSGrounder.resolveImageSpace`, OS-Atlas normalized output, and `MixtureGrounder.displayLocalPoint`.
- Add a recorder-derived grounding corpus exporter in a test/support target. Use `InputRecorder.clickLabel(atCG:)`, `RecordedContext` screenshot paths, OCR boxes, `RecipeStep.ocrAnchor`, app/window, role, and point/box to export ScreenSpot/Jedi-like JSONL. Keep it local-only and privacy-gated; this is future distillation/eval data, not a cloud upload path.
- Route by risk in `ComputerUseAgent.groundedClick`: exact AX/DOM can act; local VLM high-confidence can act; low-confidence visual on destructive/external actions should highlight/ask or escalate to Claude. This is the visual-misclick analogue of the irreversible-key gate.
- Use CogAgent/Holo-style UI VQA as a verifier, not a locator. Add optional `verify_state` after risky visual clicks that asks "did the expected menu/dialog/field appear?" and maps negative answers to `AgentFailureKind.groundingMiss` for the existing no-effect/stall recovery.

## Quick Wins vs Larger Bets

Quick wins:

- Return structured `GroundingResult` and audit grounding source/confidence.
- Add 3-sample dispersion gating for visual grounders on canvas apps and high-risk actions.
- Add crop retry based on AX/OCR/recorded anchors before falling back to Claude.
- Add endpoint health plus coordinate-probe status for local/hosted UI-TARS in Settings.
- Add `drag_target` so sliders, timeline handles, split panes, and selections stop depending on raw-coordinate drag guesses.
- Add a small XCTest grounding benchmark from synthetic screenshots and recorded fixtures.

Larger bets:

- Evaluate UI-Venus-1.5 2B/8B, GUI-AIMA-3B, Holo 3B/7B, ShowUI-2B, UGround, OS-Atlas 4B/7B, and Jedi behind the same `GrounderRegistry`.
- Distill a Cascade-private local grounder from recorder traces using Jedi-style decomposition once trace export is privacy-safe.
- Port adaptive quadtree/token budgeting deeply into local screenshot preprocessing.
- Train or integrate a drag expert inspired by ShowUI-pi if `drag_target` plus endpoint grounding is not enough for design/video/spreadsheet handles.
- Treat UI-TARS-2/Seed-style multi-turn RL as an offline eval/data-generation strategy, not a production executor, until Cascade has stable local sandbox rollouts.

## License/Attribution notes

- Star counts and repo metadata were checked from GitHub/Hugging Face pages on 2026-06-26 and are volatile.
- Code license and model-weight license are separate. Do not infer weight redistribution rights from a GitHub repo license.
- Apache-2.0 code/models verified in this pass: `bytedance/UI-TARS-desktop`, `showlab/ShowUI`, `zai-org/CogAgent` code, `OS-Copilot/OS-Atlas-*` model cards, and `xlang-ai/OSWorld-G`. Preserve notices in `docs/THIRD_PARTY_NOTICES.md` if code is ported.
- MIT verified in this pass: `likaixin2000/ScreenSpot-Pro-GUI-Grounding`.
- `inclusionAI/UI-Venus` reports strong numbers but the repo license section says research and educational purposes only. Treat as evaluation/hosted-by-user only until `LEGAL.md` and each model card are reviewed.
- `xlang-ai/aguvis`, ShowUI-pi, Holo/Holo1.5, UGround, and GUI-AIMA require model-card and repo-license verification before vendoring code, downloading weights automatically, or redistributing checkpoints.
- For paper-only techniques such as SafeGround, DRS-GUI, GUI-Cursor, AQuaUI, and ScreenSeekeR, reimplement the ideas independently unless released code/data licenses are explicitly checked.
- Cascade should remain BYO-endpoint/BYO-model by default and record selected model id, endpoint class, coordinate convention, and license note in audit metadata when a non-Claude grounder is used.
