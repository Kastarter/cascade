# Third-Party Notices

Cascade Native currently includes Cascade-owned source plus generated icon assets supplied at `/Users/khalidsh/Downloads/cascade-icons`.

The following repositories are approved reference sources for future ports:

- `farzaa/clicky` — MIT License.
- `jasonkneen/openclicky` — MIT License.
- `milind-soni/tiptour-macos` — MIT License.
- `shujanshaikh/glide` — MIT License.

When source is copied or substantially adapted, add the original repository, file path, copyright/license header, and local destination here.

## Adapted Source

- `jasonkneen/openclicky` (MIT) — `cursor-buddy/CompanionScreenCaptureUtility.swift`
  → `Sources/MacContextKit/ScreenCapture.swift`. Adapted the ScreenCaptureKit
  cursor-screen selection, own-window exclusion via `SCContentFilter`, and the
  `SCStreamConfiguration` + `SCScreenshotManager` single-frame capture path.
  Re-implemented as a Cascade-owned, fail-closed observer paired with on-device OCR.

- `jasonkneen/openclicky` (MIT) — `cursor-buddy/ElementLocationDetector.swift`
  → `Sources/ProviderKit/ElementLocator.swift`. Adapted the aspect-ratio-matched
  resize, the `computer_20251124` Computer Use tool declaration, and the
  pixel-coordinate parse, as a Cascade-owned BYOK element locator.

- `jasonkneen/openclicky` (MIT) — `cursor-buddy/OverlayWindow.swift`
  → `Sources/ComputerUseKit/GuidanceOverlay.swift`. Adapted the transparent,
  click-through, always-on-top overlay-window setup and the blue guide-cursor idea
  into a small Cascade-owned guide cursor + label callout.

- `jasonkneen/openclicky` (MIT) — `cursor-buddy/OpenClickyComputerUseRuntime.swift`
  patterns informed Cascade's agent/teaching runtime in `Sources/AppShell` and
  `Sources/AgentOrchestrator`.

Do not copy TipTour Neko sprite assets unless their separate BSD 2-Clause license is included and the product actually needs them.
