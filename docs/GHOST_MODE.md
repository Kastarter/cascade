# Ghost mode — visible cursor, non-blocking work

**Goal (user's words):** "I want to see the cursor move on the screen and do the work
while I'm working — visible to me, but it doesn't prevent me from doing my work."

Ghost mode lets the on-screen agent act **without touching the system cursor or
stealing keyboard focus**, so you can keep using your machine while a translucent
companion cursor shows you what the agent is doing.

It is **OFF by default**. Turn it on in **Settings → "Ghost mode (work alongside
me)"**, or:

```
defaults write com.humain.cascade cascade.ghostMode -bool YES
```

## Why "transparent cursor" alone doesn't solve it

macOS has exactly **one** system cursor and **one** input focus. Making the cursor
image transparent changes nothing about where clicks and keystrokes land — they
still go to your focused window and interrupt you. The real fix is to **decouple the
agent's input from yours**: deliver the action without moving the shared cursor.

## Two layers

### 1. The visible layer (cosmetic) — already existed
`GuidanceOverlay` draws a click-through, always-on-top **companion cursor** that
flies to each target, ripples on press, and pulses while the model thinks. Ghost
mode renders it **semi-transparent** (`setGhost(true)`, ~0.6 opacity) so it reads
clearly as *the agent's* cursor working next to yours — present and visible, but
unmistakably not your real pointer. The overlay never intercepts input
(`ignoresMouseEvents = true`), so it can't block you.

### 2. The dispatch layer (the real work) — `GhostActuator`
This is the new piece. When ghost mode is on, `executeCU` routes actions through
`GhostActuator`, targeting the agent's app **by PID**:

- **Click / right-click →** `AXUIElementPerformAction(kAXPressAction / kAXShowMenuAction)`
  on the control found by `AXUIElementCopyElementAtPosition(appElement, x, y)`.
  Hit-testing against the **app's own** element (not the system-wide one) reaches
  that app's controls even when another window is on top at that screen point, and
  the press is a logical message — **zero cursor movement, no focus steal, works on a
  background/occluded window.**
- **Type →** set `kAXSelectedText` on the app's focused element. No clipboard, no
  keystrokes the user's focus could intercept. The write is **verified by reading the
  value back** (web `<input>`/comboboxes accept the set and report success while the
  value never changes — the audited phantom "can't type").
- **Keys →** already post to the target PID via `CGEvent.postToPid` (existing path),
  so they don't move the cursor.

### What ghost mode deliberately does NOT do
- **No synthetic mouse events as the primary path.** A pid-posted mouse click is
  unreliable — many apps read the *global* cursor position, so the click lands at the
  user's real pointer, not the target. That approach was built and **reverted** once
  (see CLAUDE.md, 2026-06-22). AX-press is primary; pid-mouse is not used.
- **No silent cursor warp on failure.** When AX can't press a target (canvas/Electron
  leaf, unlabeled element, multi-line caret placement), `GhostActuator` returns
  `.missed` and the caller **degrades to the proven cursor-restoring CGEvent click**
  so the task still progresses — and audits `ghost.fallback`. Double/triple click,
  drag, scroll, and bare moves have no cursor-free AX equivalent, so they always keep
  the cursor-restoring path.

## Honest limits
- **Same app = conflict.** There is one text caret / selection / focus *per app*. If
  the agent works in App B while you work in App A, great. If you both touch App A at
  once, you fight — unavoidable on macOS.
- **AX-blind apps degrade.** Canvas apps (Blender/Figma/Photoshop, gated off via
  `axUnreliable`) and Electron/Chromium apps that haven't opted into accessibility
  expose few/no pressable elements, so ghost mode falls back to a real click for
  those (briefly disrupting you). Coverage there is a follow-up — see below.
- **"AXPress success" can lie.** The API can report success while the app ignored the
  press. Cascade's existing **no-effect detector** (grid-hash frame diff) is the
  backstop: a press that changed nothing is caught and re-grounded just like any other
  dead action — ghost mode rides that scaffolding unchanged.
- **Scope of this PR:** the *single on-screen agent* becomes non-blocking. Running N
  agents on different apps in parallel (the reverted multi-cursor effort) is separate
  and not part of this.

## Follow-ups (researched, not in this PR)
- **Electron/Chromium coverage** via per-app `AXManualAccessibility = true` (the
  canonical recipe to force the full a11y tree). Deferred: it mutates the target app's
  accessibility mode, builds asynchronously, and can't be runtime-verified here yet.
  Prefer it over `AXEnhancedUserInterface`, which breaks window managers (Magnet etc.).
- **True background capture** (act on an app that is fully occluded behind yours)
  needs occluded-window screenshotting — the larger piece noted in CLAUDE.md.

## Background mode — work *behind* your window

Plain ghost mode stops the agent from stealing your cursor/keyboard, but it still
works in the **foreground** (the target app is on top), because the agent screenshots
the visible screen each turn to decide what to do. **Background mode** closes that
last gap: the agent captures the target window's pixels **even when it's hidden
behind your window**, so it never has to come forward.

Turn it on in **Settings → Ghost mode → "…behind my window"** (requires ghost mode),
or:
```
defaults write com.humain.cascade cascade.ghostMode -bool YES
defaults write com.humain.cascade cascade.ghostBackground -bool YES
```

**How it works**
- **Perception:** `ScreenCaptureUtility.captureWindowJPEG(pid:)` captures just the
  target app's main window via `SCContentFilter(desktopIndependentWindow:)` — it
  works on an occluded window, so the agent sees the app without it being frontmost.
  (Recovered from the 2026-06-22 revert; that part was always sound.)
- **Coordinates:** the window is treated as the agent's "display"; the model's
  window-local points are mapped to global screen points by `NativeWindowMapping`
  (pure + unit-pinned — a wrong flip presses the wrong row).
- **Action:** the same `GhostActuator` AX-press / AX-insert by PID. AX hit-testing by
  position reaches the target's controls even fully occluded (Apple's `AXUIElement.h`:
  passing an app element restricts the hit-test to that app).
- **Trigger:** an action task that names a running native app (e.g. *"in Notes,
  make a checklist…"*) routes here automatically; if no app is named or it isn't
  running, it falls back to the normal foreground flow. There's also a **"Try it on
  Notes"** button in Settings for a one-click test.

**Extra limits specific to background mode (honest):**
- **The target app must already be running** (we never launch+position a window
  behind yours — too surprising). Open it first.
- **App-command shortcuts (⌘N, ⌘S, ⌘F…) are pressed via the AX MENU BAR**, not
  posted as keys — `GhostActuator.pressMenuShortcut` walks the app's menu bar, matches
  the item's command-key equivalent, and AXPresses it. This works reliably on a
  background window — it's why "create a new note" = ⌘N → File ▸ New Note now lands;
  a raw posted ⌘N did not. Audited as `ghost.bg.menu`.
- **Bare keys (Enter/Tab/Escape/arrows) remain best-effort** — no menu item exists,
  so they fall to `CGEvent.postToPid`, which some apps ignore when not frontmost. The
  agent is told to prefer clicking buttons over pressing Return; drag and scroll are
  skipped. So background mode is strongest for **click, type into fields, and menu
  commands**.
- **AX-blind apps** (canvas, Electron-not-opted-in) expose nothing to press, so a
  background run on them will mostly miss — use a native app.
- Still the **single** agent — one task at a time, not N parallel.

## Audit signals
Every ghost action is audited so a run is debuggable.

Foreground ghost mode: `ghost.press` (AX press/focus landed), `ghost.type` (AX
insert landed), `ghost.fallback` (AX missed → real cursor-restoring click).

Background mode: `ghost.bg.start` / `ghost.bg.done`, `ghost.bg.press` (AX press
landed on the hidden window), `ghost.bg.type`, `ghost.bg.menu` (app command pressed
via the menu bar), `ghost.bg.key` (best-effort posted bare key), `ghost.bg.miss` (AX
couldn't reach it — no fallback, the no-effect detector re-grounds), `ghost.bg.skip`
(drag/scroll), `ghost.bg.stalled` / `ghost.bg.noeffect`.

```
sqlite3 "$HOME/Library/Application Support/Cascade/Cascade.sqlite" \
  "select created_at, action, detail from audit_event where action like 'ghost.%' order by id desc limit 30;"
```

## Prior art (validated by research; see `docs/THIRD_PARTY_NOTICES.md`)
The AX-press-by-pid-first / CGEvent-fallback architecture is what the leading
open-source macOS computer-use agents do: `steipete/AXorcist`, `ghostwright/ghost-os`
(built on AXorcist), Hammerspoon's `hs.axuielement`, and `vimac`. Apple's
`AXUIElement.h` header confirms that passing an application element restricts the
hit-test to that application (the linchpin), while the system-wide element returns
"whichever window is topmost."
