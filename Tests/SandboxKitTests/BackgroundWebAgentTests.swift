import Testing

@testable import ProviderKit
@testable import SandboxKit

// MARK: - Fix #1: a transport failure must never be read as a completion
//
// Audit-log evidence (Cascade.sqlite, 2026-06-14T04:02): a background run was mid
// flight-comparison when the API turn failed; ComputerUseAgent surfaced that as a
// `done` step carrying "I couldn't reach Claude just now.", the loop read it as a
// finish, and the page-verifier — failing open on the SAME outage — "verified" it,
// so the run was recorded `completed`. `classifyDone` is the pure decision that now
// makes an unreachable turn a failure instead.

@Test
func transportFailureIsNeverAFinish() {
    // The exact 04:02 row: the failure text rode in on a `failed` turn.
    #expect(
        BackgroundWebAgent.classifyDone(rawText: "I couldn't reach Claude just now.", failed: true)
            == .transportFailure
    )
    // Empty text on a failed turn (the JSON-encoding failure path) is also a failure.
    #expect(BackgroundWebAgent.classifyDone(rawText: "", failed: true) == .transportFailure)
}

@Test
func failedFlagWinsOverWhateverTextTheTurnCarries() {
    // The invariant that closes the hole: a failed turn is a failure REGARDLESS of its
    // text — a stale success/login/incomplete line on a failed round trip must not be
    // mistaken for a real outcome.
    #expect(
        BackgroundWebAgent.classifyDone(rawText: "All the flight data has been added.", failed: true)
            == .transportFailure
    )
    #expect(
        BackgroundWebAgent.classifyDone(rawText: "NEEDS_LOGIN Gmail", failed: true) == .transportFailure
    )
    #expect(
        BackgroundWebAgent.classifyDone(rawText: "INCOMPLETE: the form wouldn't submit", failed: true)
            == .transportFailure
    )
}

@Test
func genuineDoneStillClassifiesNormally() {
    // A real completion (the 17:57 Notion run) — failed: false — is still finished.
    #expect(
        BackgroundWebAgent.classifyDone(
            rawText: "All the flight information has been added to the Notion page.", failed: false
        ) == .finished("All the flight information has been added to the Notion page.")
    )
    // Empty success text falls back to "Done.", never to a failure.
    #expect(BackgroundWebAgent.classifyDone(rawText: "", failed: false) == .finished("Done."))
}

@Test
func loginAndIncompleteSignalsStillRoute() {
    #expect(
        BackgroundWebAgent.classifyDone(rawText: "NEEDS_LOGIN Gmail", failed: false)
            == .needsLogin("Gmail")
    )
    #expect(
        BackgroundWebAgent.classifyDone(rawText: "INCOMPLETE: the editor wouldn't accept input", failed: false)
            == .incomplete("the editor wouldn't accept input")
    )
    // "incomplete" only counts as a leading marker — a success that merely mentions the
    // word is still a finish (the existing protocol, re-checked through classifyDone).
    #expect(
        BackgroundWebAgent.classifyDone(rawText: "Done — some dates had incomplete pricing.", failed: false)
            == .finished("Done — some dates had incomplete pricing.")
    )
}

// MARK: - Fix #2: every audited row is attributable to its run

@Test
func auditTagPrefixesDetailSoConcurrentRunsAreDistinguishable() {
    // Two runs logging the same action into the one shared audit_event stream must be
    // tellable apart — the 17:5x window was unreadable precisely because they weren't.
    let a = BackgroundWebAgent.taggedDetail(tag: "a1b2c3d4", "click (10,20)")
    let b = BackgroundWebAgent.taggedDetail(tag: "e5f6a7b8", "click (10,20)")
    #expect(a == "[a1b2c3d4] click (10,20)")
    #expect(b == "[e5f6a7b8] click (10,20)")
    #expect(a != b)
}

@Test
func emptyTagLeavesDetailUntouched() {
    // No tag set → legacy behavior, so an untagged caller never gains a stray "[] ".
    #expect(BackgroundWebAgent.taggedDetail(tag: "", "key Return") == "key Return")
}

// MARK: - Efficiency parity: state-change classification gates both circuit-breakers

@Test
func observationActionsDoNotCountAsStateChange() {
    // A read/look turn must NOT count as acting, or no-effect would false-fire on a
    // read and the stall guard would never catch a model that only observes.
    #expect(BackgroundWebAgent.isStateChanging(.screenshot) == false)
    #expect(BackgroundWebAgent.isStateChanging(.wait) == false)
    #expect(BackgroundWebAgent.isStateChanging(.zoom(nx: 0, ny: 0, nw: 1, nh: 1)) == false)
    #expect(BackgroundWebAgent.isStateChanging(.highlight(x: 0, y: 0, width: 1, height: 1, label: "x")) == false)
    // A clipboard copy leaves the page unchanged by design (predicted-effect), so a
    // copy-only turn must not be charged as a no-effect failure.
    #expect(BackgroundWebAgent.isStateChanging(.key("cmd+c")) == false)
    #expect(BackgroundWebAgent.isStateChanging(.key("cmd+x")) == false)
}

@Test
func realActionsCountAsStateChange() {
    #expect(BackgroundWebAgent.isStateChanging(.click(x: 1, y: 2)))
    #expect(BackgroundWebAgent.isStateChanging(.type("hi")))
    #expect(BackgroundWebAgent.isStateChanging(.openURL("https://example.com")))
    #expect(BackgroundWebAgent.isStateChanging(.key("return")))
}

@Test
func backgroundWebAgentRejectsInvalidCoordinateFormatting() {
    let invalid = [Double.nan, .infinity, -.infinity, 1_000_000_000]
    for value in invalid {
        #expect(BackgroundWebAgent.sandboxTopLeftPoint(x: value, y: 10) == nil)
        #expect(BackgroundWebAgent.sandboxTopLeftPoint(x: 10, y: value) == nil)
    }

    #expect(BackgroundWebAgent.sandboxTopLeftPoint(x: 10.8, y: 20.2)?.x == 10)
    #expect(BackgroundWebAgent.sandboxTopLeftPoint(x: 10.8, y: 20.2)?.y == 539)
    #expect(BackgroundWebAgent.invalidCoordinateDetail("click") == "invalid-coordinate action=click")
}

@Test
func backgroundWebAgentScrollFormattingIsBounded() {
    #expect(BackgroundWebAgent.sandboxScrollDelta(direction: "down", amount: 2) == 240)
    #expect(BackgroundWebAgent.sandboxScrollDelta(direction: "up", amount: 2) == -240)
    #expect(BackgroundWebAgent.sandboxScrollDelta(direction: "down", amount: Int.max) == nil)
    #expect(BackgroundWebAgent.sandboxScrollDelta(direction: "down", amount: 1_000_000_000) == nil)
}
