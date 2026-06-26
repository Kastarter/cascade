---
name: keynote
description: Use when controlling Apple Keynote — slides, placeholders, tables, charts, layouts, presenter notes, play mode, and export.
useWhen: any work in Apple Keynote (or Keynote Creator Studio) — building or editing slides, decks, presentations
---

# Keynote

Keynote is a standard Mac app: placeholders, sidebars, and menus all respond
to normal clicking and typing. Two builds exist — legacy "Keynote" (14.x,
frozen; shows a daily upgrade nag at launch — dismiss it) and "Keynote
Creator Studio" (15.x; some themes and menu items carry subscription badges —
a subscribe sheet is a paywall, not an error: back out and pick a non-badged
option). Open Keynote (or Numbers/Pages) with your open_app tool, never via
Spotlight.

For business/consulting deck recipes pull `keynote-consulting` too. Pull
`keynote-applescript` ONLY when the user's own words ask for a script, or for
file exports — deck building is screen work the user watches; scripting it
abandons that work (and Cascade will refuse the script).

## Pacing — make turns count

Every round trip costs the user seconds of a motionless cursor. A sequence
you can already predict from the current screenshot is ONE chained turn, and
the NEXT turn's screenshot is the check — no look-only turns in between:
double-click a placeholder → `cmd+a` → type is one turn; click a field →
`cmd+a` → type → `Return` is one turn; `cmd+shift+n` → double-click the new
slide's title → type is one turn. For ANY text entry, the `fill_field` tool IS
that one turn — it clicks the spot, selects what's there, types, and presses
the finisher in a single call (`click:double`, `submit:cmd_return` for a title
or body placeholder; `submit:return` for a sidebar field). Go one-action-solo
only when the next step depends on what appears: the theme chooser, a
just-inserted table or chart, an unfamiliar dialog, Edit Chart Data.

## Documents and themes

- `cmd+n` opens the theme chooser, a modal gallery. DOUBLE-click a theme to
  create the deck — a single click does nothing useful. `Escape` closes the
  chooser. For business decks pick `Basic White`.
- If a macOS Open panel appears instead, click `New Document` at its bottom
  left to reach the chooser.
- A freshly picked theme can render blurry for a few seconds — it is still
  downloading. Wait and re-screenshot before judging anything.
- Keynote AUTOSAVES. Never press `cmd+s` unless asked to save/name the file;
  the first save opens a name + Where sheet — fill it deliberately, don't
  Escape-spam it.

## Focus model — where typing lands

Three input zones; the same keys do different things in each. Always click
where you intend to type, then confirm from the screenshot.

- Slide NAVIGATOR (left thumbnails): `Return` creates a NEW SLIDE, `Tab`
  indents the slide, `Delete` deletes it. After ANY thumbnail click the
  navigator has focus — click the canvas before typing. If the slide count
  grew unexpectedly, a stray `Return` landed here: `cmd+z`.
- CANVAS with an object selected (one click → handles): `Tab` jumps to the
  next object, arrow keys MOVE it (1 pt; `shift`+arrow 10 pt), `Delete`
  deletes it. Typing right after a SINGLE click on a text box REPLACES its
  entire content.
- TEXT EDITING (insertion point visible): a second single click inside a
  selected box places the cursor; double-clicking a placeholder clears its
  prompt text and edits. Leave text editing with `cmd+return` (ends editing,
  keeps the box selected). Do NOT use `Escape` to leave text — it can pop a
  word-completion list instead of deselecting.

## When a click seems to do nothing

Never re-click the same point again and again — "nothing happened" is a mode
signal, not a missed click. You get ONE corrective re-aim per control (aim at
the control itself — a checkbox is the small box LEFT of its label, not the
word); if the next screenshot still shows no change, the route is wrong —
switch to a menu, the toolbar, or a different control. A third click at the
same point is never the answer (a real run burned six turns alternating
clicks and zooms on one checkbox). Otherwise, screenshot and classify:

- Object shows no handles when clicked → it is LOCKED (Arrange > Unlock) or
  belongs to the slide LAYOUT and can't be edited from a normal slide.
- The whole window vanished → you pressed `cmd+h` and HID the app — bring it
  back with open_app.
- Bare full-screen slide, no toolbar → play mode; press `Escape` (or `q`).
- Blue bar with a `Done` button at the bottom and layout names in the
  navigator → you're in EDIT SLIDE LAYOUT mode; click `Done`, then redo the
  edit on the slide itself.
- Overlapping objects: click the top one, then `Tab`/`shift+Tab` cycles down
  the stack; or open View > Show Object List for a layers panel. An UNFILLED
  box or thin line only selects from its EDGE, not its middle.

## Set values in fields — don't mash keys

- Font size: select the text or box → Format sidebar > `Text` tab →
  `fill_field` the size field with the number (`submit:return`). NEVER hammer
  `cmd+plus` repeatedly.
- Position and size: Format > `Arrange` tab → Position X/Y (the object's
  upper-LEFT corner) and Size W/H — `fill_field` each (`submit:return`, or
  `submit:tab` to jump to the next field). This is how you "move the title
  up": set Y once.
- One key event per key ACTION (several key actions still chain in the same
  turn); modifiers are only cmd/shift/option/ctrl. To press a key N times
  send N separate actions — and if N would exceed ~3, stop: there is a
  numeric field or menu item that does it in one step.
- Arrow nudges (1 pt / 10 pt with shift) are for a final touch-up only.

## Text and placeholders

- Layout placeholders read "Double-click to edit". One click selects the
  box; double-click enters it. To replace existing text: double-click,
  `cmd+a`, type.
- Text in boxes AUTO-SHRINKS to fit: if rendered type looks smaller than the
  size you set, the box overflowed — enlarge the box or cut words; don't
  re-send the font size. A small `+` badge at a box's bottom edge means
  clipped overflow text, NOT failed typing.
- Filling placeholders — name the prompt text you SEE: each placeholder shows
  its own prompt ("Presentation Title", "Presentation Subtitle", "Author and
  Date", "Title", "Subtitle", etc.). Target that VISIBLE prompt text and fill it
  (`fill_field` / type-with-target: `click:double`, `submit:cmd_return`) —
  double-click enters the box, `cmd+a` selects, type replaces, `cmd+return`
  exits. The on-screen text is located by OCR, so naming the prompt you can read
  lands on the right box every time — no coordinate guessing.
- Fill EACH placeholder separately by its own prompt text. Do NOT press `Tab` to
  hop between placeholders and then type: on a slide, `Tab` only SELECTS the next
  object — typing or pasting onto a merely-selected (not edited) box drops a NEW
  floating text box on top of the slide instead of replacing the placeholder
  (this is the audited "made three text boxes, left the placeholders blank" bug).
  One named fill per placeholder; if a layout has no such placeholder, there is
  nothing to fill — don't force one.
- Go to the sidebar ONLY if the canvas truly shows no title box: click empty
  canvas (deselect all) → Format sidebar `Slide` tab shows `Title` / `Body`
  checkboxes → check `Title` ONCE; the next screenshot must show a title box
  ON THE CANVAS — then work in that box, the checkbox's job is done. One
  re-aim at the checkbox maximum; still nothing → toolbar `Text` button
  instead. Never alternate clicks between canvas and checkbox hoping for a
  reaction.
- If rendered text differs from what you sent — curly quotes, capitalized
  words, a typed "1." turned into a list bullet — auto-correction fired on
  typed text. It is not a typing failure: NEVER blind-retype (it
  duplicates). Pasted text skips substitutions. If it keeps biting, uncheck
  the offenders in Keynote > Settings > Auto-Correction (smart quotes,
  capitalize words, detect lists).
- Prefer layout placeholders over free text boxes — consistent position and
  type across slides.

## Exact geometry and alignment

- Dragging snaps to alignment guides; hold `cmd` while dragging to suppress
  snapping — or skip dragging and set X/Y in Arrange.
- To line up SEVERAL objects, never nudge them one by one: `shift`+click
  each (or drag a marquee STARTING ON EMPTY canvas), then Format > Arrange →
  Align / Distribute pop-ups.
- Any window resize or zoom change invalidates every coordinate you
  remember — re-screenshot. The Format sidebar's contents swap with every
  selection change — re-locate its controls each time; never reuse
  remembered sidebar coordinates.

## Shortcuts — safe list and danger list

Safe (verified defaults): `cmd+shift+n` new slide; `cmd+d` duplicate (slide
in navigator, object on canvas — the copy lands slightly offset and
SELECTED: move it before clicking anything); `Delete` in navigator deletes
the slide; `cmd+shift+h` skip slide; `cmd+option+g` group /
`cmd+option+shift+g` ungroup; `shift+cmd+f` front / `shift+cmd+b` back;
`cmd+option+c` / `cmd+option+v` copy / paste style; `cmd+b`/`cmd+i`/`cmd+u`;
`cmd+shift+p` presenter notes; `cmd+return` end text editing; `cmd+z` undo.

DANGER: `cmd+h` HIDES Keynote, `cmd+q` QUITS it, `cmd+f` opens Find,
`cmd+option+p` starts the slideshow. Never guess a shortcut — anything not
in the safe list goes through the MENU BAR. Menus never collapse; toolbar
buttons DO disappear when the window is narrow (no Table/Chart button ≠ no
feature — use the Insert menu).

## Tables

- Toolbar `Table` button → style gallery (side arrows page styles) → click
  one to insert.
- Fill cell-by-cell: single-click a cell and TYPE (replaces its content),
  `Tab` → next column, `Return` → next row. Double-click only to EDIT
  existing content. `option+return` makes a line break inside a cell.
- NEVER paste several cells' worth of text in one go — it all lands in ONE
  cell. One cell, one type action.
- Rows control at the table's BOTTOM-LEFT, columns at the TOP-RIGHT — click
  their arrows. Mid-table: `ctrl`+click a cell → Add/Delete Row/Column.
  Header rows: Format → `Table` tab → Headers & Footers pop-ups.
- The small yellow dot on a cell selection is AUTOFILL — dragging it copies
  content across cells (`cmd+z` fixes).
- Done with the table: click outside it twice (leaves the cell, then
  deselects the table).

## Charts

- Toolbar `Chart` button → 2D / 3D / Interactive tabs — use 2D → click a
  style.
- Select the chart → `Edit Chart Data` → a FLOATING editor opens; edits
  apply live, and any click OUTSIDE its edge closes it and deselects the
  chart. Keep every click inside the panel until the data is done.
- Recolor: chart selected → Format → `Chart` tab palettes; one series →
  click one of its bars → `Style` tab.

## Slides, layouts, presenter notes, images

- `Add Slide` (toolbar) opens the layout picker — read the real layout names
  from it (typical: Title & Subtitle, Title & Bullets, Title - Center,
  Title - Top, Bullets, Quote, Photo, Blank).
- Change a slide's layout: click its navigator thumbnail → Format sidebar →
  the layout button near the top → pick.
- Outline view (toolbar View → Outline) is the fastest way to enter a whole
  deck's text: type a title, `Return` for the next slide, `Tab` to demote
  the line to a bullet, `shift+Tab` to promote back to a new slide.
- Presenter notes: `cmd+shift+p` opens a white pane below the canvas. Click
  INTO the pane before typing; click back on the slide when done.
- Images: toolbar `Media` → Choose, or drag from Finder. Double-click an
  image = crop/mask mode — click `Done` to leave. Replace without
  re-layout: Format → `Image` tab → Replace.

## Play mode — input trap

`cmd+option+p` (or an auto-play file opening) shows a bare full-screen slide
and CAPTURES every key and click until `Escape` or `q`. Never start playback
unless asked. A full-screen slide right after opening a file means play
mode, not a broken launch.

## Export

- File → Export To → PDF / PowerPoint / Images → options sheet → name +
  Where sheet → `Export`. If the user wants a file, export it — the open
  .key document is not the deliverable.
- Don't claim done until a fresh screenshot shows the expected content —
  auto-shrink, focus traps, and replaced cell text all fail silently.

```cascade-runtime-hints
{
  "appMatchers": {
    "bundleIdentifiers": ["com.apple.Keynote", "com.apple.iWork.Keynote"],
    "names": ["Keynote"]
  },
  "axUnreliable": true
}
```

<!-- axUnreliable: the iWork SLIDE CANVAS is NOT faithfully in the accessibility
tree — AX exposes slide placeholders as wide AXTextAreas whose geometric CENTER is
empty space, so an AX-first grounder returns a point off the text and a double-click
there spawns a NEW text box (audited: "Presentation Title" grounded to (1304,637),
the empty upper-right of the box). Flagging axUnreliable skips the AX grounding tier
for Keynote, so a named target resolves by OCR (the visible prompt text, located
exactly) then the visual grounder. Chrome (menus, buttons) still grounds fine — it's
visible text too. -->

