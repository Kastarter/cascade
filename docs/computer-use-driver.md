# Cascade Computer-Use Driver Notes

Last updated: 2026-06-08

Cascade's computer-use runtime is a Cascade-owned driver layer with selected MIT-licensed patterns ported from Clicky/OpenClicky/TipTour. We keep Cascade's Screenpipe-style context as the advantage while copying the proven macOS pieces that matter: prompt-once permission flow, ScreenCaptureKit capture, native cursor/control behavior, display metadata, and local action routing.

## Driver Contract

All execution backends implement the same shape:

- `observe()` captures the current visual state plus OCR, accessibility/app/window context, cursor/display scale, and recent Rewind context.
- `act()` performs typed actions through the backend: browser DOM injection, real macOS input synthesis, or a future local VM bridge.
- `verify()` uses layered evidence: DOM/AX/state first when available, OCR/text-region delta second, image diff last.
- `status`, `pause`, and `stop` update the visible control dock and the `cascade_agent_runs` lifecycle.

## Backends

- `local_browser`: current isolated WKWebView sandbox. It is the default and accepts the legacy `sandbox` setting value. Verification now treats low/no image delta as unclear instead of failed, which prevents stale WK snapshots from poisoning the model history.
- `screen`: real Mac apps through native ComputerUseKit capture and input routing. It is blocked unless Screen Recording, Accessibility, Input Monitoring, healthy screen frames, and UI recorder health are all present. It has a visible STOP dock, a max real-screen action cap, repeated-action guard, timeout guard, and orphaned-run cleanup.
- `local_vm`: defined but fail-closed. The first provider should expose the same observe/act/verify contract from a local isolated browser/app VM, then later replace the current browser sandbox boundary.

## Reference Audit

- `farzaa/clicky`: useful for ScreenCaptureKit capture, native Swift overlays, permission-first flow, and making the cursor/control layer feel like a real Mac app.
- `jasonkneen/openclicky`: useful for a local bridge model, cursor and screenshot endpoints, display metadata, external control routing, and Codex-style agent mode.
- `milind-soni/tiptour-macos`: useful for polished macOS accessibility/onboarding and native cursor/control UX.

Port the working modules/patterns directly when they map to Cascade's driver contract, with attribution and license notes. Do not vendor full apps unless there is a concrete build-time dependency.
