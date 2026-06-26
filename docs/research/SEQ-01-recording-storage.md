# SEQ-01 Recording, Storage, and Timeline Retrieval Research

## Overview

Cascade already has a strong Swift-first recorder foundation:

- `Sources/MacContextKit/RewindRecorder.swift` records ScreenCaptureKit frames through `RewindStreamOutput`, computes a 3x3 dHash grid with `PerceptualHash`, writes JPEG frames through `FrameStore`, runs AX harvesting and Vision OCR in `RewindEngine`, and inserts `RecordedContext` rows.
- `Sources/MacContextKit/ScreenCapture.swift` caps capture to 1920 px, uses ScreenCaptureKit for live streams and screenshots, and includes a native-resolution zoom capture path for sparse-text windows.
- `Sources/MacContextKit/ScreenTextRecognizer.swift` wraps Apple Vision text recognition, including bounding-box recognition via `recognizeBoxes`, but the recorder currently stores only merged text.
- `Sources/MacContextKit/AXTextHarvester.swift` performs bounded AX-tree harvesting and merges AX-first text with OCR lines.
- `Sources/MacContextKit/InputRecorder.swift` records listen-only mouse, keyboard, scroll, and AX click labels, but those events do not currently drive capture cadence.
- `Sources/CascadeMemory/CascadeMemory.swift` stores `recorded_context`, `input_event`, `audit_event`, FTS5 (`rewind_fts`), and embeddings (`context_embedding`) in SQLite WAL, with age and size pruning.
- `Sources/CascadeMemory/SemanticIndex.swift` uses on-device `NLEmbedding` word-vector averaging and brute-force cosine search, fused with FTS via `RankFusion`.

The biggest production gap is that Cascade treats capture as a fixed 1 fps image stream with frame-level dedup. Market-leading open-source tools increasingly treat recording as an event-indexed memory system: capture on app switches, clicks, typing pauses, scroll ends, and idle heartbeats; store video segments or compressed frame groups instead of loose JPEG piles; retain structured text geometry; and query sessions rather than only individual frames.

The recommendations below prioritize techniques that are portable into Swift and compatible with Cascade's local-first, audited enterprise posture.

## OSS Repos & Papers

| name | url | license | technique | maturity |
| --- | --- | --- | --- | --- |
| Screenpipe | https://github.com/screenpipe/screenpipe | Source-available commercial license; personal/noncommercial/research free, commercial license required | Event-driven screen capture on app switch, click, typing pause, scroll, clipboard, plus idle fallback; full accessibility tree first, OCR fallback; SQLite FTS5; local-first filters and optional encryption; claims roughly 300 MB per 8 hours for screenshots vs about 2 GB continuous | High adoption and active: about 19.5k stars, 10k+ commits. Strong architecture reference, but do not port code without commercial clearance |
| OpenRecall | https://github.com/openrecall/openrecall | AGPL-3.0 | Local screenshot snapshots, OCR/text extraction, semantic search, privacy-first no-cloud workflow | Moderate: about 2.9k stars, about 90 commits, limited release maturity |
| Windrecorder | https://github.com/yuka-friends/Windrecorder | GPL-2.0 | Changed-scene indexing, active-window/multi-monitor recording, custom skip rules by app/title/text/stillness, OCR, browser URL/title capture, and 15-minute screenshot-to-video compaction; reports 2-100 MB/hour and 10-20 GB/month | Mature hobby app: about 3.9k stars, 500+ commits. Strong storage architecture reference, GPL code is not portable into proprietary Cascade |
| rem | https://github.com/jasonjmcghee/rem | MIT | Swift macOS app; screenshot every 2 seconds; OCR, timeline scrubber, app filtering, local vector embeddings, efficient local history UX | Relevant Swift-native reference: about 2.5k stars, about 200 commits; alpha-stage but practical |
| xrem | https://github.com/jasonjmcghee/xrem | MIT | Cross-platform Rust/Tauri rewrite; non-blocking screenshots, OCR, embeddings, stream frames directly to MP4 instead of writing PNGs, timeline seeking/cache notes | Early but useful: about 280 stars, about 40 commits; validates stream-to-video direction |
| Memento | https://github.com/apirrone/Memento | MIT | Screenshots every 2 seconds, H.264 video segment compaction, OCR, SQLite/vector DB, FTS5, LLM chat over screen memory | Small but complete: about 650 stars, 200+ commits, release v0.1.2; reports about 120 MB/hour |
| pHash | https://github.com/aetilius/pHash | GPL-3.0 | DCT pHash, Radon/Radish, Marr-Hildreth wavelet hash, and DCT video hash with keyframe detection and LCS matching | Mature perceptual-hash library: about 600 stars and 600 commits. Use only as algorithm reference because GPL |
| ImageHash | https://github.com/JohannesBuchner/imagehash | BSD-2-Clause | Average hash, dHash, pHash, wavelet hash, HSV color hash, crop-resistant hashing; Hamming-distance thresholding guidance | Mature Python reference: about 3.8k stars. Good permissive reference for algorithm behavior and tests |
| blockhash | https://github.com/commonsmachinery/blockhash | MIT | Block Mean Value Based Image Perceptual Hashing; robust block-level perceptual hash suited to screen regions | Small but permissive: about 90 stars. Algorithm is simple and portable to Swift |
| Tesseract OCR | https://github.com/tesseract-ocr/tesseract | Apache-2.0 | Mature offline OCR with LSTM engine, 100+ languages, multiple output formats | Very mature. Useful as optional language fallback, but not ideal for Cascade's hot path |
| RapidOCR | https://github.com/RapidAI/RapidOCR | Apache-2.0 | Lightweight offline OCR using ONNX-converted PaddleOCR models; multi-platform, multi-language, low-resource deployment | Active: about 7k stars. Good candidate for optional background "OCR rescue" sidecar |
| PaddleOCR | https://github.com/PaddlePaddle/PaddleOCR | Apache-2.0 | High-accuracy multilingual OCR and document parsing, PP-OCRv6 claims better CPU speed and accuracy across 50+ languages | Very mature: 80k+ stars. Powerful but heavier than Cascade's hot path |
| EasyOCR | https://github.com/JaidedAI/EasyOCR | Apache-2.0 | 80+ language OCR, bounding boxes, confidence scores, CPU mode | Mature Python OCR benchmark reference; less directly Swift-portable |
| FFmpeg | https://ffmpeg.org/about.html and https://ffmpeg.org/legal.html | LGPL-2.1+ by default; GPL/nonfree depending on build flags | Video encode/decode/muxing, including H.264/H.265/AV1 pipelines if legal constraints are met | Industry-standard, but Cascade should prefer AVFoundation/VideoToolbox first to avoid bundling/licensing burden |
| Reciprocal Rank Fusion | https://plg.uwaterloo.ca/~gvcormac/cormacksigir09-rrf.pdf | Academic paper | Robust fusion of multiple ranked lists with `1 / (k + rank)`, commonly `k = 60`; improves over individual lexical systems | Cascade already implements this in `RankFusion.swift`; keep it |
| SQLite FTS5 docs | https://www.sqlite.org/fts5.html | Public SQLite documentation | External-content FTS5, prefix indexes, `columnsize`, `detail`, BM25 ranking, optimize/merge maintenance knobs | Directly applicable. Cascade already uses external-content FTS5 but does not yet use maintenance and schema tuning aggressively |
| ColBERT | https://arxiv.org/abs/2004.12832 | Academic paper | Late-interaction retrieval: pre-compute token-level document representations and use cheap query-time matching | Larger bet for session/chunk retrieval. Too heavy for first pass, but relevant if word-vector averaging caps quality |
| Hamming Distributions of Popular Perceptual Hashing Techniques | https://arxiv.org/abs/2212.08035 | Academic paper | Large-scale analysis of Hamming-distance distributions for pHash, PDQ, NeuralHash, and variants under image transforms | Useful for replacing Cascade's hard-coded hash thresholds with measured false-positive/false-negative curves |
| State of the Art: Image Hashing | https://arxiv.org/abs/2108.11794 | Academic survey | Survey of traditional and deep hashing for duplicate and near-duplicate image retrieval | Good algorithm selection reference for dHash vs pHash vs wavelet/block hashes |
| Near-Duplicate Video Detection with Temporal and Perceptual Structures | https://arxiv.org/abs/2005.07356 | Academic paper | Combines temporal structure and perceptual visual structure using N-gram sliding windows and logical inference matching | Maps well to Cascade's future sequence-of-frame-hashes dedup and video segment search |
| HEVC Screen Content Coding: Intra Prediction | https://arxiv.org/abs/1511.01862 | Academic paper | Screen content has sharp edges and repeated structure; specialized intra prediction improves bit rate | Supports moving from JPEG piles to screen-optimized video segments |
| Improved Screen Content Coding in VVC | https://arxiv.org/abs/2305.05440 | Academic paper | Screen regions often have repeated colors and blocks; palette and intra-block-copy style coding reduces bitrate | Supports AVFoundation/VideoToolbox segment compaction and region-aware dedup |

## Concrete Techniques to Adopt

### 1. Replace fixed-save cadence with an event-driven capture scheduler

Current code:

- `RewindRecorder.start(displayID:fps:)` defaults to `fps = 1`.
- `ScreenCaptureUtility.makeRewindStream(displayID:fps:)` sets `SCStreamConfiguration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))`.
- `InputRecorder` records meaningful interaction events but does not influence capture cadence.
- `ContextRecorder.handleAppActivated` already triggers a debounced `captureOnce` after app activation, proving this pattern fits the codebase.

Change:

- Add a `CaptureScheduler` in `MacContextKit` with capture reasons such as `streamHeartbeat`, `appActivated`, `click`, `typingPause`, `scrollEnd`, `windowChanged`, and `idleHeartbeat`.
- Let `InputRecorder` expose an optional callback, for example:
  - `var onActivity: (@Sendable (InputActivity) -> Void)?`
  - Emit privacy-safe activity types after the existing sensitivity gates in `record(_:)` and `flushTypedBuffer`.
- In `ContextRecorder.start`, wire `InputRecorder.onActivity` to a scheduler that debounces:
  - clicks: capture after 150-300 ms,
  - typing: capture after 600-900 ms of pause,
  - scroll: capture after 300-500 ms of no scroll,
  - app activation: keep the existing 1.5 second settle capture,
  - idle heartbeat: 5-15 seconds only when content is changing.
- In `RewindStreamOutput.stream`, keep SCStream as a low-latency producer, but call OCR/storage only when the scheduler marks the latest frame as worth keeping. This is less invasive than replacing SCStream with one-shot screenshots.

Impact:

- Reduces Vision OCR and JPEG writes during static screens.
- Captures semantically important transitions faster than a blind 1 fps tick.
- Aligns Cascade with Screenpipe's event-driven architecture while preserving Swift/ScreenCaptureKit control.

### 2. Disable cursor capture in rewind frames and reconstruct pointer context from input events

Current code:

- `ScreenCaptureUtility.makeRewindStream` sets `configuration.showsCursor = true`.
- `PerceptualHash.isDuplicateGrid` can treat cursor-only movement as regional visual change.
- `InputRecorder` already records click positions and labels.

Change:

- Set `configuration.showsCursor = false` for rewind capture streams.
- Keep cursor visible for foreground computer-use screenshots if needed, but not for long-term memory frames.
- For timeline replay, render click markers from `input_event.x`, `input_event.y`, `timestamp`, and AX label metadata rather than baking cursor pixels into every frame.

Impact:

- Fewer false "changed" frames from cursor jitter.
- Cleaner OCR inputs.
- Smaller storage and less noisy dedup.

### 3. Add stronger multi-hash frame signatures and changed-region metadata

Current code:

- `PerceptualHash.hash(cgImage:)` implements 64-bit dHash.
- `PerceptualHash.gridHashes(cgImage:)` computes a 3x3 grid of dHashes.
- `RewindStreamOutput` drops only when every grid region is within `gridSkipThreshold`.
- `RecordedContext.frameHash` stores only a folded `combinedHash`.

Change:

- Extend `PerceptualHash.swift` with one additional Swift-native hash:
  - DCT pHash, using a 32x32 luminance resize and 8x8 low-frequency DCT median bits, or
  - block mean hash using the MIT `blockhash` algorithm as reference.
- Add a `FrameSignature` value:
  - `dhash: UInt64`
  - `gridDHash: [UInt64]`
  - `phash: UInt64?`
  - `changedCellsMask: UInt16`
  - `textDigest: UInt64?`
- In `RewindStreamOutput`, compute the changed-cell mask against `lastGrid` before folding hashes.
- Add storage for signatures:
  - either columns on `recorded_context` for quick wins (`frame_width`, `frame_height`, `frame_bytes`, `changed_cells_mask`, `capture_reason`),
  - or a new `frame_signature(context_id, algorithm, values_blob, changed_cells_mask)` table for cleaner evolution.
- Tighten duplicate decisions to require both visual and textual stability:
  - same bundle/window bucket,
  - low visual Hamming distance,
  - no meaningful AX/OCR text digest change.

Impact:

- Reduces duplicate frames caused by cursor, blinking caret, small animations, and ads.
- Prevents missed captures where small text changes occur in only one region.
- Gives future retrieval a cheap "what changed" signal.

### 4. Compact older frames into AVFoundation video segments

Current code:

- `FrameStore.save(_:)` writes one JPEG per captured context.
- `CascadeStore.prune(maxAge:maxBytes:)` enforces retention by walking frame paths, checking file size, deleting rows, and deleting orphan files.
- `RecordedContext.imagePath` assumes a still image path.

Open-source pattern:

- Windrecorder converts screenshots into videos every 15 minutes.
- Memento stores H.264 video segments.
- xrem streams directly to MP4 instead of writing image files.

Change:

- Keep recent frames as JPEGs for fast UI thumbnails, for example last 24 hours or last N GB.
- Add asynchronous compaction for older frames:
  - group by display, dimensions, and 15-minute time bucket,
  - write an H.264 or HEVC segment using `AVAssetWriter` and VideoToolbox,
  - preserve sharp text with a screen-content preset: low frame rate, high quality, keyframes every few seconds, no heavy blur,
  - verify segment seek before deleting original JPEGs.
- Add schema:
  - `frame_segment(id TEXT PRIMARY KEY, start_at TEXT, end_at TEXT, path TEXT, codec TEXT, width INTEGER, height INTEGER, bytes INTEGER, frame_count INTEGER, created_at TEXT)`
  - add nullable `segment_id`, `segment_time_ms`, `image_kind`, and `image_bytes` to `recorded_context`
- Update retrieval:
  - `context(id:)` can return still-image contexts as today.
  - UI paths that need thumbnails first use `imagePath`; if missing, seek `segment_id` at `segment_time_ms` and cache a thumbnail.

Impact:

- Largest storage-footprint improvement.
- Enables longer retention without changing privacy posture.
- Avoids GPL/FFmpeg issues by using Apple's native AVFoundation/VideoToolbox stack.

### 5. Store OCR/AX text as structured lines with geometry

Current code:

- `ScreenTextRecognizer.recognizeBoxes(in:)` already returns bounding boxes.
- `RewindEngine.process` calls `recognizeText` and `AXTextHarvester.text`, then `AXTextHarvester.merge(ax:ocr:)`.
- `recorded_context.ocr_text` stores a flattened string.

Change:

- Replace the recorder's OCR call with `recognizeBoxes` for Vision paths.
- Add a table:
  - `ocr_line(context_id INTEGER, line_index INTEGER, source TEXT, text TEXT, x REAL, y REAL, width REAL, height REAL, confidence REAL, PRIMARY KEY(context_id, line_index, source))`
- Store AX lines too, using `source = 'ax'`, and preserve Vision/native-res crop lines as `source = 'vision'` or `source = 'vision_native_crop'`.
- Keep `recorded_context.ocr_text` as the merged FTS document, generated from structured lines for compatibility.
- Extend `AXTextHarvester` later to return structured records with role/title/value/source path instead of only a joined string.

Impact:

- Enables search result highlighting directly on screenshots.
- Improves "where did I see X" grounding.
- Gives privacy rules and future redaction exact regions instead of full-frame drops only.
- Improves manager/audit explainability because text evidence can point to a line and region.

### 6. Fix embedding coverage gaps and move from frame embeddings to chunk/session embeddings

Current code:

- `RewindEngine.process` calls `store.indexEmbedding(for: context)` after `store.insert`.
- `ContextRecorder.captureNow(reason:)` inserts a `RecordedContext` but does not call `indexEmbedding`.
- `SemanticIndex.search` brute-force scans every `context_embedding` row and embeds only the first 1000 chars.

Change:

- Immediate bug fix: call `try? store.indexEmbedding(for: context)` in `ContextRecorder.captureNow(reason:)` after `store.insert(context)`.
- Add chunk embeddings:
  - chunk long `ocr_text` by visual line groups or 500-1000 chars,
  - store in `context_embedding(context_id, chunk_index, vector, text_digest)` or a new `context_chunk_embedding` table,
  - keep the current per-context embedding as a summary vector for compatibility.
- Add app/time filters to semantic search:
  - `semantic.search` should accept optional time range and bundle/app filters before scoring vectors.
- Add a materialized `session` or `timeline_episode` table derived from `SessionSegmenter`:
  - `id`, `start_at`, `end_at`, `bundle_identifier`, `app_name`, `window_title_hint`, `context_count`, `representative_context_id`, `summary_text`.
  - Query sessions first, then frames inside sessions.

Impact:

- Fixes missing semantic retrieval for explicit captures.
- Reduces noise from one-frame retrieval.
- Makes timeline search feel closer to human memory: "that Pages editing session" rather than a pile of near-identical frames.

### 7. Add SQLite retrieval and retention maintenance

Current code:

- `CascadeStore.migrate` enables WAL and creates external-content FTS5.
- Indexes exist mainly on `recorded_context(captured_at)`, `input_event(timestamp)`, and audit fields.
- `prune(maxAge:maxBytes:)` stats files on every survivor to enforce byte retention.

Change:

- Add indexes:
  - `CREATE INDEX IF NOT EXISTS idx_recorded_context_bundle_time ON recorded_context(bundle_identifier, captured_at);`
  - `CREATE INDEX IF NOT EXISTS idx_recorded_context_app_time ON recorded_context(app_name, captured_at);`
  - if segments are added, `CREATE INDEX idx_recorded_context_segment ON recorded_context(segment_id, segment_time_ms);`
- Persist `image_bytes` on insert so `prune` can calculate storage pressure without filesystem stats for every row.
- During retention maintenance:
  - checkpoint WAL after large deletes,
  - run `PRAGMA optimize`,
  - periodically run `INSERT INTO rewind_fts(rewind_fts) VALUES('optimize')` after bulk deletes,
  - consider `VACUUM` only during explicit maintenance windows because it can be expensive.
- Benchmark FTS5 prefix indexes for the current prefix query style:
  - Cascade currently builds queries like `"token"*`.
  - FTS5 `prefix='2 3'` can accelerate short prefix lookups at extra disk cost.
- Keep `bm25(rewind_fts)` unless a measured disk issue forces `columnsize=0`; SQLite documents that `columnsize=0` can save space but makes BM25 and size-aware ranking slower.

Impact:

- Faster app-scoped timeline queries.
- Lower hourly retention overhead.
- More predictable database size over multi-day recording.

### 8. Add user and enterprise skip rules beyond substring privacy

Current code:

- `PrivacyRules` is a static substring deny-list over app, bundle, window, and text.
- `RewindEngine.process` applies rules pre-OCR and post-OCR.

Open-source pattern:

- Windrecorder supports skip conditions by app title, process, text, and stillness.
- Screenpipe exposes pipe-level and data-access filtering.

Change:

- Add persisted skip rules:
  - `privacy_rule(id, scope, match_kind, pattern, action, enabled, created_at)`
  - scopes: `bundle`, `app`, `window_title`, `ocr_text`, `url`, `duration`, `stillness`
  - actions: `drop_frame`, `drop_text`, `pause_recording`, `audit_only`
- Extend `PrivacyRules` to load static defaults plus store-backed org/user rules.
- Add an audit event when a rule drops a frame, without logging the sensitive matched text.

Impact:

- Better enterprise acceptance.
- Lets admins tune recording for HR, finance, legal, password managers, and healthcare apps without code changes.

### 9. Add optional OCR quality rescue outside the hot path

Current code:

- Apple Vision `.fast` runs when AX text is rich.
- Apple Vision `.accurate` runs for sparse AX windows.
- Native-res crop OCR runs every 3 seconds for focused sparse windows.

Change:

- Keep Vision as the default hot path.
- Add a background, opt-in OCR rescue queue for low-confidence or sparse captures:
  - trigger when Vision returns very few lines for text-heavy apps,
  - run on downscaled/cropped regions only,
  - store engine metadata in `ocr_line.source`.
- Evaluate:
  - RapidOCR for a portable ONNX-based sidecar,
  - Tesseract for broad language fallback,
  - PaddleOCR only if the app can tolerate model size.

Impact:

- Improves non-English and difficult UI retrieval without harming battery during normal recording.
- Keeps enterprise deployments deterministic because OCR rescue can be disabled.

## Quick Wins vs Larger Bets

### Quick Wins

1. In `ScreenCaptureUtility.makeRewindStream`, set rewind `showsCursor` to `false` and rely on `input_event` click positions for pointer history.
2. In `ContextRecorder.captureNow(reason:)`, call `store.indexEmbedding(for:)` after `store.insert`.
3. Add `frame_width`, `frame_height`, `image_bytes`, `capture_reason`, and `changed_cells_mask` fields to `recorded_context` or `metadata_json`; use `image_bytes` in `CascadeStore.prune`.
4. Add app/time indexes to `recorded_context` for timeline filtering.
5. Run FTS and SQLite maintenance during retention: `PRAGMA optimize`, FTS5 optimize after bulk deletes, and WAL checkpoints.
6. Use `ScreenTextRecognizer.recognizeBoxes` for new recorder captures and persist `ocr_line` rows, while keeping merged `ocr_text` for current FTS.
7. Add a deterministic `textDigest` check to dedup so small text changes are not accidentally skipped.
8. Add user/org skip rules to `PrivacyRules` for bundle/window/title/text patterns.

### Larger Bets

1. Build `CaptureScheduler` and wire `InputRecorder`, app activation, scroll, and idle heartbeats into event-driven capture gates.
2. Add AVFoundation/VideoToolbox frame compaction into 15-minute segments, with cached thumbnail extraction for timeline replay.
3. Replace dHash-only dedup with multi-hash signatures: dHash grid plus DCT pHash or block mean hash, changed-cell masks, and sequence-level dedup.
4. Materialize sessions from `SessionSegmenter` and retrieve sessions first, then frames.
5. Move semantic retrieval from one word-averaged vector per frame to chunk/session embeddings.
6. Add optional OCR rescue using RapidOCR/Tesseract/PaddleOCR in a low-priority background queue.
7. Explore late-interaction retrieval, ColBERT-style, only after chunk/session embeddings hit quality limits.

## License/Attribution Notes

- Screenpipe's current license is source-available/commercial. Treat it as architecture inspiration only unless HUMAIN obtains a commercial license. Do not copy code.
- Windrecorder is GPL-2.0. Do not copy or link code into Cascade unless Cascade is prepared for GPL obligations. Its design pattern, especially scene indexing and video compaction, can be independently implemented.
- OpenRecall is AGPL-3.0. Avoid code reuse or linking in Cascade unless AGPL network-use obligations are acceptable.
- pHash is GPL-3.0. Do not copy implementation code. Reimplement perceptual hashing from papers or use permissive references.
- rem, xrem, Memento, and blockhash are MIT; ImageHash is BSD-2-Clause; Tesseract, RapidOCR, PaddleOCR, and EasyOCR are Apache-2.0. These are safer references, but still keep attribution in `docs/PORT_MAP.md` or a dedicated third-party notices file if implementation is derived from them.
- FFmpeg can be LGPL, GPL, or nonfree depending on build. Prefer Apple's AVFoundation/VideoToolbox APIs for Cascade's first video-segment compaction pass. If FFmpeg is ever bundled, maintain a strict compliance checklist and avoid GPL/nonfree codecs unless the product decision explicitly accepts that.
- Academic papers can guide clean-room implementation of algorithms, but implementation should be written directly in Swift with local tests and benchmarks.

