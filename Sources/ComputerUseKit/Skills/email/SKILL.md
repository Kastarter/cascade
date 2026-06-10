---
name: email
description: Reading, triaging, and drafting email in Apple Mail or webmail.
useWhen: reading, triaging, replying to, or composing email (Apple Mail, Gmail, Outlook web)
---

# Email

- Open the message before acting on it — never judge from the preview line.
- Apple Mail shortcuts: reply `cmd+r`, reply-all `cmd+shift+r`, forward
  `cmd+shift+f`, new message `cmd+n`, send `cmd+shift+d`.
- Webmail (Gmail/Outlook): single-letter shortcuts only work if the user
  enabled them — click the visible buttons instead.
- DRAFT, don't send: write the reply, then stop and tell the user it's ready.
  Only press send when the user's request explicitly said to send.
- Address fields autocomplete — after typing a recipient, check the suggestion
  that got selected is the intended person before moving on.
- Archive and delete are different actions; when the user says "clean up",
  archive — never delete unless they said delete.
- For "summarize my inbox" tasks, read the visible list first, then open only
  the messages whose subject lines need detail; zoom if subject text is small.

```cascade-runtime-hints
{
  "appMatchers": {
    "bundleIdentifiers": ["com.apple.mail"],
    "names": ["Mail"]
  }
}
```
