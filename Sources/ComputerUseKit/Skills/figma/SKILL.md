---
name: figma
description: Design work on Figma's canvas — frames, shapes, text, components.
useWhen: any design work in Figma — frames, shapes, text layers, moving or styling elements
---

# Figma

Figma's canvas is invisible to macOS accessibility — work purely from
screenshots, and zoom on small labels or layer names.

- Always return to the Move tool (`v`) after using any other tool.
- Press `Escape` to exit text editing BEFORE pressing any tool shortcut —
  otherwise the shortcut types letters into the text layer.
- Create: frame `f`, rectangle `r`, ellipse `o`, text `t`, then drag on the
  canvas to place it. After creating, the new layer is selected.
- Enter a group/frame's contents by double-clicking; `Escape` climbs back out
  one level.
- Move precisely with arrow keys (1px) or shift+arrows (10px) while a layer is
  selected.
- The right panel edits the CURRENT selection — check what's selected (blue
  outline) before changing fills or sizes there.
- Zoom: `cmd+=` / `cmd+-`, `shift+1` fits everything; do this instead of
  squinting at a small canvas.

```cascade-runtime-hints
{
  "appMatchers": {
    "bundleIdentifiers": ["com.figma.Desktop"],
    "names": ["Figma"]
  },
  "axUnreliable": true
}
```
