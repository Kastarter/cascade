# Rewind Capture — Handoff

Goal: turn Cascade's Rewind into a **continuous, always-on, privacy-first screen
recorder** — screenpipe-quality, but **Swift-native** (Cascade was rebased off the
Rust screenpipe fork, so we port the *design*, not the Rust engine). Output: a
searchable timeline of moments, each with a real screenshot + OCR + app/window,
stored locally only.

screenpipe reference: <https://github.com/screenpipe/screenpipe> (see its
`screenpipe-vision` continuous-capture + OCR + dedup loop). Local MIT refs already
on disk: `~/Desktop/cursor-refs/{openclicky,clicky}/…/CompanionScreenCaptureUtility.swift`.

---

## What already exists (don't rebuild these)

| Piece | File | Notes |
|---|---|---|
| Single-frame capture | `Sources/MacContextKit/ScreenCapture.swift` | `ScreenCaptureUtility.captureCursorScreenContext(includeImage:)` — **fail-closed** on `CGPreflightScreenCaptureAccess()`, picks the cursor display, excludes Cascade's own windows, `SCScreenshotManager.captureImage`, caps long side 1920. Returns `ScreenContextSample` (Sendable: `ocrText`, `frontAppName`, `frontBundleIdentifier`, `pixelWidth/Height`, `isCursorScreen`, `imagePNG`). |
| OCR | `Sources/MacContextKit/ScreenTextRecognizer.swift` | `recognize(inPNG:) async -> String` — Vision `VNRecognizeTextRequest`, runs **off the main actor**. |
| App/window/display enum | `Sources/MacContextKit/SystemEnumerator.swift` | displays, running apps, on-screen windows. |
| Recorder | `Sources/MacContextKit/MacContextKit.swift` | `ContextRecorder` (`@MainActor`, `ObservableObject`): a **4s `Timer`** loop today. `captureNow() async -> RecordedContext?` captures + OCRs + saves the PNG via `saveFrame(_:)` → `~/Library/Application Support/Cascade/frames/<uuid>.png`, then inserts. `AppWindowObserver` = frontmost app/window via AX. `PermissionProbe` = TCC preflight/requests. |
| Storage | `Sources/CascadeMemory/CascadeMemory.swift` | `CascadeStore` (actor) over SQLite3 C API. Table `recorded_context(captured_at, source, app_name, bundle_identifier, window_title, ocr_text, image_path, metadata_json)`. `insert`, `recentContexts(limit:)`, `appendAudit`. |
| Reel UI | `Sources/AppShell/CascadeRootView.swift` | Scene card already renders `NSImage(contentsOfFile: context.imagePath)`; scrubber steps `model.contexts`. |
| Privacy filter | `Sources/SuggestionEngine/SuggestionEngine.swift` | `PrivacyRules.isSensitive(_:)` (bank/health/legal/dating/private-browsing/password/keychain/wallet). |

So today: on-demand / 4s sampling, each tick = 1 screenshot + OCR + row. **The gap
is continuity, dedup, search, and retention.**

---

## Target architecture

Replace the 4s `Timer` with a continuous `SCStream`, gated + deduped:

```
SCStream (≈1 fps) ──▶ SCStreamOutput delegate (OFF main)
      │                   │ CMSampleBuffer → CVPixelBuffer → CGImage
      │                   ▼
      │           change detector (perceptual hash vs last frame)
      │                   │  (skip near-identical frames)
      │             changed? ──no──▶ drop
      │                   │yes
      │                   ▼
      │        encode PNG/JPEG → save to frames/ ; enqueue OCR (throttled)
      │                   ▼
      │        frontmost app/window (AppWindowObserver) ; PrivacyRules gate
      │                   ▼
      └────────▶ CascadeStore.insert(RecordedContext) + FTS index
```

New type: **`RewindRecorder`** in `MacContextKit` (or fold into `ContextRecorder`).
It owns the `SCStream`, the last-frame hash, an OCR queue, and writes to `CascadeStore`.

### 1. Continuous capture — `SCStream` (not `SCScreenshotManager`)
- `SCStreamConfiguration`: set `minimumFrameInterval = CMTime(value: 1, timescale: 1)` (1 fps; tune 0.5–2 fps), `queueDepth = 3`, `showsCursor = true`, `width/height` ≈ native capped (reuse the 1920-longest-side logic from `ScreenCapture.swift`), `pixelFormat = kCVPixelFormatType_32BGRA`.
- `SCContentFilter(display:excludingApplications:exceptingWindows:)` — exclude Cascade itself (so the overlay/app never records into the user's rewind).
- Conform a delegate to `SCStreamOutput`; implement `stream(_:didOutputSampleBuffer:of:)` for `.screen`. Convert: `CMSampleBufferGetImageBuffer` → `CIImage(cvPixelBuffer:)` → `CIContext().createCGImage`.
- Start/stop: `try await stream.startCapture()` / `stopCapture()`. **Fail-closed**: don't start unless `CGPreflightScreenCaptureAccess()` is true.
- Reference: clicky/openclicky `CompanionScreenCaptureUtility.swift` (filter + config patterns, already ported in `ScreenCapture.swift`); tiptour `ScreenRecorder.swift` (continuous stream); screenpipe `screenpipe-vision` capture loop.

### 2. Change detection / dedup (bounds storage — screenpipe does this)
- Cheap perceptual hash: downscale CGImage to 16×16 (or 8×8) grayscale, build an aHash/dHash `UInt64`. Compare Hamming distance to the previous stored frame's hash; **skip if distance < threshold** (e.g., ≤ 5). Only changed frames become moments.
- Store the hash alongside the row (add `frame_hash INTEGER` column) so you can also dedupe across restarts and answer "did this screen repeat."

### 3. OCR pipeline (throttled — it's CPU-heavy)
- Only OCR **stored (changed)** frames, via existing `ScreenTextRecognizer.recognize(inPNG:)`.
- Run on a bounded background queue (serialize OCR so it can't pile up); drop/skip if backed up. Don't block capture.

### 4. Search — SQLite FTS5
- Add a virtual table indexing `ocr_text` + `window_title` + `app_name`:
  ```sql
  CREATE VIRTUAL TABLE IF NOT EXISTS rewind_fts USING fts5(
      ocr_text, window_title, app_name, content='recorded_context', content_rowid='id'
  );
  ```
  Keep it in sync on insert (triggers, or insert into FTS in `CascadeStore.insert`).
- Add `CascadeStore.searchContexts(query:) async throws -> [RecordedContext]` using `rewind_fts MATCH ?` joined back to `recorded_context`. Wire a search box in the Reel.

### 5. Retention / disk management
- Cap by **age or size** (e.g., keep 7 days, or ≤ 5 GB of frames). A periodic prune task: delete oldest `recorded_context` rows + their `image_path` files (and FTS rows). screenpipe has configurable retention — mirror it.
- Consider storing **JPEG** (q≈0.6) instead of PNG to cut disk ~3–5×: re-encode in `saveFrame` via `NSBitmapImageRep.representation(using: .jpeg, properties: [.compressionFactor: 0.6])`.

### 6. Privacy boundary (non-negotiable)
- **Fail-closed** on `CGPreflightScreenCaptureAccess()` — never touch capture paths when denied.
- **Skip sensitive apps**: before storing, check the frontmost app via `PrivacyRules.isSensitive(...)` — if sensitive (banking/health/password manager/private browsing), **drop the frame entirely** (don't save the PNG, don't OCR, don't store). Move `PrivacyRules` into `CascadeMemory` or `MacContextKit` so the recorder can use it without depending on `SuggestionEngine`.
- Local-only storage; the Manager view stays **aggregate-only** (never reads frames/OCR).

---

## Swift 6 concurrency gotchas (this is where it gets fiddly)
- `SCStreamOutput.stream(_:didOutputSampleBuffer:of:)` is called **off the main actor** on an arbitrary queue. `CMSampleBuffer` / `CVPixelBuffer` / `CGImage` are **not Sendable** — do the convert + hash + PNG-encode **inside the delegate**, then hand off only **Sendable** values (PNG `Data`, the `UInt64` hash, app name/bundle `String`) to the `CascadeStore` actor / `@MainActor` recorder.
- Make the delegate a `final class … NSObject, SCStreamOutput, @unchecked Sendable` that owns a small serial `DispatchQueue` (or an `actor`) for frame work, and `await store.insert(...)` from a `Task`.
- `ScreenCaptureUtility` today is `@MainActor`; the continuous recorder must **not** be — keep stream/frame work off-main, hop to the store actor for writes and to `@MainActor` only to publish `latestContext` for the UI.

---

## Build order (suggested)
1. **`RewindRecorder`** with `SCStream` at 1 fps → log frames (no storage yet). Verify fail-closed + own-window exclusion.
2. Add **change detection**; store only changed frames (reuse `saveFrame` + `CascadeStore.insert`, add `frame_hash`).
3. Add **OCR** on changed frames (throttled).
4. Add **`PrivacyRules` gate** + retention prune task.
5. Add **FTS5** + `searchContexts` + a Reel search box.
6. Swap the app over: replace `ContextRecorder`'s `Timer` loop with `RewindRecorder` (keep `captureOnce()` for the manual "Capture now" button).

## Testing
- Keep `swift test` green (`MacContextKitTests` OCR test already exists).
- Add deterministic tests: perceptual-hash (two near-identical synthetic images → small Hamming distance; very different → large), and FTS round-trip (insert rows, `searchContexts("…")` returns the right one). No real screen needed.

## Out of scope for v1 (note as future)
- **Audio + transcription** (screenpipe captures system/mic audio → STT). Defer; it overlaps with the two-way-voice pillar (Apple `Speech` + `AVSpeechSynthesizer`).
- Multi-display continuous capture (start with the cursor display; one `SCStream` per display later).

## Build/run
`export PATH` not needed — Xcode is installed. `swift build` · `swift test` ·
`./scripts/build-app.sh` → `.build/Cascade.app`. Bundle id `com.humain.cascade`.
Frames live at `~/Library/Application Support/Cascade/frames/`; DB at
`~/Library/Application Support/Cascade/Cascade.sqlite`.

> ⚠️ Ad-hoc signing drops TCC grants on every rebuild. If you iterate a lot, set up
> a stable self-signed code-signing cert and switch `scripts/build-app.sh` to
> `--sign "<cert name>"` so Screen-Recording permission persists across rebuilds.
