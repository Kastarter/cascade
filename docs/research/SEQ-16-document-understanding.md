# Research Sequence 16: Document and Screen-Content Understanding

## Overview

Cascade already captures the hard primitive: `ScreenTextRecognizer.recognizeBoxes(...)` returns Apple Vision OCR text lines with bounding boxes, and `RewindRecorder` persists merged AX/OCR text into `recorded_context.ocr_text`. `CascadeMemory` then indexes that flat text through `rewind_fts`, while `RecordRecall` exposes `search_record`, `get_timeframe`, and `inspect_moment` to Q&A and agents.

The missing layer is structural. Today, a screenshot containing an invoice, spreadsheet-like table, form, settings page, or code editor becomes one flat string. That makes questions like "what was the invoice total?", "extract that table", or "what code was visible?" depend on fuzzy prose reconstruction instead of a deterministic screen parse.

The highest-leverage path is not a heavy document model first. It is a pure-Swift geometry pass over Vision OCR boxes:

1. Convert boxes into ordered `OCRLine` records.
2. Cluster lines into blocks and reading-order groups.
3. Detect aligned rows/columns as tables.
4. Extract key-value pairs using text patterns plus spatial adjacency.
5. Detect lists, headings, form-like controls, and code blocks.
6. Store a versioned structured layer beside `ocr_text`, leaving FTS unchanged.

This gives Cascade auditable extraction with the same privacy posture as the current recorder: on-device OCR, deterministic geometry, and source rectangles for every answer.

## OSS / Papers

| Project / Paper | URL | License | Technique | On-device feasibility for Cascade |
|---|---|---|---|---|
| Apple Vision OCR / VisionKit / Foundation data detectors | https://developer.apple.com/documentation/vision/vnrecognizetextrequest, https://developer.apple.com/documentation/visionkit/datascannerviewcontroller, https://developer.apple.com/documentation/foundation/nsdatadetector | Apple platform APIs | Native text recognition, document/data scanning APIs, and `NSDataDetector` typed extraction for dates, links, phones, addresses, and related text entities. | High. `VNRecognizeTextRequest` is already in `ScreenTextRecognizer.swift`. `NSDataDetector` can run over recognized text immediately. VisionKit scanner APIs are more relevant to camera/document import than screen capture. |
| pdfplumber | https://github.com/jsvine/pdfplumber | MIT | Text layout, word boxes, table finding by explicit/implied lines, intersections, cells, and contiguous table grouping; includes alignment-based `"text"` table strategies. | High as an algorithm source. Its "implied lines from aligned words" table strategy maps directly to Vision OCR box clustering in Swift. |
| img2table | https://github.com/xavctn/img2table | MIT | OpenCV-based table identification/extraction for PDFs and images; intentionally lighter than neural networks and CPU-friendly. | Medium. Good inspiration for bordered-table detection and debug overlays; direct dependency would require OpenCV/C++ packaging, so port only the geometry ideas first. |
| Microsoft Table Transformer / PubTables-1M (TATR) | https://github.com/microsoft/table-transformer, https://arxiv.org/abs/2110.00061 | MIT | DETR-style object detection for table detection, structure recognition, rows, columns, cells, headers, and functional analysis. Pretrained models are about 110 MB. | Medium later, low for first pass. It is strong for page-like documents but adds model conversion, memory, and domain mismatch risk for live desktop screenshots. Use as a benchmark/larger bet. |
| PaddleOCR / PP-Structure | https://github.com/PaddlePaddle/PaddleOCR | Apache-2.0 | Full OCR/document parsing stack with PP-Structure, table, key information extraction, layout, and PDF-to-structured-data tooling. | Medium as sidecar/benchmark, low as native Swift dependency. Useful for comparing extraction quality on fixtures before porting algorithms. |
| docTR | https://github.com/mindee/doctr | Apache-2.0 | Deep-learning OCR pipeline with optional layout detection regions such as title, text, table, page header, and footer. | Medium as a Python benchmark, low as a bundled app dependency. Its region taxonomy is useful for Cascade's `OCRBlock.kind`. |
| LayoutParser | https://github.com/Layout-Parser/layout-parser, https://arxiv.org/abs/2103.15348 | Apache-2.0 | Document image analysis toolkit with layout objects, filtering by geometric intervals, OCR per region, and model-backed layout detection. | High as API inspiration, medium/low as dependency. The data structures are more valuable to Cascade than the model stack. |
| LayoutLM / LayoutLMv3 family | https://github.com/microsoft/unilm/tree/master/layoutlm, https://arxiv.org/abs/1912.13318, https://arxiv.org/abs/2204.08387 | MIT repo; model/dataset terms vary | Multimodal document AI that jointly models text tokens, layout coordinates, and visual features for forms, receipts, classification, and DocVQA. | Low for on-device first pass. Very useful as inspiration: model every token with text plus normalized box, not text alone. A smaller local ranker could come later. |
| Recursive XY-Cut / XY-Cut++ | https://arxiv.org/abs/2504.10258 | Paper technique; verify implementation licenses before reuse | Reading-order recovery by recursively splitting layout regions using whitespace and hierarchy. XY-Cut++ adds masking and matching for complex layouts. | High. The classic recursive geometry version can be implemented in Swift over OCR rectangles without model weights. |
| OCRopus / ocropy lineage | https://github.com/ocropus-archive/DUP-ocropy | Apache-2.0 | Traditional OCR/document analysis with line segmentation, page segmentation, hOCR, and modular layout processing. | Medium as old algorithm source. Good for line/block segmentation ideas, but archived and Python-centric. |
| psc2code | https://arxiv.org/abs/2103.11610 | Paper technique | Programming screencast code extraction: classify code frames, segment likely editor regions, crop code windows, OCR, then denoise with cross-frame/language-model signals. | Medium. Cascade can implement a simpler heuristic first: app allowlist plus code punctuation/indentation/line-number patterns, then use repeated frames to improve confidence. |
| Document layout analysis surveys / geometric methods | https://en.wikipedia.org/wiki/Document_layout_analysis | Mixed references | Top-down whitespace splitting, bottom-up symbol/word/line/block grouping, skew/noise handling, geometric and logical labeling. | High. Cascade already has text boxes; deterministic grouping and logical labels are the right first layer. |

## Concrete Techniques

### 1. Add a structured OCR model, not just flat text

Create a new pure-Swift parser near `Sources/MacContextKit/ScreenTextRecognizer.swift`, for example `ScreenContentStructurer.swift`.

Input:

- `[ScreenTextRecognizer.TextBox]`
- screenshot width/height
- optional AX text lines from `AXTextHarvester`
- app name, bundle id, and window title

Output:

```swift
struct StructuredScreenContent: Codable, Sendable {
    var version: Int
    var lines: [OCRLine]
    var blocks: [OCRBlock]
    var tables: [OCRTable]
    var fields: [OCRField]
    var lists: [OCRList]
    var codeBlocks: [OCRCodeBlock]
}
```

Keep each object source-grounded:

- `contextID`
- `orderIndex`
- `text`
- image-space and Vision-normalized bounds
- `source`: `ocr`, `ax`, or `merged`
- `confidence`
- evidence line ids

Storage mapping:

- Keep `recorded_context.ocr_text` and `rewind_fts` exactly as-is for compatibility.
- Add either a new `ocr_structure` table (`context_id`, `version`, `json`) or normalized `ocr_line` / `ocr_block` / `ocr_table` tables if query performance becomes important.
- Put only a compact summary in `metadata_json` if needed; do not overload `metadata_json` with full structure long-term.

### 2. Reading order and block segmentation

Start from the existing reading-order assumption in `ScreenTextRecognizer.setOfMarks`: higher `midY` first, then lower `midX`. Extend it from a target list into a full page layout pass.

Algorithm:

1. Normalize OCR boxes to pixel/display coordinates.
2. Estimate median line height and median vertical gap.
3. Merge boxes into lines when their vertical overlap or baseline distance is within tolerance.
4. Sort tokens within each line by `x`.
5. Recursively split the page by major whitespace gaps:
   - vertical splits for multi-column layouts,
   - horizontal splits for stacked sections,
   - stop when a region has too few lines or no strong gap.
6. Assign each line to an `OCRBlock` and emit block reading order.

Block labels can be deterministic:

- `heading`: short line, large box height relative to local median, whitespace below, title-like text.
- `paragraph`: multiple nearby lines with similar left edge and prose density.
- `list`: repeated bullet/number prefixes or consistent hanging indent.
- `table`: grid alignment detected by the table pass.
- `form`: dense label/value or label/control pairs.
- `code`: code heuristics from section 5.

This maps to `RewindRecorder.swift` immediately after OCR and before `CascadeStore.insert(context:)`.

### 3. Geometry-first table reconstruction

Use the pdfplumber-style `"text"` strategy before any ML detector:

1. Candidate table region:
   - at least 3 rows and 2 columns,
   - repeated x alignments across lines,
   - low prose wrapping,
   - similar row heights or regular row gaps.
2. Column anchors:
   - cluster `x0`, `midX`, and `x1` values with tolerance derived from median character width or box height,
   - require support from at least 3 rows for a column anchor,
   - prefer left/right edge clusters for numeric/currency columns.
3. Row anchors:
   - cluster line baselines or row centers by y,
   - merge wrapped cell lines when they share a column and small vertical gap.
4. Cell assignment:
   - each OCR line belongs to the nearest row and column interval,
   - preserve multiline cells as arrays plus joined text,
   - infer header row from top row text, repeated separators, or nonnumeric labels over numeric columns.
5. Export:
   - `OCRTable.cells`
   - `toMarkdown()`
   - `toCSV()`
   - source bounding boxes for every cell.

Cascade use:

- `inspect_moment` can include `TABLE 1: 5 rows x 4 columns` plus a compact Markdown preview.
- A future recall tool can expose `extract_table(id, table_index, format)` for deterministic harness extraction.
- Q&A should answer "what was the invoice total?" by checking fields and table cells before asking a model to infer from flat prose.

### 4. Key-value and form extraction

Run text detectors and spatial pairing together.

Typed detectors:

- `NSDataDetector` for dates, links, phone numbers, addresses, and transit-like references where supported.
- Regexes for currency, invoice/order IDs, emails, account-like IDs, percentages, quantities, and totals.

Geometry pairers:

- `label: value` on the same line.
- label left, value right on the same baseline.
- label above, value below with aligned left edge.
- label near an empty-looking field/control region if AX exposes a text field, checkbox, radio, or popup nearby.
- table footer rows where label contains `total`, `subtotal`, `tax`, `balance`, `amount due`, or `grand total` and a currency-like value is right-aligned.

Output:

```swift
struct OCRField: Codable, Sendable {
    var key: String
    var value: String
    var kind: FieldKind
    var confidence: Double
    var keyLineIDs: [String]
    var valueLineIDs: [String]
}
```

This makes invoice/receipt questions deterministic:

- "invoice total" -> highest-confidence `total` currency field.
- "due date" -> date detector near a `due` label.
- "who was this from" -> email/name/address block near top-left or sender labels.

### 5. Code-block detection on screen

No new model is required for a first version.

Signals:

- App/window hints: Xcode, VS Code, Cursor, Terminal, iTerm, JetBrains, Sublime, TextEdit with code-like extension in title.
- Line-number gutter: many short numeric boxes with aligned right edge.
- Monospace proxy: similar character pitch inferred from OCR box width / text length.
- Syntax density: braces, semicolons, `=>`, `==`, imports, `func`, `let`, `var`, `class`, `struct`, `if`, `for`, `return`, shell prompts.
- Indentation: repeated left-edge steps and leading whitespace reconstructed from x gaps.
- Low natural-language sentence density.

Store a code block with:

- app/window language hint,
- reconstructed text,
- line boxes,
- confidence,
- crop bounds.

For Q&A, `inspect_moment` can return code blocks as fenced snippets. For harness extraction, a deterministic `extract_code_block` tool could write the visible code into a file without asking a model to retype from a screenshot.

### 6. Retrieval and harness integration

`RecordRecall` currently returns text lines from `recorded_context`. Extend its output, not its privacy model.

Recommended changes:

- `search_record`: keep concise text hits, but boost moments with structured matches (`field.key`, table header/cell text, code block symbols).
- `inspect_moment`: append a bounded `STRUCTURE` section:
  - headings,
  - fields,
  - tables with dimensions and preview rows,
  - list summaries,
  - code block summaries.
- `get_timeframe`: keep session-level behavior, but include top structured entities per session.
- Harness: when the user asks to "extract that table" or "copy the invoice total", use structured OCR data and source boxes first; only fall back to visual action if no structure exists.

Potential tool definitions:

- `extract_table`: `{ "moment_id": 123, "table_index": 0, "format": "csv" }`
- `extract_fields`: `{ "moment_id": 123, "query": "invoice total due date vendor" }`
- `extract_code_block`: `{ "moment_id": 123, "block_index": 0 }`

These should resolve in-process like `RecordRecall` and `AgentHarness`, with every extraction audited and source-cited.

## Quick Wins vs Larger Bets

### Quick Wins

1. **Structured OCR JSON sidecar**
   - Add `ScreenContentStructurer`.
   - Persist one JSON blob per context in a new `ocr_structure` table.
   - Keep `ocr_text` and FTS untouched.

2. **Line, block, heading, list detection**
   - Pure Swift over `TextBox`.
   - Unit-test with synthetic OCR boxes.
   - Use deterministic thresholds based on median line height/gap.

3. **Key-value extraction**
   - Add `NSDataDetector` plus regex/entity pass.
   - Pair labels and values by same-line and nearest-neighbor geometry.
   - Use this first for invoice/receipt totals.

4. **Table reconstruction v1**
   - Implement pdfplumber-inspired text alignment strategy.
   - Export Markdown/CSV.
   - Add confidence and source boxes for each cell.

5. **`inspect_moment` structure summary**
   - Add a compact bounded section to `RecordRecall`.
   - Let Q&A and agents see fields/tables/code without re-parsing flat text.

6. **Debug overlay**
   - Reuse the existing guidance/debug drawing style to show OCR blocks, table cells, and field pairs over a frame.
   - This is essential for tuning thresholds and auditing extraction failures.

### Larger Bets

1. **Core ML table detector**
   - Convert or replace TATR for table detection on document-like screenshots.
   - Keep the geometry extractor as the text/cell assignment layer.

2. **PaddleOCR/docTR/LayoutParser comparison harness**
   - Run these offline against Cascade fixtures to learn failure cases.
   - Do not bundle until they beat the Swift geometry path on real screen captures.

3. **LayoutLM-style local ranker**
   - Train or fine-tune a small classifier over `(text, bbox, block kind, neighbors)` for field roles such as total, vendor, due date, address, and account.
   - Use geometry features first; avoid a huge multimodal model.

4. **Cross-frame structure stabilization**
   - Merge the same table/form/code block across adjacent frames.
   - Improve confidence when fields persist over time and reduce OCR jitter.

5. **Code OCR correction**
   - For code blocks, use app/window/language hints and repeated-frame voting.
   - Later, add a small local language-aware corrector for visible code, inspired by psc2code.

## Implementation Shape

Recommended first slice:

1. `Sources/MacContextKit/ScreenContentStructurer.swift`
   - `structure(boxes:imageSize:appName:windowTitle:axText:) -> StructuredScreenContent`
   - reading order, blocks, lists, headings, fields, table candidates.

2. `Sources/CascadeMemory/CascadeMemory.swift`
   - add `ocr_structure(context_id INTEGER PRIMARY KEY, version INTEGER, json TEXT NOT NULL)`
   - prune with `recorded_context`.
   - retrieval helper `structure(forContextID:)`.

3. `Sources/MacContextKit/RewindRecorder.swift`
   - after `recognizeBoxes`, structure once and persist with the inserted context id.
   - keep current `ocr_text` generation unchanged.

4. `Sources/ProviderKit/RecordRecall.swift`
   - enrich `inspect_moment` with bounded structural summaries.
   - later add extraction tools after the structure is stable.

5. Tests
   - synthetic two-column reading order,
   - invoice key-values,
   - borderless table with aligned columns,
   - list detection,
   - code block detection from OCR-like boxes,
   - retention pruning removes structures.

This is a small architectural addition with a large product payoff: Cascade can answer and act on what the user saw as structured facts, not just a bag of OCR words.
