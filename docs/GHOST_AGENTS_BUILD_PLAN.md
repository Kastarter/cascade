# Plan B — Ghost Agents (actionable build plan)

Status: proposed · Author: audit follow-up · Date: 2026-06-13
Scope: parallel window-scoped computer use — N agents, each its own visible cursor, working
different windows at once without taking focus.
Companion: `docs/GHOST_AGENTS_PLAN.md` holds the vision + physics rationale; this is the
concrete, grounded build path with real touchpoints. Depends on the parity refactor in
`docs/AGENT_PARITY_AND_INTELLIGENCE_PLAN.md` §B1–B2.

## The one physics change everything hangs on

Keys already post per-PID (`event.postToPid(pid)`, `ComputerUseKit.swift:457`) ✅, but **mouse
events post to the shared `.cghidEventTap`** (`:320`, `:334`, `:362`) — so only one agent can
click, and clicks fight the user's real cursor. Ghost agents need a **per-PID mouse path**:

- `click` / `doubleClick` / `tripleClick` / `drag` / `scroll` gain a `pid:` variant that builds
  the same `CGEvent`s but calls `.postToPid(pid)` — coordinates mapped through the target
  window's live frame from `CGWindowList`, **not** the HID tap.
- Consequences: no focus steal, no cursor fight, and the listen-only `InputRecorder` never sees
  ghost work → workflow detection stays uncontaminated by agent activity.

**Compatibility caveat (validate in P1):** many AppKit apps ignore synthetic mouse events sent
to unfocused windows. AX press / focus / setValue on the window's tree is the reliable fallback;
vision-click is the last resort. Keep the plan's "2 unverified actions → reroute to the serial
foreground queue" as the safety net — worst case a ghost subtask runs serially like today.

## How it rides the parity refactor (don't build it twice)

The parity plan extracts `AgentRuntime` + an `ActionExecutor` protocol with `RealScreenExecutor`
and `WebSandboxExecutor`. **Ghost is just a third executor: `GhostWindowExecutor`** (per-PID
actuator + window capture). Sequence ghost *after* B1/B2 lands and it inherits streaming, skills,
harness, memory, and STOP for free. Building it before the extraction means writing a third
engine you then have to merge.

## Pieces & touchpoints

1. **`GhostWindowExecutor`** (`ActionExecutor` impl) — per-PID mouse actuator (above) + AX
   act + window-frame coordinate mapping. The make-or-break primitive.
2. **`GhostWindowAgent`** (SandboxKit sibling) — same `ComputerUseAgent` brain, observing via
   `SCContentFilter(desktopIndependentWindow:)` (capture already uses `SCContentFilter` at
   `ScreenCapture.swift:102/134/253` — add the per-window filter) and acting via the executor.
   Shaped like `BackgroundWebAgent` with a different actuator.
3. **`GhostBoxController`** — clone `SandboxBoxController` (`AppShell`): one watch panel per
   ghost (window snapshot + drawn cursor + status + per-ghost STOP).
4. **Per-agent companion cursors** — `GuidanceOverlay` already draws one themeable companion
   cursor; parameterize by agent → N colored instances, shown only while the target window is
   actually on screen.
5. **Swarm entry + HUD** — `⌃⌥⇧Space` or a "split this up…" phrasing; a mission-control panel
   (per-subagent lane / steps-used / budget / verdict) fed by data that already exists (step
   counts, findings, completion). Audit each action as `ghost.<n>.<action>`.

## Lane routing (the planner already decomposes)

- web → sandbox box (`BackgroundWebAgent`, exists)
- work that lives in one app window → ghost
- anything needing app activation, menus, system dialogs, or cross-app flow → the serial
  foreground queue (the existing assist agent, untouched)

## Build order

- **P1 — one ghost, end to end (the spike, do this first, behind a flag):** bind to a
  Notes / TextEdit window, type a document while the user keeps focus elsewhere; watch panel +
  verify loop. Proves the per-PID mouse + window-capture physics *in our codebase* before any
  swarm UI exists. This is where the platform risk lives — retire it here.
- **P2 — the swarm:** planner lanes, N ghosts + sandbox boxes in parallel, HUD with
  budgets / metrics, synthesis, colored cursors.
- **P3 — compatibility pass:** per-app matrix (AppKit vs Catalyst vs Electron), fallback tuning;
  the 6 "wow use cases" in `GHOST_AGENTS_PLAN.md` become the test suite.

## Why it can't harm existing features

New executor + new entry point; the foreground actuator, hotkey, replay, and sandbox agents are
untouched. `postToPid` events bypass the HID tap, so the `InputRecorder` never records ghost
work. Same permission set (SR + AX + Input Monitoring), same `PrivacyRules` gates on every ghost
frame, same STOP semantics (per-ghost in its panel; Esc stops everything).

## Risks / effort

Large, and P1 carries real platform risk — synthetic input to background windows is
app-dependent. De-risk with the P1 spike before committing to the HUD. Highest demo payoff in
the product if it lands ("three Mail replies typing at once while you keep scrolling").

## Sequencing relative to other work

1. Parity refactor `AgentRuntime` + `ActionExecutor` (B1–B2) lands first.
2. Ghost P1 spike (`GhostWindowExecutor` + one ghost), flagged off.
3. Ghost P2/P3 only after the spike proves the physics.
