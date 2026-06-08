# First Slice Test Plan

## Automated

Run:

```bash
swift test
./scripts/build-app.sh
```

Required passing tests:

- `CascadeMemoryTests`: context and audit events persist to SQLite.
- `SuggestionEngineTests`: suggestions require non-sensitive evidence.
- `AgentOrchestratorTests`: driver observes context and verifies against recorded state.

## Manual Native App

1. Launch `.build/Cascade.app`.
2. Confirm the menu bar shows the Cascade template icon.
3. Confirm the top bar shows `REC · LOCAL` or `PAUSED · LOCAL`.
4. Open Settings and verify permission rows render without triggering Screen Recording prompts automatically.
5. Click `Request Screen Recording`; only then may macOS show a native prompt.
6. Paste an Anthropic key in `Claude key`; verify Settings shows `CONNECTED`.
7. Click `Capture now`; verify a local context sample appears in Reel and the Moment panel is populated.
8. Ask `What did I do today?`; verify answer is grounded and does not pretend to know unavailable OCR/screenshots.
9. Press `Control-Option-Space`; verify the control dock appears and audit logs `device.intent hotkey`.
10. Confirm Audit records context captures.
11. Capture repeated contexts in the same app/window; verify Cascades surfaces a reviewable helper without horizontal clipping.
12. Confirm Manager shows only aggregate-style counts, not raw OCR/screenshots.

## Future Native Computer-Use Gate

Screen agent status may become healthy only when all are true:

- Screen Recording granted.
- Accessibility granted.
- Input Monitoring granted.
- Recorder health is fresh.
- STOP/control dock is visible.
- Action caps and loop guards are active.
- Audit logging is writable.

Until then, screen actions must fail closed with a clear reason.
