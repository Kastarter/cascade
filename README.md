# Cascade

Cascade is now a Swift-first macOS app. The old Screenpipe/Tauri/Rust fork has been removed from this base so the team can focus on reliable native recording, permissions, rewind context, and supervised computer use.

## What Works In This Slice

- Native macOS app shell with Reel, Cascades, Manager, and Settings.
- Menu bar icon from `/Users/khalidsh/Downloads/cascade-icons`.
- Permission preflight for Screen Recording, Accessibility, and Input Monitoring.
- Prompting only from explicit permission buttons.
- Local SQLite store for recorded app/window context and audit events.
- Reel timeline, Moment panel, local Q&A placeholder, and visible Computer Use panel.
- Evidence-backed suggestion cards from repeated local context.
- Claude API key storage in macOS Keychain.
- `Control-Option-Space` use-device hotkey that opens the supervised dock.
- STOP dock visibility fixed through nested model observation.
- `AgentDriver` protocol plus first `LocalMacDriver` shell.

## What Is Not Done Yet

- OpenClicky/TipTour-style ScreenCaptureKit screenshot/OCR capture is not fully ported.
- Real-screen agent planning through Claude is not wired yet.
- The hotkey opens the supervised dock; it does not yet run an autonomous workflow.
- Native cursor overlay, display metadata, app/window enumerators, and action routing still need to be copied into `ComputerUseKit`.
- Local VM/background sandbox is intentionally not built.

## Build And Test

```bash
swift test
./scripts/build-app.sh
open .build/Cascade.app
```

The packaged app uses:

- Bundle id: `com.humain.cascade`
- Permission logger subsystem: `com.humain.cascade`
- Keychain service: `com.humain.cascade`

For Xcode logs, open the package:

```bash
xed .
```

Then run the `Cascade` executable target and inspect Console.app for subsystem `com.humain.cascade`.

## Where The Reference Code Goes

Reference repos are implementation sources, not just inspiration. Port concrete files into Cascade-owned Swift modules with attribution:

- `jasonkneen/openclicky`: screenshot/display metadata, local bridge shape, app/window enumeration.
- `milind-soni/tiptour-macos`: permission flows, AX action routing, hotkey, cursor/control dock.
- `farzaa/clicky`: native overlay/cursor and ScreenCaptureKit patterns.
- `shujanshaikh/glide`: Input Monitoring request flow and voice/teaching product patterns.

The port map is in `docs/PORT_MAP.md`. Current status and next steps are in `HANDOFF.md`.
