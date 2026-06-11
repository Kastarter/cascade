---
name: blender-archviz
description: Build architecture in Blender — buildings, offices, interiors, furniture — with reliable recipes and real-world dimensions.
useWhen: building any architecture or interior in Blender — a house, office, building, room, walls, windows, furniture, plus lighting, camera, and rendering it
---

# Blender — architecture and interiors

Pull the `blender` skill first — its rules still apply (one chained batch per
turn: a known transform or a full field row; clean single clicks on field
centers; fresh screenshot after every menu). Every build here is viewport
work: typed N-panel fields handle exact dimensions and duplication
(`shift+D`, `alt+D` linked, Array modifier) handles massive repetition —
never switch to scripting for it.

The default startup scene already has a Cube, a Light, and a Camera — reuse
them instead of adding new ones.

## Ground rules

- Set exact sizes in the `N` sidebar (Item tab → Dimensions X/Y/Z), then set
  Location Z = height/2 so the object sits on the ground plane.
- After resizing and BEFORE adding a Boolean or Solidify modifier: hover the
  viewport and `ctrl+a` → click `Scale` (unapplied scale breaks thickness and
  booleans).
- Build walls as separate cube slabs (typed Dimensions + Location), not by
  edge-tracing a floor plan — each slab is independently verifiable and a
  mistake costs one object. Slabs may interpenetrate at corners; that is safe.
  Only coplanar (flush) faces flicker — keep attached panels 1–5 cm proud.
- Typed values beat snapping. Never eyeball what you can type.
- Pace the recipes by BATCH, not by keystroke: a Dimensions or Location row
  is one chained turn (click the X field, type, `Tab`, type, `Tab`, type,
  `Return`), a known transform is one chained turn (click object, key, axis,
  digits, `Return`), and a just-added object is already selected — chain its
  transform without re-clicking (a click could grab the overlapping body
  instead). Menu navigation stays one click per turn.
- Never `Escape` out of an extrude — the new geometry remains invisibly
  stacked; press `cmd+z` instead.

## Real-world dimensions (meters)

| Item | Size |
|---|---|
| Office ceiling / storey height | 2.7 / 3.5–3.7 |
| Interior door | 0.9 wide × 2.04 high |
| Interior wall / exterior wall thickness | 0.12 / 0.25 |
| Desk top | 1.4 × 0.7, height 0.73 |
| Chair seat / chair overall | 0.45 / 1.05 high |
| 24" monitor panel | 0.54 × 0.32, center ~1.05 high |
| Corridor / glass partition | 1.5 wide / 0.01 thick |
| Window sill / head | 0.9 / 2.4 |
| Bookshelf | 1.2 × 0.35 × 1.96 |
| Stair riser / tread | 0.17 / 0.28 |

## Window grids, ranked by reliability

1. BEST — glazing panes + Array modifiers (no booleans, all Object Mode):
   add a thin cube pane (e.g. 1.4 × 0.1 × 2.2), place it on the facade
   sitting ~5 cm proud, apply scale, then Array along X (Count = columns,
   Relative Offset Factor X ≈ 1.35), then a second Array for storeys
   (Factor X `0`, tick Constant Offset, Distance Z = storey height,
   Count = floors). Dark-glass material sells it as windows.
2. Real openings — arrayed cutter + Boolean Difference (only when you must
   see through): cutter cube DEEPER than the wall (overshoot both faces),
   Array modifiers on the cutter (the Boolean evaluates them live — no need
   to apply), then on the building: Add Modifier → Generate → Boolean,
   Operation `Difference`, pick the cutter in the Object dropdown, Solver
   `Exact` (never "Fast"/"Float"). Hide the cutter with the Outliner eye
   icon — the boolean keeps working.
3. AVOID — loop-cut + inset + negative extrude facades: long stateful
   edit-mode chains fail silently. Use only when topology truly matters.

## Modifier panel navigation

- Properties editor, wrench tab → `Add Modifier` → it is a nested menu:
  `Generate` → `Array` / `Boolean` / `Solidify`. Typing right after it opens
  searches.
- Blender 5.0 trap: plain "Array" is a new nodes-based modifier — click
  `Array (Legacy)` for the classic panel these recipes use.
- Apply a modifier (rarely needed — leave them live): hover the Properties
  editor and press `ctrl+a`, or the modifier header `⌄` menu → Apply.
  Object Mode only.

## Materials

Material Properties tab (checkered-sphere icon near the bottom of the
Properties tab column) → `New`. Click the Base Color swatch → `Hex` tab →
click the field → `ctrl+a` (the field may keep its old hex — typing must
replace, not append) → type the hex → `Return` → click outside the popup.

- Concrete/plaster: hex `CFCBC3`, Roughness 0.6 (walls `F1EEE8`, 0.8)
- Facade glazing: hex `101820`, Metallic 0.9, Roughness 0.08 — do NOT use
  Transmission for facades (raytracing is off by default; metallic dark
  glass looks right everywhere)
- See-through partition: Transmission Weight 1.0, Roughness 0, IOR 1.5
- Screens / light panels: raise Emission Strength to 3–5
- Wood: `A07A52`, Roughness 0.4; dark fabric: `2A2A2E`
- Different material on some faces: Edit Mode → `3` → select faces → `+`
  slot → New → `Assign` (the Assign row only exists in Edit Mode).

Switch the viewport to Material Preview with the THIRD of the four shading
icons at the right end of the viewport header (never the `Z` pie) — it lights
everything with a built-in HDRI, no lamps needed.

## Sun, camera, render

- Sun: `Shift+A` → Light → Sun, set Strength `3` (its data tab is the green
  bulb icon). Only rotation matters — aim with typed modals, one chained turn
  each: `R`, `X`, `50`, `Return`, then next turn `R`, `Z`, `35`, `Return`.
- Camera: select the existing Camera in the Outliner and type N-panel
  Location/Rotation values, then check framing via `View` → `Viewpoint` →
  `Camera`. If you added a new camera: `View` → `Cameras` → `Set Active
  Object as Camera`, or renders fail with "no camera".
- Render: `Render` menu → `Render Image`. A separate "Blender Render" window
  opens — wait for it to finish, screenshot it as proof, then close it with
  `Escape` while the pointer is over it (Escape mid-render cancels instead).

## Organization

In Object Mode select related objects (click + shift+click) and press `M` →
`New Collection` → name it (`M` is Move-to-Collection ONLY in Object Mode —
in Edit Mode it is Merge). Rename objects/collections by double-clicking
their Outliner name.

## Recipe: simple house (primitives, one batch per turn)

1. One turn: `A`, `X`, `Return` (the `Return` confirms the delete popup —
   harmless if none appeared).
2. `Shift+A` → Mesh → Cube (menu clicks stay solo); then one turn per
   transform: `S`, `3`, `Return`; next turn `S`, `Z`, `0.7`, `Return` —
   checking each result in the screenshot before the next.
3. `Shift+A` → Mesh → Cone for the roof — in the Adjust Last Operation
   panel (`F9`) set Vertices `4` for a pyramid roof; raise, one turn: `G`,
   `Z`, `1.1`, `Return`; widen, next turn: `S`, `2.4`, `Return`. The cone
   spawns selected inside the body — do NOT click it to "select" it.
4. Small cubes for a door and a window, placed with axis-locked `G`/`S` on
   the front face, each sitting slightly proud.
   Progress over perfection: body, roof, door, one window.

## Recipe: office tower exterior (~20 steps)

1. Click the default Cube → `N` → Dimensions `20` Tab `15` Tab `35` Enter;
   Location Z `17.5`. Hover viewport, `ctrl+a` → Scale.
2. Concrete material (above).
3. `Shift+A` → Mesh → Cube (the glazing pane) → Dimensions `1.4, 0.1, 2.2`;
   Location `-8.4, -7.56, 1.5` (front facade is at Y −7.5; pane 6 cm proud).
   `ctrl+a` → Scale.
4. Wrench tab → Add Modifier → Generate → Array: Count `9`, Relative Offset
   Factor X `1.35`.
5. Add Modifier → Generate → Array: Factor X `0`, tick Constant Offset,
   Distance Z `3.5`, Count `10`.
6. Glazing material (above).
7. Entrance: cube `6, 0.2, 3.2` at `0, -7.6, 1.6`, glazing material via the
   material dropdown → pick existing.
8. Ground: `Shift+A` → Mesh → Plane → `S`, `100`, `Return`; material
   `8A8A85`.
9. Sun Strength `3`, aim `R X 50`, `R Z 35` (one chained turn each).
10. Material Preview shading icon.
11. Camera (Outliner) → N panel Location `48, -42, 28`, Rotation
    `72, 0, 49` → View → Viewpoint → Camera; nudge with typed `G` moves.
12. Render → Render Image; screenshot; `Escape` over the render window.

## Recipe: furnished office interior (~25 steps)

1. Delete the default Cube. Floor: Plane, Dimensions `8 × 6`, wood material.
2. Back wall: cube `8, 0.15, 2.7` at `0, 3.07, 1.35`, wall material. Side
   wall: cube `0.15, 6, 2.7` at `-4.07, 0, 1.35`, same material.
3. Door: cube `0.9, 0.05, 2.04` at `2.5, 2.99, 1.02`, hex `4A3B2A` (a leaf
   1 cm proud of the wall — no boolean needed).
4. Glass partition: cube `0.02, 4, 2.7` at `0.5, -1, 1.35`, partition glass.
5. Workstation at `X -2.8`: desk top `1.4, 0.7, 0.04` at z `0.71`; two side
   panels `0.04, 0.66, 0.69` at z `0.345` (make the second with `Shift+D`,
   `X`, `1.32`, `Return`); monitor `0.54, 0.03, 0.32` at `-2.8, 1.7, 1.05`
   with Emission Strength `3`; stand `0.06, 0.15, 0.18` at z `0.82`; chair:
   seat `0.45, 0.45, 0.06` at z `0.45`, back `0.45, 0.05, 0.55` at z `0.78`,
   post `0.06, 0.06, 0.42` at z `0.21`, dark fabric.
6. Select the workstation's 8 objects (click + shift+click) → `M` → New
   Collection → `Workstation`.
7. Two more workstations: with all 8 still selected, `Shift+D`, `X`, `2.2`,
   `Return` — twice (one chained turn each; `Shift+D` opens a move modal
   directly, so the axis/digits/Return complete it).
8. Bookshelf `1.2, 0.35, 1.96` at `3.5, 2.7, 0.98`, wood.
9. Ceiling light: Plane `6 × 4` at Z `2.69`, Emission Strength `5`.
10. Material Preview shading; Camera → Location `4.4, -4.6, 1.65`, Rotation
    `81, 0, 42` → View → Viewpoint → Camera.
11. Render → Render Image; screenshot; `Escape` over the render window.

Verify every batch in the screenshot that opens the next turn — N-panel
numbers, object outlines, modifier panel — before building on it; don't add
look-only turns, the next turn's screenshot IS the check. A wrong dimension
caught immediately costs one fix; caught at the end it costs the build.
