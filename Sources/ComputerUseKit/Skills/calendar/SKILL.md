---
name: calendar
description: Creating and managing events in Apple Calendar.
useWhen: creating, moving, or checking events and meetings in Calendar
---

# Calendar

- `read_screen_elements` lists this window's real controls — exact labels,
  values, and clickable coordinates — instantly, no screenshot needed. Use it
  FIRST to find a field or event, and to VERIFY what you just set, instead of
  zooming or spending a look-only turn.
- Create an event by double-clicking the target day/time slot — the event
  appears with its title field already editable. Type the title, `Return`.
- Set details (time, invitees, location) by double-clicking the created event
  and editing its popover; press `Return` or click outside to commit.
- Check the CURRENT view first (day/week/month, which week is shown) before
  clicking a slot — the most common mistake is the right time on the wrong
  week. Navigate with `cmd+arrow` keys; today is `cmd+t`.
- Inviting people: type their email in "Add Invitees", pick the autocomplete
  suggestion, and verify the chosen address.
- Don't send invitations unless the user asked — close the popover after
  saving details; only click "Send" on explicit request.
- Moving an event: drag its block to the new slot; verify the new time in a
  fresh screenshot.

```cascade-runtime-hints
{
  "appMatchers": {
    "bundleIdentifiers": ["com.apple.iCal"],
    "names": ["Calendar"]
  }
}
```
