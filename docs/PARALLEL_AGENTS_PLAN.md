# Parallel on-screen agents (multi-cursor, real work)

Goal: more than one agent doing **real work on real native macOS apps at the same
time**, while the user keeps using their Mac — each agent shown by its own
translucent companion cursor (the visual layer already shipped).

## The hard constraint
macOS has exactly **one real system cursor and one real HID event stream**. Two
agents that both move the pointer + click would fight each other and hijack the
user's mouse. So parallel agents **cannot** use the shared cursor. The route is
**pid-posted events**: inject each agent's clicks/keystrokes straight into its
target app's process via `CGEvent.postToPid`, with no cursor movement and no
focus steal. Keys already do this (`post(_:pid:)`); the new piece is **mouse**.

This is the one make-or-break unknown. Cascade's multi-cursor research found it
viable (the `axcli` recipe), but it's unverified in Cascade and varies per app
(hover menus/tooltips and some dialogs may still need the real cursor). The
design isolates it so we can prove it before trusting it.

## Architecture (3 layers)

### Layer 1 — `PidEventActuator` (ComputerUseKit)  ← the linchpin
Posts a `ComputerUseAction` (global CG coords) to a **specific pid** via
`postToPid`, never the global HID tap, so it cannot move the user's cursor:
- pre-send a `mouseMoved` to the pid (pointer-tracking apps read button events at
  the last moved-to position — the Blender lesson, generalized);
- then `leftMouseDown`/`Up` (and double/right/drag/scroll) to the pid;
- keys/typing reuse the existing pid path.
Multiple actuators bound to different pids never conflict.

### Layer 2 — per-window capture + the agent loop
- `WindowCapture` (MacContextKit): find an app's main window via
  `SCShareableContent` and capture **just that window** (even when it's behind
  the user's active window) with `SCContentFilter(desktopIndependentWindow:)`,
  at `AgentResolution.best(window.size)`, returning JPEG + the window's global CG
  frame.
- `BackgroundNativeAgent` (AppShell): binds `(appName, pid, window)`; runs a
  `ComputerUseAgent` loop where the "display" IS the window — capture the window
  → model → translate model-pixel → window → global CG → `PidEventActuator` →
  re-observe. Carries the structural guards (no-effect via window-signature,
  stall) and a companion cursor that flies/clicks to show the work. Runs as a
  detached async task, so N agents run concurrently.

### Layer 3 — orchestration + entry
- `CascadeAppModel` spawns/tracks/stops N `BackgroundNativeAgent`s, one companion
  cursor each. STOP halts all; every action audited.
- Entry: the existing "in the background, do X" path routes a task that names a
  **native** app to a `BackgroundNativeAgent` (vs a web task → the web sandbox).
  Plus a Settings/debug launcher for testing.

## Coordinate flow (the precise bit)
`ComputerUseAgent` scales model pixels → display-local AppKit (bottom-left) using
the dims passed to `begin`. We pass the **window** size, so its action coords are
**window-local AppKit (bottom-left)**. Convert to global CG (top-left) for the
pid post:
```
globalCG.x = windowFrame.minX + localAppKit.x
globalCG.y = windowFrame.minY + (windowFrame.height - localAppKit.y)
```
(`SCWindow.frame` is already global CG top-left.) This is pure + unit-tested — a
wrong flip clicks the wrong row.

## Verification ladder (because it's unverified)
1. **Prove pid-posted mouse**: a background click that lands without moving the
   user's cursor or stealing focus. If this fails → fall back to a second login
   session / VM (out of scope here).
2. **One** background-native agent finishing a task in one app while the user
   works.
3. **N** agents, N apps, N cursors, live.

## Status
v1 implemented end-to-end; **runtime-unverified** (pid-posted mouse, background
window capture, and coordinate mapping all need a live test). Build the trust by
walking the ladder above, not by assuming it works.
