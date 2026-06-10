---
name: blender-python
description: Build precise or complex Blender scenes by running a Python script inside Blender's Scripting workspace.
useWhen: ONLY when the user asks for a script, or a Blender build genuinely needs exact dimensions everywhere or 10+ identical repeated parts — runs inside Blender's own Text Editor, never in Terminal
---

# Blender — Python in the Scripting workspace

Viewport work is the default — model with clicks and the `blender` skill.
Scripting earns its place only when the user asked for it, or the build has
exact dimensions everywhere or more than ~10 repeated parts (a window grid,
rows of desks, a multi-storey facade). Pull the `blender` skill too — its
pointer and screenshot rules still apply.

The script runs INSIDE Blender's Text Editor. Never open Terminal, never
write the script to a file, never run `blender --python` — those leave the
app the user is watching and are always the wrong move.

## Running a script (Text Editor path — the reliable one)

1. Click the `Scripting` tab at the top of the Blender window (rightmost
   workspace tab). Fresh screenshot: you should see a Python console
   (mid-left), an Info log (bottom-left), and a large Text Editor.
2. Create a text block: click the `+ New` BUTTON in the Text Editor header
   (next to the datablock dropdown). Avoid the `Text` MENU — if you do open
   any menu, click an item or press `Escape`: an open menu stays up and EATS
   your next click (the click only dismisses it).
3. VERIFY the text block exists before going on — fresh screenshot: the
   header now shows a name field reading `Text` (with an `X` beside it) and
   the body shows line number `1`. THIS IS THE GATE: with no text block
   open, Blender's paste operator is disabled and every paste silently does
   nothing, no matter how many times you try.
4. Click once in the CENTER of the editor's large dark body — not the
   header, not the line-number gutter. The paste is delivered to the region
   under the pointer; a pointer parked on a header or button kills it.
5. Immediately type the full script as ONE `type` action — Cascade delivers
   it via clipboard paste, which the Text Editor accepts verbatim (blank
   lines and indentation are safe here). Do not click anything between the
   body click and the type.
6. Click the `▶ Run Script` button at the right of the Text Editor header
   (or press `alt+p` after clicking inside the editor).
7. Screenshot to judge the outcome (below). The embedded 3D viewport in the
   Scripting workspace shows the scene — also check there.

If the editor shows no code after typing, do NOT detour to Terminal or
files — the text never lands there for one of exactly three reasons: no
text block is open (step 3 gate failed), a menu was left open and ate a
click, or the pointer was over a header when the paste fired. Take a fresh
screenshot, fix the one that applies, click the body center, and re-issue
the SAME type action — every type re-arms the paste.

Do NOT paste multi-line scripts into the interactive Python Console (the
mid-left REPL): it executes line by line, and a blank line inside an indented
block raises IndentationError. The console is for one-liners only.

## Detecting success or failure

- Failure: a transient red banner appears — "Python script failed, check the
  message in the system console" — the offending line gets selected in the
  Text Editor, and a red error row is logged persistently in the Info editor
  (bottom-left). The full traceback is NOT visible in the GUI.
- Success: no red banner, and the expected objects appear in the viewport and
  the Outliner (top-right).
- `print()` output is invisible in the GUI. To self-report, end the script
  with a marker the Outliner shows, e.g.
  `bpy.context.scene.collection.children.link(bpy.data.collections.new("DONE_step1"))`
  — seeing `DONE_step1` in the Outliner proves the whole script ran.
- One script run = ONE undo step: to revert it, click an object in the 3D
  viewport (not the Text Editor — undo is area-sensitive) and press `cmd+z`.

## Writing scripts that don't fail

- Run in chunks: one script per build stage (shell → openings → furniture →
  materials → light/camera), verifying the viewport between runs. A failed
  monolith is unreadable; a failed chunk is obvious.
- Start every script with a mode guard:
  `if bpy.context.object and bpy.context.object.mode != 'OBJECT': bpy.ops.object.mode_set(mode='OBJECT')`
- Prefer the data API (`bpy.data.*`, `obj.dimensions`, `obj.location`) over
  `bpy.ops.*` — it has no context dependence. Never call `bpy.ops.view3d.*`
  or other viewport-bound operators from a script.
- `bpy.ops.object.modifier_apply(modifier=...)` needs the object ACTIVE
  (`bpy.context.view_layer.objects.active = obj`) and Object Mode.
- Find Principled nodes by type, not name (names are localized):
  `next(n for n in mat.node_tree.nodes if n.type == 'BSDF_PRINCIPLED')`.
  Sockets "Base Color", "Roughness", "Metallic" are stable across 4.x/5.x.
- Setting `obj.dimensions` changes scale — follow with
  `bpy.ops.object.transform_apply(scale=True)` (object selected) before
  booleans or arrays so modifiers work on true sizes.

## Reference snippets

Exact-size box (location is the object's CENTER — a 2.5 m wall sits at z=1.25):

```python
import bpy
if bpy.context.object and bpy.context.object.mode != 'OBJECT':
    bpy.ops.object.mode_set(mode='OBJECT')
bpy.ops.mesh.primitive_cube_add(size=1, location=(0, 0, 1.25))
wall = bpy.context.active_object
wall.name = "Wall"
wall.dimensions = (4.0, 0.2, 2.5)
bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
```

Window grid cut into a wall (cutter deeper than the wall so it punches through):

```python
import bpy
wall = bpy.data.objects["Wall"]
cutters = []
for i in range(3):
    bpy.ops.mesh.primitive_cube_add(size=1, location=(-1.2 + i * 1.2, 0, 1.4))
    c = bpy.context.active_object
    c.dimensions = (0.7, 0.5, 1.0)
    cutters.append(c)
for c in cutters:
    m = wall.modifiers.new(name="Cut", type='BOOLEAN')
    m.operation = 'DIFFERENCE'
    m.object = c
bpy.context.view_layer.objects.active = wall
wall.select_set(True)
for m in list(wall.modifiers):
    bpy.ops.object.modifier_apply(modifier=m.name)
for c in cutters:
    bpy.data.objects.remove(c, do_unlink=True)
```

Material with a base color, assigned to an object:

```python
import bpy
mat = bpy.data.materials.new(name="WallPaint")
mat.use_nodes = True
bsdf = next(n for n in mat.node_tree.nodes if n.type == 'BSDF_PRINCIPLED')
bsdf.inputs["Base Color"].default_value = (0.85, 0.82, 0.75, 1.0)
bsdf.inputs["Roughness"].default_value = 0.9
obj = bpy.data.objects["Wall"]
obj.data.materials.clear()
obj.data.materials.append(mat)
```

Sun + camera so the scene renders presentably:

```python
import bpy, math
bpy.ops.object.light_add(type='SUN', location=(5, -5, 10), rotation=(math.radians(50), 0, math.radians(30)))
bpy.context.active_object.data.energy = 3.0
bpy.ops.object.camera_add(location=(8, -8, 5), rotation=(math.radians(70), 0, math.radians(45)))
bpy.context.scene.camera = bpy.context.active_object
```

After the final script, switch back to the `Layout` workspace tab and frame
the result (`View` menu → `Frame All`) before declaring done — judge the
build visually, never from script success alone.
