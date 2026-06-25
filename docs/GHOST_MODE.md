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

## Audit signals
Every ghost action is audited so a run is debuggable:
`ghost.press` (AX press/focus landed), `ghost.type` (AX insert landed),
`ghost.fallback` (AX missed → real cursor-restoring click).

## Prior art (validated by research; see `docs/THIRD_PARTY_NOTICES.md`)
The AX-press-by-pid-first / CGEvent-fallback architecture is what the leading
open-source macOS computer-use agents do: `steipete/AXorcist`, `ghostwright/ghost-os`
(built on AXorcist), Hammerspoon's `hs.axuielement`, and `vimac`. Apple's
`AXUIElement.h` header confirms that passing an application element restricts the
hit-test to that application (the linchpin), while the system-wide element returns
"whichever window is topmost."
