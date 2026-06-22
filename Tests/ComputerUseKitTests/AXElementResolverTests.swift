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
