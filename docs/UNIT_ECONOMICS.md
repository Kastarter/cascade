# Cascade Unit Economics — API Cost Model

Last updated: 2026-07-06. Pricing verified against Anthropic's current price sheet; call sites verified against `Sources/` on main.

## Current Anthropic pricing (per 1M tokens)

| Model | Input | Output | Notes |
|---|---|---|---|
| Opus 4.8 (`claude-opus-4-8`) | $5.00 | $25.00 | `AnthropicModel.opus` |
| Sonnet 5 (`claude-sonnet-5`) | $3.00 (**$2.00 intro through 2026-08-31**) | $15.00 (**$10.00 intro**) | `AnthropicModel.sonnet` — **CU default** |
| Haiku 4.5 (`claude-haiku-4-5`) | $1.00 | $5.00 | `AnthropicModel.haiku` (locator regions; coerced to Sonnet for CU) |

Prompt caching: reads ≈ 0.1× input price; writes 1.25× (5-min TTL) or 2× (1-h TTL). We use **1h TTL** on system/tools (`ComputerUseAgent.swift:966,1012`) and 5-min ephemeral on the last 3 turns.

Images: ≈ (width × height) / 750 tokens. Our screenshots cap at 1920px (`ScreenCapture.maxPixelDimension`); Sonnet 5/Opus 4.8 accept up to 2576px without downscaling → a 1920×1080 frame ≈ **~2,800 tokens** (~$0.0056 at Sonnet intro input price, uncached).

## Every paid call site (end-to-end sweep)

| # | Surface | Model (default) | Shape | Cost driver |
|---|---|---|---|---|
| 1 | On-screen CU agent (`ComputerUseAgent`) | **Sonnet 5** (`cascade.onScreenModel`; opus opt-in) | Vision loop, `screenshotKeepWindow = 3`, maxTokens 2048/turn, history compaction after 6 turns, caching on | **~90% of spend** |
| 2 | Background web agent (`SandboxKit`) | Same `ComputerUseAgent` → JS actions | Same loop; ≤5 subtasks, 25 steps/episode | Same per-turn math |
| 3 | `ClaudeSingleStepPlanner` | Opus | Text-only, 1 JSON step/call | ~$0.02/step |
| 4 | `ElementLocator` / Claude grounder fallback | Claude vision (haiku for regions) | 1 screenshot + short output | ~$0.01–0.02/call; only fires when AX-first grounding misses |
| 5 | `ClaudeGroundedAnswerer` (record Q&A) | Opus | maxTokens 300 | pennies/question |
| 6 | `RecordSearchAnswerer` | Opus | Cached system+tools | pennies/question |
| 7 | Scout planner (`GroqClient`) | `qwen/qwen3.6-plus` (OpenRouter) / Llama-4 Scout (Groq) | Cheap tier of two-tier planner | ~free (<$0.001/call) |
| 8 | Hosted UI-TARS grounder (OpenRouter) | UI-TARS-1.5-7B | 1 image/call | ~free-to-cheap |
| 9 | Voice PTT (`RealtimeVoice`) | OpenAI `gpt-realtime-2` | Per audio-second; PTT + local VAD gate (D-13) bound upload | **Unverified — check OpenAI price sheet**; realtime audio is the priciest per-minute channel |
| 10 | **Recorder + suggestions** | none | ScreenCaptureKit, Vision OCR, SQLite, heuristic WasteDetector | **$0 — fully local** |

Key structural fact: **the wedge (recording, rewind, waste detection) has zero marginal API cost.** Only agent execution and Q&A spend money.

## Per-turn and per-run math (CU agent)

Per turn at Sonnet 5 intro pricing, caching healthy:

- Fresh input: 1 new screenshot (~2,800 tok) + tool results/text (~500 tok) ≈ 3,300 tok at 1.25× write ≈ **$0.008**
- Cache reads (system, tools, prior turns, 2 old screenshots): ~20k tok at $0.20/M ≈ **$0.004**
- Output (~500 tok actual, 2048 cap) at $10/M ≈ **$0.005**

→ **~$0.015–0.02 per turn.** A typical run (10–25 turns, 25-step episode cap):

| Model | Per turn | Per run (typ. 15 turns) | Range |
|---|---|---|---|
| Sonnet 5 (intro, through 2026-08-31) | ~1.7¢ | **~$0.25** | $0.10–0.50 |
| Sonnet 5 (post-intro $3/$15) | ~2.5¢ | ~$0.38 | $0.15–0.75 |
| Opus 4.8 | ~4¢ | **~$0.60** | $0.25–1.25 |

⚠️ **Budget for post-intro Sonnet pricing (×1.5) from Sept 2026** — don't build the pricing model on the intro rate.

If caching breaks (silent invalidator, >5-min gaps between turns), per-turn input goes ~5–10× — watch `cache_read_input_tokens` in usage; zero across turns means we're paying full freight.

## Monthly COGS per user (Sonnet default, intro pricing)

| Profile | Agent runs | Agent cost | + Q&A/planner/grounding | ≈ COGS/user/mo |
|---|---|---|---|---|
| Light | 2/workday (40/mo) | ~$10 | ~$2 | **~$12** |
| Moderate | 5/workday (100/mo) | ~$25 | ~$4 | **~$30** |
| Heavy | 20/workday (400/mo) | ~$100 | ~$8 | **~$110** |

Voice excluded (unverified pricing; PTT-bounded). Recording excluded ($0).

## The margin story (this is the YC-worthy part)

Marginal cost per workflow **decreases with repetition**, unlike generic computer-use agents:

1. **Action-trajectory cache** (`actionTrajectoryCachePreflight`): a replayed recipe that hits the cache executes with **zero model calls**. The product's core premise — repeated work — is exactly the case where cost → $0.
2. **AX-first grounding**: every grounding resolved from the AX tree is a vision call *not made*. The moat and the COGS lever are the same investment.
3. **GroundingCache / ModelCallCache** (flag-gated): exact-hit reuse across runs.
4. **Two-tier planner**: Qwen cheap tier handles routine steps; Sonnet/Opus only on fallback.
5. Already shipped: screenshot history 8→3, Sonnet CU default, batched actions, prompt caching with 1h TTL.

So steady-state COGS for a mature deployment trends well below the table above — first-run cost is the ceiling, replay cost is the floor (~$0).

## Pricing implication (recommendation, not decided)

- Comparables: Rewind/Limitless-class recorders at $19–30/seat/mo; enterprise agent platforms far higher. Our buyer thinks in billable hours: one reclaimed hour/month ≈ $100–300 of billable value.
- Suggested shape: **$40–60/seat/mo** (recording + rewind + suggestions + bundled agent runs with a fair-use cap, e.g. 150 runs/seat/mo), usage credits beyond the cap, enterprise tier custom. At $49/seat and moderate use (~$30 COGS) margin is ~40% on day one and improves with replay-cache hit rate; heavy users are protected by the cap.
- Do **not** price unlimited agent runs flat — a heavy Opus user ($110+/mo COGS) inverts the margin.

## Open items

- [ ] Verify `gpt-realtime-2` audio pricing and add voice to the COGS table.
- [ ] Instrument actual per-run token usage (the `AgentUsage.prunedImages` plumbing exists; add cache-read/write counters to `audit_event` or the reliability report) so these estimates become measured numbers before quoting them to YC or customers.
- [ ] Re-run this model at post-intro Sonnet pricing before setting public prices (Sept 2026).
