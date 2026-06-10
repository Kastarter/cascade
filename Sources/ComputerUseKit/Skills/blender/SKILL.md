---
name: blender
description: Use when controlling Blender — menus, modal transforms, object creation, movement, scaling, rotation, and keyboard workflows.
useWhen: any work in Blender — 3D modeling, transforms, adding/deleting objects, importing models
attribution: Adapted from milind-soni/tiptour-macos TipTour/Skills/blender/SKILL.md (MIT)
---

# Blender

Blender is a canvas app: macOS accessibility cannot see its menus, viewport, or
modal tool state. Work purely from screenshots. Zoom in when a menu label or
number field is too small to read confidently.

Viewport objects (a cube, cylinder, cone, roof, house body) are different from
UI labels. A visible mesh has no clickable label on the canvas — click it at
its visual coordinates from a fresh screenshot. Never click lookalike text in
the right-hand Outliner or Properties sidebar when you mean a viewport object
or an open menu item.

## Pointer rules

Blender routes keyboard shortcuts to the editor under the pointer. Cascade
keeps the real pointer wherever you last clicked and moves it into the Blender
window before bare key presses — but you must keep the interaction inside the
3D viewport:

- Before a transform (`G`/`S`/`R`), make sure your last click was inside the
  3D viewport — normally by clicking the object you are transforming. Do not
  press transform keys right after clicking sidebar or menu-bar UI.
- Clicking empty viewport space DESELECTS everything. To position the pointer
  without losing the selection, click the object itself.
- `Shift+A` opens the Add menu at the pointer, so it appears near your last
  click — take a fresh screenshot to see where it landed.

## Modal transforms — one key per action

Transforms are keyboard-modal sequences: `G` (grab/move), `S` (scale), `R`
(rotate), then an optional axis key `X`/`Y`/`Z`, then the numeric value, then
`Return` to confirm (`Escape` cancels).

- Send each token as its OWN action and observe the result between tokens.
  Scaling by 3 is three separate actions: press `S`, type `3`, press `Return`.
  Moving up 1.5 on Z is four: press `G`, press `Z`, type `1.5`, press `Return`.
- This overrides the usual guidance to batch confident actions — NEVER batch a
  transform key, its number, and Return in one turn.
- Never press `S` (or `G`/`R`) twice unless the previous transform was
  cancelled with `Escape`.
- Numeric input must be the plain value only — digits, `.`, `-` (for example
  `3` or `-1.5`). Cascade delivers it as real keystrokes automatically; do not
  try to paste numbers.

## Menus

- Add objects through `Shift+A` (or the visible `Add` menu), then `Mesh`, then
  the object type.
- After `Shift+A` or opening any submenu, take a fresh screenshot before
  clicking the next item — menu contents and positions change.
- Do not use bare accelerator letters such as `M`, `P`, or `C` unless the
  correct popup/submenu is visibly open in your latest screenshot.
- When a menu is open, click the item inside the menu popup, not a duplicate
  label elsewhere on screen.

## Deleting

Select all with `A` when needed, delete with `X`, confirm with `Return` if a
confirmation popup appears. Press `Return` as a plain key action — do not hunt
for a confirm button to click.

## Reliable house recipe

When asked to make a simple house, build it from primitives, one action at a
time, observing between steps:

1. Switch to (or open) Blender.
2. Select all with `A`, delete with `X`, confirm with `Return` if asked.
3. `Shift+A` → fresh screenshot → click `Mesh` → fresh screenshot → click
   `Cube` for the house body.
4. Scale it up: `S`, type `3`, `Return`.
5. Flatten on Z: `S`, `Z`, type `0.7`, `Return`.
6. `Shift+A` → `Mesh` → `Cone` for the roof (4 vertices makes a pyramid roof
   if the option is easy to set; the default cone is fine otherwise).
7. Move the roof up: `G`, `Z`, type `1.1`, `Return`. Widen it: `S`, type
   `2.4`, `Return`.
8. Add small cubes for a door and at least one window via `Shift+A` → `Mesh` →
   `Cube`, then place them with axis-constrained `S`/`G` moves on the front.

Prefer progress over perfection: a body, a roof, a door, one window. If a menu
item is not visible or the modal state is uncertain, take a fresh screenshot
before continuing.

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
