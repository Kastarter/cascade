# Cascade Swift-First Handoff

Last updated: 2026-06-08.

## Current Direction

Cascade has been rebased into a clean Swift-first macOS app at the repository root. The old Screenpipe/Tauri/Rust implementation paths have been removed from this branch. Keep the architecture focused on employee-owned local context first, then supervised agents.

The app is not an OpenClicky fork yet. OpenClicky/TipTour are reference implementations we are porting into Cascade-owned Swift modules.

## Build

```bash
cd /Users/khalidsh/Humain/cascade
swift test
./scripts/build-app.sh
open .build/Cascade.app
```

`scripts/build-app.sh` writes `.build/Cascade.app`, signs it ad hoc, and sets:

- `CFBundleIdentifier = com.humain.cascade`
- Keychain service = `com.humain.cascade`
- Permission log subsystem = `com.humain.cascade`

Open in Xcode for live logs:

```bash
xed /Users/khalidsh/Humain/cascade
```

Run the `Cascade` executable target. In Console.app, filter by subsystem `com.humain.cascade` and category `permissions`.

## What Is In The App Now

- SwiftPM package at repo root.
- `Sources/CascadeApp`: app entry point and menu bar item.
- `Sources/AppShell`: native SwiftUI UI.
- `Sources/MacContextKit`: permission preflight, app/window observation, context recorder.
- `Sources/ComputerUseKit`: action types, hotkey monitor, native actuator shell, STOP dock model.
- `Sources/CascadeMemory`: SQLite context/audit store.
- `Sources/SuggestionEngine`: evidence-backed suggestion cards.
- `Sources/ProviderKit`: local Q&A placeholder and Keychain-backed Anthropic key storage.
- `Sources/AgentOrchestrator`: `AgentDriver` protocol and `LocalMacDriver` shell.

## What Works

- App launches as `com.humain.cascade`.
- Settings shows exact app identity/path being evaluated by macOS TCC.
- Screen Recording, Accessibility, and Input Monitoring use preflight checks.
- Permission prompts are only called from explicit buttons.
- `Open Settings` is debounced and reveals the app bundle in Finder.
- Claude key card is visible and stores the key in macOS Keychain.
- Reel has Moment, timeline, Ask panel, Audit, and Computer Use status panel.
- `Control-Option-Space` opens the supervised dock and logs `device.intent hotkey`.
- STOP dock visibility bug was fixed by forwarding nested observable changes.
- Cascades view uses adaptive grid instead of clipping horizontally.
- Manager view shows aggregate-only prototype metrics.
- Tests pass: 4 Swift tests.

## What Is Not Done

- Real ScreenCaptureKit screenshots/OCR are not ported yet.
- OpenClicky-style display metadata and app/window enumeration are not ported yet.
- TipTour/OpenClicky AX action routing is not ported yet.
- Claude does not yet generate executable computer-use plans.
- Suggestions are review cards only, not runnable workflows.
- Local Browser driver and Local VM driver are not built in this Swift base.
- Native cursor overlay/control dock polish is first-slice only.

## Immediate Next Steps

1. Verify macOS permissions against the new bundle id `com.humain.cascade`.
2. If Settings still says denied, remove old duplicate Cascade entries from Privacy settings and add `.build/Cascade.app`.
3. Port ScreenCaptureKit capture into `MacContextKit` from OpenClicky/TipTour, strictly gated by `CGPreflightScreenCaptureAccess()`.
4. Port AX/action routing into `ComputerUseKit` from TipTour `ActionExecutor` and `TipTourActionDriver`.
5. Add display/cursor metadata and app/window enumeration from OpenClicky runtime files.
6. Wire Claude provider behind `ProviderKit` to generate reviewed single-step plans first.
7. Keep STOP visible and audit every proposed/approved action.

## Reference Port Map

Use `docs/PORT_MAP.md` as the source of truth for what to copy and where. Preserve MIT notices in `docs/THIRD_PARTY_NOTICES.md`.

Most important source areas:

- OpenClicky: `CompanionScreenCaptureUtility.swift`, `OpenClickyApplicationUsageLogStore.swift`, `OpenClickyComputerUseRuntime.swift`.
- TipTour: `WindowPositionManager.swift`, `GlobalPushToTalkShortcutMonitor.swift`, `ActionExecutor.swift`, `TipTourActionDriver.swift`, `OverlayWindow.swift`.
- Glide: `OnboardingView.swift` listen-event access patterns.

## User Feedback To Address

- The user wants to know where to test real computer use. Keep the Reel Computer Use panel obvious.
- The user expects a hotkey. Current hotkey is `Control-Option-Space`.
- The user expects the Claude key field. It is in Settings.
- The user does not want old Screenpipe/Tauri code in the active base.
- The user wants Cascade to feel native, smooth, small, white/blue, and trust-forward.
