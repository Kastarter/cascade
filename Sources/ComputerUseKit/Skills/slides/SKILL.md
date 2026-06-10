---
name: slides
description: Building and editing presentations in Keynote or PowerPoint.
useWhen: creating or editing slides, decks, presentations (Keynote, PowerPoint)
---

# Slides

- New slide: `cmd+shift+n` in Keynote; in PowerPoint use the visible "New
  Slide" button (its shortcut varies).
- Text lives in placeholders: click once to select the box, double-click to
  enter text editing. Type, then click OUTSIDE the box (or press `Escape`) to
  commit — `Escape` while editing exits to box-selection, a second `Escape`
  deselects.
- While a text box is selected (not editing), arrow keys MOVE the box — don't
  press arrows unless you mean to move it.
- Pick a slide layout with content placeholders rather than drawing text boxes
  by hand when possible.
- Reorder slides in the left navigator by dragging thumbnails.
- Build incrementally: one slide finished (title + content) before the next;
  re-screenshot after each slide to confirm the text landed in the right box.
- Don't touch theme/master settings unless asked.

```cascade-runtime-hints
{
  "appMatchers": {
    "bundleIdentifiers": ["com.apple.iWork.Keynote", "com.microsoft.Powerpoint"],
    "names": ["Keynote", "Microsoft PowerPoint"]
  }
}
```
