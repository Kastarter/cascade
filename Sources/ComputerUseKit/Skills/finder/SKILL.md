---
name: finder
description: Organizing files and folders in Finder.
useWhen: moving, renaming, organizing files and folders, or navigating to paths in Finder
---

# Finder

- `Return` on a selected file RENAMES it (it does not open it). Open with
  `cmd+o` or double-click.
- Go straight to any path: `cmd+shift+g`, type the absolute path, `Return` —
  never click through folder trees when the path is known.
- New folder: `cmd+shift+n` (created in the current folder, name editable
  immediately — type the name, `Return`).
- Move files by dragging; holding `option` while dragging COPIES instead.
  Verify drops landed by screenshotting the destination.
- Quick Look with `space` to peek at a file without opening its app.
- Trash is `cmd+delete` on the selection — only when the user asked to delete;
  emptying the Trash is never yours to do unprompted.
- List view (`cmd+2`) is easiest to read for file work; sort by clicking
  column headers.

```cascade-runtime-hints
{
  "appMatchers": {
    "bundleIdentifiers": ["com.apple.finder"],
    "names": ["Finder"]
  }
}
```
