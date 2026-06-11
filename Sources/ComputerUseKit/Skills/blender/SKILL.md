---
name: blender
description: Use when controlling Blender — menus, modal transforms, exact dimensions, edit mode, viewport navigation, and keyboard workflows.
useWhen: any work in Blender — 3D modeling, transforms, adding/deleting objects, edit mode, importing models
attribution: Adapted from milind-soni/tiptour-macos TipTour/Skills/blender/SKILL.md (MIT)
---

# Blender

Blender is a canvas app: macOS accessibility cannot see its menus, viewport, or
modal tool state. Work purely from screenshots. Zoom in when a menu label or
number field is too small to read confidently.

Read the mode from the viewport header's top-left dropdown — it literally says
`Object Mode` or `Edit Mode`. `Tab` toggles between them (pointer over the
viewport). `Escape` never exits Edit Mode — only `Tab` does.

Viewport objects (a cube, a wall, a roof) are different from UI labels. A mesh
has no clickable label on the canvas — click it at its visual coordinates from
a fresh screenshot. Never click lookalike text in the Outliner or Properties
sidebar when you mean a viewport object or an open menu item.

To CREATE anything — an object, prop, food, vehicle, character, scene —
pull `blender-modeling` for the decompose-and-blockout method; for
buildings, offices, rooms, or furniture pull `blender-archviz` too.
ALL modeling happens in the viewport with the cursor and keyboard: exact
sizes are typed into N-panel fields, repeated parts are duplicates
(`shift+D`, `alt+D` linked) or an Array modifier. There is no scripting lane
in Blender work — never open the Scripting workspace, the Python console, or
the Text Editor, no matter how big, precise, or repetitive the build looks.

## Pointer rules

Blender routes keys to the editor at the pointer position it last saw.
Cascade handles the mechanics: it re-teaches Blender your last click/hover
point before every key press, then returns the user's cursor — Blender keeps
acting at YOUR last click or hover even though the visible cursor goes home.
You must still keep the interaction inside the 3D viewport:

- Hotkeys (`G`/`S`/`R`/`Tab`/`N`) need the pointer OVER the viewport. Hovering
  is enough — do not click to "focus": clicking empty viewport space DESELECTS
  everything and also destroys the adjust-last-operation panel. To position
  the pointer safely, click the object you are working on.
- Never right-click in the viewport (context menu), and never
  shift+right-click (it moves the 3D cursor).
- `Shift+A` opens the Add menu at the pointer — take a fresh screenshot to see
  where it landed.
- Never press bare number keys in Object Mode — in Blender 4.x they hide
  collections and the scene "vanishes" (undo will NOT bring it back; you must
  re-enable collections in the Outliner). Numbers are safe only inside a
  modal transform or in Edit Mode.

## Modal transforms — one chained sequence per turn

Transforms are keyboard-modal sequences: `G` (move), `S` (scale), `R`
(rotate), then an axis key `X`/`Y`/`Z`, then the numeric value, then `Return`
to confirm (`Escape` cancels and fully reverts).

- Each token is its OWN action (press `S`, press `X`, type `3`, press
  `Return` — never one combined keystroke string), but a transform whose
  axis and value you already know is ONE TURN: click the object first (that
  parks the pointer over the viewport AND proves selection), then chain the
  whole sequence in the same turn — click, `S`, `X`, `3`, `Return` — and
  verify the result in the next screenshot (N-panel numbers or the
  viewport). Waiting for a screenshot between tokens you already know wastes
  five seconds per keypress.
- Batch ONE transform per turn, never two: a move and a scale chained
  blindly compound a miss. If the result looks wrong, `cmd+z` once and redo
  that transform with single stepped tokens, reading the header readout
  between tokens.
- Mouse-driven or stateful modals (loop cut, bevel, extrude-then-drag) stay
  stepped one token at a time — their state is only readable between tokens.
- ALWAYS send the axis key for moves — `G` plus a number with no axis moves
  along X silently.
- READ the modal state from the screenshot: during a modal, the viewport
  header replaces its menus with a live readout such as
  `D: 1.5 (1.5) along global Z axis`, `Scale X: 2.00 Y: 2.00 Z: 2.00`, or
  `Rotation: 45.00 along global Z axis`. Readout present = mid-modal; menus
  restored = no modal active. Confirm the value and axis there before
  pressing `Return`.
- Never press `S` (or `G`/`R`) twice unless the previous transform was
  cancelled with `Escape`.
- Numeric input must be the plain value only — digits, `.`, `-` (for example
  `3` or `-1.5`). Cascade delivers it as real keystrokes automatically; do
  not try to paste numbers.

## Exact values — sidebar and adjust panel

- `N` toggles the sidebar (pointer over viewport). Item tab → Transform:
  Location, Rotation, Scale, and Dimensions fields. Setting Dimensions X/Y/Z
  is how you make real-world sizes (a 4 × 0.2 × 2.5 m wall) — more reliable
  than chained scale modals.
- Editing a field: ONE clean single click in the CENTER of the field (the
  edges have hidden `<` `>` step arrows, and any click-drag scrubs the
  value), then type the number. `Tab` commits and jumps to the next field
  (X→Y→Z), `Return` commits, `Escape` reverts.
- A full Dimensions entry is ONE TURN: click the X field, type the value,
  `Tab`, type Y, `Tab`, type Z, `Return` — chain it all; `Tab` commits and
  advances by itself, so nothing needs re-observing between fields. Verify
  all three numbers in the next screenshot.
- REPLACING a value: click the field ONCE, then use the type action, then
  `Return` — Cascade's typing clears Blender fields automatically (it
  selects all before delivering), so the new value REPLACES the old one.
  Never press `ctrl+v` or `cmd+v` yourself to enter content: that pastes
  whatever the USER last copied and corrupts the field (hex soup like
  `FFFFFFCFCBC3`). Never triple-click a field either — a single click
  enters edit mode with the content selected. Fix a botched field with
  `ctrl+a` and retype — never with repeated Delete.
- After any Add or tool operation, the Adjust Last Operation panel
  (bottom-left of the viewport, or press `F9`) re-runs it with exact values —
  e.g. after Add → Cube set its Size and Location numerically. It DIES on the
  next operator, including a stray click that changes selection. Use it
  immediately or lose it.

## Menus, search, and pies

- Add objects through `Shift+A` (or the `Add` menu), then `Mesh`, then the
  type. After any submenu opens, take a fresh screenshot before clicking —
  menu contents and positions change.
- Menus and popups stay open until you click an item or press `Escape`
  (Blender 5.x) — and an open menu EATS your next click: clicking anywhere
  else only dismisses it, the thing you aimed at is NOT clicked. If a menu
  you didn't want is visible in your screenshot, press `Escape` first.
- `F3` opens menu search — the universal fallback when you cannot find or
  reach something: hover the viewport, press `F3`, type the operation name
  ("loop cut", "shade smooth", "subdivide"), click the result row. That is
  exactly equivalent to clicking the menu item.
- If a pie menu opens (`Z` shading, backtick view, `Shift+S` snap), `Escape`
  is the ONLY safe dismissal — clicking anywhere activates the nearest wedge.
  Use `Shift+Z` for wireframe instead of the `Z` pie.
- Do not use bare accelerator letters such as `M`, `P`, or `C` unless the
  correct popup is visibly open in your latest screenshot. `M` is Merge in
  Edit Mode but Move-to-Collection in Object Mode.

## Edit mode toolbox

With the pointer over the viewport: `Tab` enter/exit, `1`/`2`/`3`
vertex/edge/face select (Edit Mode only), `A` select all, `Alt+A` deselect.

- `E` extrude (a move modal follows — axis, number, `Return`). `Escape`
  during the move still KEEPS the new geometry stacked in place; press
  `cmd+z` if the extrude itself was a mistake.
- `I` inset faces; `Ctrl+B` bevel (type a width, then `Return`; refine in the
  F9 panel).
- `Ctrl+R` loop cut, exact dance: press `ctrl+r`, hover the face so the
  yellow preview appears, type the cut count, left-click once, then press
  `Escape` — that leaves clean, perfectly centered cuts. (`Escape` BEFORE the
  click aborts entirely.)
- `F` fills a face from selected verts/edges; `X` opens the delete menu.
- macOS keys: editing chords work as real `ctrl` (`ctrl+r`, `ctrl+b`);
  system-style ones use `cmd` (`cmd+s` save, `cmd+z` undo).

## Viewport navigation — no numpad, no middle mouse

- `View` menu → `Viewpoint` → Front/Right/Top/Camera for exact angles;
  `View` → `Frame Selected` to center on the selection; `home` key = Frame
  All.
- The navigation gizmo (top-right of viewport): single-click an axis label to
  snap to that orthographic view; click the same label again to flip to the
  opposite side; drag the ball to orbit.
- `Shift+C` resets the 3D cursor to the origin and frames everything — use it
  when new objects spawn somewhere unexpected (objects always spawn at the 3D
  cursor, the small red-white dashed circle).
- Never enter walk/fly mode (`shift+backtick`) — it is a modal mouse-look
  trap.

## Deleting

Select all with `A` when needed, delete with `X`, confirm with `Return` if a
confirmation popup appears. Press `Return` as a plain key action — do not hunt
for a confirm button to click. When the target is already selected in the
current screenshot, chain click-object, `X`, `Return` in one turn.

## Importing a downloaded model

For a realistic, detailed, or marketplace-quality model, do not build it from
primitives — get a real asset:

1. Find a free or clearly licensed asset with the browser (`open_url`). Prefer
   `.glb`/`.gltf`; `.obj`, `.fbx`, and `.blend` also work. Skip installers,
   archives with executables, and paid or login-gated assets.
2. Download it and note the absolute file path.
3. In Blender: `File` → `Import` → the matching format (`glTF 2.0`,
   `Wavefront (.obj)`, `FBX`), or `File` → `Open`/`Append` for `.blend`.
4. In the macOS file dialog, press `cmd+shift+g`, type the absolute path, and
   press `Return` — do not click through folders.
5. Do not claim success until the model is visible in the viewport.

```cascade-runtime-hints
{
  "appMatchers": {
    "bundleIdentifiers": ["org.blenderfoundation.blender"],
    "names": ["Blender"]
  },
  "inputPolicies": [
    {
      "kind": "numericModalText",
      "delivery": "physicalKeys",
      "maxLength": 12,
      "characters": "0123456789.-"
    }
  ],
  "axUnreliable": true,
  "keysFollowPointer": true
}
```
