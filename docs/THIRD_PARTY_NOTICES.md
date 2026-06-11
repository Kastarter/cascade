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

- `milind-soni/tiptour-macos` (MIT) — `TipTour/UI/OverlayWindow.swift`
  (`CursorArrowShape`, the Lucide mouse-pointer-2 port) → `PointerShape` in
  `Sources/ComputerUseKit/GuidanceOverlay.swift`. Path geometry copied; the
  green mint-glow cursor styling (white core, green edge, seafoam halo) is
  adapted from the TipTour companion's look.

- `milind-soni/tiptour-macos` (MIT) — `TipTour/Skills/MarkdownAppSkill.swift`
  → `Sources/ComputerUseKit/AppSkill.swift`. Adapted the markdown skill model,
  frontmatter/fenced-hints parsing, app matching, physical-keys input policy,
  and registry precedence. Cascade adds the `axUnreliable` hint and drops
  commandAliases/targetPolicies/plannerInstructions.

- `milind-soni/tiptour-macos` (MIT) — `TipTour/Skills/blender/SKILL.md`
  → `Sources/ComputerUseKit/Skills/blender/SKILL.md`. Blender workflow
  knowledge (modal transform sequencing, house recipe, import workflow)
  rewritten for Cascade's computer-use agent.

Do not copy TipTour Neko sprite assets unless their separate BSD 2-Clause license is included and the product actually needs them.
