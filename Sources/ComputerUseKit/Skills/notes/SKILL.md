---
name: notes
description: Reading, editing, and checking off items in Apple Notes.
useWhen: opening, editing, creating, or checking off items in a note in Apple Notes
---

# Apple Notes

- `read_screen_elements` lists this window's real controls — exact labels,
  values, and clickable coordinates — instantly, no screenshot needed. Use it
  FIRST to find the right note row or checklist circle, and to VERIFY an edit
  landed, instead of zooming or spending a look-only turn.
- A "note" lives in THIS app, not on disk. Never satisfy a Notes task by
  reading or editing a similarly named file found with the file tools — the
  note in the app is the artifact; a look-alike `.md`/`.txt` file is context
  at best. Do the work in the editor pane.
- Find a note: `cmd+option+f` focuses search (or click the search field above
  the note list), type a word from the title, click the matching note in the
  list. Confirm the right note is open by its title in the EDITOR pane — the
  list highlight alone is not proof.
- Checklist items (round checkboxes): check one off by clicking its CIRCLE,
  or click into the item's text and press `shift+cmd+u` (Mark as Checked).
  The circle is small — aim at its center and verify the fill in the next
  screenshot before moving on.
- Plain-text checkboxes (`- [ ]` typed as ordinary text) are NOT checklist
  circles: click immediately after the `[`, press `shift+right` to select the
  space between the brackets, then type `x`. Turn selected lines into a real
  checklist with `shift+cmd+l` only if the user asks for it.
- DANGER keys: `cmd+h` HIDES the entire app (if the screen suddenly shows a
  different app, this is what happened — bring Notes back with open_app);
  `ctrl+h` deletes the character before the cursor. Neither has anything to
  do with checking items off.
- The editor is click-to-place rich text: click where the caret should go,
  then type. New note: `cmd+n` (lands in the currently selected folder).
- Edits save automatically — there is no save step, and no cmd+s ritual.

```cascade-runtime-hints
{
  "appMatchers": {
    "bundleIdentifiers": ["com.apple.Notes"],
    "names": ["Notes"]
  }
}
```
