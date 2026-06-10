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
}
