# Sequence 19: Performance, Energy Efficiency, and Resource Footprint

## Overview

Cascade is an always-on local context recorder. That makes performance and energy behavior a product requirement, not a tuning pass: if the app keeps CPU, memory, battery, thermal pressure, or disk I/O high on enterprise laptops, IT will block deployment.

The codebase already has several strong foundations:

- `Sources/MacContextKit/ScreenCapture.swift` uses ScreenCaptureKit with a 1920 px long-side cap and `queueDepth = 3` for the rewind stream.
- `Sources/MacContextKit/RewindRecorder.swift` drops incomplete SCStream frames, hashes a 3x3 grid, skips near-identical frames, JPEG-encodes changed frames at about q=0.6, and coalesces OCR backlog to one in-flight plus one pending frame.
- `Sources/MacContextKit/RewindRecorder.swift` runs AX text first, downgrades OCR to Vision `.fast` when AX text is rich, and rate-limits native-resolution OCR rescue to every 3 seconds.
- `Sources/CascadeMemory/CascadeMemory.swift` already enables SQLite WAL and batches input-event inserts.
- `Sources/MacContextKit/MacContextKit.swift` already performs app-activation captures and hourly retention pruning in a background task.

The remaining gap is adaptive resource control. Cascade still starts the rewind stream as a fixed 1 fps producer, encodes whole changed frames, performs OCR over whole images, and has no first-class recorder health budget visible to users or admins. The strongest Apple-specific path is to treat the recorder as a budgeted background service:

- lower capture work when the user is idle, Low Power Mode is enabled, or thermal pressure rises;
- trigger higher fidelity around meaningful events such as app activation, click, typing pause, and scroll end;
- OCR only the changed or sparse-AX regions that need OCR;
- move SQLite checkpoints, FTS maintenance, vacuuming, and retention to coalesced background windows;
- continuously measure CPU, wakeups, memory, WAL growth, frame processing latency, OCR latency, and disk bytes.

## Techniques Table

| Source | Technique | Expected win | Effort |
|---|---|---:|---:|
| [ScreenCaptureKit `SCStreamConfiguration`](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration), [`minimumFrameInterval`](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/minimumframeinterval), [`queueDepth`](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/queuedepth?language=objc), [WWDC22 ScreenCaptureKit](https://developer.apple.com/videos/play/wwdc2022/10155/) | Keep `queueDepth` small, process and release surfaces quickly, and change `minimumFrameInterval` instead of buffering inside ScreenCaptureKit. | Lower memory pressure and fewer dropped frames or stalls. | S |
| [Capturing screen content in macOS](https://developer.apple.com/documentation/ScreenCaptureKit/capturing-screen-content-in-macos) | Use ScreenCaptureKit for continuous capture, but gate expensive work downstream by frame status, content change, and app policy. | Keeps capture native while cutting OCR/storage work. | S |
| [Energy Efficiency Guide: Minimize Timer Usage](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/Timers.html) | Add timer tolerance and coalesce periodic maintenance. Prefer event-driven work over fixed polling. | Fewer CPU wakeups and better App Nap cooperation. | S |
| [Energy Efficiency Guide: QoS](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/PrioritizeWorkAtTheTaskLevel.html) | Run recorder maintenance, retention, checkpointing, and non-urgent indexing at `.utility` or `.background`; reserve user-initiated QoS for active UI/agent work. | Lower scheduler priority and I/O pressure during normal recording. | S |
| [Energy Efficiency Guide: App Nap](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/AppNap.html), [`beginActivity(options:reason:)`](https://developer.apple.com/documentation/foundation/processinfo/1415995-beginactivity) | Do not disable App Nap globally. Use `ProcessInfo.beginActivity` only for bounded user-visible operations such as export or active agent control. | Avoids making an always-on recorder look like foreground work. | S |
| [`ProcessInfo.thermalState`](https://developer.apple.com/documentation/foundation/processinfo/thermalstate), [Respond to Thermal State Changes](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/RespondToThermalStateChanges.html), [`isLowPowerModeEnabled`](https://developer.apple.com/documentation/foundation/processinfo/islowpowermodeenabled) | Observe power/thermal changes and degrade capture cadence, OCR level, and native-res rescue under Low Power Mode, `.serious`, or `.critical`. | Battery and fan-noise protection; enterprise-friendly fail-soft behavior. | M |
| [Vision `VNRecognizeTextRequest`](https://developer.apple.com/documentation/vision/vnrecognizetextrequest), [`recognitionLevel`](https://developer.apple.com/documentation/vision/vnrecognizetextrequest/recognitionlevel), [`regionOfInterest`](https://developer.apple.com/documentation/vision/vnimagebasedrequest/regionofinterest?language=objc), [WWDC19 Vision Text Recognition](https://developer.apple.com/videos/play/wwdc2019/234/?time=1938) | Use `.fast` for insurance OCR, `.accurate` only when OCR is load-bearing, and set `regionOfInterest` for changed cells or focused-window crops. | Largest CPU win: Vision is one of the expensive hot-path stages. | M |
| [ImageIO `CGImageSourceCreateThumbnailAtIndex`](https://developer.apple.com/documentation/imageio/1465099-cgimagesourcecreatethumbnailatin), [ImageIO Guide](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Conceptual/ImageIOGuide/imageio_source/ikpg_source.html), [WWDC18 Memory Deep Dive](https://developer.apple.com/videos/play/wwdc2018/416/) | Downsample/decode with ImageIO instead of AppKit drawing where possible; avoid full-resolution decode when only a hash, OCR ROI, or thumbnail is needed. | Lower peak RSS and autoreleased object churn in frame pipelines. | M |
| Swift/Objective-C runtime practice: `autoreleasepool` around image loops | Wrap SCStream frame conversion, `NSBitmapImageRep`, JPEG encode, and OCR decode loops in `autoreleasepool`. | Lower transient memory growth during long always-on sessions. | S |
| [SQLite WAL](https://sqlite.org/wal.html), [SQLite PRAGMA docs](https://sqlite.org/pragma.html), [`wal_checkpoint`](https://sqlite.org/pragma.html#pragma_wal_checkpoint), [`busy_timeout`](https://sqlite.org/pragma.html#pragma_busy_timeout), [`mmap_size`](https://sqlite.org/pragma.html#pragma_mmap_size), [`synchronous`](https://sqlite.org/pragma.html#pragma_synchronous) | Tune WAL with `synchronous=NORMAL`, `busy_timeout`, measured `mmap_size`, explicit checkpoint scheduling, and a lower auto-checkpoint threshold or disabled auto-checkpoint plus background checkpoints. | Smoother inserts, fewer foreground fsync spikes, bounded WAL growth. | M |
| [SQLite VACUUM](https://sqlite.org/lang_vacuum.html), [FTS5 docs](https://www.sqlite.org/fts5.html) | Run `PRAGMA optimize`, FTS maintenance, `incremental_vacuum`/scheduled `VACUUM`, and retention compaction only during background maintenance windows. | Lower database bloat without surprise UI stalls. | M |
| [Power Profiler](https://developer.apple.com/documentation/Xcode/measuring-your-app-s-power-use-with-power-profiler), [Monitor Usage Regularly](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/MonitoringEnergyUsage.html), `man powermetrics` | Measure with Instruments Power Profiler, Time Profiler, Allocations, File Activity, and `powermetrics --show-process-qos --show-process-io --show-process-energy`. | Turns "lightweight" into a release gate with budgets. | S |

## Concrete Optimizations

### 1. Adaptive recorder cadence

Map to:

- `Sources/MacContextKit/ScreenCapture.swift`
- `Sources/MacContextKit/RewindRecorder.swift`
- `Sources/MacContextKit/MacContextKit.swift`
- `Sources/MacContextKit/InputRecorder.swift`

Current state:

- `ScreenCaptureUtility.makeRewindStream(... fps: 1)` sets `minimumFrameInterval = 1 / fps`.
- `MacContextKit.ContextRecorder` already captures on app activation and follows the cursor display.
- `InputRecorder` already records click, type, key, and scroll events, but those events do not alter capture cadence.

Implementation:

- Add a `CaptureBudget` or `RecorderCadenceController` in `MacContextKit`.
- Inputs:
  - recent input event timestamp;
  - app activation timestamp;
  - last stored-frame timestamp;
  - `ProcessInfo.processInfo.isLowPowerModeEnabled`;
  - `ProcessInfo.processInfo.thermalState`;
  - AC/battery state if available through IOKit later;
  - recorder backlog and OCR duration.
- Policies:
  - Active input window: 1 fps for 10-20 seconds after click/key/scroll.
  - Typing burst: capture after a 600-900 ms typing pause, not every key.
  - Scroll burst: capture after 300-500 ms of scroll quiet.
  - Idle with unchanged screen: drop to 0.1-0.2 fps equivalent storage/OCR work, or keep SCStream alive but only store idle heartbeats every 10-30 seconds.
  - Low Power Mode: cap normal cadence to 0.2-0.5 fps, use OCR `.fast`, disable native-res rescue except user-initiated ask/agent flows.
  - Thermal `.serious`: same as Low Power plus skip embeddings until recovery.
  - Thermal `.critical`: pause OCR/indexing, keep only sparse app/input metadata, and surface "reduced recording to cool down."

Expected win:

- Fewer Vision passes, fewer JPEG writes, fewer SQLite inserts, and fewer CPU wakeups during static work.
- Better recall around meaningful transitions because event-triggered captures can happen sooner than a blind 1-second tick.

Measure:

- Add counters to `metadataJSON` or a new `recorder_metric` table: `frames_received`, `frames_complete`, `frames_dropped_duplicate`, `frames_stored`, `capture_reason`, `effective_fps`, `ocr_ms`, `insert_ms`.
- Compare 30-minute traces: idle desktop, typing in Notes, scrolling browser, and app-switch-heavy research.
- Instruments Power Profiler: average power impact and wakeups.
- `powermetrics`: process QoS, CPU residency, package power, thermal pressure.

### 2. Changed-region OCR instead of whole-frame OCR

Map to:

- `Sources/MacContextKit/RewindRecorder.swift`
- `Sources/MacContextKit/ScreenTextRecognizer.swift`
- `Sources/MacContextKit/PerceptualHash.swift`

Current state:

- `RewindStreamOutput` computes a 3x3 hash grid and drops frames only when every cell is near-identical.
- `RewindEngine` then OCRs the whole JPEG frame.
- `ScreenTextRecognizer` supports Vision text recognition but does not expose `regionOfInterest`.

Implementation:

- Compute and carry `changedCellsMask` from `RewindStreamOutput` to `ChangedFrame`.
- Extend `ScreenTextRecognizer.recognize` with:
  - `regionOfInterest: CGRect?`;
  - `recognitionLanguages: [String]?` later, if admin policy or locale warrants;
  - `usesLanguageCorrection` already gated by level.
- Map changed grid cells into Vision-normalized ROI rectangles.
- Run OCR on:
  - changed cells when AX text is rich;
  - focused-window native crop when AX is sparse;
  - full frame only when many cells changed, OCR text disappeared unexpectedly, or a periodic quality audit sample is due.
- Persist `changed_cells_mask` and `ocr_mode` in `metadataJSON` first; migrate to columns if metrics prove useful.

Expected win:

- Vision cost scales with changed area instead of full display area for chat badges, spreadsheet cell edits, terminal output, and browser notifications.
- Fewer repeated OCR lines to merge.

Measure:

- Compare `VNRecognizeTextRequest` wall time for full frame vs ROI on common screens.
- Track `ocr_pixels_requested / frame_pixels`.
- Add quality sampling: every N stored frames, full-frame OCR in background and compare text delta against ROI OCR.

### 3. Image pipeline memory hygiene

Map to:

- `Sources/MacContextKit/RewindRecorder.swift`
- `Sources/MacContextKit/ScreenCapture.swift`
- `Sources/MacContextKit/ScreenTextRecognizer.swift`

Current state:

- SCStream frames are converted `CVPixelBuffer -> CIImage -> CGImage -> NSBitmapImageRep -> JPEG Data`.
- Zoom capture downscales with `NSBitmapImageRep`, `NSGraphicsContext`, and `NSImage.draw`.
- `ScreenTextRecognizer.decode` decodes image data before Vision.

Implementation:

- Wrap per-frame conversion and JPEG encode in `autoreleasepool` inside `RewindStreamOutput.stream`.
- Prefer ImageIO thumbnail/downsample APIs for any decode path that does not need full resolution.
- Reuse long-lived `CIContext` already present, and avoid creating AppKit image objects in hot loops where CoreGraphics/ImageIO can do the work.
- Add a hard cap for in-memory pending frame bytes in `RewindEngine` so coalesce-latest cannot retain multiple large `Data` objects during thermal or disk stalls.

Expected win:

- Lower peak RSS over long sessions, fewer autoreleased AppKit objects, less memory pressure when multiple displays or large external monitors are present.

Measure:

- Instruments Allocations and Leaks over 2-hour recording.
- Record RSS every minute through a debug-only metric.
- Synthetic stress: 5K display, rapid scrolling, sparse-AX browser window.

### 4. SQLite write and checkpoint tuning

Map to:

- `Sources/CascadeMemory/CascadeMemory.swift`
- `Sources/MacContextKit/MacContextKit.swift`

Current state:

- Migration runs `PRAGMA journal_mode=WAL`.
- There is no visible `synchronous`, `busy_timeout`, `mmap_size`, `wal_autocheckpoint`, explicit checkpoint, `PRAGMA optimize`, or vacuum scheduling.
- `withStatement` prepares/finalizes every call; input events use one transaction.

Implementation:

- On connection open, after WAL:
  - `PRAGMA synchronous=NORMAL;`
  - `PRAGMA busy_timeout=2500;`
  - `PRAGMA temp_store=MEMORY;`
  - `PRAGMA mmap_size=268435456;` behind a measured default and admin override;
  - `PRAGMA wal_autocheckpoint=0;` only if Cascade owns all connections and adds explicit background checkpoints; otherwise set a measured threshold such as 256-1000 pages.
- Add `CascadeStore.performMaintenance(reason:)`:
  - `PRAGMA wal_checkpoint(PASSIVE)` every 10-30 minutes or after WAL bytes exceed a budget;
  - `PRAGMA wal_checkpoint(TRUNCATE)` only on app idle/quit or admin maintenance, because it can block;
  - `PRAGMA optimize` after retention deletes and before app termination;
  - optional `VACUUM` or `incremental_vacuum` during rare maintenance windows, not while the user is active.
- Cache prepared insert statements for hot writes (`recorded_context`, FTS trigger remains automatic, `audit_event`, `input_event`) or at least batch recorder-side writes where correctness allows.

Expected win:

- Smoother inserts, bounded WAL growth, fewer surprise fsync stalls on the recorder path, lower disk churn during the workday.

Measure:

- Track SQLite insert latency p50/p95/p99 and WAL file bytes.
- Instruments File Activity for write volume and fsync clustering.
- `fs_usage` during a 30-minute trace if Instruments is not available.
- Unit tests for maintenance calls should use temp DBs and assert that PRAGMAs apply without changing retention semantics.

### 5. Coalesced maintenance and QoS discipline

Map to:

- `Sources/MacContextKit/MacContextKit.swift`
- `Sources/CascadeMemory/SemanticIndex.swift`
- `Sources/AppShell/CascadeAppModel.swift`

Current state:

- Retention pruning runs hourly in `Task.detached(priority: .background)`.
- Embedding indexing runs best-effort right after insert.
- UI model updates happen per inserted moment.

Implementation:

- Create one `RecorderMaintenanceScheduler` for retention, embedding backlog, WAL checkpoint, FTS optimize, and resource metric flush.
- Use timer tolerance for recurring work. A one-hour maintenance timer can tolerate minutes.
- Run maintenance at `.background`; run semantic indexing at `.utility` only when plugged in or active enough to justify it.
- Use `ProcessInfo.beginActivity` only for bounded user-visible exports, not normal recording.
- Batch UI updates where possible: the Reel does not need to redraw for every stored frame during high-change bursts.

Expected win:

- Fewer wakeups, less disk head-of-line blocking, and clearer separation between always-on recorder work and user-requested work.

Measure:

- Instruments System Trace/Power Profiler: timer wakeups and QoS distribution.
- `powermetrics --show-process-qos --show-process-io --show-process-energy -i 5000 -n 12`.
- App metric: background maintenance duration and bytes written per run.

### 6. Resource budget and health surface

Map to:

- `Sources/MacContextKit/MacContextKit.swift`
- `Sources/AppShell/CascadeRootView.swift`
- `Sources/AppShell/CascadeAppModel.swift`
- `Sources/CascadeMemory/CascadeMemory.swift`

Implementation:

- Extend `CascadeRecorderStatus` with lightweight health:
  - `effectiveCaptureRate`;
  - `framesStoredPerMinute`;
  - `duplicateDropRate`;
  - `ocrMedianMs` / `ocrP95Ms`;
  - `sqliteInsertP95Ms`;
  - `walBytes`;
  - `frameBytesLastHour`;
  - `thermalState`;
  - `lowPowerMode`;
  - `degradedReason`.
- Surface this in Settings or an admin/debug Details view, not the default user flow.
- Add warning states:
  - "Reduced capture: Low Power Mode";
  - "Reduced OCR: thermal pressure";
  - "Database maintenance pending";
  - "Storage budget near limit."

Expected win:

- Enterprise trust. Admins can see the recorder self-throttles and stays within a budget instead of treating performance regressions as invisible.

Measure:

- Make the health surface itself reflect the same counters used in tests and traces.
- Add a "copy diagnostics" payload with redacted metrics only, no OCR text or file names.

## Quick Wins vs Larger Bets

Quick wins:

- Set `configuration.showsCursor = false` for rewind streams in `ScreenCaptureUtility.makeRewindStream`; input events already store click coordinates and labels. This reduces cursor-jitter false changes and OCR noise.
- Wrap `RewindStreamOutput.stream` image conversion/JPEG encode in `autoreleasepool`.
- Add `ProcessInfo` low-power and thermal checks before native-res OCR rescue and before `.accurate` OCR.
- Add SQLite `busy_timeout` and `synchronous=NORMAL` after WAL, then measure.
- Add recorder metrics and `os_signpost` spans around hash, JPEG encode, OCR, native OCR, SQLite insert, embedding index, prune, and checkpoint.
- Give the hourly retention timer tolerance or move it into a shared background maintenance scheduler.

Larger bets:

- Adaptive cadence controller driven by app activation, input events, idle state, thermal state, and backlog.
- Changed-cell OCR with Vision `regionOfInterest`, plus periodic full-frame audit sampling to catch missed text.
- Explicit WAL checkpoint and FTS maintenance scheduler with file-size budgets.
- Hot-path prepared-statement reuse or a small write queue for recorder inserts and audit events.
- Admin-facing resource health panel and exported redacted diagnostics.
- Optional per-app capture budgets, for example slower cadence for video players and faster event-triggered cadence for terminals, browsers, editors, and spreadsheets.

## How to Measure Each Optimization

| Optimization | Primary metric | Tooling | Pass condition |
|---|---|---|---|
| Adaptive cadence | Stored frames/minute, OCR passes/minute, recall around app switches/clicks | Recorder counters, XCTest trace replay, Instruments Power Profiler | Idle workload cuts OCR/storage by at least 70 percent while app-switch and typing-pause moments are still captured. |
| Changed-region OCR | OCR wall time, OCR pixels requested, text delta vs full OCR | `os_signpost`, periodic full-frame audit OCR, Time Profiler | ROI OCR reduces median OCR time materially with less than 2 percent sampled text loss on benchmark traces. |
| Low-power/thermal degrade | Capture rate, OCR mode mix, thermal recovery | `ProcessInfo` notifications, Power Profiler, `powermetrics` thermal sampler | Low Power Mode and thermal `.serious` visibly reduce work within one control interval. |
| Image memory hygiene | Peak RSS, transient allocations/frame, autorelease growth | Instruments Allocations/Leaks, Memory Graph, debug RSS sampler | Two-hour recording has flat or bounded RSS; no frame-pipeline growth trend. |
| SQLite tuning | Insert p95/p99, WAL bytes, fsync clusters, busy errors | File Activity, SQLite counters, WAL file stat, `fs_usage` | Inserts stay below budget during recording; checkpoints happen off the hot path; WAL remains under configured limit. |
| Maintenance coalescing | Timer wakeups, background bytes, maintenance duration | Power Profiler, `powermetrics`, internal maintenance metrics | Retention/checkpoint/FTS work runs in scheduled windows and does not overlap active capture bursts except when budgets force it. |
| Health surface | Diagnostic completeness, warning correctness | UI snapshot tests, synthetic low-power/thermal injection, temp DB WAL tests | Admin/debug view explains current degradation and resource budgets without exposing private OCR content. |

Suggested baseline traces:

- 30 minutes idle desktop.
- 30 minutes browser research with scrolling and tabs.
- 30 minutes terminal/editor coding.
- 30 minutes spreadsheet/document editing.
- 30 minutes video call or video playback, where Cascade should avoid wasteful frame churn.
- 2 hours mixed work for memory and WAL growth.

Suggested local commands:

```bash
sudo powermetrics --show-process-qos --show-process-io --show-process-energy -i 5000 -n 12
```

```bash
sudo fs_usage -w -f filesys Cascade
```

Use Instruments templates:

- Power Profiler for energy and wakeups.
- Time Profiler for OCR/hash/JPEG hot spots.
- Allocations and Leaks for image pipeline memory.
- File Activity for SQLite/WAL/frame writes.
- System Trace when timer wakeups or QoS behavior is unclear.
