---
name: keynote-applescript
description: AppleScript fallback for Keynote — PDF/PowerPoint exports and batch edits over existing decks (presenter notes, retitles, skipping) via osascript.
useWhen: ONLY when the user asks for a script, or for PDF/PowerPoint exports and batch passes over an EXISTING deck (presenter notes, retitles across many slides) — building decks happens in Keynote's UI
explicitAskOnly: true
---

# Keynote — AppleScript for exports and batch edits

Decks are BUILT in Keynote's own UI — `keynote` plus `keynote-consulting`;
Outline view enters a whole skeleton as fast as any script without leaving
the app. Reach for AppleScript only when the user explicitly asked for a
script, the task is a PDF/PowerPoint export, or a batch pass over an
existing deck (presenter notes, retitles on many slides) that the UI route
already failed at. AppleScript runs through Terminal, which abandons the
app the user is watching — that makes it the exception, never the default.
When you do script, pull `terminal` for driving Terminal and `keynote` for
the hand-finishing.

Scripting fills CONTENT: documents, slides with layouts, title/body text,
presenter notes, skipped flags, exports, and plain text items with exact
position/size. It can NOT style: no text alignment, bullet styles,
per-paragraph formatting, or table/chart looks — finish those in the UI.

## Addressing the app

Use `tell application id "com.apple.Keynote"` — the 15.x build's app NAME is
"Keynote Creator Studio", so the name form breaks on it. On a legacy-only
Mac (bundle `com.apple.iWork.Keynote`) that id errors "can't be found":
fall back to `tell application "Keynote"`.

## First run — Automation consent

The first osascript that controls Keynote pops a consent dialog: «"Terminal"
wants access to control "Keynote"». Click OK yourself — it is on screen. If
Don't Allow was ever clicked, every script fails with error -1743 and macOS
NEVER re-asks; the fix lives in System Settings → Privacy & Security →
Automation. Don't retry the script against -1743 — switch to UI clicking or
tell the user.

## Dictionary facts

- The UI says "slide layouts"; the dictionary still says `master slide`
  (class) and `base slide` (slide property). Master slides belong to the
  DOCUMENT — resolve `master slide "Title & Bullets"` at document level,
  never inside a slide tell block.
- Layout names vary by theme — when one errors, list them first:
  `get name of every master slide of front document`.
- Every slide has a `default title item` and `default body item` (on a
  Title & Subtitle layout the body IS the subtitle). Multi-line body text:
  join lines with `& return &`.
- One script run = one shot: screenshot Keynote after each run and judge
  visually — osascript prints errors to Terminal, but a "no error" run can
  still have put text on the wrong slide.

## Snippets

Deck skeleton — theme, title slide, sections (run as one Terminal paste):

```bash
osascript <<'EOF'
tell application id "com.apple.Keynote"
  activate
  set deck to make new document with properties {document theme:theme "Basic White"}
  tell deck
    set object text of default title item of slide 1 to "Onboarding redesign cut churn 18%"
    set object text of default body item of slide 1 to "Client readout — June 2026"
    repeat with t in {"Agenda", "Where churn stands", "What drove the drop", "Next steps"}
      set s to make new slide with properties {base slide:master slide "Title & Bullets"}
      set object text of default title item of s to t
    end repeat
  end tell
end tell
EOF
```

Body bullets on one slide:

```bash
osascript -e 'tell application id "com.apple.Keynote" to set object text of default body item of slide 2 of front document to "Kickoff and data request" & return & "Diagnostic findings" & return & "Recommendations"'
```

Presenter notes:

```bash
osascript -e 'tell application id "com.apple.Keynote" to set presenter notes of slide 2 of front document to "Pause here — ask about the Q3 caveat."'
```

Skip a slide / export PDF (long decks need the timeout):

```bash
osascript -e 'tell application id "com.apple.Keynote" to set skipped of slide 3 of front document to true'
osascript <<'EOF'
tell application id "com.apple.Keynote"
  set out to (path to desktop folder as text) & "deck.pdf"
  with timeout of 300 seconds
    export front document to file out as PDF
  end timeout
end tell
EOF
```

For PowerPoint replace `as PDF` with `as Microsoft PowerPoint` and use a
`.pptx` filename.

After the final script, switch to Keynote and screenshot the navigator —
declare the skeleton done from what the slides show, never from script
success alone. Styling passes (alignment, sizes, tables, charts) continue by
hand with the `keynote` and `keynote-consulting` skills.
