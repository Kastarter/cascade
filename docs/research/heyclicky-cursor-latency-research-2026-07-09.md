# HeyClicky Cursor Speed: Grounder, Planner, or Animation?

## 1. **TL;DR**

For HeyClicky specifically, public evidence does **not** reveal enough production architecture to prove what governs every cursor movement. But the best-supported answer from the public Clicky/HeyClicky lineage is:

- **Time to DECIDE the next action**: governed by the planner / reasoning / routing model and network/API latency.
- **Time to LOCALIZE the target on screen**: governed by the vision/grounding path that produces coordinates.
- **Cursor TRAVEL animation once coordinates exist**: governed by local client UI code, not by the planner or grounder.

So if the visible cursor is already moving, its speed is probably **not bounded by the model**. It is usually a product-chosen tween: distance-based duration, easing curve, timer/display-link cadence, or OS pointer movement duration.

In the public Clicky code, this is explicit: once a target point exists, `OverlayWindow.swift` animates the visible buddy/cursor with `animateBezierFlightArc`, computes duration from distance, and clamps it between **0.6s and 1.4s**. That is UI code. It is not inference.

The model-bound part is the pause **before** movement: deciding what to do, reading the screen, producing a target coordinate, parsing it, and routing it to the overlay. In simple point-and-talk flows, decide and localize appear fused into a single Claude vision response. In heavier agentic flows, planner latency likely dominates.

## 2. **What We Actually Know About HeyClicky**

Public HeyClicky-specific sources establish only the product surface:

- The official homepage says HeyClicky is “an ai buddy that lives on your mac,” sits near the cursor, and sees the user’s screen.
- YC describes HeyClicky as a consumer interface for spawning agents.
- YC Launch frames it as an AI buddy next to the computer cursor.
- A third-party TBPN digest says HeyClicky routes across models: GPT Realtime for quick routing/answers, Claude for heavier image understanding, and Codex/GPT-4.5-style subprocesses for agentic work.

What those sources do **not** provide:

- No first-party production architecture.
- No cursor animation implementation.
- No measured latency breakdown.
- No proof that production HeyClicky moves the real macOS cursor rather than rendering an overlay cursor.
- No direct statement that cursor speed is bounded by a planner, grounder, or local animation.

The strongest technical evidence comes from the public `farzaa/clicky` repo, which appears to be the open-source lineage/prototype, not guaranteed production HeyClicky.

In that repo:

- The README describes a flow where transcript plus screenshot are sent to Claude, which emits coordinate tags.
- `AGENTS.md` says Claude embeds `[POINT:x,y:label:screenN]` tags that drive cursor pointing across monitors.
- `CompanionManager.swift` captures screens, calls Claude, parses point tags, converts coordinates, and publishes `detectedElementScreenLocation`.
- `OverlayWindow.swift` listens for that already-produced coordinate and animates the visible cursor locally.
- `ElementLocationDetector.swift` shows a separate Claude Computer Use coordinate-detection path, but available evidence does not prove it is wired into the main point-and-talk path.

Important correction: the public implementation’s visible cursor is best understood as an overlay/buddy cursor. Third-party analysis says Clicky does not move the actual mouse pointer. For production HeyClicky, that remains unverified.

## 3. **What the Papers Say**

The supplied research packet includes only one general GUI-agent literature reference: GUI-Actor. It supports the conceptual split between a planner and a grounder, with one model deciding/planning and another localizing the GUI target.

However, the provided material does **not** include usable numeric latency measurements for planner-vs-grounder inference. Therefore, this report cannot honestly claim paper-backed values such as “grounder takes X ms” or “planner takes Y seconds.”

The numeric latency evidence in the packet is instead from Clicky’s client animation code:

- Cursor flight duration: `min(max(distance / 800.0, 0.6), 1.4)`
- Nominal frame interval: `1.0 / 60.0`
- This means the visible travel animation is bounded locally to roughly **0.6-1.4 seconds**, independent of model inference once the coordinate exists.

The literature-level takeaway is architectural, not numeric: GUI agents often separate planning from grounding. Cursor travel is a third layer and should not be confused with either.

## 4. **How They Likely Mask Thinking Time**

The public Clicky flow appears to hide decision/localization latency behind a broad processing/responding state.

Evidence from `CompanionManager.swift` says the runtime state machine uses broad voice states such as idle, listening, processing, and responding. There is no visible split between:

- “planner is deciding”
- “grounder is localizing”
- “overlay is executing movement”

In the public implementation, the spinner appears to remain until response/TTS behavior begins, and coordinates are parsed after the model response. That means the user’s perceived “thinking” phase likely includes screen capture, model inference, coordinate generation, response parsing, and possibly speech setup.

Once `detectedElementScreenLocation` is published, `OverlayWindow.swift` begins local animation. The animation uses:

- coordinate conversion from AppKit screen coordinates to SwiftUI coordinates,
- multi-display gating via `detectedElementDisplayFrame`,
- Bezier flight,
- distance-based duration,
- 60Hz timer-driven updates,
- local easing/rotation/scale effects.

This is a classic UX masking pattern: wait invisibly while the model reasons, then animate confidently to the target with a smooth, product-controlled flight. The motion can make the system feel intentional even if the real bottleneck happened before movement started.

## 5. **Implications for Cascade**

1. **Do not optimize cursor tween speed as if it were model latency.**  
   If Cascade has already chosen a coordinate, visible travel should be controlled by product code. Make it smooth, bounded, and predictable.

2. **Instrument three separate timers.**  
   Track `decide_ms`, `localize_ms`, and `travel_ms` separately. A single “action latency” metric will hide the real bottleneck.

3. **AX-first grounding can win before the cursor moves.**  
   If HeyClicky-style flows rely on screenshot-to-coordinate model inference, Cascade’s AX-first approach can reduce localization latency and improve reliability by producing targets deterministically or semi-deterministically before invoking heavy vision.

4. **Use cursor animation as a confidence signal, not a truth source.**  
   Smooth cursor travel does not mean the agent localized quickly. It may only mean the client tween is polished.

5. **Separate demo UX from execution architecture.**  
   Public Clicky appears to draw a virtual overlay cursor. If Cascade controls the real pointer or real apps, it should avoid conflating “looks like movement” with “safe action execution.”

## 6. **Confidence & Open Questions**

Confidence is high for the public Clicky repo:

- `OverlayWindow.swift` is presentation and animation code, not inference code.
- Target coordinates are externalized before animation.
- The visible flight duration is computed locally and clamped to 0.6-1.4s.
- The flight is timer-driven at nominal 60Hz.
- Coordinate conversion and multi-display gating are deterministic client plumbing.

Confidence is medium for applying this to production HeyClicky:

- HeyClicky’s public pages confirm cursor-adjacent, screen-aware positioning.
- Third-party sources describe model routing and agent subprocesses.
- But no production source confirms the exact cursor implementation.

Open questions:

- Does production HeyClicky move the real macOS cursor, render an overlay cursor, or use both depending on mode?
- Does production HeyClicky still use Claude point tags, a Claude Computer Use detector, AX APIs, or a private grounding model?
- Does it stream target coordinates before the full answer, or only after a complete model response?
- What are the actual p50/p95 latencies for decide, localize, and travel?
- Are heavy agentic flows visually tied to cursor movement, or are they mostly background jobs?

Refuted/corrected claim:

- It is supported that Clicky disables implicit SwiftUI animation during target navigation and uses timer-driven movement.  
  It is **not** directly supported that the source file itself proves this was designed to separate travel animation from model inference latency. That separation is an external architectural inference.

## 7. **Sources**

- https://github.com/farzaa/clicky/blob/main/leanring-buddy/OverlayWindow.swift
- https://raw.githubusercontent.com/farzaa/clicky/main/leanring-buddy/OverlayWindow.swift
- https://github.com/farzaa/clicky/blob/main/README.md
- https://raw.githubusercontent.com/farzaa/clicky/main/README.md
- https://github.com/farzaa/clicky/blob/main/AGENTS.md
- https://raw.githubusercontent.com/farzaa/clicky/main/AGENTS.md
- https://github.com/farzaa/clicky/blob/main/leanring-buddy/CompanionManager.swift
- https://raw.githubusercontent.com/farzaa/clicky/main/leanring-buddy/CompanionManager.swift
- https://github.com/farzaa/clicky/blob/main/leanring-buddy/ElementLocationDetector.swift
- https://raw.githubusercontent.com/farzaa/clicky/main/leanring-buddy/ElementLocationDetector.swift
- https://raw.githubusercontent.com/farzaa/clicky/main/leanring-buddy/ClaudeAPI.swift
- https://github.com/farzaa/clicky
- https://isaacflath.com/writing/how-clicky-works
- https://www.heyclicky.com/
- https://www.ycombinator.com/companies/heyclicky
- https://www.ycombinator.com/launches/QNN-this-is-heyclicky-an-ai-buddy-that-lives-next-to-your-computer-cursor
- https://www.tbpndigest.com/story/2026-06-10/hey-clicky-founder-farza-majeed-built-a-voice-controlled-ai-desktop-agent-in-8-weeks-now-using-claude-4-by-default
- https://hokai.io/hub/tools/heyclicky
- https://www.producthunt.com/products/clicky-2
- https://www.xda-developers.com/someone-built-tiny-ai-that-lives-next-to-your-cursor-the-most-useful-thing-ive-tried-this-year/
- https://www.aibyaakash.com/p/clicky
- https://arxiv.org/html/2506.03143v1