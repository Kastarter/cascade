---
name: keynote-consulting
description: Build consulting-style business decks in Keynote — action titles, agendas, takeaways, 2x2 matrices, comparison tables, charts.
useWhen: building a business, consulting, or executive deck in Keynote — readouts, proposals, agendas, takeaways, 2x2s, comparison slides
---

# Keynote — consulting decks

Pull `keynote` too — its focus model, field-not-keys rule, and table/chart
mechanics apply to every recipe here. Build entirely in Keynote's UI —
Outline view (below) enters a whole skeleton in one pass; never detour to
Terminal or AppleScript unless the user asked for a script or an export.

## Style rules — apply to every slide

- ACTION TITLES: the headline is a full-sentence takeaway, not a topic label.
  "Onboarding redesign cut churn 18% in Q3", never "Q3 churn". One or two
  lines, top of slide, the largest text on it.
- One message per slide; everything on the slide supports its title.
- At most 5 bullets, one line each, parallel grammar ("Reduce…", "Expand…",
  "Launch…" — not a mix of fragments and sentences).
- Body text 24 pt or larger — set sizes by typing the number in Format >
  Text's size field, never by mashing `cmd+plus`. If text auto-shrinks, cut
  words instead.
- Titles come from layout placeholders only — never draw a title as a free
  text box, or it will sit at a different position on every slide.
- In tables: numbers right-aligned, labels left-aligned, one header row.

## Theme

`Basic White` (or `Basic Black` for a dark deck). New deck: double-click it
in the theme chooser. Existing deck: File → Change Theme → pick → Choose.

## How experienced users actually build — copy this

- TEXT FIRST, STYLE SECOND. Enter the whole deck's titles and bullets in
  Outline view (toolbar View → Outline): type a title, `Return` starts the
  next slide, `Tab` demotes the line to a bullet, `shift+Tab` promotes back
  to a new slide. Then switch back to Navigator view and style.
- DUPLICATE, DON'T REBUILD. The next slide of the same shape is `cmd+d` on
  the previous one in the navigator, then edit its text — never compose the
  same kind of slide twice from a blank layout. Same on the canvas: style
  ONE object completely, then `cmd+d` it (the copy lands slightly offset
  and selected — reposition it immediately) and only change what differs.
- PROPAGATE STYLE, DON'T REFORMAT. `cmd+option+c` copies an object's or
  text's full style, `cmd+option+v` pastes it onto the next selection.
- ALIGN BY COMMAND, NOT BY EYE. `shift`+click the objects that must line
  up → Format → Arrange → Align (edges) / Distribute (even spacing).
  Alignment guides don't snap to other objects — dragging until it "looks
  right" is how decks get crooked.
- LOCK FINISHED SCAFFOLDING. Once axes, dividers, or background shapes are
  placed, Arrange → Lock them so later clicks can't drag them. Unlock via
  Arrange → Unlock if you must edit again.
- Bringing text in from elsewhere: Edit → Paste and Match Style (by MENU),
  so foreign fonts and sizes don't ride along.

## Slide recipes

- Title slide — layout `Title & Subtitle` (a new deck opens on it): title =
  the engagement's one-line conclusion or the deck name; subtitle = client +
  date.
- Agenda — layout `Title & Bullets`, title "Agenda", one bullet per section,
  no sub-bullets.
- Executive summary — `Title & Bullets`: action title carrying the single
  overall message, then 3–5 bullets, one per supporting section, mirroring
  the agenda order.
- Three takeaways — `Title & Bullets` with exactly 3 bullets; or, more
  consulting-styled, `Title - Top` plus three text boxes side by side:
  build and style the FIRST box fully, set its exact Y/W/H in Arrange, then
  `cmd+d` twice and set only X on the copies — never style three boxes
  separately.
- 2x2 matrix — layout `Title - Top`. Toolbar `Shape` → straight line,
  twice: one horizontal, one vertical, crossing at the content area's
  center — set each line's position and length in Format → Arrange, then
  LOCK both lines (Arrange → Lock). Quadrant labels: one styled text box,
  `cmd+d` three times, place by Arrange X/Y; two more for the axis labels.
  Alternative when speed beats looks: a 2x2 table with headers set to 0 —
  always axis-aligned, but no axes.
- Comparison table — `Title - Top` or `Blank`, then the table mechanics from
  the `keynote` skill: insert, set the column count with the top-right
  control, one header row via Headers & Footers. Fill cell-by-cell —
  single-click, type, `Tab` across, `Return` down; NEVER paste the whole
  table's text in one go (it lands in one cell). Line break inside a cell:
  `option+return`.
- Chart slide — `Title - Top`, toolbar `Chart` → 2D column (or bar for long
  category names) → `Edit Chart Data`, enter the real numbers keeping every
  click inside the floating editor, close it. One chart per slide; the
  title states what the chart proves.
- Section divider — layout `Title - Center` with only the section name.
- Quote — layout `Quote`: quote placeholder + attribution placeholder.
- Next steps / closing — `Title & Bullets`, title "Next steps", one bullet
  per action with owner and date ("Maha to circulate revised model — Jun 17").

## Build order

1. Skeleton first: every slide with its layout and action title before any
   body content — Outline view does this in one pass, and wrong structure
   surfaces early in the navigator.
2. Fill slide by slide, completing one before the next; screenshot after
   each to confirm the text landed in the right placeholder.
3. Presenter notes (if asked) as a final pass: `cmd+shift+p` once, then
   navigator-click each slide and type into the notes pane.
4. Deliverable pass: flip through the navigator to spot-check that titles
   sit at identical positions, then export (File → Export To) if the user
   wants a PDF or PowerPoint file.
