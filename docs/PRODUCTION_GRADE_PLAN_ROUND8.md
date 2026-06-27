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
