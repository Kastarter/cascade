# SEQ-24: UI State Representation & Change Diffing

## Overview

Cascade already has a useful first layer: `PerceptualHash.gridHashes(_:)` drops near-identical recorder frames, `AXTextHarvester.text(forWindowOfPID:)` merges exact AX text with OCR, `AXElementResolver.frontmostFingerprint()` gives recipe replay a coarse post-action check, `CascadeAppModel.gridHashes(ofJPEG:)` drives on-screen no-effect detection, and `BackgroundWebAgent.pageSignature()` compares URL plus readable text for sandbox no-effect detection.

The missing optimization is a canonical UI state layer that can explain what changed before Cascade pays for OCR, model re-grounding, or a redundant screenshot loop. The strongest pattern across OSS and papers is a layered state signature:

1. event-driven dirty signals (`AXObserver` / `MutationObserver`) say whether the UI claims anything changed;
2. structural snapshots (AX/DOM/ARIA node Merkle hashes) identify inserted, removed, moved, focused, selected, and value-changed controls;
3. perceptual region diffing catches canvas/image-only changes and narrows OCR to changed regions;
4. semantic text diffs summarize novel lines and state deltas for the agent instead of replaying the whole screen.

This sequence should make recorder dedup more precise and should let `ComputerUseAgent` verify "action had no effect" structurally before spending another vision/model turn.

## OSS Repos & Papers

| name | url | stars/venue | license | technique |
|---|---|---:|---|---|
| rrweb | https://github.com/rrweb-io/rrweb | 19.8k stars | MIT | Serializes DOM into stable node IDs, records an initial snapshot, then stores incremental mutations and interactions instead of repeated full screenshots. Portable concept: "initial UI tree + delta log" for AX and web sandbox state. |
| Playwright | https://github.com/microsoft/playwright | 91.7k stars | Apache-2.0 | Uses resilient role/label locators, auto-wait/actionability checks, trace viewer with DOM snapshots, screenshots, network, and console at every step. Portable concept: verify actionability and capture step-level state bundles. |
| Puppeteer | https://github.com/puppeteer/puppeteer | 95.2k stars | Apache-2.0 | Drives Chrome/Firefox over DevTools Protocol / WebDriver BiDi and exposes ARIA/text locators. Paired with CDP `DOMSnapshot.captureSnapshot`, it shows how to turn DOM, layout, styles, input values, checked states, clickability, and text boxes into a compact state source. |
| Appium | https://github.com/appium/appium | 21.7k stars | Apache-2.0 | Cross-platform native/hybrid/web automation on W3C WebDriver. Useful model for page-source/UI-source snapshots across native app backends and stable element identity abstraction independent of pixels. |
| Selenium | https://github.com/SeleniumHQ/selenium | 34.2k stars | Apache-2.0 | W3C WebDriver ecosystem with explicit waits and element staleness/actionability ideas. Portable concept: wait on state predicates rather than fixed sleeps after actions. |
| pixelmatch | https://github.com/mapbox/pixelmatch | 6.9k stars | ISC | Tiny raw-pixel diff with anti-aliased pixel detection and perceptual YIQ color distance. Portable concept: use cheap pixel diff only inside changed dHash regions to distinguish real content movement from rendering noise. |
| morphdom | https://github.com/patrick-steele-idem/morphdom | 3.6k stars | MIT | Single-pass real-DOM tree matching that preserves node state and matches nodes by IDs. Portable concept: match AX nodes by stable ID/role/label/path, then produce minimal updates instead of full tree churn. |
| GumTree | https://github.com/GumTreeDiff/gumtree | 1.3k stars; ASE 2014 paper | LGPL-3.0 repo; paper DOI | Tree differencing that detects inserts, deletes, updates, moves, and renames instead of line-only changes. Portable concept: use bottom-up/top-down similarity over AX/DOM nodes to detect moved controls and renamed labels. |
| Healenium Web | https://github.com/healenium/healenium-web | 199 stars | Apache-2.0 | Self-healing Selenium locators with `score-cap`, recovery tries, and persisted alternatives. Portable concept: after AX descriptor miss, rank candidate controls by ID/role/label/container/path/frame similarity and audit the healed target. |
| diffDOM | https://github.com/fiduswriter/diffDOM | 860 stars | LGPL-3.0 | Produces JSON patch objects for modifications, insertions, removals, and relocations between DOM fragments; prefers relocation over remove/insert. Portable concept only; avoid code reuse because LGPL-3.0 is restrictive. |
| Visual Testing of GUIs by Abstraction | https://arxiv.org/abs/2007.10419 | arXiv 2020 | Paper | Defines an abstract GUI state with structural relations to ignore unimportant pixel changes and produce richer diagnostics than raw image differencing. Direct fit for recorder dedup and no-effect explanations. |
| Understanding Automated Web GUI Testing | https://arxiv.org/abs/2606.16650 | arXiv 2026 | Paper | Shows state abstraction strongly affects exploration; compact functionality-level history helps LLM-based GUI testing. Direct fit for pushing concise state deltas to `ComputerUseAgent`. |
| VisCritic | https://arxiv.org/abs/2606.24525 | arXiv 2026 | Paper | Compares pre/post screenshots in visual feature space as a process reward for GUI agents, producing action success/progress/error signals. Larger bet for local visual no-effect scoring beyond hashes. |
| Screen Parsing | https://arxiv.org/abs/2109.08763 | arXiv 2021 | Paper | Infers UI elements and relationships from screenshots for UI similarity search and accessibility enhancement. Larger bet for canvas/native surfaces where AX is sparse. |
| Sikuli: Using GUI Screenshots for Search and Automation | https://dl.acm.org/doi/10.1145/1622176.1622213 | UIST 2009 | Paper / OSS lineage | Image-based GUI search and automation from screenshots. Useful fallback principle: visual anchors are necessary when structural APIs are unavailable, but should be bounded by region/state gates. |
| HILC: GUI Task Automation Through Demonstration and Follow-up Questions | https://arxiv.org/abs/1611.03906 | arXiv 2016 | Paper | Learns scripts from demonstrations using screenshots and event signals plus follow-up disambiguation. Useful for generating clarification only when state diff cannot distinguish intended target. |

Supporting APIs worth using, not copied: Chrome DevTools Protocol `DOMSnapshot.captureSnapshot` returns flattened DOM plus layout, styles, input values, checked/selected states, clickability, bounds, and rendered text boxes (https://chromedevtools.github.io/devtools-protocol/tot/DOMSnapshot/). `MutationObserver` watches DOM changes and can report attributes, child-list, subtree, and text mutations without polling (https://developer.mozilla.org/en-US/docs/Web/API/MutationObserver).

## Concrete Techniques to Adopt

- Add a shared `UIStateSnapshot` value type in `Sources/MacContextKit/UIStateSnapshot.swift`. Build it from bounded AX nodes with fields `{stableKey, role, title, valueHash, selected, focused, enabled, frameBucket, childHashes}` and a root Merkle hash. Use stableKey priority `AXIdentifier > role+normalizedTitle+container > role+treePath+frameBucket`. This replaces the lossy `Int` returned by `AXElementResolver.frontmostFingerprint()` with a comparable state object.

- Extend `Sources/ComputerUseKit/AXElementResolver.swift` with `frontmostState(limit:depth:) -> UIStateSnapshot` and `diff(_:_:) -> UIStateDelta`. Keep `frontmostFingerprint()` as a compatibility wrapper returning `snapshot.rootHash`. The delta should classify `inserted`, `removed`, `valueChanged`, `focusChanged`, `selectionChanged`, `moved`, and `renamed`, borrowing the GumTree/morphdom idea of matching nodes before declaring delete/insert.

- Change recipe verification in `Sources/AppShell/CascadeAppModel.swift` around `uiFingerprint()` / `uiChanged(after:)` to store `UIStateSnapshot` before a recipe click, poll for `UIStateDelta.hasMeaningfulChange`, and audit a reason such as `focus changed to "Subject"` or `value changed in "Search"`. Keep the current zero/AX-unavailable skip behavior for canvas apps.

- Change on-screen no-effect detection in `Sources/AppShell/CascadeAppModel.swift` around `episodeOnce` lines that compare `lastFrameHashes` to `observedHashes`. Compute pre/post `UIStateSnapshot` once per turn. If AX delta is meaningful, clear `noEffectTurns` even when dHash is unchanged. If dHash changed but AX delta is empty, treat it as visual-only and run the current delayed recheck plus changed-region OCR before spending another model turn.

- Make `AXElementResolver.interactables(limit:)` return a richer `Interactable` descriptor containing `identifier`, `role`, `title`, `valueHash`, `enabled`, `selected`, `focused`, `container`, `frame`, `pathHash`, and `subtreeHash`. Use the same data for `interactableSummary(_:)`, recipe `target_descriptor`, and healing. This prevents duplicate "Save" or table-cell ambiguity and makes locator healing auditable.

- Add Healenium-style candidate scoring to `AXElementResolver.find(descriptor:near:)`: `identifier 0.40`, `role 0.15`, `label similarity 0.20`, `container/path 0.15`, `frame proximity 0.10`; require a configurable `scoreCap` (start `0.72`) for automatic healing and audit lower scores as "needs re-grounding". This is an evolution of the existing label/role/container matcher, not a new dependency.

- Add `AXStateObserver` in `Sources/MacContextKit` and wire it through `MacContextKit.startRecording` / `AppWindowObserver.snapshot()`. Register an `AXObserver` for the frontmost app when AX is trusted and subscribe to focused-window, focused-element, value, selected-children/text, title, window-created/destroyed/moved/resized notifications. Debounce to one dirty event per 150-250ms and store `lastAXDirtyAt`, `dirtyReason`, and `dirtyElementKey`.

- Use `AXStateObserver` to reduce recorder work in `Sources/MacContextKit/RewindRecorder.swift`: after `PerceptualHash.gridHashes(cgImage)`, if the pixel grid differs but there has been no AX dirty event and the last `UIStateSnapshot.rootHash` is unchanged for an AX-rich native app, skip `.accurate` OCR and either drop the frame or record a cheap metadata-only "visual-noise" audit. This targets blinking cursors, caret changes, progress spinners, and video/animation inside otherwise unchanged native windows.

- Add changed-region output to `Sources/MacContextKit/PerceptualHash.swift`: `diffRegions(_ current:[UInt64], previous:[UInt64], threshold:Int) -> [CGRect]`. For a quick win, return the 3x3 region rects whose Hamming distance exceeds threshold. For a second pass, subdivide only changed cells to 6x6 or 9x9, avoiding a full-frame cost. Pass these rects into `RewindEngine.process(_:)`.

- Add cropped OCR entry points in `Sources/MacContextKit/ScreenTextRecognizer.swift`: `recognize(inImageData:regions:level:)`. In `RewindEngine.process(_:)`, when AX text is rich and only one or two regions changed, OCR only those changed crops at `.fast`; when AX is sparse, keep the current `.accurate` and native-res rescue. Store `metadataJSON` with `changedRegions`, `uiHash`, `uiDelta`, and `changeKind`.

- Add a semantic text delta after `AXTextHarvester.merge(ax:ocr:)`: compute normalized line hashes and a SimHash/MinHash over text shingles. Store only novel/removed line summaries in metadata, while keeping full `ocrText` for FTS as today. Use the delta for audit detail (`"Mail · 2 new lines, focus -> Reply"`) and for `RecordSearchAnswerer` source snippets.

- Extend `Sources/CascadeMemory/CascadeMemory.swift` migration with optional columns or metadata keys for `ui_hash`, `text_simhash`, `change_kind`, and `delta_json`. Keep compatibility by storing in `metadata_json` first; only add columns if queries need them. Add indexes later only for `ui_hash` or `change_kind` if replay/search starts filtering by them.

- Replace `Sources/SandboxKit/BackgroundWebAgent.swift` `pageSignature()` with `webStateSignature()`: inject a small script into `WebSandbox` that returns `{url,title,activeElement,scroll,interactivesHash,formValuesHash,ariaTextHash,mutationSeq}`. Include form values, checked/selected states, contenteditable text, role/name labels, and button/link/input identity. URL + first 4000 chars misses many no-effect and false-effect cases.

- Install a `MutationObserver` in `Sources/SandboxKit/WebSandbox.swift` at document start. Accumulate a bounded mutation ring (`childList`, `attributes`, `characterData`, target role/name/path, old/new value hash) and expose `consumeMutations()` to `BackgroundWebAgent`. Use it to skip `readPageText()` on every loop when there are no mutations and no navigation.

- For web pages that can expose Chrome DevTools Protocol in the future, add a `DOMSnapshot` adapter path to `SandboxKit`: request only whitelisted styles needed for layout/visibility plus `includeDOMRects`, then hash flattened nodes by backend node id, role/name, bounds, input value, checked/selected, and clickability. This is a larger bet because `WKWebView` does not expose CDP, but it is useful for a Chrome-backed sandbox or browser connector.

- Change `ComputerUseAgent` prompts and `CascadeAppModel.scoutContextNote()` to pass a "state delta since last turn" block before any full interactable list: `changed: value "Search" -> nonempty; focus "Search"; inserted button "Clear"; removed menu "File"`. The 2026 AWGT paper suggests compact functionality-level history is better for LLM agents than verbose raw state.

- Add a local `StateDiffVerifier` in `ProviderKit` or `AppShell`: given `{goal, action, expectedVisibleChange, preState, postState, pixelDiffStats}`, return `.changed(reason)`, `.unchanged(reason)`, `.visualOnly(regions)`, or `.ambiguous`. Start rule-based; leave a hook for a future VisCritic-style local model when on-device VLM capacity is available.

- Use pixelmatch-style perceptual color difference as a second-stage visual comparator only inside changed dHash cells. Implement in Swift with Accelerate/vImage or SIMD over downscaled RGBA buffers: ignore anti-aliased edge pixels and produce `diffPixelRatio`, `changedBounds`, and `dominantChangeType`. This makes `PerceptualHash.isDuplicateGrid` less binary and reduces false "changed" from small visual noise.

- Add tests: `AXStateSnapshotTests` for moved/renamed/value/focus changes; `PerceptualHashRegionTests` for small-region changes; `WebStateSignatureTests` using static HTML snippets with form value and attribute mutations; `NoEffectStateVerifierTests` for AX-changed/pixel-unchanged and pixel-changed/AX-unchanged cases.

## Quick Wins vs Larger Bets

Quick wins:

- Replace `BackgroundWebAgent.pageSignature()` with a JS state object including URL, title, active element, interactives, form values, checked/selected states, scroll, and normalized text hash.
- Add `PerceptualHash.diffRegions(...)` and log changed grid cells in `RewindRecorder` metadata before changing OCR behavior.
- Expand `AXElementResolver.frontmostFingerprint()` into `frontmostState()` while preserving the existing `Int` wrapper.
- Use AX delta to clear no-effect false positives when pixel hashes are unchanged but focus/value/selection changed.
- Add richer `target_descriptor` fields for future recordings: identifier, role, container, frame bucket, path hash, selected/focused/value hashes.

Larger bets:

- Event-driven AX observer pipeline that lets the recorder skip OCR when neither AX nor meaningful visual regions changed.
- Region-cropped OCR path so screen recording no longer runs full-frame OCR for small changed areas.
- GumTree-style tree edit distance for AX and DOM snapshots with move/rename detection.
- DOM mutation ring for the WKWebView sandbox and eventual CDP `DOMSnapshot` support for Chrome-backed web agents.
- On-device visual process reward / VisCritic-style verifier for canvas-heavy apps where AX and OCR are sparse.

## License/Attribution Notes

- MIT / Apache-2.0 / ISC sources (`rrweb`, `Playwright`, `Puppeteer`, `Appium`, `Selenium`, `morphdom`, `pixelmatch`, `Healenium`) are safe as implementation inspiration; copy code only with notice updates.
- `GumTree` and `diffDOM` are LGPL-3.0. Do not port code into Cascade. Reimplement the tree matching ideas from the papers/behavior only.
- Academic papers are safe to cite as techniques; implementation should be original Swift. Mention `Visual Testing of GUIs by Abstraction`, `GumTree`, and `VisCritic` in source comments only where their concepts directly shape an algorithm.
- For `DOMSnapshot` and `MutationObserver`, use the public platform APIs directly; no third-party code is needed.
- If future code uses reference implementations for YIQ/perceptual color distance or anti-alias detection, verify license compatibility and add entries to `docs/THIRD_PARTY_NOTICES.md`.
