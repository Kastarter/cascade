# Reference Port Map

Reference repos are implementation sources, not mood boards. Port concrete working pieces with attribution and tests.

## Permission Flow

Primary source: `milind-soni/tiptour-macos`

- `TipTour/Utilities/WindowPositionManager.swift`
  - `hasAccessibilityPermission`
  - `requestAccessibilityPermission`
  - `hasScreenRecordingPermission`
  - `requestScreenRecordingPermission`
  - `permissionRequestPresentationDestination`
- `TipTour/App/CompanionManager.swift`
  - `refreshAllPermissions`
  - `requestScreenContentPermission`
  - `startPermissionPolling`

Secondary source: `shujanshaikh/glide`

- `apps/macos/Glide/OnboardingView.swift`
  - Input Monitoring request/preflight pattern using listen-event access.

## Screen Capture

Primary source: `jasonkneen/openclicky`

- `cursor-buddy/CompanionScreenCaptureUtility.swift`
  - `currentShareableContent`
  - `prewarmShareableContent`
  - `captureAllScreensAsJPEG`
  - `captureCursorScreenAsJPEG`
  - `captureFocusedWindowAsJPEG`

Secondary source: `milind-soni/tiptour-macos`

- `TipTour/Perception/CompanionScreenCaptureUtility.swift`
  - `capturePrimaryScreenAsCGImage`
  - `captureCursorScreenAsCGImage`

Future audio/video only:

- `TipTour/Recording/ScreenRecorder.swift`
- `cursor-buddy/OpenClickySystemAudioCaptureController.swift`

## Accessibility And Input

Primary source: `milind-soni/tiptour-macos`

- `TipTour/Perception/AccessibilityTreeResolver.swift`
- `TipTour/Actions/ActionExecutor.swift`
  - `setFocusedValue`
  - `raiseMainWindowIfPossible`
  - `accessibilityWindowAttribute`

## Hotkey And Teaching

Primary source: `milind-soni/tiptour-macos`

- `TipTour/Utilities/GlobalPushToTalkShortcutMonitor.swift`
- `TipTour/Utilities/PushToTalkShortcut.swift`
  - `shortcutTransitionPublisher`
  - `start`
  - `stop`
  - `handleGlobalEventTap`
  - `shortcutTransition`

Optional later:

- `GlobalTextCommandShortcutMonitor`
- `GlobalRadialInputShortcutMonitor`
- `GlobalHighlightShortcutMonitor`
- `ClickDetector`

## Cursor, Overlay, Control Dock

Primary source: `milind-soni/tiptour-macos`

- `TipTour/UI/OverlayWindow.swift`
  - `OverlayWindow`
  - `OverlayWindowManager`
  - `BlueCursorView`
  - `startTrackingCursor`
  - `startNavigatingToElement`
  - `animateBezierFlightArc`
  - `dockBackToCursor`

Adapt to Cascade style: white/blue cursor, small STOP dock, no bulky mascot surface.

## App And Window Logging

Primary source: `jasonkneen/openclicky`

- `cursor-buddy/OpenClickyApplicationUsageLogStore.swift`
  - `recordFrontmostApplication`
  - `recordApplication`
  - `updateUsageFile`
- `cursor-buddy/OpenClickyComputerUseRuntime.swift`
  - `OpenClickyComputerUseAppEnumerator`
  - `OpenClickyComputerUseWindowEnumerator`

Secondary source: `milind-soni/tiptour-macos`

- `TipTourSettingsWindowManager.swift`
  - `PipelineLogEvent`
  - `PipelineLogStore`

## Computer-Use Action Routing

Primary source: `milind-soni/tiptour-macos`

- `TipTour/Actions/TipTourActionDriver.swift`
- `TipTour/Actions/ActionExecutor.swift`
  - `click`
  - `rightClick`
  - `doubleClick`
  - `pressKeyboardShortcut`
  - `pressKey`
  - `typeText`
  - `setFocusedValue`
  - `scroll`
  - `openApplication`
  - `openURL`

Planning/routing references:

- `PointerPromptRouter.swift`
- `WorkflowPlan`
- `WorkflowRunner`
- `ElementResolver`
- `TipTourEngine`

Use OpenClicky native runtime only for safer native subsets. Avoid private SkyLight/background-helper paths unless we explicitly accept the support risk.

## Voice And Natural Teaching

Primary source: `milind-soni/tiptour-macos`

- `TipTour/Voice/GeminiLiveSession.swift`
- `TipTour/Voice/GeminiLiveClient.swift`
- `TipTour/Voice/GeminiLiveAudioPlayer.swift`
- `PCM16AudioConverter`
- `ScreenshotPerceptualHash`

Teaching flow references:

- `startVoiceInputFromUserGesture`
- `sendFreshScreenshotForUserContext`
- `handleToolSubmitWorkflowPlan`
- `focusHighlightContextPrompt`
- `hoverWindowContextPrompt`
- `textSelectionContext`

Provider-specific code must sit behind `ProviderKit` protocols.

## Markdown App Skills

Primary source: `milind-soni/tiptour-macos`

- `TipTour/Skills/MarkdownAppSkill.swift`
  → `Sources/ComputerUseKit/AppSkill.swift`. Frontmatter parser, fenced
  runtime-hints extraction, app matcher (bundle-id exact / name substring),
  `shouldTypeUsingPhysicalKeys`, registry precedence (user dir overrides
  bundled, first-name-wins).
- `TipTour/Skills/blender/SKILL.md`
  → `Sources/ComputerUseKit/Skills/blender/SKILL.md` (rewritten for Cascade's
  agent vocabulary, not copied — TipTour's harness endpoints don't exist here).

Cascade divergences:

- `axUnreliable` hint (Cascade extension): replay skips AX target resolution
  and AX-fingerprint verification for canvas apps instead of false-pausing.
- Fence name is `cascade-runtime-hints`; the `tiptour-runtime-hints` fence
  still parses so TipTour skill files drop in unmodified.
- `commandAliases`, `targetPolicies`, and `plannerInstructions` are not
  ported (no voice-alias fast path or local OCR target list in Cascade; the
  markdown body carries all prompt instructions).
- Only files named `SKILL.md` load (TipTour also accepts other `.md` names).

## Known Architecture Risks To Avoid

- Do not copy `CompanionManager.swift` wholesale from any repo.
- OpenClicky’s background-computer-use selector is not honest for clicks; selected background mode can still route to cursor-warping native clicks.
- TipTour’s workflow submission intentionally truncates to one step; keep that safety for teaching, but do not mistake it for full automation.
- Do not copy analytics wrappers or API-key assumptions.
- Do not use Screen Recording "previously confirmed" workarounds as proof of current permission.

## Attribution

All four referenced repos are MIT-licensed. Preserve copyright notices in copied source files and update `docs/THIRD_PARTY_NOTICES.md` when code is ported.

OpenClicky also carries CUA Driver attribution in its third-party notices; include that if adapting those patterns.
