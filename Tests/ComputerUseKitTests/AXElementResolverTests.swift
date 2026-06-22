import Foundation
import Testing

@testable import ComputerUseKit

// Pure matching logic — the AX tree walks themselves need a live session and are
// exercised manually.
struct AXElementResolverTests {
    @Test func exactMatchScoresHighest() {
        #expect(AXElementResolver.matchScore(needle: "send", candidate: "send") == 3)
    }

    @Test func containmentScoresAboveWordOverlap() {
        let contains = AXElementResolver.matchScore(needle: "send", candidate: "send message")
        let overlap = AXElementResolver.matchScore(needle: "send the message", candidate: "message send now")
        #expect(contains == 2)
        #expect(overlap > 1 && overlap < 2)
    }

    @Test func unrelatedTextDoesNotMatch() {
        #expect(AXElementResolver.matchScore(needle: "send", candidate: "delete draft") == 0)
        #expect(AXElementResolver.matchScore(needle: "", candidate: "anything") == 0)
    }

    @Test func weakWordOverlapIsRejected() {
        // 1 of 3 words shared (33%) — below the 60% bar, must not hijack a click.
        #expect(AXElementResolver.matchScore(needle: "open the inbox", candidate: "the archive") == 0)
    }

    @Test func normalizeCollapsesWhitespaceAndCase() {
        #expect(AXElementResolver.normalize("  Send\n  Message ") == "send message")
    }

    // MARK: - B1 ranked locator: rank(recorded:candidate:)

    private func desc(_ label: String, role: String? = nil, id: String? = nil) -> AXElementResolver.Descriptor {
        AXElementResolver.Descriptor(label: label, role: role, identifier: id)
    }

    @Test func labelOnlyRankReducesToTextScore() {
        // Legacy recipes carry no role/identifier — rank must equal the old matchScore
        // so the find(label:) wrapper behaves exactly as before.
        #expect(AXElementResolver.rank(recorded: desc("Send"), candidate: desc("Send")) == 3)
        #expect(AXElementResolver.rank(recorded: desc("Send"), candidate: desc("Send Message")) == 2)
        #expect(AXElementResolver.rank(recorded: desc("Send"), candidate: desc("Delete")) == 0)
    }

    @Test func matchingIdentifierDominatesEvenWhenLabelDrifted() {
        // The button was relabeled "Submit" but kept its identifier — a stable id beats
        // a perfect-label-but-different-element candidate.
        let renamed = AXElementResolver.rank(
            recorded: desc("Send", role: "AXButton", id: "composeSend"),
            candidate: desc("Submit", role: "AXButton", id: "composeSend"))
        let lookalike = AXElementResolver.rank(
            recorded: desc("Send", role: "AXButton", id: "composeSend"),
            candidate: desc("Send", role: "AXButton", id: "otherSend"))
        #expect(renamed == 100)
        #expect(renamed > lookalike)
    }

    @Test func roleAgreementBreaksTiesBetweenEqualLabels() {
        // Two "Save" controls — prefer the one whose role matches the recorded click
        // (a button), over a same-label menu item.
        let sameRole = AXElementResolver.rank(
            recorded: desc("Save", role: "AXButton"),
            candidate: desc("Save", role: "AXButton"))
        let otherRole = AXElementResolver.rank(
            recorded: desc("Save", role: "AXButton"),
            candidate: desc("Save", role: "AXMenuItem"))
        #expect(sameRole > otherRole)
        // A role mismatch still keeps a genuine label match positive (role data is imperfect).
        #expect(otherRole > 0)
    }

    @Test func mismatchedIdentifierFallsBackToLabelNotDisqualify() {
        // Different identifiers must not short-circuit to a match, but a strong label
        // match should still score (the id branch only fires on EQUAL non-empty ids).
        let score = AXElementResolver.rank(
            recorded: desc("Send", role: "AXButton", id: "a"),
            candidate: desc("Send", role: "AXButton", id: "b"))
        #expect(score == 3.25) // label exact (3) + same-role tiebreak (0.25)
    }

    @Test func roleTiebreakNeverOverridesABetterLabelMatch() {
        // Exact label in the "wrong" role must still beat a partial label in the right
        // role — role only reorders WITHIN a label-score tier (the ±0.25 audit fix).
        let exactWrongRole = AXElementResolver.rank(
            recorded: desc("Save", role: "AXButton"),
            candidate: desc("Save", role: "AXMenuItem"))      // 3 - 0.25 = 2.75
        let partialRightRole = AXElementResolver.rank(
            recorded: desc("Save", role: "AXButton"),
            candidate: desc("Save Document", role: "AXButton")) // 2 + 0.25 = 2.25
        #expect(exactWrongRole > partialRightRole)
    }

    // The flail-moment grounding push: turn live AX controls into the compact
    // list handed to the model when its action changed nothing on screen.
    private func match(_ title: String, _ role: String) -> AXElementResolver.Match {
        AXElementResolver.Match(center: .zero, role: role, title: title, score: 0)
    }

    @Test func interactableSummaryFormatsLabelAndShortRole() {
        let summary = AXElementResolver.interactableSummary([
            match("Save", "AXButton"), match("Bold", "AXCheckBox"),
        ])
        #expect(summary == "“Save” (button), “Bold” (checkbox)")
    }

    @Test func interactableSummaryIsNilWhenEmpty() {
        // Canvas/Electron apps expose no AX controls — caller must degrade to a
        // plain nudge, so an empty harvest yields nil, not "".
        #expect(AXElementResolver.interactableSummary([]) == nil)
    }

    @Test func interactableSummaryRespectsLimit() {
        let many = (0..<10).map { match("Item \($0)", "AXButton") }
        let summary = AXElementResolver.interactableSummary(many, limit: 3)
        #expect(summary?.components(separatedBy: ", ").count == 3)
    }
}
