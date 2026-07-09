# HeyClicky / farzaa/clicky — Competitor + Reference Analysis

Researched 2026-07-07. Sources at bottom. Note: `farzaa/clicky` is already one of Cascade's **reference repos** (CLAUDE.md, PORT_MAP.md) — we port its native overlay/cursor + ScreenCaptureKit patterns.

## What it is

Mac-native AI assistant that **sees your screen and talks back**. Founder **Farza Majeed** (ex-Buildspace, large audience), SF team, **YC Spring 2026**, reported **~$10.1M** funding. ~95% Swift, open-source. Menu-bar app, **Control+Option** hotkey. Free tier; **Pro $20/mo** (150 agent messages + unlimited voice). Traction: ~3M launch views, ~6.3k GitHub stars, #6 Product of the Day.

## Why it feels fast (the "crazy" part = latency engineering, not model magic)

Streaming-first pipeline, everything overlapped:
1. **Push-to-talk audio → AssemblyAI real-time websocket** transcription (streamed, not batched)
2. **ScreenCaptureKit** grabs the screen on-demand when activated
3. **Claude streamed via SSE**, token-by-token
4. Tokens feed **ElevenLabs TTS immediately** — it starts speaking before Claude finishes
5. **Cloudflare Worker** holds all API keys and proxies `/chat`, `/tts`, `/transcribe-token` — thin client, no local key handling

So the speed comes from **pipeline overlap + streaming + a hosted proxy**, plus using fast hosted services (AssemblyAI/ElevenLabs). Model is just Claude (Sonnet/Opus picker).

## The pointing UX

Claude emits inline markup `[POINT:x,y:label:screenN]`; the app renders a **blue cursor overlay** that points at the exact UI element across multiple monitors. It *shows* rather than *tells*. **This is exactly what Cascade's `GuidanceOverlay` does** (blue companion cursor, trail, ripple, marching-ants highlight) — same lineage, since we port from this repo.

## What it does / doesn't do

- **Core loop = guidance only.** It observes and points; it **does not click, type, or manipulate the target app**. "Teach, don't do."
- **BUT "clicky agent" mode** (say "clicky agent") spins up a **background agent** to research, organize Notes/Calendar, or build a Mac app — so it *does* cross into execution, just in a separate background lane, and Pro meters it (150 agent messages/mo).

## Cascade vs Clicky — the honest diff

| Axis | Clicky | Cascade |
|---|---|---|
| Primary loop | Voice Q&A + point (guidance) | **Record → discover repeated work → execute supervised** |
| Real-screen action | No (guidance); background agent lane only | **Yes — native CGEvent execution, STOP-gated, audited** |
| Context source | On-demand screenshot when you ask | **Continuous local recorder + rewind + waste mining** |
| Discovery | None — user must ask | **Suggests automations from evidence, unprompted** |
| Grounding | Vision + `[POINT]` coords | **AX-first grounding** (the moat) + vision fallback |
| Buyer | Prosumer / individual, viral bottom-up | Services firms (audit/BPO/support), billable-hours ROI |
| Trust surface | Light (it can't act) | **Audit log, privacy rules, permission preflight** — because it *acts* |
| Pricing | Free + $20/mo prosumer | Seat + bundled runs, enterprise (see UNIT_ECONOMICS) |

## Strategic implications

1. **This is the #1 "why are you different" question in the YC interview** — more than cua. Same city, same space, same YC-adjacent timing, **and it's our own reference repo**. Have the crisp answer ready: Clicky is a *personal on-screen tutor that points*; Cascade is an *enterprise system that discovers repetitive work from local evidence and does it under supervision with an audit trail*. Guidance vs. execution; ask-driven vs. discovery-driven; prosumer vs. services-firm.

2. **Don't out-Clicky Clicky on voice-point latency.** Farza has a huge audience, viral distribution, and a head start on the delightful voice+point loop. Competing on "faster talking cursor" is a losing frame. Our wedge is the **recorder + discovery + supervised execution** they deliberately don't do — that's a different product, not a faster one.

3. **Steal the latency architecture, we already have the overlay.** Their streaming pipeline (websocket STT → SSE token stream → immediate TTS, thin client + edge proxy) is the reference for making our voice path feel instant. We already share the overlay DNA. Port the *pipeline overlap*, not just the cursor.

4. **Their existence de-risks our category for YC.** 3M views + 6.3k stars + $10M proves demand for AI-that-sees-your-Mac. We ride that validation while occupying the half they left open: actually doing the work, for teams, safely.

5. **"Teach vs do" is a real market fork — pick our side loudly.** Clicky bet that *guiding* is safer and more viral. Cascade bets the enterprise value is in *doing* (reclaimed billable hours), which is exactly why we invest in STOP/audit/AX-grounding. Frame this as a deliberate strategic divergence, not a gap.

## Sources
- https://github.com/farzaa/clicky
- https://www.heyclicky.com/
- https://dailydropout.substack.com/p/heyclicky-give-your-cursor-infinite
- https://www.everydev.ai/tools/hey-clicky
- https://hokai.io/hub/tools/heyclicky
