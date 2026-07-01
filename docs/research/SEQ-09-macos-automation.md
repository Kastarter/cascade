# Research Sequence 9: macOS Automation Robustness

## Overview

Cascade already has the right foundation for real Mac actuation: STOP-gated `CGEvent` posting, AX-first click activation, AX label/identifier replay, OCR/vision fallback, bounded AX walks, Secure Input avoidance while recording, and skill-level escape hatches for canvas-heavy apps. The most important robustness gap is not "more clicks"; it is replacing time-based assumptions with observable UI state.

The strongest open-source patterns converge on five upgrades:

- Use `AXObserver` notifications as a readiness gate, with bounded polling only as fallback.
- Treat Secure Input as an action-time blocker, not only a recording-time privacy condition.
- Make text entry return a verified result per method: AX selected-text, paste, layout-aware physical keys, Unicode events.
- Centralize AX reads behind typed, timeout-bound helpers that preserve errors and validate frames.
- Centralize display coordinate conversion so model points, AppKit points, CGEvent points, and ScreenCaptureKit pixels are never mixed.

## OSS Repos & Techniques

| Project / source | License | Relevant technique | Cascade adoption |
|---|---:|---|---|
| [Hammerspoon](https://github.com/Hammerspoon/hammerspoon) | MIT | Mature macOS automation bridge exposing AX, event taps, screen coordinates, hotkeys, window state, and observers. | Use as the reference architecture for "small wrappers over native APIs with explicit failure states." |
| [Hammerspoon `hs.axuielement`](https://www.hammerspoon.org/docs/hs.axuielement.html) | MIT docs/source | Explicitly warns that AX set operations can report success while the app refuses the change; callers must read back values to confirm. | Cascade already verifies `axInsertText`; extend this confirmation discipline to action results and frame reads. |
| [Hammerspoon `hs.axuielement.observer`](https://www.hammerspoon.org/docs/hs.axuielement.observer.html) | MIT docs/source | Wraps `AXObserver` and notification subscriptions for app/window/focused-element changes; notes support is app-dependent. | Add `AXReadinessWatcher` to replace fixed sleeps in `uiChanged`, `activateAndConfirm`, and post-click recipe replay. |
| [Hammerspoon `hs.eventtap`](https://www.hammerspoon.org/docs/hs.eventtap.html) | MIT docs/source | Exposes Secure Input detection: when password/system secure input is active, keyboard event taps cannot observe keys. | Promote `IsSecureEventInputEnabled()` from recorder-only to action-time health and refusal. |
| [Hammerspoon `hs.eventtap.event`](https://www.hammerspoon.org/docs/hs.eventtap.event.html) | MIT docs/source | Builds event sequences and exposes raw flags, click-state fields, scroll fields, and synthetic-event flags. | Improve `pressKey` to post modifier down/up sequences for raw-modifier-sensitive apps. |
| [Hammerspoon `hs.screen`](https://www.hammerspoon.org/docs/hs.screen.html) | MIT docs/source | Documents global screen coordinates: top-left primary origin, negative coordinates for screens left/above, points not pixels under HiDPI. | Replace `CascadeAppModel.toCGGlobal` primary-height shortcut with a display-aware mapper and tests. |
| [BlueM/cliclick](https://github.com/BlueM/cliclick) | BSD-style | CLI for emulating mouse/keyboard events; source uses layout-aware keycode discovery via current keyboard layout and adds pacing between actions. | Add layout-aware physical key mapping for symbols/dead keys instead of static ANSI-only map for all key text cases. |
| [tmandry/AXSwift](https://github.com/tmandry/AXSwift) | MIT | Swift wrapper around AX C APIs with explicit error handling and broad API coverage. | Build a small Cascade-owned `AXClient` wrapper instead of scattered force casts and boolean-only failures. |
| [tmandry/Swindler](https://github.com/tmandry/Swindler) | MIT | Maintains an async in-memory model over AX because window/AX notifications can be missing, duplicated, or out of order. | `AXReadinessWatcher` should combine notifications, current-state reads, and bounded polling; do not trust observer delivery alone. |
| [browser-use/macOS-use](https://github.com/browser-use/macOS-use) | MIT | AI agent framework for local macOS control; warns early-stage agents can touch private credentials and auth surfaces. | Keep Cascade's STOP/audit/privacy gates as product requirements; add secure-input refusal before typing into credential surfaces. |
| [mediar-ai/MacosUseSDK](https://github.com/mediar-ai/MacosUseSDK) | MIT | Swift tools for visible AX traversal, input control, and UI highlighting. | Add internal debug commands: dump visible AX tree, highlight selected AX nodes, replay input in a diagnostic harness. |
| [bradthebeeble/mcp-macos-cua](https://github.com/bradthebeeble/mcp-macos-cua) | MIT | MCP server using screenshots, mouse/keyboard input, AX queries, AppleScript, and scale auto-detection. | Useful reference for a minimal external test harness around screenshots plus AX element dumps. |
| [sam-siavoshian/agent-notch](https://github.com/sam-siavoshian/agent-notch) | MIT | Swift macOS computer-use agent using ScreenCaptureKit, CGEvent, Accessibility API, live tool calls, kill switch, and stable signing guidance. | Reinforces Cascade's STOP model; consider stable development signing to reduce TCC permission churn during frequent builds. |
| [Electron accessibility docs](https://www.electronjs.org/docs/latest/tutorial/accessibility) | MIT project docs | Native clients can set the app-level `AXManualAccessibility` attribute to enable Electron accessibility support. | For Electron-like sparse AX trees, attempt `AXManualAccessibility=true` before harvesting/interactables, then measure AX richness. |
| [JetAstra/MacAgentBench](https://github.com/JetAstra/MacAgentBench) | MIT | macOS agent benchmark with 676 tasks across 25 apps and rule-based multi-checkpoint evaluation. | Use its app breadth as a template for Cascade's local robustness matrix. |

Related non-OSS or research-only references:

- BetterTouchTool is not open source, but its practical lesson is clear: robust Mac automation needs per-app policies, explicit fallback paths, and user-visible recovery, not a single global event path.
- [Screen2AX](https://arxiv.org/abs/2507.16704) reports that many macOS apps expose incomplete AX trees and that screenshot-derived tree metadata can outperform native AX alone. This supports Cascade's existing AX + OCR + vision fallback architecture.

## Concrete Techniques to Adopt

### 1. Add `AXReadinessWatcher`

Target files/functions:

- `Sources/AppShell/CascadeAppModel.swift`
  - `uiChanged(after:)`
  - `activateAndConfirm(name:bundle:)`
  - `runAgentRecipe(_:)`
  - `executeCU(_:, on:)` for `openApp`, `openURL`, `wait`, and post-action settling
- New helper in `Sources/ComputerUseKit/AXReadinessWatcher.swift` or `Sources/MacContextKit/AXObserverClient.swift`

Implementation shape:

- Create an app-scoped observer with `AXObserverCreate(pid, callback, &observer)`.
- Add the observer run-loop source with `AXObserverGetRunLoopSource`.
- Subscribe where supported:
  - App/window readiness: `kAXFocusedWindowChangedNotification`, `kAXMainWindowChangedNotification`, `kAXWindowCreatedNotification`, `kAXUIElementDestroyedNotification`.
  - Focus/text readiness: `kAXFocusedUIElementChangedNotification`, `kAXValueChangedNotification`, `kAXSelectedTextChangedNotification`.
  - Layout/content readiness: `kAXLayoutChangedNotification`, `kAXRowCountChangedNotification`, `kAXTitleChangedNotification`.
- Return an async result: `.changed(notification)`, `.timeout(lastFingerprint)`, `.unsupported(error)`, `.invalidated`.
- Always combine observer delivery with a final state read, because Swindler's model and Hammerspoon's docs both point to app-dependent notification behavior.

Concrete replacement:

- `uiChanged(after:)` currently polls `AXElementResolver.frontmostFingerprint()` five times with 80 ms sleeps. Replace with `await AXReadinessWatcher.waitForFingerprintChange(pid:before:timeout:0.8)` and fall back to the current polling loop on unsupported notifications.
- `activateAndConfirm` currently sleeps 8 x 250 ms. Subscribe to workspace activation plus focused-window AX notifications, then poll only until timeout.
- `runAgentRecipe` currently sleeps 320 ms after moving and 500 ms after every step. Replace with action-specific waits:
  - click/menu: wait for focused element/window/layout/fingerprint change.
  - type: wait for focused text value or selected text change.
  - scroll: wait for layout or visible row/text change.

### 2. Surface Secure Input before actuation

Target files/functions:

- `Sources/ComputerUseKit/ComputerUseKit.swift`
  - `NativeComputerUseActuator.health()`
  - `pressKey(_:modifiers:pid:)`
  - `typeText(_:pid:)`
- `Sources/AppShell/CascadeAppModel.swift`
  - `executeCU(.type)`
  - `executeCU(.key)`
  - `pasteText(_:pointerRouted:)`
- `Sources/MacContextKit/InputRecorder.swift`
  - keep current recording gate

Current state:

- `InputRecorder` already calls `IsSecureEventInputEnabled()` for key events and drops them.
- Actuation paths do not check Secure Input before synthetic key, paste, or Unicode typing.

Implementation:

- Add `SecureInputStatus.current()` wrapper around `IsSecureEventInputEnabled()`.
- In `NativeComputerUseActuator.health()`, include `secureInputEnabled`.
- Before key/text/paste methods, if Secure Input is enabled:
  - Refuse action with `ComputerUseError.unsupported("Secure Input is active...")`.
  - Audit `computer.secureInput`.
  - Show voice/dock copy: "Secure Input is active. Type this field yourself, then I can continue."
- Do not try to bypass password fields. Treat it as a user-control boundary.

### 3. Harden text entry and key synthesis

Target files/functions:

- `Sources/AppShell/CascadeAppModel.swift`
  - `axInsertText(_:)`
  - `pasteText(_:pointerRouted:)`
  - `executeCU(.type)`
- `Sources/ComputerUseKit/ComputerUseKit.swift`
  - `typeText(_:pid:)`
  - `pressKey(_:modifiers:pid:)`
  - `KeyCodes`

Current state:

- Text entry is already tiered: physical-key policy, AX selected-text insert, paste, then Unicode synthetic typing.
- `axInsertText` correctly reads back value and falls through on phantom success.
- `typeText` chunks by 16 UTF-16 units, which can split surrogate pairs or combining sequences.
- `KeyCodes` is static ANSI, so physical typing of symbols/dead keys is incomplete outside simple layouts.

Implementation:

- Replace UTF-16 fixed chunks with grapheme-safe chunking. Convert each chunk to UTF-16 only after chunk boundaries are chosen by `Character`.
- Return `TextInjectionResult` with:
  - method: `ax`, `paste`, `unicodeEvent`, `physicalKeys`
  - focused role/subrole/bundle
  - secureInput state
  - readback success or reason for fallback
  - elapsed time
- Add `KeyboardLayoutMapper` using Text Input Sources (`TISCopyCurrentKeyboardLayoutInputSource`, `kTISPropertyUnicodeKeyLayoutData`) and `UCKeyTranslate` to map printable ASCII and symbols to virtual key + modifiers.
- For modifier shortcuts, post an event sequence:
  - modifier key down events
  - main key down/up
  - modifier key up events
  - keep current flags-on-key fallback if per-PID modifier events prove noisy.
- Keep Unicode events for arbitrary non-ASCII text, but verify via AX value where available and prefer paste for complex combining marks.

### 4. Build a typed `AXClient`

Target files/functions:

- `Sources/ComputerUseKit/AXElementResolver.swift`
- `Sources/ComputerUseKit/ComputerUseKit.swift` (`AXClickSnap`)
- `Sources/MacContextKit/AXTextHarvester.swift`
- `Sources/MacContextKit/ScreenCapture.swift` (`focusedWindowNormalizedRect`)
- `Sources/AppShell/CascadeAppModel.swift` (`axInsertText`, `unexpectedModal`, `axActivate`)

Current state:

- AX access is direct and scattered.
- Several reads force-cast `AXValue` or `AXUIElement` after success checks.
- Timeouts are set in some places but not centralized.
- Failure reasons are usually collapsed to nil/false, limiting app-specific diagnosis.

Implementation:

- Add `AXClient` helpers:
  - `attribute<T>(_ element, _ name, as: T.Type) -> Result<T, AXReadError>`
  - `stringAttributes(_ element, preferred: [String])`
  - `frame(_ element) -> Result<CGRect, AXReadError>`
  - `actionNames(_ element) -> [String]`
  - `performPress(_ element) -> AXError`
  - `isSettable(_ element, _ attribute) -> Bool`
- Validate:
  - `CFGetTypeID` before casting.
  - finite nonzero frame.
  - frame intersects one known display.
  - parent fallback when child has no frame or tiny frame.
- Preserve error codes like `.cannotComplete`, `.attributeUnsupported`, `.noValue`, `.invalidUIElement`, and include bundle/role/subrole in diagnostics.
- Keep current bounded walks, but record "AX richness" per app: node count, labeled actionable controls, identifiers present, frame failures, timeouts.

### 5. Handle Electron, Catalyst, and WebView sparsity explicitly

Target files/functions:

- `Sources/MacContextKit/AXTextHarvester.swift`
- `Sources/ComputerUseKit/AXElementResolver.swift`
- `Sources/AppShell/CascadeAppModel.swift`
- `Sources/ComputerUseKit/AppSkill.swift`

Implementation:

- Add `AXRuntimeProfile` per frontmost app:
  - bundle id, executable name, role density, labeled-control count, identifier count, AX timeout rate, canvas-sized element ratio.
- If the app is Electron-like or AX richness is low, try:
  - `AXUIElementSetAttributeValue(appRef, "AXManualAccessibility" as CFString, kCFBooleanTrue)`
  - Re-run a bounded tree sample.
- If richness remains low:
  - mark the turn as `axSparse`.
  - prefer OCR/native-res crop/vision grounding.
  - avoid treating unchanged AX fingerprints as proof of click failure.
  - suggest a learned `axUnreliable` skill policy after repeated sparse sessions.

This keeps the current skill system but lets Cascade discover bad AX surfaces instead of waiting for hand-authored hints.

### 6. Fix coordinate conversion as a first-class module

Target files/functions:

- `Sources/AppShell/CascadeAppModel.swift`
  - `toCGGlobal(_:)`
  - `displayBounds(of:)`
  - `executeCU(_:, on:)`
  - `regroundedTarget(anchor:recorded:)`
  - `regroundedByOCR(anchor:)`
- `Sources/MacContextKit/ScreenCapture.swift`
  - `cursorDisplay()`
  - `appKitFrame(for:)`
  - `outputPixelSize(for:)`
  - `captureCursorScreenZoomJPEG`

Current risk:

- `toCGGlobal(_:)` uses the primary screen height and flips y globally:
  - `CGPoint(x: appkit.x, y: primaryHeight - appkit.y)`
- That works for the common single-display case but is fragile with screens above/below the primary display, negative coordinates, and mixed Retina/non-Retina layouts.

Implementation:

- Add `DisplayCoordinateMapper` with explicit types:
  - `ScreenLocalPoint` in AppKit points.
  - `AppKitGlobalPoint` in AppKit global points.
  - `CGGlobalPoint` in top-left global display coordinates.
  - `ImagePixelPoint` in captured bitmap pixels.
- Use each `NSScreen`'s `NSScreenNumber` and `CGDisplayBounds(displayID)` as the source of truth for CG global bounds.
- Keep model coordinates in screen-local points.
- Convert local AppKit point to CG point by mapping within that display's CG bounds, not by the primary screen height.
- Multiply by `backingScaleFactor` only when converting to image pixels.
- Add tests for:
  - main display only.
  - secondary left of main with negative x.
  - secondary above main with negative y in AppKit space.
  - Retina primary + non-Retina secondary.
  - cursor on secondary while capture follows cursor display.

### 7. Improve scroll and click event fidelity

Target files/functions:

- `Sources/ComputerUseKit/ComputerUseKit.swift`
  - `click`, `doubleClick`, `tripleClick`, `drag`, `scroll`, `pressKey`

Implementation:

- Use a persistent `CGEventSource(stateID: .hidSystemState)` or measured alternative instead of `nil` source, then log app-specific success. Keep `.cghidEventTap` for pointer paths that need real HID behavior.
- For double/triple clicks, create fresh down/up events for each click rather than reposting the same event object multiple times. Some apps inspect timestamps/event numbers.
- For scroll:
  - Continue pixel scrolling for precision.
  - Consider setting continuous-scroll fields and phases for apps that distinguish wheel vs trackpad.
  - Move pointer before scroll, as Cascade already does for pointer-routed apps.
- Keep per-PID keyboard posting as an option, but collect failures where apps ignore targeted events and require HID-level delivery.

### 8. Add an AX/input diagnostic harness

Target files/functions:

- New debug target under `Sources/` or `scripts/`
- `Sources/ComputerUseKit/AXElementResolver.swift`
- `Sources/MacContextKit/InputRecorder.swift`
- `Sources/MacContextKit/ScreenCapture.swift`

Implementation:

- Add a developer-only command that dumps the frontmost app's visible AX tree to JSON:
  - role, subrole, title, value summary, description, help, identifier, action names, settable attributes, frame, pid, bundle id.
- Add a highlight overlay command that draws the frame of any node by index.
- Capture before/after diagnostics for failed actions:
  - screenshot thumbnail
  - AX dump diff
  - event method used
  - secure input state
  - screen/display mapping used
- This mirrors MacosUseSDK's traversal/highlight tools and will make app-specific failures reproducible.

## Quick Wins vs Larger Bets

Quick wins:

- Add action-time Secure Input refusal for `key`, `typeText`, and paste paths.
- Make `typeText` grapheme-safe so chunks never split surrogate pairs or combining marks.
- Create fresh CGEvents for each double/triple click post.
- Wrap AX frame reads with finite/nonzero/intersects-display validation.
- Log AX richness metrics per frontmost app and audit when the AX tier is sparse.
- Add tests for `toCGGlobal` multi-display conversion before changing behavior.

Medium bets:

- Add `AXReadinessWatcher` and integrate it first in `uiChanged(after:)` and `activateAndConfirm`.
- Build `AXClient` and migrate `AXElementResolver`, `AXClickSnap`, `AXTextHarvester`, and `ScreenCaptureUtility.focusedWindowNormalizedRect`.
- Add Electron `AXManualAccessibility` enablement behind a measured profile gate.
- Add layout-aware `KeyboardLayoutMapper` for symbols and dead keys.

Larger bets:

- Maintain a Swindler-style live AX state model for the frontmost app during an agent run.
- Build a full app compatibility matrix modeled after MacAgentBench: native AppKit, SwiftUI, Electron, Catalyst, WKWebView, Safari, Office, Blender/canvas, Adobe-style pro apps.
- Train or integrate a local screenshot-to-AX fallback for sparse apps, using Screen2AX as the research direction while keeping Cascade's privacy constraints.

## Gotchas/Risks

- `AXObserver` is not a replacement for polling. Apps can omit notifications, deliver them late, or reorder them. Use observer events as early wakeups, then confirm state.
- Secure Input is a hard boundary. Do not attempt to capture, synthesize, or bypass password-field input. Pause and ask the user to type.
- AX set success is not semantic success. `axInsertText` already learned this; keep readback verification everywhere an AX mutation is used.
- Electron `AXManualAccessibility` can enlarge the tree and slow walks. Enable it per app/process, keep existing node/depth/time caps, and measure before relying on it.
- Clipboard paste is reliable but sensitive. Keep restoring the clipboard, never audit text contents, and consider refusing paste when the previous clipboard contains very large or file/object payloads that cannot be restored safely.
- Coordinate bugs are high blast radius. A single bad conversion can click the wrong app on another monitor. Gate coordinate refactors behind unit tests and a diagnostic overlay that shows both AppKit and CG positions.
- Synthetic Unicode events are not text input in every app. Some Catalyst/Electron/canvas apps drop them; physical keys or paste may still be required.
- Per-PID keyboard posting prevents focus theft but may not trigger apps that only listen at HID/session level. Keep per-app telemetry and fallback paths.
- Stable signing matters for TCC. Cascade currently builds an ad hoc signed app; repeated development builds may churn Accessibility/Input Monitoring grants. Stable developer signing is worth considering if permission churn appears.
