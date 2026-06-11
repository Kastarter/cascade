---
name: blender-modeling
description: Create any object or scene in Blender from primitives — decompose, block out, smooth, color, render.
useWhen: creating or modeling anything in Blender that is not architecture — props, food, vehicles, characters, furniture pieces, logos, abstract shapes (buildings and interiors → also pull blender-archviz)
---

# Blender — modeling any object

Pull the `blender` skill first — its rules still apply (one chained batch per
turn, fresh screenshot after every menu, exact values typed into fields).
This skill is the general METHOD for building anything from primitives;
`blender-archviz` specializes it for buildings and interiors. All of it is
viewport cursor work — repetition is duplicates or an Array modifier, never a
detour to any other surface.

If the user wants a realistic, detailed, or marketplace-quality model, do not
build it from primitives — import a real asset (see "Importing a downloaded
model" in the `blender` skill).

## Decompose first

Before touching the viewport, write the build plan in one message: list the
subject's parts, pick a primitive for each, give each a size and a position.
Almost anything reads correctly as a short list of primitives plus one or two
modifiers:

- mug = cylinder body + torus handle (half-buried in the side)
- donut = torus + second slightly larger, flattened torus on top (icing) +
  small elongated cubes hand-scattered (sprinkles)
- snowman = three UV spheres stacked, shrinking upward
- car blockout = flattened cube body + smaller cabin cube + four cylinder
  wheels rotated upright (`R`, `X`, `90`)
- tree = cylinder trunk + one to three cones or icospheres for the crown
- table = thin box top + four box legs (build one leg, `shift+D` the rest)

Primitive options live in the Adjust Last Operation panel (`F9`) right after
adding: Cylinder/Cone Vertices (6 reads as a nut/bolt, 32 as smooth), Torus
Major/Minor Radius, Sphere Segments. The panel dies on the next operator —
set options immediately or re-add.

## Block out, then refine

1. Build every part as a primitive with exact N-panel Dimensions + Location.
   Interpenetration is fine — half-bury the handle, sink the wheels.
2. Check proportions from TWO views (`View` → `Viewpoint` → `Front`, then
   `Right`) before any refinement — wrong blockout proportions are the main
   reason a model reads wrong, and they are cheapest to fix now.
3. Only then smooth, deform, and color.

## Smooth and organic shapes — ranked by reliability

1. Shade Smooth: `Object` menu → `Shade Smooth` (never right-click — banned
   in the viewport). Zero risk, makes faceted primitives read smooth.
   `Shade Auto Smooth` keeps genuinely sharp edges sharp.
2. Subdivision Surface modifier (wrench tab → `Add Modifier` → `Generate` →
   `Subdivision Surface`, Levels Viewport `2`): rounds boxy shapes — a cube
   becomes a cushion, a box-built animal becomes soft. Combine with Shade
   Smooth.
3. Simple Deform modifier (`Add Modifier` → `Deform` → `Simple Deform`):
   Bend / Taper / Twist a whole object with typed Angle or Factor fields —
   a banana is a tapered, bent cylinder. Pick the Axis in the panel.
4. Proportional editing, for one-off bulges and dents only: in Edit Mode
   select a vertex, press `O`, start a `G` modal — a gray influence circle
   appears; resize it with `pageup`/`pagedown` (stepped, one press at a
   time, watching the circle). This is a stateful modal — step every token.
   Press `O` again to turn it OFF as soon as you are done; left on, it
   silently corrupts every later edit. The header shows the proportional
   (circle) icon while it is on.
5. Holes and cutouts: Boolean Difference with an overshooting cutter —
   `blender-archviz` has the full ranked recipe.

## Scatter and repeats

- Regular repetition (wheels, legs, buttons, a fence) → `shift+D` duplicates
  with typed axis moves, or an Array modifier (recipes in `blender-archviz`).
- Random-looking scatter (sprinkles, pebbles, leaves): hand-place 8–15
  `shift+D` duplicates, each with a small typed `G` move and a different
  `R` rotation — that reads as random and every copy is verifiable. Particle
  scatter exists but is many fragile steps — only attempt it if the user
  asks for hundreds of instances.

## Color and finish

Material Properties tab (checkered-sphere icon) → `New` → click the Base
Color swatch → `Hex` tab → single-click the field → type the 6-digit hex →
`Return` → click outside the popup. Cascade's typing replaces the field's
old value by itself — never press `ctrl+v`/`cmd+v` to "paste" the hex (that
pastes the user's clipboard) and never triple-click the field. Then set Roughness: `0.8` matte, `0.3` satin, `0.05` glossy.
Metallic `1.0` only for actual metal. Emission Strength `3–5` for glowing
parts (screens, lava, neon). One material per part keeps it simple; a second
color on some faces = Edit Mode face-select + new slot + `Assign`
(`blender-archviz` has that recipe).

Switch the viewport to Material Preview with the THIRD of the four shading
icons at the right end of the viewport header (never the `Z` pie).

## Camera and render

Select the existing Camera in the Outliner, type N-panel Location/Rotation
values, check framing via `View` → `Viewpoint` → `Camera`, and nudge with
typed `G` moves. Render with the `Render` menu → `Render Image`; wait for
the separate render window to finish, screenshot it as proof, then close it
with `Escape` while the pointer is over it.

Progress over perfection: a recognizable blockout with clean materials beats
a half-finished masterpiece. Verify every batch in the next turn's
screenshot before building on it.
