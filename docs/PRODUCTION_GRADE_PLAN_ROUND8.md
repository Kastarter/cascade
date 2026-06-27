# Cascade Production-Grade Plan - Round 8

Date: 2026-06-26

## Findings

### P8-01 - Recorder capture audits persisted raw app names

- Files: `/Users/khalidsh/Humain/cascade/Sources/MacContextKit/MacContextKit.swift`; `/Users/khalidsh/Humain/cascade/Sources/MacContextKit/RewindRecorder.swift`
- Build: Add `ContextRecorder.captureAuditDetail(appName:axChars:ocrChars:)` and route both one-shot `context.capture` and continuous `rewind.capture` details through it. Store `appHash`, `appChars`, `axChars`, and `ocrChars`; do not persist the raw app name in audit detail.
- Test: `ContextRecorderAuditTests.contextCaptureAuditDetailHashesAppNameAndKeepsOnlyCounts` asserts the detail contains the app hash/counts and excludes a unique raw app-name token.
- Status: Fixed 2026-06-26.
- Risk: med
- Seq: SEQ-07/SEQ-14

### P8-02 - App-shell assist audits persisted raw user/model text

- Files: `/Users/khalidsh/Humain/cascade/Sources/AppShell/CascadeAppModel.swift`
- Build: Route `reel.point`, `voice.fragment.ignored`, `voice.duplicate.ignored`, `assist.validate`, `assist.stalled`, `agent.ground`, and Scout planner-failed `assist.timing` through `AuditIdentity`-backed descriptors. Preserve raw text only in live UI/model control flow; store hashes/counts/status in audit rows.
- Test: `CascadeAppModelTests.appShellAuditDetailsKeepStableIdentityReferencesNotRawText` now covers all of those rows with unique raw tokens and asserts only hashes/counts/status survive.
- Status: Fixed 2026-06-26.
- Risk: high
- Seq: SEQ-07/SEQ-14

### P8-03 - Harness watched-app denial audit persisted raw app identity

- Files: `/Users/khalidsh/Humain/cascade/Sources/AppShell/CascadeAppModel.swift`
- Build: Replace `harness.denied.watched-app` detail `"\(name) -> \(watched)"` with `harnessDeniedWatchedAppAuditDetail(toolName:watchedApp:)`, keeping the fixed tool token and hashing the watched app identity.
- Test: `CascadeAppModelTests.appShellAuditDetailsKeepStableIdentityReferencesNotRawText` asserts the row contains `tool=run_applescript` plus `appHash` and excludes the raw watched-app token.
- Status: Fixed 2026-06-26.
- Risk: med
- Seq: SEQ-05/SEQ-07/SEQ-14

### P8-04 - Cursor flight sleeps converted non-finite delay to Int

- Files: `/Users/khalidsh/Humain/cascade/Sources/AppShell/CascadeAppModel.swift`
- Build: Add `safeFlightDelayMilliseconds(_:)` and use it before all five `Task.sleep(.milliseconds(...))` calls fed by `GuidanceOverlay.navigate`. Non-finite and negative values become `0`; large finite delays clamp to `1000ms`.
- Test: `CascadeAppModelTests.flightDelayMillisecondsRejectsNonFiniteAndClampsLargeValues` asserts `.nan`, `.infinity`, negative, normal, and oversized values are finite-safe.
- Status: Fixed 2026-06-26.
- Risk: med
- Seq: SEQ-02/SEQ-09

### P8-05 - UI-TARS smart-resize helpers could trap on invalid factor or overflow product checks

- Files: `/Users/khalidsh/Humain/cascade/Sources/ProviderKit/VisualGrounder.swift`
- Build: Harden `UITARSGrounder.smartResize` with a positive `safeFactor`, finite/range-checked factor-multiple conversion, and division-based product comparisons instead of `wb * hb` before bounds checks.
- Test: `VisualGrounderTests.smartResizeRejectsInvalidFactorAndAvoidsOverflowingProductCheck` asserts invalid factors and `Int.max` dimensions return positive bounded dimensions without overflowing.
- Status: Fixed 2026-06-26.
- Risk: med
- Seq: SEQ-02/SEQ-09

## Sweep Notes

- Post-fix audit scan checked every `appendAudit`, `AuditEvent(`, and `audit(` call in `Sources`.
- Remaining audit details are fixed vocabulary, IDs/counts/status, or already-hashed descriptors. The only raw-looking app-shell details left are user-facing strings outside audit rows or fixed system messages.
- Remaining `Int(` hits are database integers, fixed Cocoa window levels, normal screen geometry conversions, or already finite/range guarded helper paths; no further high-confidence non-finite-to-Int trap was found.
- Verification: focused audit/finite tests passed, and full `swift test` passed on 2026-06-26.

Convergence: after the five fixes above, no remaining high-confidence raw-PII audit emit-sites or non-finite-to-Int traps were found.
