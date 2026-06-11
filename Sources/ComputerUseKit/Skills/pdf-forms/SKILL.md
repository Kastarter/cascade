---
name: pdf-forms
description: Filling, annotating, and signing PDFs in Preview.
useWhen: filling PDF forms, signing documents, annotating PDFs in Preview
---

# PDF forms (Preview)

- `read_screen_elements` lists this window's real controls — exact labels,
  values, and clickable coordinates — instantly, no screenshot needed. Use it
  FIRST to find form fields, and to VERIFY what you just filled, instead of
  zooming or spending a look-only turn.
- Form fields: click the field, type, then `Tab` to commit and jump to the
  next field. Re-screenshot to confirm the text landed in the right box —
  PDF fields are easy to mis-target.
- If clicking a field does nothing, the PDF has no interactive fields — use
  the Markup toolbar's text tool (toolbar pencil icon → "A" text button) and
  place a text box over the blank.
- Signatures: Markup toolbar → signature button → pick an existing saved
  signature and drag it into place. Creating a NEW signature needs the user's
  trackpad/camera — hand that step back to them.
- Checkboxes in flat PDFs: use the Markup text tool with an "X" placed over
  the box.
- Save with `cmd+s` when done; "Export as PDF…" only when a copy is asked for.
- Page navigation: thumbnails sidebar (`View > Thumbnails`) beats scrolling
  for long documents.

```cascade-runtime-hints
{
  "appMatchers": {
    "bundleIdentifiers": ["com.apple.Preview"],
    "names": ["Preview"]
  }
}
```
