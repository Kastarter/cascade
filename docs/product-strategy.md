# Cascade Product Strategy

Last updated: 2026-06-08

Cascade is two products in one, but they should stay separated in the code:

1. Employee context: local capture, rewind, search, Q&A, privacy aggregation.
2. Agent execution: local browser driver today, real-screen computer use today, local VM sandbox later.

The monitoring/context layer is the wedge. The computer-use layer matters, but it is downstream: agents are useful only when the recording proves what work is repetitive, what tools the employee already uses, and where the output should land.

## Reference Projects

Use the open-source Clicky-style repos as implementation references, not as wholesale vendors:

- `mediar-ai/screenpipe`: source of truth for passive capture, OCR, local event store, and rewind UI. Cascade remains a soft fork/overlay on this.
- `farzaa/clicky`: reference for a native Swift overlay, ScreenCaptureKit capture pipeline, permission-led onboarding, and polished cursor presence.
- `jasonkneen/openclicky`: strongest reference for native macOS computer-use UX: overlay guidance, local control bridge, screenshots with display metadata, cursor endpoints, fallback native control, and Codex-style agent mode. MIT licensed.
- `milind-soni/tiptour-macos`: reference for the macOS accessibility flow, native cursor/control affordances, and an app-like control dock that does not feel like a webview pasted over the desktop.
- `shujanshaikh/glide`: useful product reference for voice, authenticated cloud tools, and Composio-style integrations, but less directly reusable for Cascade because it is a cloud-backed companion app rather than a local monitoring system. MIT licensed.

Do not copy entire apps into `vendor/` unless there is a concrete build-time dependency. Pull ideas and small, attributed patterns into Cascade-owned Rust/Tauri modules instead.

## Execution Modes

Cascade should expose one driver contract with three backends:

- `local_browser`: a visible isolated browser controlled by the agent. Best for web workflows, safe to watch, and backed by layered verification so small text-field changes, dropdowns, async loads, and stale WK snapshots do not become false failures.
- `screen`: native macOS input synthesis against the user's actual apps. Best for local apps, higher trust requirement, and blocked unless Screen Recording, Accessibility, Input Monitoring, healthy screen frames, and UI recorder/event taps are all working. It must keep STOP visible, cap real-screen actions, guard repeated actions, and audit every run.
- `local_vm`: a defined but fail-closed backend. The first implementation should run an isolated local browser/app VM in the background, then later replace today's weaker sandbox boundary without changing the agent planner.

The future VM should replace the sandbox boundary, not the agent planner. The loop remains: Rewind grounding -> agent spec -> supervised run -> audit/result.

The `AgentDriver` contract is:

- `observe()` returns screenshot, OCR text, accessibility/app/window metadata, cursor/display scale, and recent Rewind context.
- `act()` performs typed mouse, keyboard, navigation, app, or browser actions through the selected backend.
- `verify()` checks DOM/AX/state first when available, OCR/text-region deltas second, and image diff last. It should say "state unclear, re-observe" when uncertain, never poison history with an unproven failure.
- `stop/pause/status()` powers the visible control dock and DB lifecycle, including cleanup of orphaned `running` rows after app restarts.

## First Buyer

The best initial buyer is a services business that sells time and has repeatable knowledge work:

- consulting firms and implementation partners
- accounting, audit, legal ops, and compliance-adjacent professional services
- BPO/back-office operations teams
- customer support, QA, sales ops, and RevOps teams with many browser workflows

Why them: they already think in billable hours, recurring client work, SOPs, and process improvement. Cascade's pitch is not "employee surveillance." It is "discover repetitive work from local evidence, prove the privacy boundary, then deploy reviewed helpers that save time."

Avoid starting with highly regulated employee-surveillance-sensitive deployments where the buyer wants manager visibility more than employee trust. Cascade wins when employees can see the same Rewind, preview the privacy outbox, and pause agents instantly.

## Near-Term Priorities

1. Make Rewind-derived detection boringly reliable.
2. Keep all manager-visible signals privacy-aggregated and previewable.
3. Improve Local Browser reliability on real SPAs: typing, click targeting, no-effect loop detection, login handling.
4. Keep real-screen mode conservative, visible, stoppable, and audited.
5. Only then add external app integrations or cloud VM execution.
