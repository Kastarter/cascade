# SEQ-02 — Computer-Use / GUI Agent Architectures, Action Loops, Reliability, Cost

Date: 2026-06-26

## Overview

Cascade is already on the right side of the current GUI-agent research curve: a real screen loop, structural target tools, AX-first grounding with visual fallback, direct-Mac harness tools, prompt caching, streamed/batched actions, no-effect detection, replay recipes, and an audit log. The highest-return research findings are therefore not "replace the agent" findings. They are hardening moves around the existing loop:

1. Make verification semantic, not just visual-diff based.
2. Use Cascade's local recorder as a demo-conditioned runtime memory, not only as recall/search.
3. Keep planner and grounder split, but make confidence/routing explicit per target.
4. Reduce screenshot and model-call volume with exact local state channels: AX, DOM, harness, and recorded trajectories.
5. Build an OSWorld-style local evaluation harness around saved tasks, trajectories, videos, and per-step failure tags.

The core production lesson from the best systems is that GUI agents win through loop engineering: observe, plan, act, verify, recover, and log. Prompt-only advice is weak; runtime structure wins.

## OSS Repos & Papers

| name | url | license | technique | benchmark |
| --- | --- | --- | --- | --- |
| Anthropic computer-use docs | https://platform.claude.com/docs/en/agents-and-tools/tool-use/computer-use-tool | Proprietary docs/API | Official loop: Claude emits `computer_20251124` tool calls, app executes actions, sends screenshots/tool results back until done. Strong guidance: text before image, `enable_zoom` for small text, screenshot sizing, action verification, action delays, logging, sandboxing, human confirmation for high-consequence actions, and tool augmentation with bash/text/custom tools. | Beta `computer-use-2025-11-24` supports Opus 4.8/4.7/4.6, Sonnet 4.6, Opus 4.5. Tool overhead: 466-499 system tokens plus 735 input tokens for Claude 4.x tool definition, before screenshots/tool results. Opus 4.8/4.7 image limit: 2576 long edge; earlier models: 1568 long edge and about 1.15MP. |
| Anthropic reference implementation | https://github.com/anthropics/claude-quickstarts/tree/main/computer-use-demo | MIT at repo root | Minimal Docker/X11/VNC desktop, Streamlit UI, agent loop, Anthropic computer-use tool handlers, coordinate scaling, and explicit security warnings. Useful as a sanity-check implementation, not a production architecture. | README recommends XGA 1024x768 and warns against relying on API resizing because it reduces accuracy and slows performance. |
| Anthropic "Building Effective Agents" | https://www.anthropic.com/engineering/building-effective-agents | Proprietary article | Simple composable patterns: augmented LLM, prompt chaining with gates, routing, parallelization, orchestrator-workers, evaluator-optimizer, autonomous agents. Key GUI-agent mapping: use dynamic agents only where fixed workflows fail; design clear Agent-Computer Interfaces; require ground truth from environment each step; set stopping conditions. | No GUI benchmark. Important production guidance: agents trade latency/cost for task performance; use evals and add complexity only when it improves outcomes. |
| UI-TARS | https://github.com/bytedance/UI-TARS and https://arxiv.org/abs/2501.12326 | Apache-2.0 | Native GUI VLM family with desktop/mobile/browser action schemas, explicit thought-before-action option, grounding-only prompt mode, and coordinate post-processing for Qwen2.5-VL absolute-coordinate behavior. Strong lesson: separate planner/action schema from coordinate normalization and verify coordinate spaces. | UI-TARS-1.5 README: OSWorld 100-step 42.5 vs OpenAI CUA 36.4, Claude 3.7 28, prior SOTA 38.1 at 200 steps. ScreenSpot-v2 94.2; ScreenSpotPro 61.6 vs Claude 27.7. UI-TARS-1.5-7B: OSWorld 27.5 and ScreenSpotPro 49.6. |
| UI-TARS Desktop / Agent TARS | https://github.com/bytedance/UI-TARS-desktop | Apache-2.0 | Product architecture around the model: local and remote computer/browser operators, hybrid browser agent using GUI or DOM, protocol-driven event stream, MCP integration, real-time status, cross-platform UI. Useful for Cascade's activity/audit UX and split local/remote operator design. | No independent benchmark in repo; it inherits UI-TARS model results. Repo claims Windows/macOS/browser support and local processing for UI-TARS Desktop. |
| Agent-S / Agent-S2 / Agent-S3 | https://github.com/simular-ai/Agent-S, https://arxiv.org/abs/2410.08164, https://arxiv.org/abs/2504.00906 | Apache-2.0 | Agent-Computer Interface, experience-augmented hierarchical planning, internal/external knowledge retrieval, reflection agent, max trajectory window, local code environment for non-GUI work, Proactive Hierarchical Planning, and Mixture-of-Grounding. Strong lesson: generalist planner plus specialist grounder/verifier beats a monolithic GUI model. | Agent-S: +9.37pp over baseline on OSWorld, 83.6% relative improvement. Agent-S2: +18.9% relative on OSWorld 15-step, +32.7% on OSWorld 50-step, +52.8% on WindowsAgentArena, +16.52% on AndroidWorld. Agent-S3 README: OSWorld 66% at 100 steps, 72.6% with Behavior Best-of-N, WindowsAgentArena 50.2→56.6 with 3 rollouts, AndroidWorld 68.1→71.6. |
| OpenAdapt | https://github.com/OpenAdaptAI/OpenAdapt | MIT | Demonstrate -> Learn -> Execute pipeline. Captures user demonstrations and screenshots, scrubs PII/PHI, retrieves demos, trains/evaluates models, separates policy from grounding, gates actions for safety, and feeds successful traces back into eval/training. Most directly relevant to Cascade's local recorder advantage. | Controlled macOS System Settings benchmark: demo-conditioned prompting improved first-action accuracy from 46.7% zero-shot to 100% on 45 tasks sharing one entry point; length-matched control only +11.1pp. |
| self-operating-computer | https://github.com/OthersideAI/self-operating-computer | MIT | Early minimal human-like loop: screenshot in, mouse/keyboard out through PyAutoGUI. Supports OCR mode that maps text labels to coordinates and SoM mode with YOLO button detection. Strong lesson: even simple OCR/click maps beat pure screenshots for grounding. | No rigorous current benchmark. README says GPT-4-with-OCR became default because OCR performed better than SoM and vanilla GPT-4 in their tests. |
| CUA / trycua | https://github.com/trycua/cua | MIT, with third-party caveats | Computer-use infrastructure, not just an agent: background desktop driver that clicks/types/verifies without stealing cursor/focus; unified sandboxes across Linux/macOS/Windows/Android; Cua-Bench for OSWorld, ScreenSpot, Windows Arena, custom tasks; Lume macOS virtualization on Apple Silicon; trajectory export for training/eval. | No single algorithm score. Cua-Bench provides evaluation/training substrate and trajectory export. README says CUA has 19k stars and supports OSWorld, ScreenSpot, Windows Arena, and custom tasks. |
| Browser-Use | https://github.com/browser-use/browser-use | MIT | Browser-specific agent stack with Rust core, persistent browser harness, real browser/computer action space, custom tools, allowed-domain profiles, real browser profiles for auth, recovery loops inspired by coding agents, and CLI state/click/type commands. Strong lesson: web should be DOM/browser-native first, GUI fallback second. | BU Bench covers 100 real-world browser tasks. README claims optimized ChatBrowserUse completes tasks 3-5x faster than other models with SOTA accuracy; exact score chart is image-only in README. |
| OSWorld | https://github.com/xlang-ai/OSWorld and https://arxiv.org/abs/2404.07972 | Apache-2.0 | Benchmark/environment pattern: real VM setup, open-ended tasks across desktop/web/file workflows, custom initial state, execution-based evaluation scripts, saved screenshots/actions/videos, manual examination tool, parallel execution. This is the evaluation model Cascade should copy locally. | 369 tasks. Original paper: humans 72.36%, best model 12.24%, with failures mainly from GUI grounding and operational knowledge. OSWorld-Verified later improves benchmark signals and supports parallel AWS evaluation. |
| Set-of-Mark prompting | https://arxiv.org/abs/2310.11441 and https://github.com/microsoft/SoM | See repo before porting code; paper/dataset terms vary | Mark candidate regions/elements so the model selects labels instead of raw coordinates. Useful only when local AX/DOM/OCR candidate extraction can create stable marks cheaply. | Strong zero-shot visual grounding gains in the paper; Anthropic's current docs emphasize correct image sizing/zoom and do not recommend SoM as a universal default. |
| SeeClick / ScreenSpot | https://arxiv.org/abs/2401.10935 | Paper; verify code/data terms before porting | GUI grounding pretraining and ScreenSpot benchmark. Reinforces that downstream task success is bottlenecked by element grounding, not only planning. | ScreenSpot remains a standard grounding benchmark; pair with ScreenSpot-v2/Pro for current relevance. |
| ScreenSpot-Pro / ScreenSeekeR | https://arxiv.org/abs/2504.07981 | Paper/data; verify code/data terms | High-resolution professional UI grounding benchmark; ScreenSeekeR narrows search area before grounding. Direct Cascade lesson: crop/region planning before visual grounding is cheaper and more accurate than whole-screen grounding. | Existing models struggle on professional software; reported best baseline 18.9%, ScreenSeekeR 48.1% without additional training. |
| Agent-R | https://arxiv.org/abs/2501.11425 | Paper; verify implementation terms | Error-step reflection: identify the first wrong step in failed trajectories and learn recovery behavior. Useful as an offline failure-mining loop over Cascade audit/video traces. | Reports +5.59% over baselines across three interactive environments. |
| AgentRR | https://arxiv.org/abs/2505.17716 | Paper; verify implementation terms | Record-and-replay for agents: convert interaction traces into structured experience and replay with check functions. Maps almost directly onto Cascade's `AgentRecipe`, `input_event`, `recorded_context`, and audit store. | Framed around reliability, privacy, cost, and performance; benchmark details should be verified before citing numerically. |
| VeriGUI | https://arxiv.org/abs/2508.04026 | Paper/dataset; verify data/code terms | Long-horizon GUI tasks decomposed into independently verifiable subtasks, including alternate valid starting points. Strong lesson: per-subtask verification beats final-state-only scoring. | Useful for eval design; long-chain failures hidden by outcome-only metrics become visible. |

## Concrete Techniques to Adopt

- **Semantic post-action verifiers, not just grid no-effect.** Map to `Sources/AppShell/CascadeAppModel.swift` in `runAssistEpisode` / `runScoutEpisode` and `Sources/SandboxKit/BackgroundWebAgent.swift` around `pageSignature` / `classifyDone`. Keep existing grid-hash no-effect as the cheap first pass, then add optional app-specific `expectedState` probes: AX value changed, focused text equals intended text, file exists, document title changed, checkbox state toggled, web DOM node text changed. Persist verifier result and failure type in `audit_event` as `assist.verify.*`.

- **Demo-conditioned runtime replay from the local recorder.** Map to `Sources/CascadeMemory` recorded moments, `Sources/AgentOrchestrator` recipe replay, `Sources/ProviderKit/AssistMemory.swift`, and `Sources/SuggestionEngine/WasteDetector` output. Add a retrieval step before `ComputerUseAgent.begin/proceed`: find the closest successful local trajectory by app, window title, goal tokens, and first 2-3 action labels; inject only a compact "successful trajectory sketch" plus check functions. This is the OpenAdapt result Cascade is uniquely positioned to exploit.

- **Explicit target-level grounding confidence.** Map to `Sources/AppShell/MixtureGrounder.swift`, `Sources/ProviderKit/VisualGrounder.swift`, `Sources/ComputerUseKit/AXElementResolver.swift`, and `Sources/ProviderKit/ComputerUseAgent.swift` structural actions (`click_target`, `fill_target`, `scroll`). Return `GroundingCandidate { point, source: ax|dom|ocr|visual|recorded, confidence, reason, rect }`; let the runtime choose the cheapest confident source and escalate to crop/visual grounding only when confidence is below threshold.

- **Region-first visual grounding for professional apps.** Map to `ElementLocator`, `UITARSGrounder`, and `captureCursorScreenZoomJPEG`. Before whole-screen UI-TARS/Claude visual grounding, derive a crop from app/window region, recent cursor area, AX containers, or target words. Send crop plus coordinate offset metadata; audit `ground.crop` and map back to display-local coordinates. This copies ScreenSeekeR's search-area narrowing without training a new model.

- **OSWorld-style local eval harness.** Map to a new XCTest/eval runner around `CascadeAppModel`, `NativeComputerUseActuator`, `BackgroundWebAgent`, and demo fixtures under `scripts/demo-setup.sh`. For each scenario, store initial state, goal, allowed app(s), max steps, expected final probe, screenshots/actions/video/audit JSONL, and failure taxonomy. Add `show_result`-style summaries by domain: Keynote, Notes, Finder, browser, spreadsheets, files/harness.

- **Trajectory-window and screenshot budget policy.** Map to `Sources/ProviderKit/ComputerUseAgent.swift` functions `pruned`, `withMovingCacheBreakpoints`, `imageBlock`, and usage logging. Adopt Agent-S3's fixed max trajectory window concept for images (for example 8 image turns) while preserving text summaries/tool results. Add counters for image count, cache read/write tokens, tool-definition tokens, and verifier-call tokens per episode.

- **Action-space split by surface.** Map to `BackgroundWebAgent`, `WebDOMGrounder`, `AgentHarness`, and `ComputerUseAgent.extraTools`. Browser-Use and Agent TARS both validate that browsers need DOM-first tools. Make DOM/state tools the default for background web agents, GUI only for login/canvas/unsupported sites. On-screen browser control should still prefer AX/DOM state when available before coordinate clicks.

- **Behavior Best-of-N only for high-value or stuck tasks.** Map to `runAssistEpisode` stuck/no-effect paths and `AgentTaskPlanner`. Do not run N rollouts routinely. When `noEffectTurns == 2` or a high-value unattended background run fails, replay from the last stable checkpoint with 2-3 strategy variants in sandbox/background where possible, then choose the first verifier-passing trajectory. Keep foreground real-screen runs single-lane unless the user approves.

- **Reflection memory over failed traces.** Map to `audit_event`, `AssistMemory`, `AgentRecipe`, and a new offline `FailureMemory` table. After a stopped/stalled/failed episode, store the first likely bad step, screen signature, app, target label, action, failure type, and successful recovery if later observed. Inject only matching concise reflections, not general warnings.

- **Event stream as product surface.** Map to `NotchController`, Cascades Activity drawer, and `audit_event`. Agent TARS's event stream pattern should become a first-class Cascade activity timeline: thinking started, tool call, grounding source, action point, verifier result, no-effect/stall, STOP, recovery. This makes automation trustable and debuggable without exposing raw JSON by default.

- **Local computer-use infrastructure parity.** Map to `NativeComputerUseActuator`, `SandboxKit`, and possible future virtualized test runners. CUA's driver/sandbox split suggests factoring native action execution behind a clean protocol that can target the real screen, a WKWebView sandbox, or a VM/recorded fixture with the same action/result schema.

- **OCR/clickable-map fallback.** Map to `AXTextHarvester`, `Vision OCR`, and `MixtureGrounder`. self-operating-computer's OCR mode is crude but practical: build a cheap local map of OCR text boxes and clickable AX rects, then let structural actions select labels. Use this before asking a visual model for raw coordinates.

- **High-risk action gates stay structural.** Map to `ComputerUseAgent.isIrreversibleCombo`, paste gate, `AgentHarness` destructive deny-list, watched-app script gate, and `AgentRunState` STOP. Anthropic docs and all mature agent stacks point to confirmation gates and sandboxing; keep gates outside the model and audit every refusal.

## Quick Wins vs Larger Bets

**Quick wins**

- Add `GroundingCandidate.source/confidence/reason` and audit it for every structural target.
- Extend `assist.noeffect` into `assist.verify` with AX value/readback checks for typing and toggles.
- Add `assist.capture` logging: native size, sent size, scale, image count, screenshot token estimate, cache read/write tokens.
- Push compact successful trajectory sketches from local recorder for repeated app+goal patterns.
- Add Browser-Use-style allowed-domain and persistent-profile labels to background web runs, then show them in Cascades.
- Add per-task JSONL eval output for the existing demo fixtures, even before a full VM runner exists.

**Larger bets**

- Build a demo-conditioned replay engine: retrieve local successful traces, abstract them into steps/check functions, and apply them as a runtime prior.
- Create an OSWorld-like eval suite for macOS app workflows with automated final-state probes and saved videos.
- Split native action execution into a CUA-like protocol so the same agent can target real screen, sandbox, VM, and replay fixture.
- Add verifier-guided recovery/Best-of-N for background tasks, using stable checkpoints rather than repeatedly acting on the live foreground screen.
- Train or integrate a local lightweight grounding verifier using Cascade's recorded AX/OCR/click traces; do not block product reliability on it.

## License/Attribution notes

- Anthropic docs/API/blog/reference implementation: docs are proprietary; `claude-quickstarts` code is MIT. Use docs as guidance; copy code only with MIT attribution if needed.
- UI-TARS and UI-TARS Desktop / Agent TARS are Apache-2.0. Port ideas freely with notice; copying code requires preserving license headers/notices.
- Agent-S is Apache-2.0. Its high-level planner/grounder/reflection architecture is safe to emulate; preserve attribution if code is copied.
- OpenAdapt is MIT. Its demo-conditioned pipeline is directly relevant, but verify sub-package licenses before copying from newer split repos.
- self-operating-computer is MIT. Good source for minimal OCR/SoM loop ideas; code can be ported with MIT notice.
- trycua/cua is MIT, but README flags third-party caveats: Kasm MIT, OmniParser CC-BY-4.0, optional `cua-agent[omni]` includes ultralytics AGPL-3.0. Avoid optional AGPL components in Cascade unless legal approves.
- Browser-Use is MIT. Browser-harness ideas can be copied with attribution; cloud/hosted claims are service-specific and should not be represented as OSS guarantees.
- OSWorld is Apache-2.0. Its evaluation harness structure is safe to adapt; VM images/tasks may have separate operational constraints.
- Papers such as SoM, SeeClick, ScreenSpot-Pro, Agent-R, AgentRR, and VeriGUI should be treated as research references until each code/data license is checked.

## Sources

- Anthropic computer-use docs: https://platform.claude.com/docs/en/agents-and-tools/tool-use/computer-use-tool
- Anthropic reference implementation: https://github.com/anthropics/claude-quickstarts/tree/main/computer-use-demo
- Anthropic "Building Effective Agents": https://www.anthropic.com/engineering/building-effective-agents
- UI-TARS: https://github.com/bytedance/UI-TARS and https://arxiv.org/abs/2501.12326
- UI-TARS Desktop / Agent TARS: https://github.com/bytedance/UI-TARS-desktop
- Agent-S: https://github.com/simular-ai/Agent-S, https://arxiv.org/abs/2410.08164, https://arxiv.org/abs/2504.00906
- OpenAdapt: https://github.com/OpenAdaptAI/OpenAdapt
- self-operating-computer: https://github.com/OthersideAI/self-operating-computer
- CUA: https://github.com/trycua/cua
- Browser-Use: https://github.com/browser-use/browser-use
- OSWorld: https://github.com/xlang-ai/OSWorld and https://arxiv.org/abs/2404.07972
- Set-of-Mark prompting: https://arxiv.org/abs/2310.11441
- SeeClick: https://arxiv.org/abs/2401.10935
- ScreenSpot-Pro: https://arxiv.org/abs/2504.07981
- Agent-R: https://arxiv.org/abs/2501.11425
- AgentRR: https://arxiv.org/abs/2505.17716
- VeriGUI: https://arxiv.org/abs/2508.04026
