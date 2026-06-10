---
name: terminal
description: Running commands in Terminal or iTerm2 safely.
useWhen: running shell commands, scripts, or CLI tools in Terminal or iTerm2
---

# Terminal

- Type the command, then press `Return` as a SEPARATE action — never embed a
  newline in the typed text.
- Wait for the prompt to come back before sending the next command; screenshot
  and check. A missing prompt means the command is still running.
- Read the output of each command before the next one — error messages change
  what to do next.
- Destructive commands (`rm -rf`, `git reset --hard`, `kill`, anything with
  `sudo`) need the user's explicit request — if the task merely implies one,
  stop and ask instead of running it.
- Long output: scroll or pipe through `| head` / `| tail` rather than zooming
  through pages.
- If a command needs input (password prompts, y/n confirmations), answer only
  what the user's request covers; passwords are NEVER yours to type.
- `ctrl+c` cancels a stuck command; `cmd+k` clears the screen.

```cascade-runtime-hints
{
  "appMatchers": {
    "bundleIdentifiers": ["com.apple.Terminal", "com.googlecode.iterm2"],
    "names": ["Terminal", "iTerm2"]
  }
}
```
