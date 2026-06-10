---
name: spreadsheets
description: Working with cells, formulas, and fills in Numbers or Excel.
useWhen: entering data, formulas, sorting, or filling ranges in Numbers, Excel, or Google Sheets
---

# Spreadsheets

- Click a cell ONCE, then type — typing replaces the cell's content. Double-click
  only to edit existing content in place.
- `Return` commits and moves down; `Tab` commits and moves right; `Escape`
  cancels the edit. Commit every cell — an uncommitted cell loses its value
  when you click elsewhere.
- Formulas start with `=`. Type cell references like `B2` directly; clicking
  cells mid-formula inserts their reference but is easy to misfire — prefer
  typing references.
- Fill a column: enter the first value/formula, select the range, then
  `cmd+d` (fill down) in Excel/Numbers. For Google Sheets use `cmd+d` too.
- Headers matter: row 1 is usually labels — start data at row 2 unless the
  sheet says otherwise.
- After entering a batch, take a fresh screenshot and verify a couple of cells
  actually contain what you typed before declaring done.
- Don't resize columns/rows unless asked; accidental drags on header borders
  do that — click header centers, not edges.

```cascade-runtime-hints
{
  "appMatchers": {
    "bundleIdentifiers": ["com.apple.iWork.Numbers", "com.microsoft.Excel"],
    "names": ["Numbers", "Microsoft Excel"]
  }
}
```
