# Open-Source Computer-Use Agents — trycua/cua Analysis

Researched 2026-07-06. Sources: github.com/trycua/cua, cua.ai, andrew.ooo review (links at bottom).

## What trycua/cua is

**Open-source infrastructure for computer-use agents** — sandboxes, SDKs, and benchmarks. MIT license, ~19.4k stars, very active (546 releases). **It is a YC X25 company** monetizing via cloud (cua.ai).

Components:

- **Lume** — macOS/Linux VM layer on Apple's Virtualization.Framework (Apple Silicon only, near-native perf, ~50 GB images).
- **Cua Sandbox SDK** — one API over VMs/containers: local (QEMU/Lume) or cloud; macOS, Linux, Windows, Android.
- **Cua Driver** — background macOS/Windows desktop control **without stealing cursor/focus/Space**; CLI + MCP server.
- **Cua Agent SDK** — provider-agnostic agent loop (screenshot → plan → act); optional OmniParser for UI element detection.
- **cua-bench** — OSWorld / ScreenSpot / Windows Arena evaluation, parallel execution, trajectory export for RL.
- **CuaBot** — multi-agent sandbox orchestration.

Business model: free OSS + paid cloud — **Cua Run** (warm machine fleets for evals/RL/batch rollouts), **Verified Data** (human-reviewed golden trajectories). Customers include Google DeepMind and Qwen Code. Target buyer = **AI/ML teams training and evaluating agents** — model labs, not end users.

## Honest weaknesses (from independent review)

- Grounding is **vision/pixel-first**; review concedes "pixel-driving agents are inherently brittle" and SOTA OSWorld accuracy is still **30–50%** — "not production-ready for complex tasks."
- 50 GB VM images; Apple Silicon required for macOS VMs; rapid API churn (pin versions).
- Trajectory recording helps debugging but "doesn't solve brittleness."

## What this means for Cascade

### 1. Not a competitor for our buyer — a different layer
cua sells *infrastructure to developers/labs*; Cascade sells a *closed-loop product to services firms* (record → discover repeated work → execute supervised, audited). cua has **no context recorder, no workflow discovery, no privacy/audit layer, no AX-first grounding**. If anything, cua is a vendor we could build on.

### 2. Lume ≈ our unbuilt `local_vm` backend
`product-strategy.md` defines `local_vm` as fail-closed and unbuilt. **Lume (MIT) is that backend** — adopting/porting it (with attribution, per PORT_MAP conventions) could deliver the isolated VM sandbox without building virtualization ourselves. Caveats: Apple Silicon only, big images, their API churn — pin a version.

### 3. Cua Driver validates background-control demand
Background macOS control without stealing the cursor is a real gap they're filling; compare against our `SandboxKit` WKWebView approach and `GuidanceOverlay` UX before investing further in either direction.

### 4. cua-bench = credible external numbers for YC
We could run our grounding stack against ScreenSpot / OSWorld-subset via cua-bench and quote a *measured* delta ("AX-first grounding resolves X% where vision-only SOTA gets 30–50%"). We already have `GroundingBench` in-repo; cua-bench gives the standardized external yardstick.

### 5. Their weakness is our thesis
The cua ecosystem's own framing — vision-first, 30–50% OSWorld, brittleness unsolved — is independent confirmation that **grounding is the wall**. Same signal as Agent S3 (70% OSWorld) failing "open Notes and type hello" on real screens (2026-07-02). AX-first grounding + recorder-derived anchors attack exactly what the open-source stack can't fix at the infra layer.

### 6. YC interview prep
They are YC X25; expect **"how are you different from cua?"** Answer: different customer (services firms vs. AI labs), different layer (product vs. infrastructure), different moat (local context + discovery + AX grounding vs. sandboxes at scale). Possible complement: their VM layer under our agent.

## On-screen agent, models, and pricing (follow-up 2026-07-06)

**On-screen/host control:** cua is sandbox-first (VMs are the flagship), but host control exists: **Cua Driver** drives the real macOS/Windows desktop *in the background* (no cursor/focus steal; CLI + MCP server), and the computer-server can run on the host for direct control. There is **no supervised-execution UX** — no STOP overlay, no companion cursor, no audit trail, no permission preflight. Host mode is developer plumbing, not an end-user product.

**Model handling:** provider-agnostic via **liteLLM strings** — the developer picks the model per agent:
- `anthropic/<model>` — the same computer-use beta loop we run (with prompt caching; Bedrock/Vertex too)
- `openai/computer-use-preview` — OpenAI Operator CUA
- `huggingface-local/…UI-TARS-1.5-7B` / `ollama_chat/…` — local open models
- `omniparser+<any LLM>` — OmniParser Set-of-Marks + any VLM (vision-only grounding aid)
- **Composed agents**: `<grounder>+<planner>` split (e.g. GTA1-7B + GPT-4o) — same architecture direction as our two-tier planner + MixtureGrounder, but **vision-only, no AX**

**Pricing:** the framework is free (MIT); **users bring their own API keys and pay model providers directly** — identical Anthropic token rates to ours, so our per-turn math (~1.5–2¢ Sonnet) applies to their anthropic loop too. cua monetizes **sandbox compute** (usage-based cloud fleets), not tokens. Local models swap token cost for GPU/inference cost. They have no replay/trajectory-cache economics — every run pays the full vision loop.

## Broader OSS CUA landscape (context)

| Project | What | Relation to us |
|---|---|---|
| trycua/cua | Sandboxes/SDK/bench infra (this doc) | Possible `local_vm` layer; bench yardstick |
| UI-TARS + UI-TARS-desktop (ByteDance) | Open VLM grounder + desktop app | Already our default hosted grounder (SEQ-21) |
| Agent S3 (Simular) | 70% OSWorld SOTA agent loop | Failed real-screen trivial task — proves loop ≠ moat |
| Open Interpreter / self-operating-computer | Early OSS operators | Vision-first, largely stalled; no discovery layer |
| browser-use / Skyvern | Web-only agents | Web sandbox comparables for SandboxKit |
| OmniParser (Microsoft) | Screen-parsing for grounding | CC-BY-4.0; candidate extra signal for MixtureGrounder |

## Sources

- https://github.com/trycua/cua
- https://cua.ai/
- https://andrew.ooo/posts/trycua-cua-open-source-computer-use-agents/
