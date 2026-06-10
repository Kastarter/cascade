---
name: xcode
description: Navigating, editing, and building projects in Xcode.
useWhen: editing code, building, running, or debugging in Xcode
---

# Xcode

- Open any file fast: `cmd+shift+o`, type part of the name, `Return`. Faster
  and more reliable than clicking through the navigator tree.
- Click inside the editor before typing — focus may be in a navigator or
  inspector, and typing there triggers shortcuts instead of inserting code.
- Build `cmd+b`, run `cmd+r`, stop `cmd+.`. After a build, check the activity
  bar / issue navigator (`cmd+5`) instead of assuming success.
- Navigators: project `cmd+1`, find `cmd+3`, issues `cmd+5`. The left sidebar
  toggles with `cmd+0`.
- Jump to a line: `cmd+l`, type the number, `Return`.
- Don't change project/build settings unless the task asks for it.
- Errors show inline in red — click one to jump to the offending line; zoom if
  the message is truncated.

```cascade-runtime-hints
{
  "appMatchers": {
    "bundleIdentifiers": ["com.apple.dt.Xcode"],
    "names": ["Xcode"]
  }
}
```
