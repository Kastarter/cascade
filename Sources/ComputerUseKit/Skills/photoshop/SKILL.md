---
name: photoshop
description: Editing images in Adobe Photoshop — tools, layers, text, selections.
useWhen: image editing in Photoshop — layers, selections, text, drawing, retouching
---

# Photoshop

Photoshop's canvas and panels are mostly invisible to macOS accessibility —
work from screenshots and zoom on small panel text.

- Select the right tool FIRST, then act: move `v`, text `t`, brush `b`,
  marquee `m`, lasso `l`. The Options bar under the menu reflects the active
  tool — glance at it to confirm.
- Text: with `t` active, click once on the canvas, type, then commit with
  `Escape` (or the checkmark in the Options bar). Uncommitted text is lost.
- Deselect with `cmd+d` when a selection would otherwise restrict your next
  edit — many "nothing happened" failures are edits outside an old selection.
- New layer before painting/drawing (`cmd+shift+n`) so edits stay reversible;
  check the Layers panel shows the intended layer highlighted before editing.
- Undo is `cmd+z` (steps back repeatedly). Use it instead of trying to paint
  over mistakes.
- Dialogs (resize, filters) block everything else — finish or cancel them
  before any other action.

```cascade-runtime-hints
{
  "appMatchers": {
    "bundleIdentifiers": ["com.adobe.Photoshop"],
    "names": ["Photoshop"]
  },
  "axUnreliable": true
}
```
