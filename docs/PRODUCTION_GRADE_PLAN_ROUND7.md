# Cascade Production-Grade Plan - Round 7

Date: 2026-06-26

## Findings

### P7-01 - Web sandbox coordinate Int conversions can trap before JS dispatch

- Files: `/Users/khalidsh/Humain/cascade/Sources/SandboxKit/WebSandbox.swift`; `/Users/khalidsh/Humain/cascade/Sources/SandboxKit/BackgroundWebAgent.swift`
- Build: Add a small finite/range helper for web action coordinates, for example `SandboxCoordinate.safeInt(_ value: CGFloat, min:max:) -> Int?`, and use it before every `Int(x)`, `Int(y)`, `Int(dy)`, and top-left Y audit conversion in the sandbox bridge. Non-finite or absurd values should no-op with a sanitized audit/refusal such as `invalid-coordinate`, not enter the JS string or `lastActionPoint`.
- Test: Unit-test `click`, `scroll`, and `BackgroundWebAgent.apply`-reachable action formatting with `.nan`, `.infinity`, `-.infinity`, and very large finite values. Assert no trap, no invalid JS is emitted, and any stored cursor/action point is finite and bounded.
- Status: Fixed 2026-06-26 with shared `SandboxCoordinate` guards before web JS/audit formatting.
- Risk: med
- Seq: SEQ-02/SEQ-09

### P7-02 - Planner action labels convert model coordinates with raw `Int(...)`

- Files: `/Users/khalidsh/Humain/cascade/Sources/ProviderKit/Planner.swift`
- Build: Replace coordinate label interpolation in `PlannedAction.shortLabel` with a finite-safe formatter that clamps to a sane display range or prints `?` for invalid values. Apply it to move/click/double-click/right-click and scroll deltas. Do not let a display label be the first code path that traps on model output.
- Test: Assert `PlannedAction.click(x: .nan, y: .infinity).shortLabel`, `scroll(deltaX: .greatestFiniteMagnitude, deltaY: -.infinity).shortLabel`, and normal finite labels all return deterministic strings without trapping.
- Status: Fixed 2026-06-26 with finite-safe label formatting for planner coordinates and scroll deltas.
- Risk: low
- Seq: SEQ-02

### P7-03 - Harness audit summaries still emit raw queries, paths, commands, and script bodies

- Files: `/Users/khalidsh/Humain/cascade/Sources/ProviderKit/AgentHarness.swift`; `/Users/khalidsh/Humain/cascade/Sources/AppShell/CascadeAppModel.swift`; `/Users/khalidsh/Humain/cascade/Sources/SandboxKit/BackgroundWebAgent.swift`
- Build: Split user-visible/dock text from audit text. Replace `HarnessCall.auditSummary` with a safe audit descriptor per call: `queryHash`, `folderHash`, `pathHash`, `commandHash`, `scriptHash`, content byte count, and tool name. Use that descriptor for `harness.*`, `harness.slow`, `sandbox.harness`, and any trace-building inputs. Keep raw path/command only in the supervised local execution result shown to the model/user, not the stored audit detail.
- Test: Construct every `HarnessCall` using a distinctive path, query, command, AppleScript, and file content. Assert audit descriptors contain hashes/counts/tool names and do not contain any raw path component, query term, command token, script text, or content prefix.
- Status: Fixed 2026-06-26 with `HarnessCall.auditDescriptor` hashes/counts, dock-only display summaries, and sandbox harness audit routing through safe descriptors.
- Risk: med
- Seq: SEQ-05/SEQ-07/SEQ-14

### P7-04 - Recall audit detail stores raw record search queries

- Files: `/Users/khalidsh/Humain/cascade/Sources/ProviderKit/RecordRecall.swift`; `/Users/khalidsh/Humain/cascade/Sources/AppShell/CascadeAppModel.swift`; `/Users/khalidsh/Humain/cascade/Sources/SandboxKit/BackgroundWebAgent.swift`
- Build: Change `RecordRecall.Call.auditDetail` to a safe descriptor. For `search_record`, store query length plus `queryHash`; for timeframe/session calls store normalized timestamps only; for inspect calls keep moment IDs only. Route `agent.recall` and sandbox recall/harness audit through this safe descriptor, while preserving raw query text only inside the local model tool result where recall must function.
- Test: A search query containing a unique company/person/file phrase must not appear in the audit detail, dock-backed audit, or sandbox harness audit. Assert the row still records `search_record`, length, and a stable hash.
- Status: Fixed 2026-06-26 with `RecordRecall.Call.auditDetail` safe descriptors, dock/`agent.recall` reuse of the descriptor, and sandbox harness audit routing recall calls through the recall descriptor.
- Risk: med
- Seq: SEQ-04/SEQ-07/SEQ-14

### P7-05 - No-effect, ground-miss, and OCR mark audits embed raw AX/OCR labels

- Files: `/Users/khalidsh/Humain/cascade/Sources/AppShell/CascadeAppModel.swift`
- Build: Keep raw labels in the prompt nudge if the agent needs them to re-ground, but change audit detail for `assist.noeffect`, `agent.ground.miss`, and `scout.ocr.marks` to counts plus hashes. Examples: `labelsHash`, `coordsHash`, `ocrMarksHash`, `controlCount`, `ocrLineCount`, and the turn number. Do not store `interactableSummary`, `located`, missed target text, frontmost window title, or Set-of-Marks text verbatim in audit rows.
- Test: Feed fake controls/OCR marks containing a unique sensitive phrase through the no-effect and OCR mark paths. Assert the next model note can still include the phrase when needed, but appended audit rows contain only counts/hashes and never the raw labels or OCR text.
- Risk: med
- Seq: SEQ-03/SEQ-07/SEQ-14

### P7-06 - Background web-agent audit rows leak typed text, URLs, tool args, and final findings

- Files: `/Users/khalidsh/Humain/cascade/Sources/SandboxKit/BackgroundWebAgent.swift`
- Build: Replace `argSummary`, `sandbox.act` type/open rows, `sandbox.tool`, `sandbox.turn`, `sandbox.ground`, `sandbox.ground.miss`, `sandbox.verify`, and `sandbox.done` detail strings with safe descriptors: action kind, char counts, URL hash, target hash, result hash, and status. Keep the raw final result in the user-facing update/result channel, not in audit detail.
- Test: Run synthetic sandbox actions/tool calls containing a unique URL, field label, typed value, and final finding. Assert emitted audit details contain hashes/counts/status and do not contain the raw URL, label, typed value, or finding text.
- Risk: med
- Seq: SEQ-07/SEQ-14

### P7-07 - App-shell and local-driver audit rows persist raw user goals, agent names, artifact paths, and labels

- Files: `/Users/khalidsh/Humain/cascade/Sources/AppShell/CascadeAppModel.swift`; `/Users/khalidsh/Humain/cascade/Sources/AgentOrchestrator/AgentOrchestrator.swift`
- Build: Introduce a shared audit-sanitizing helper for user/agent identity strings, for example `AuditIdentity.hash(_:)`, and use it on `assist.task`, `sandbox.task`, `sandbox.steer`, `agent.run.completed`, `teach.*` intent/reveal/pointed labels, `agent.approved/declined`, recipe label details, learned-skill draft goals, schedule rows, `computer.act`, and `artifact.write`. Store stable IDs/hashes/counts; keep raw text in UI state and local artifacts where needed.
- Test: Exercise representative audit paths with unique task text, agent name, artifact title/path, pointed label, and schedule name. Assert stored `AuditEvent.detail` contains stable references and never raw goal/name/path/label text.
- Risk: high
- Seq: SEQ-07/SEQ-14

### P7-08 - Unguarded AX focused-window force casts remain outside the resolver

- Files: `/Users/khalidsh/Humain/cascade/Sources/MacContextKit/AXTextHarvester.swift`; `/Users/khalidsh/Humain/cascade/Sources/MacContextKit/MacContextKit.swift`; `/Users/khalidsh/Humain/cascade/Sources/MacContextKit/ScreenCapture.swift`
- Build: Add or reuse a tiny `decodeAXElement(_ ref: CFTypeRef?) -> AXUIElement?` helper that checks `CFGetTypeID(ref) == AXUIElementGetTypeID()` before casting. Replace the remaining unguarded `focusedRef as! AXUIElement` / `focused as! AXUIElement` sites. Leave already-guarded casts alone.
- Test: Unit-test the helper with a real `AXUIElement`, `nil`, and non-AX CF values such as `CFString`. Add coverage around focused-window title/text/normalized-rect helpers using injected decode inputs or a small internal helper so malformed providers return nil/empty instead of trapping.
- Risk: med
- Seq: SEQ-09/SEQ-29

## Sweep Notes

- Already-guarded class-A hits not carried forward: `UIStateSnapshot.FrameBucket.bucket`, `ScreenElementIndex.quantized`, `WebStateSignature.integer`, and `VerifierCalibration.bucketIndex`.
- Already-hashed class-B hit not carried forward: `WebStateSignature.description` now emits URL/title/active-element hashes, not raw page identity.
- No high-confidence divide-by-zero or empty-collection trap was found beyond the force-cast item above; the visible `[0]`/`first!`/`last!` hits checked are protected by count guards, non-empty cluster construction, or system-created buffers.
