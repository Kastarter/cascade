# Cascade — Project Memory

## Product
- Enterprise **local context recorder first**: record employee work context (screen/OCR/app/window/input), rewind timeline, audit log, suggestions/agents from repeated work. Real-screen computer use only when permissions + STOP/audit are healthy.
- Reference repos are **implementation sources** to port (with attribution): farzaa/clicky, jasonkneen/openclicky, milind-soni/tiptour-macos, shujanshaikh/glide. Port map: `docs/PORT_MAP.md`.

## Stack
- Swift-first macOS app, SwiftPM package at repo root (no Xcode project). Old Screenpipe/Tauri/Rust base removed.
- Build: `swift test` then `./scripts/build-app.sh` → `.build/Cascade.app` (ad hoc signed). Bundle id / keychain service / log subsystem: `com.humain.cascade`.
- LLMs: Anthropic Messages API (non-streaming) — opus 4.8 / sonnet 4.6 / haiku 4.5; computer-use beta `computer-use-2025-11-24`. Voice: OpenAI Realtime `gpt-realtime-2` (PTT = Right Command). Keys in Keychain.

## Architecture (Sources/)
- `MacContextKit` — permission preflight (record needs Screen Recording only; agent needs SR+AX+Input Monitoring), ScreenCaptureKit capture (1fps SCStream, 1920px cap, excludes own windows), dHash dedup (Hamming ≤6 skip), Vision OCR, listen-only CGEvent input tap, RewindRecorder (JPEG frames + OCR → SQLite).
- `CascadeMemory` — SQLite (WAL) at App Support/Cascade: `recorded_context`, `input_event`, `audit_event`, `agents` (recipe JSON), `rewind_fts` (FTS5). Retention 7 days / 5GB prune. `PrivacyRules` = substring exclude-list (bank/health/password/…), drops frames (no redaction).
- `SuggestionEngine` — heuristic (no LLM): repeated-work groups ≥3 moments, daily recap; `WasteDetector` mines repeated input token sequences → `AgentRecipe`.
- `ProviderKit` — AnthropicClient, `ComputerUseAgent` (vision loop, tools: computer_20251124 + open_app/open_url, prompt caching, batched actions), `ClaudeSingleStepPlanner` (one JSON step), `ElementLocator` ("where is X" via Claude vision; region via haiku), `ClaudeGroundedAnswerer` + local fallback.
- `ComputerUseKit` — action types, Ctrl-Opt-Space hotkey, `NativeComputerUseActuator` (CGEvent, STOP+health gated), `GuidanceOverlay` (click-through panel: blue companion cursor, trail, ripple, marching-ants highlight), `AgentRunState` STOP flag.
- `AgentOrchestrator` — `AgentDriver` protocol, `LocalMacDriver`, recipe/planned-action mapping, `CascadeOrchestrator` glue.
- `SandboxKit` — `WKWebView` web sandbox (persistent default data store → reuses sign-ins), `BackgroundWebAgent` (same ComputerUseAgent routed to JS actions; NEEDS_LOGIN pause/resume protocol), `AgentTaskPlanner` (≤5 subtasks, per-episode 25 steps, findings memo).
- `AppShell` — `CascadeAppModel` (orchestration hub), `CascadeRootView` (tabs: Reel / Cascades / Manager; Settings is a sheet), `RealtimeVoice`, `NotchController` (floating notch HUD), `SandboxBoxController` (one floating panel per web agent).

## Conventions
- Permission prompts only from explicit Settings buttons; preflight everywhere; fail closed without Screen Recording.
- Every agent/computer action audited to `audit_event`. STOP (esc) checked before posting events.

## Current State (2026-06-10)
- Working: recording+rewind+FTS, Reel scrubber timeline, Ask panel (grounded Q&A), where-is-X overlay, foreground computer-use agent, saved-agent replay with OCR re-anchoring, background web sandbox agents, GPT-Realtime voice PTT, Manager/Cascades prototype views.
- README/HANDOFF "not done" lists are STALE (dated 2026-06-08) — most items have since landed per git log.
- NEW (2026-06-10c): smart+fast CU pass (per Anthropic computer-use docs): adaptive thinking + effort medium (benchmarked optimum for Sonnet 4.6 CU), max_tokens 2048 with max_tokens-truncation recovery (nudge retry; never silently "Done"); `enable_zoom` + native-res crop path (`captureCursorScreenZoomJPEG`, proceed(zoomResult:)) so small text is readable; agent-side `highlight` tool (CUAction.highlight → guidanceOverlay; persists past run end via agentDidHighlight; "highlight/point out/mark" routes to action loop); instruction-before-image ordering everywhere; per-turn grounding note (frontmost app+window); cache: 3 moving breakpoints on recent user turns + tools breakpoint, prune threshold 12.
- NEW (2026-06-10b): speed + safety pass — teach/showOnScreen/reground capture JPEG directly at model resolution (`AgentResolution.best`, no OCR/PNG on the hot path); prewarm on PTT press; skip haiku planner for short single-part commands; `assistGeneration` token (captured synchronously in teach) invalidates superseded assist loops; AssistMemory per-turn caps (280/420 chars) and failed turns (`ok: false`) never archive; replay audits target tier (`recipe.target` via ax/vision/recorded) + `recipe.verify.unavailable`; planner fallback + unlabeled clicks logged.
- NEW (2026-06-10): assist agent conversation memory + reliable recipe replay (uncommitted):
  - `ProviderKit/AssistMemory.swift` — rolling 8-turn (user, assistant) history + compacted UserDefaults archive + last-pointed element (clicky/openclicky CompanionManager port). Replayed as plain-text turns before the screenshot in ComputerUseAgent/ElementLocator; planner gets a text memo. Referential follow-ups ("now the second one") inherit the prior teach route; bare "click that" acts instantly on the last pointed element.
  - `ComputerUseKit/AXElementResolver.swift` — tiptour port: find element by recorded AX label (role-aware fuzzy match, nearest-point tiebreak), frontmost AX fingerprint for post-click verification.
  - InputRecorder stores clicked element's AX label in `InputEvent.text` (resolved async off tap thread; label text privacy-gated; drain defers unlabeled fresh clicks to preserve order). WasteDetector prefers it as anchor; recipe replay resolves AX label → Claude OCR-anchor reground → recorded pixel, verifies via fingerprint poll, pauses after 2 unverified clicks.

## Known Issues
- `ContextRecorder.captureNow()` one-shot capture bypasses PrivacyRules (continuous rewind path is gated).
- WebSandbox header says "ephemeral" but uses persistent default WKWebsiteDataStore (intentional for session reuse).
- Manager↔employee cascade delivery is in-memory only (no remote channel, not persisted).
- `suggestions` fetched but not rendered as a full card section; `screenAgentReady/Message` mostly unsurfaced.
- VoiceListener (Apple Speech) is dead code superseded by RealtimeVoice.
- No fonts bundled (Inter Tight / Instrument Serif / JetBrains Mono intended, system fallback used).
- Reference repos cloned at /tmp/cascade-refs (clicky, openclicky, tiptour-macos, glide) — re-clone if gone.
