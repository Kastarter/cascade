# Ghost Agents — parallel window-scoped computer use (plan)

The vision: a swarm hotkey spawns N agents, each with its own visible colored
cursor, working different windows AT THE SAME TIME — without taking keyboard
focus or the user's screen — all reporting to a main agent that splits the
job and grades the results (Claude Code's lead/subagent pattern, on the Mac).

## Why this is possible without focus

A normal agent uses the shared HID input stream and whole-display capture —
that's why only one can act. A **ghost agent** is bound to ONE (pid, windowID):

- **Sees** through `SCContentFilter(desktopIndependentWindow:)` — captures
  that window's pixels even when it's behind other windows.
- **Acts** through `CGEvent.postToPid` (clicks + keys delivered straight to
  the app's process, coordinates mapped through the window's live frame from
  CGWindowList) and AX actions (press/focus/setValue) on that window's tree.
- **Shows itself** two ways: a small live watch panel (the sandbox-box
  pattern: window snapshot + the ghost's cursor drawn on it), and — when the
  window is actually visible on screen — a colored companion cursor overlay
  at its position. Multiple visible cursors, honestly earned.

The user's keyboard focus, frontmost app, and real pointer are never touched.

## Architecture (mirrors what exists — nothing is rewritten)

```
                    ┌─ main agent (planner + synthesizer) ─┐
   one goal  ──────►│  splits into lanes, budgets, grades  │────► one answer
                    └──────────────┬───────────────────────┘
            ┌──────────────┬───────┴────────┬─────────────────┐
        WEB lane       GHOST lane       GHOST lane       SCREEN lane
     BackgroundWeb    GhostWindow      GhostWindow      the existing
     Agent (exists)   Agent (new)      Agent (new)      foreground agent,
     sandbox box      Notes window     Numbers window   SERIAL queue
```

- **Lane routing** (the planner already decomposes): web → sandbox box;
  work that lives in one app window → ghost; anything needing app
  activation, menus, system dialogs, or cross-app flow → the serial
  foreground queue. The foreground cursor stays exactly as it is today.
- **Auto-fallback is the safety net**: every ghost action is verified by
  re-capturing its window (same fingerprint idea as recipe replay). Two
  unverified actions → the subtask reroutes to the foreground queue and the
  HUD says so. Apps that ignore unfocused input degrade gracefully instead
  of failing the job.

## New pieces (and what they reuse)

1. `GhostWindowAgent` (ComputerUseKit/SandboxKit sibling) — the same
   ComputerUseAgent brain (vision loop, caching, skills) with: window-capture
   observe, postToPid/AX act, window-frame coordinate mapping. ~the
   BackgroundWebAgent shape with a different actuator.
2. `GhostBoxController` — clone of SandboxBoxController: one watch panel per
   ghost (live window snapshot + drawn cursor + status + STOP).
3. Ghost cursor overlay — GuidanceOverlay already draws a companion cursor;
   add per-agent color + N instances, shown only while the target window is
   visibly on screen.
4. Swarm intent + HUD — "split this up…" phrasing or ⌃⌥⇧Space; mission
   control panel: per subagent task, lane, steps used/budget, verdict
   (done / rerouted / failed), and the main agent's synthesis at the end.
   Per-subtask metrics come from what already exists: step counts, completion,
   findings; every ghost action audited as `ghost.<n>.<action>`.

## Why it can't harm existing features

- New driver + new entry point; the foreground actuator, hotkey, replay,
  sandbox agents are untouched.
- postToPid events bypass the HID tap, so the InputRecorder never records
  ghost work — workflow detection can't be polluted by agents.
- Same permission set (SR + AX + Input Monitoring), same PrivacyRules gates on
  every ghost frame, same STOP semantics: per-ghost stop in its panel, Esc
  stops everything.
- Reliability risk is contained by lane routing + verified actions +
  foreground fallback: worst case, a ghost subtask runs serially like today.

## Build order

1. **P1 — one ghost, end to end**: bind to a TextEdit/Notes window, type a
   document while the user keeps focus elsewhere; watch panel + verify loop.
   This proves the input+capture physics in our codebase.
2. **P2 — the swarm**: planner lanes, N ghosts + sandbox boxes in parallel,
   HUD with budgets/metrics, synthesis, colored cursors.
3. **P3 — compatibility pass**: per-app matrix (AppKit vs Catalyst vs
   Electron), fallback tuning, then the demo cases below become the test
   suite.

## Wow use cases (each is a demo scene)

1. **The triple draft** — "draft replies to these three emails": three Mail
   compose windows, three colored cursors typing three different replies
   SIMULTANEOUSLY, while the user keeps scrolling their own browser in front.
   The single most legible "parallel agents" shot that exists.
2. **Research swarm with a scribe** — two sandbox boxes hunt prices on the
   web while a ghost fills the comparison into a Numbers window as findings
   arrive; the main agent announces the winner with the sheet done.
3. **Document factory** — "each of these four sections goes in its own Pages
   file": four windows being written at once, user untouched.
4. **The watcher** — a ghost pinned to a dashboard window in the corner; it
   pings (and logs) when the number it's watching moves — while everything
   else continues.
5. **Work next to me** — the user genuinely keeps typing in their editor in
   the foreground while a ghost reorganizes their Notes in a visible side
   window: human and agent working the same desktop at the same time.
6. **Pipeline** — ghost A extracts rows from a report window, main agent
   routes them, ghost B enters them in the form window: an assembly line you
   can watch.
