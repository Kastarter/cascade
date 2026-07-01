# Sequence 18 - Proactive Intelligence, Next-Action Prediction, and Just-in-Time Help

## Overview

Cascade already has the reactive loop: record local work, mine repeated action sequences, curate candidates, and schedule or review agents later. Sequence 18 is the product-magic layer that happens while the user is still in the work: predict likely next actions, detect struggle or tedium in the current episode, surface the right agent or skill at the right moment, and suppress help when interruption cost is too high.

The research split is clear:

- **Prediction can start simple.** Recent next-activity benchmarks show count/argmax baselines can match or approach LSTM, Transformer, and LLM models on many event logs. Cascade should begin with recency-weighted n-grams over `input_event`, not a large model.
- **Proactivity is two decisions, not one.** Proactive-agent papers separate "should I intervene now?" from "what help should I provide?". Cascade should do the same: an interruptibility gate before any offer, then a help selector.
- **Timing matters more than clever text.** Smart Compose succeeds because suggestions are fast, inline, easy to accept, and cheap to ignore. Cascade's equivalent is the notch HUD or dock pill, not a modal.
- **Trust is the product constraint.** Proactivity must be local, auditable, dismissible, and never action-taking without user approval.

## OSS / Papers Table

| Source | URL | Technique | Cascade Use |
|---|---|---|---|
| Weytjens & Weber, "David vs. Goliath in Next Activity Prediction" | https://arxiv.org/abs/2606.15868 | Benchmarks argmax, LSTM, Transformer, LLM, and distilled models for next-activity prediction. The key result is pragmatic: simple counting baselines are hard to beat on many logs. | Start with per-surface n-gram / Markov next-event prediction over `InputEvent` before training a local Transformer. Use deep models only after acceptance data proves baseline limits. |
| Agrawal et al., "Learning User Intent from Action Sequences on Interactive Systems" | https://arxiv.org/abs/1712.01328 | LSTM sequence model over user clickstream actions to infer intent and optimize interactive systems. | Later intent classifier over app/window/action tokens. For v1, use its framing: "intent" is a latent label inferred from recent actions, not just repeated exact routines. |
| Pinterest TransAct | https://arxiv.org/abs/2306.00248 | Transformer over realtime user actions combined with longer-term embeddings for responsive recommendations. | Larger bet: hybrid local model with short-term live prefix plus long-term per-app routine embedding. Useful once Cascade has accepted/dismissed proactive-offer labels. |
| Gmail Smart Compose | https://arxiv.org/abs/1906.00080 | Low-latency neural suggestion system that predicts text completions while typing; suggestions are inline, fast, and ignorable. | UI pattern: notch/dock suggestions should be one-tap accept, zero-friction dismiss, and never block typing. Latency target should feel immediate, not agent-like. |
| Proactive Agent / ProactiveBench | https://arxiv.org/abs/2410.12361 | Labels proactive task predictions as accepted/rejected and trains/evaluates models on whether active assistance is appropriate. | Add `proactive.offer`, `proactive.accept`, `proactive.dismiss`, and `proactive.snooze` audit rows. Treat dismissals as first-class training data, not UI noise. |
| ProAgentBench | https://arxiv.org/abs/2602.04482 | Proactive-agent benchmark over continuous real user sessions; decomposes task into timing prediction and assist-content generation. | Architectural match: `ProactiveTimingGate` decides if Cascade should surface anything; `ProactiveHelpSelector` picks agent, skill, answer, or no-op. |
| ContextAgent | https://arxiv.org/abs/2505.14668 | Context-aware proactive LLM agent that extracts multi-dimensional sensory context, predicts proactive-service necessity, then calls tools unobtrusively. | Cascade already has desktop sensory context: screen frame, OCR/AX text, app/window, and input stream. Use an LLM only as a late-stage policy over compact features, not raw continuous frames. |
| LLM JITAI paper | https://arxiv.org/abs/2402.08658 | Just-in-time adaptive intervention framing: personalize whether and what to send based on current context, not static schedules. | Product vocabulary for Cascade's live nudges: opportunity, burden, receptivity, expected benefit. Offers should be contextual interventions, not notifications. |
| LangGraph / LangChain agents | https://github.com/langchain-ai/langgraph | OSS pattern for long-running, stateful agents with human-in-the-loop checkpoints and resumable workflows. | For proactive help, keep the agent dormant until accepted. If accepted, resume into the normal audited `CascadeOrchestrator` path instead of inventing a separate automation lane. |
| OASIS interruptibility framework | https://dl.acm.org/doi/10.1145/1753326.1753706 | Links notification delivery to task structure and perceptual breakpoints so interruptions land at lower-cost moments. | Wait for boundaries: submit/save, window switch, idle pause, end of typing burst, or repeated failure plateau. Avoid interrupting active typing, dragging, screen-agent runs, meetings, or sensitive contexts. |
| Mixed-initiative UI principles | https://dl.acm.org/doi/10.1145/302979.303030 | Classic principles for systems that share initiative with people: uncertainty management, graceful failures, user control, and timing. | Cascade should explain "why now", offer "not this", "later", and "always for this", and keep every proactive decision auditable. |
| Sequence 08 local workflow mining baseline | `/Users/khalidsh/Humain/cascade/docs/research/SEQ-08-workflow-mining.md` | Current local baseline for repeated-work mining, UI-log segmentation, and routine generalization. | Sequence 18 should reuse `WasteDetector` recipe creation, not replace it. The new work is live prefix detection and timing, not another daily card. |

## Concrete Proactive Features

### 1. Online next-action predictor over `input_event`

**Goal:** predict what the user is likely to do next within the current app/window/surface.

Implementation shape:

- Add `Sources/WasteDetection/NextActionPredictor.swift`.
- Input: the latest privacy-safe `InputEvent`s from `CascadeStore.recentInputEvents(limit:)` plus active app/window and optional nearest `RecordedContext`.
- Token: reuse `WasteDetector.token` semantics, but include `kind`, app/surface, AX label, `targetDescriptor`, key combo, and coarse time gap bucket.
- Model v1: recency-weighted n-gram counts:
  - unigram: current app/window common next actions
  - bigram/trigram: recent action prefix -> top-k next actions
  - fallback: per-agent first step matching active app/window
- Output: `PredictedAction(label, confidence, evidenceCount, sourceWindow, suggestedAgentID?)`.

Why this is the right first bet: the next-activity literature says simple argmax/counting baselines are strong. Cascade's local logs are sparse and personal, so a cheap per-user predictor will likely beat a cold generic model for the first release.

Mapped files:

- `Sources/CascadeMemory/CascadeMemory.swift` - `InputEvent`, `recentInputEvents`, `inputEvents(between:and:)`.
- `Sources/MacContextKit/InputRecorder.swift` - emits the action stream and AX descriptors.
- `Sources/WasteDetection/WasteDetector.swift` - tokenization, sensitivity filtering, routine construction.
- `Sources/AgentOrchestrator/AgentOrchestrator.swift` - add `predictedNextActions(...)` next to `detectedWaste(...)`.

### 2. Live "you are doing this again" detector

**Goal:** catch repetition while it is happening, not after a refresh/digest.

Current `WasteDetector.detect` mines recent history and surfaces curated waste in the Cascades review queue. Keep that. Add a rolling session detector:

- Maintain a 5-15 minute ring buffer of non-sensitive input events.
- Segment by idle gap, app/window switch, completion controls, and copy/paste bridges.
- After the second live instance of a known sequence, produce a quiet candidate.
- After the third live instance, if the interruptibility gate passes, surface: "Run the invoice export agent?" or "Turn this into an agent?"
- If no saved agent exists, call `WasteDetector.waste(fromInstance:contexts:surface:)` on the current bracket and route to `curateRange(...)`.

Mapped files:

- `Sources/AppShell/CascadeAppModel.swift` - owns `refreshAll`, `detectedWaste`, `curatedWaste`, `dock`, and app-level state.
- `Sources/AgentOrchestrator/AgentOrchestrator.swift` - already has `curateRange` and `detectedWaste`.
- `Sources/WasteDetection/WasteDetector.swift` - reuse guards: sensitive filtering, noisy-app filtering, structural-action threshold, and session checks.

### 3. Just-in-time agent and skill surfacing

**Goal:** suggest help the moment the user is likely to need it.

Candidate surfaces:

- Saved agents whose first 1-3 recipe steps match the live prefix.
- Learned app skills whose `useWhen` matches the frontmost app and current action shape.
- Rewind Q&A prompts when the live task appears to need context, for example "where was that customer ID?" after repeated search attempts.
- Background web agents when the user is in a browser workflow that can run away from the foreground.

Offer ranking:

```text
score = predictedBenefit
      * confidence
      * userAcceptancePrior
      * surfaceRelevance
      - interruptionCost
      - recentDismissalPenalty
      - privacyRiskPenalty
```

Mapped files:

- `Sources/AppShell/CascadeAppModel.swift` - `agents`, `dock.show(...)`, `screenAgentReady`, and live state.
- `Sources/AppShell/NotchController.swift` - ambient notch surface for quiet offers.
- `Sources/AgentOrchestrator/AgentOrchestrator.swift` - saved-agent lookup and execution routes.
- `Sources/ProviderKit/AssistMemory.swift` and app skill registry paths - useful as context for matching skills to live intent.

### 4. Stuck and struggle detection

**Goal:** detect when the user is not simply repeating work, but fighting the UI.

Signals from existing streams:

- Rapid repeated click on same AX target or same coordinates with no app/window state change.
- Undo, cancel, escape, delete, backspace, or close loops.
- Error dialog / alert OCR or AX title repeated.
- Idle pause followed by high-entropy flailing: many different controls in a short time.
- Search field query rewrite loops.
- Scroll up/down oscillation in the same viewport.
- Same agent or action route paused repeatedly on the same target.

Offer policy:

- Low confidence: passive notch state only, no text.
- Medium confidence: "Want Cascade to look at this?"
- High confidence with known agent: "Run the saved cleanup agent?"
- Never auto-click or auto-type. The first action is always user acceptance.

Mapped files:

- `Sources/MacContextKit/InputRecorder.swift` - click/key/scroll stream.
- `Sources/MacContextKit/RewindRecorder.swift` - app/window/OCR/AX context for alerts and no-progress checks.
- `Sources/AppShell/CascadeAppModel.swift` - dock/notch status and STOP state.
- `Sources/CascadeMemory/CascadeMemory.swift` - audit rows and local feedback labels.

### 5. Proactive feedback loop

Every proactive offer should create a small, local, auditable training row:

- `proactive.signal` - raw reason, feature summary, confidence, active app/window.
- `proactive.offer` - selected help, surface, timing score, suppression state.
- `proactive.accept` - user accepted; link to agent run, answer, or teach flow.
- `proactive.dismiss` - user dismissed; include quick reason when available.
- `proactive.snooze` - user wants no offers for this task/app/time window.

This turns annoyance into data. The first model should learn mostly from suppression, because false positives are more damaging than missed suggestions.

## Interruptibility And Trust Model

Cascade's proactivity should be a permissioned attention system, not a notification system.

### Hard suppressions

No offer should surface when:

- `PrivacyRules` marks the app/window/context sensitive.
- Secure input is active or keystrokes are being suppressed.
- The user is actively typing, dragging, selecting text, or holding a modifier-heavy shortcut sequence.
- A screen agent is currently acting, a STOP is active, or permissions are unhealthy.
- The active app is a meeting, fullscreen media, password manager, banking, health, legal, or private browsing surface.
- The same offer or signature was dismissed recently.

### Cheap interruption moments

Offer only at boundaries:

- After idle for 2-5 seconds following repeated action.
- Immediately after save/submit/send/export/download/apply.
- After app/window switch, before the next typing burst.
- After repeated no-effect clicks or error dialogs, but only as "want help?".
- When the user opens Cascades/Reel/Manager, where attention is already inside Cascade.

### Offer levels

| Level | Surface | Use Case |
|---|---|---|
| 0 Silent | Audit only | Low confidence or high interruption cost. |
| 1 Ambient | Notch glow / icon state | "Cascade sees a possible pattern" without text. |
| 2 Passive text | Notch expanded on hover, dock pill inside Cascade | Medium confidence, no urgency. |
| 3 Action chip | One-tap "Run" / "Show" / "Teach" | High confidence, known user-approved agent or current repeated task. |
| 4 Voice | Only after user is already in PTT voice flow | Never initiate speech on its own. |

### User controls

- Global modes: Off, Quiet, Ask First.
- Per-app controls: "Never suggest in this app", "only in Cascades", "suggest saved agents only".
- Per-signature controls: "not this", "later", "always offer this".
- Evidence preview: show the last 2-3 local moments or action labels behind "why now".
- Auditability: every offer and suppression should be inspectable in Activity.

## Quick Wins vs Larger Bets

### Quick Wins

1. **Add proactive audit events.** No UI change needed. Log candidate signals and suppressions from `CascadeAppModel.refreshAll` or a small live monitor.
2. **N-gram next-action predictor.** Recency-weighted prefix counts over `recentInputEvents`; no ML dependency.
3. **Live repetition detector.** Rolling ring buffer around the latest session, using existing `WasteDetector` guards and `curateRange`.
4. **Saved-agent prefix match.** Match current live prefix to approved `AgentRecipe.humanSteps` / first action tokens and surface only in notch/dock.
5. **Stuck heuristics.** Same-target repeated clicks, undo/cancel loops, search rewrite loops, and error-dialog OCR. Start with passive "Want Cascade to look?".
6. **Cooldown and dismissal memory.** Store per-app and per-signature dismissals in UserDefaults or SQLite before expanding UI.

### Larger Bets

1. **Personalized interruptibility model.** Train a small local model from accepted/dismissed/snoozed offers plus app/time/action features.
2. **Transformer prefix model.** Only after n-gram baseline plateaus; use local personal data and compact tokens, not raw pixels.
3. **LLM proactive policy.** Feed a compact feature packet to Claude only after the local gate says an offer is plausible.
4. **Multimodal need detector.** Use OCR/AX deltas and screenshot embeddings to infer "no progress" or "searching for missing info".
5. **Proactive benchmark harness.** Replay historical local sessions and ask: would this offer have been accepted, ignored, or annoying?

## Implementation Cut

The smallest credible Sequence 18 build is:

1. Create `ProactiveSignal` and `ProactiveOffer` data types in `Sources/WasteDetection` or a new `Sources/ProactiveIntelligence` target.
2. Add `NextActionPredictor` with recency-weighted unigram/bigram/trigram counts over privacy-safe `InputEvent`s.
3. Add `ProactiveTimingGate` with hard suppressions, boundary detection, cooldowns, and expected-value thresholding.
4. Add a passive notch/dock offer path in `CascadeAppModel`, with accept/dismiss/snooze audit rows.
5. Reuse existing `WasteDetector.waste(fromInstance:)`, `AgentOrchestrator.curateRange`, and saved-agent execution. Do not create a second automation pipeline.

This keeps the system local-first, auditable, and useful even without model training. The first measurable product question becomes: "Did this offer help more often than it annoyed?", which is exactly the feedback Cascade needs before making bigger proactive bets.
