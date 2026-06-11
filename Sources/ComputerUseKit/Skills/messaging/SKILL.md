---
name: messaging
description: Sending messages in WhatsApp, Slack, Discord, or Messages.
useWhen: reading or sending messages in WhatsApp, Slack, Discord, Messages, Telegram
---

# Messaging

- `read_screen_elements` lists this window's real controls — exact labels,
  values, and clickable coordinates — instantly, no screenshot needed. Use it
  FIRST to find the right conversation row or input field, and to VERIFY a
  draft before sending, instead of zooming or spending a look-only turn.
- `Return` SENDS the message. Never include a newline in typed message text;
  for a multi-line message use `shift+Return` between lines, sent as separate
  key actions.
- Verify the recipient/channel FIRST: click the conversation, confirm the
  header shows the right name, then type. A message to the wrong person is
  the worst failure mode in these apps.
- Type the message, screenshot to confirm the input field holds exactly the
  intended text, THEN press `Return`. These apps sometimes drop characters
  from fast typing.
- Drafting vs sending: if the user said "write a reply", leave it in the input
  field unsent and say so; send only when asked to send.
- Search (`cmd+f` in Slack/Discord, `cmd+f` or the search field in WhatsApp)
  beats scrolling to find old messages.
- Read receipts and typing indicators mean the other side can see activity —
  don't open conversations the task doesn't need.

```cascade-runtime-hints
{
  "appMatchers": {
    "bundleIdentifiers": [
      "net.whatsapp.WhatsApp",
      "com.tinyspeck.slackmacgap",
      "com.hnc.Discord",
      "com.apple.MobileSMS",
      "ru.keepcoder.Telegram"
    ],
    "names": ["WhatsApp", "Slack", "Discord", "Messages", "Telegram"]
  }
}
```
