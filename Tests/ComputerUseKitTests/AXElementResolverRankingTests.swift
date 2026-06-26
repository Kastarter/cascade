import CascadeMemory
import CoreGraphics
import Testing

@testable import ComputerUseKit

struct AXElementResolverRankingTests {
    @Test func v2JSONRoundTripsAndLegacyDescriptorBridges() throws {
        let descriptor = makeDescriptor(
            label: "Send",
            id: "compose.send",
            ancestors: ["AXWindow: Compose", "AXGroup: Footer"],
            sibling: 2,
            neighbors: ["Cancel", "Attach"],
            frame: "bottom-right",
            subtree: "send-button-v1",
            semantic: "send-action")

        let encoded = try #require(descriptor.encodedJSON())
        let decoded = try #require(AXTargetDescriptorV2.decode(encoded))
        #expect(decoded == descriptor)

        let legacy = AXTargetDescriptor.encode(role: "AXButton", identifier: "compose.send", container: "AXGroup: Footer")
        let bridged = try #require(AXTargetDescriptorV2.decode(legacy, fallbackLabel: "Send"))
        #expect(bridged.label == "Send")
        #expect(bridged.role == "AXButton")
        #expect(bridged.identifier == "compose.send")
        #expect(bridged.ancestorPath == ["AXGroup: Footer"])

        let tuple = AXTargetDescriptor.decode(encoded)
        #expect(tuple.role == "AXButton")
        #expect(tuple.identifier == "compose.send")
        #expect(tuple.container == "AXGroup: Footer")
    }

    @Test func movedFixtureKeepsIdentifierMatchFirst() {
        let recorded = makeDescriptor(
            label: "Send",
            id: "compose.send",
            frame: "bottom-right",
            subtree: "send-button-v1",
            semantic: "send-action")
        let candidates = [
            makeCandidate("same-id-moved", descriptor: makeDescriptor(
                label: "Send",
                id: "compose.send",
                frame: "top-right",
                subtree: "send-button-v1",
                semantic: "send-action")),
            makeCandidate("same-label-wrong-id", descriptor: makeDescriptor(
                label: "Send",
                id: "sidebar.send",
                ancestors: ["AXWindow: Sidebar"],
                sibling: 0,
                neighbors: ["Archive"],
                frame: "left",
                subtree: "sidebar-button",
                semantic: "send-action")),
            makeCandidate("archive", descriptor: makeDescriptor(
                label: "Archive",
                id: "archive",
                ancestors: ["AXWindow: Sidebar"],
                sibling: 7,
                neighbors: ["Delete"],
                frame: "left",
                subtree: "archive-button",
                semantic: "archive-message")),
        ]

        let ranked = AXElementResolver.rank(recorded: recorded, candidates: candidates)
        #expect(ranked.map { $0.candidate.id } == ["same-id-moved", "same-label-wrong-id", "archive"])
        #expect(ranked[0].confidence > 0.90)
        #expect(AXElementResolver.find(recorded: recorded, candidates: candidates)?.candidate.id == "same-id-moved")
    }

    @Test func renamedFixturePrefersStableIdentifierOverOldLabel() {
        let recorded = makeDescriptor(
            label: "Send",
            id: "compose.send",
            subtree: "send-button-v1",
            semantic: "send-action")
        let candidates = [
            makeCandidate("renamed-submit", descriptor: makeDescriptor(
                label: "Submit",
                id: "compose.send",
                subtree: "send-button-v1",
                semantic: "send-action")),
            makeCandidate("old-label-lookalike", descriptor: makeDescriptor(
                label: "Send",
                id: "other.send",
                subtree: "send-button-v1",
                semantic: "send-action")),
        ]

        let ranked = AXElementResolver.rank(recorded: recorded, candidates: candidates)
        #expect(ranked.map { $0.candidate.id } == ["renamed-submit", "old-label-lookalike"])
        #expect(ranked[0].confidence > 0.80)
    }

    @Test func duplicateLabelFixtureUsesStructureToPickCorrectRow() {
        let recorded = makeDescriptor(
            label: "Open",
            id: nil,
            ancestors: ["AXWindow: Files", "AXTable: Documents", "AXRow: Q2 Plan"],
            sibling: 1,
            neighbors: ["Q2 Plan", "Modified Today"],
            frame: "row-1",
            subtree: "open-q2")
        let candidates = [
            makeCandidate("wrong-q1-row", descriptor: makeDescriptor(
                label: "Open",
                id: nil,
                ancestors: ["AXWindow: Files", "AXTable: Documents", "AXRow: Q1 Plan"],
                sibling: 0,
                neighbors: ["Q1 Plan", "Modified Yesterday"],
                frame: "row-0",
                subtree: "open-q1")),
            makeCandidate("correct-q2-row", descriptor: makeDescriptor(
                label: "Open",
                id: nil,
                ancestors: ["AXWindow: Files", "AXTable: Documents", "AXRow: Q2 Plan"],
                sibling: 1,
                neighbors: ["Q2 Plan", "Modified Today"],
                frame: "row-1",
                subtree: "open-q2")),
            makeCandidate("wrong-toolbar", descriptor: makeDescriptor(
                label: "Open",
                id: nil,
                ancestors: ["AXWindow: Files", "AXToolbar: Main"],
                sibling: 3,
                neighbors: ["Share"],
                frame: "toolbar",
                subtree: "open-toolbar")),
        ]

        let ranked = AXElementResolver.rank(recorded: recorded, candidates: candidates)
        #expect(ranked.map { $0.candidate.id } == ["correct-q2-row", "wrong-q1-row", "wrong-toolbar"])
        #expect(ranked[0].confidence > 0.95)
        #expect(ranked[1].confidence < 0.55)
    }

    @Test func reorderedRowFixtureDoesNotOverTrustSiblingIndex() {
        let recorded = makeDescriptor(
            label: "Approve",
            id: nil,
            ancestors: ["AXWindow: Inbox", "AXTable: Requests", "AXRow: Expense 4821"],
            sibling: 4,
            neighbors: ["Maya Chen", "$42.10"],
            frame: "row-4",
            subtree: "approve-expense-4821",
            semantic: "approve-expense")
        let candidates = [
            makeCandidate("same-index-wrong-row", descriptor: makeDescriptor(
                label: "Approve",
                id: nil,
                ancestors: ["AXWindow: Inbox", "AXTable: Requests", "AXRow: Expense 1099"],
                sibling: 4,
                neighbors: ["Nora Ali", "$71.00"],
                frame: "row-4",
                subtree: "approve-expense-1099",
                semantic: "approve-expense")),
            makeCandidate("same-row-reordered", descriptor: makeDescriptor(
                label: "Approve",
                id: nil,
                ancestors: ["AXWindow: Inbox", "AXTable: Requests", "AXRow: Expense 4821"],
                sibling: 1,
                neighbors: ["Maya Chen", "$42.10"],
                frame: "row-1",
                subtree: "approve-expense-4821",
                semantic: "approve-expense")),
        ]

        let ranked = AXElementResolver.rank(recorded: recorded, candidates: candidates)
        #expect(ranked.map { $0.candidate.id } == ["same-row-reordered", "same-index-wrong-row"])
        #expect(ranked[0].confidence > 0.80)
    }

    @Test func identifierRemovedFixtureStillPassesStructuralThreshold() {
        let recorded = makeDescriptor(
            label: "Archive",
            id: "message.archive",
            subtree: "archive-button-v1",
            semantic: "archive-message")
        let candidates = [
            makeCandidate("id-removed", descriptor: makeDescriptor(
                label: "Archive",
                id: nil,
                subtree: "archive-button-v1",
                semantic: "archive-message")),
            makeCandidate("same-label-other-panel", descriptor: makeDescriptor(
                label: "Archive",
                id: nil,
                ancestors: ["AXWindow: Mail", "AXGroup: Sidebar"],
                sibling: 0,
                neighbors: ["Trash"],
                frame: "left",
                subtree: "archive-folder",
                semantic: "archive-folder")),
        ]

        let ranked = AXElementResolver.rank(recorded: recorded, candidates: candidates)
        #expect(ranked.map { $0.candidate.id } == ["id-removed", "same-label-other-panel"])
        #expect(ranked[0].confidence > 0.70)
        #expect(AXElementResolver.find(recorded: recorded, candidates: candidates, minimumConfidence: 0.70)?.candidate.id == "id-removed")
    }

    @Test func localizedLabelFixtureUsesSemanticHashWhenTextChanges() {
        let recorded = makeDescriptor(
            label: "Send",
            id: nil,
            subtree: "send-button-v1",
            semantic: "send-action")
        let candidates = [
            makeCandidate("localized-spanish", descriptor: makeDescriptor(
                label: "Enviar",
                id: nil,
                subtree: "send-button-v1",
                semantic: "send-action")),
            makeCandidate("english-lookalike", descriptor: makeDescriptor(
                label: "Send",
                id: nil,
                ancestors: ["AXWindow: Compose", "AXGroup: Sidebar"],
                neighbors: ["Share"],
                frame: "left",
                subtree: "send-sidebar",
                semantic: "share-action")),
        ]

        let ranked = AXElementResolver.rank(recorded: recorded, candidates: candidates)
        #expect(ranked.map { $0.candidate.id } == ["localized-spanish", "english-lookalike"])
        #expect(ranked[0].confidence > 0.75)
    }

    private func makeCandidate(
        _ id: String,
        descriptor: AXTargetDescriptorV2,
        center: CGPoint? = nil
    ) -> AXElementResolver.Candidate {
        AXElementResolver.Candidate(id: id, descriptor: descriptor, center: center)
    }

    private func makeDescriptor(
        label: String,
        role: String? = "AXButton",
        id: String? = nil,
        ancestors: [String] = ["AXWindow: Compose", "AXGroup: Footer"],
        sibling: Int? = 2,
        neighbors: [String] = ["Cancel", "Attach"],
        frame: String? = "bottom-right",
        subtree: String? = nil,
        semantic: String? = nil
    ) -> AXTargetDescriptorV2 {
        AXTargetDescriptorV2(
            label: label,
            role: role,
            identifier: id,
            container: ancestors.last,
            ancestorPath: ancestors,
            siblingIndex: sibling,
            neighborLabels: neighbors,
            frameBucket: frame,
            subtreeHash: subtree,
            semanticHash: semantic)
    }
}
