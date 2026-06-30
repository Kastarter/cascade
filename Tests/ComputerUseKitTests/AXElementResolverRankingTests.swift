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
	            semantic: "send-action",
                windowTitle: "Compose",
                visualPatchHash: "patch-v1",
                createdFrom: "input_recorder")

	        let encoded = try #require(descriptor.encodedJSON())
	        let decoded = try #require(AXTargetDescriptorV2.decode(encoded))
	        #expect(decoded == descriptor)
            #expect(decoded.windowTitle == "Compose")
            #expect(decoded.siblingRoleIndex == 2)
            #expect(decoded.visualPatchHash == "patch-v1")
            #expect(decoded.semanticTextHash == "send-action")
            #expect(decoded.createdFrom == "input_recorder")

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

    @Test func legacyJSONAliasesSiblingAndSemanticFields() throws {
        let legacyJSON = #"{"label":"Send","role":"AXButton","siblingIndex":4,"semanticHash":"legacy-semantic"}"#
        let decoded = try #require(AXTargetDescriptorV2.decode(legacyJSON))

        #expect(decoded.siblingIndex == 4)
        #expect(decoded.siblingRoleIndex == 4)
        #expect(decoded.semanticTextHash == "legacy-semantic")
        #expect(decoded.semanticHash == "legacy-semantic")
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
	        #expect(ranked[0].confidence >= 0.89)
            #expect(ranked[0].components.identifier == 1)
            #expect(ranked[0].components.frameProximity == 0)
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
        #expect(ranked[0].confidence >= 0.79)
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
        #expect(ranked[1].confidence < AXElementResolver.defaultMinimumConfidence)
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
	        #expect(ranked[0].confidence >= AXElementResolver.rerankMinimumConfidence)
            #expect(ranked[0].confidence < AXElementResolver.automaticHealMinimumConfidence)
	        #expect(AXElementResolver.find(recorded: recorded, candidates: candidates, minimumConfidence: 0.55)?.candidate.id == "id-removed")
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
	        #expect(ranked[0].confidence > 0.60)
	    }

    @Test func localizedLabelWithSameIdentifierStaysAutomatic() {
        let recorded = makeDescriptor(
            label: "Send",
            id: "compose.send",
            subtree: "send-button-v1",
            semantic: "send-action")
        let candidates = [
            makeCandidate("localized-same-id", descriptor: makeDescriptor(
                label: "Enviar",
                id: "compose.send",
                subtree: "send-button-v1",
                semantic: "send-action")),
            makeCandidate("english-wrong-id", descriptor: makeDescriptor(
                label: "Send",
                id: "sidebar.send",
                ancestors: ["AXWindow: Compose", "AXGroup: Sidebar"],
                neighbors: ["Share"],
                frame: "left",
                subtree: "send-sidebar",
                semantic: "share-action")),
        ]

        let ranked = AXElementResolver.rank(recorded: recorded, candidates: candidates)
        #expect(ranked.map { $0.candidate.id } == ["localized-same-id", "english-wrong-id"])
        #expect(ranked[0].confidence >= AXElementResolver.automaticHealMinimumConfidence)
    }

    @Test func parentContainerTitleChangeKeepsTargetAheadOfLookalike() {
        let recorded = makeDescriptor(
            label: "Export",
            id: nil,
            ancestors: ["AXWindow: Keynote", "AXGroup: Share", "AXGroup: Export"],
            neighbors: ["PDF", "Movie"],
            frame: "toolbar-right",
            subtree: "export-button",
            semantic: "export-document")
        let candidates = [
            makeCandidate("retitled-parent", descriptor: makeDescriptor(
                label: "Export",
                id: nil,
                ancestors: ["AXWindow: Keynote", "AXGroup: Send", "AXGroup: Export"],
                neighbors: ["PDF", "Movie"],
                frame: "toolbar-right",
                subtree: "export-button",
                semantic: "export-document")),
            makeCandidate("format-sidebar", descriptor: makeDescriptor(
                label: "Export",
                id: nil,
                ancestors: ["AXWindow: Keynote", "AXGroup: Format", "AXGroup: Export"],
                neighbors: ["Theme"],
                frame: "sidebar",
                subtree: "export-style",
                semantic: "style-export")),
        ]

        let ranked = AXElementResolver.rank(recorded: recorded, candidates: candidates)
        #expect(ranked.map { $0.candidate.id } == ["retitled-parent", "format-sidebar"])
        #expect(ranked[0].confidence >= AXElementResolver.automaticHealMinimumConfidence)
    }

    @Test func visualOnlyCanvasTargetCanRankByPatchAndGeometry() {
        let recorded = makeDescriptor(
            label: "",
            role: "AXImage",
            id: nil,
            ancestors: ["AXWindow: Design", "AXCanvas: Toolbar"],
            neighbors: [],
            frame: "20,4,3,2",
            subtree: nil,
            visualPatchHash: "canvas-export-icon",
            createdFrom: "visual")
        let candidates = [
            makeCandidate("visual-patch", descriptor: makeDescriptor(
                label: "",
                role: "AXImage",
                id: nil,
                ancestors: ["AXWindow: Design", "AXCanvas: Toolbar"],
                neighbors: [],
                frame: "20,4,3,2",
                subtree: nil,
                visualPatchHash: "canvas-export-icon",
                createdFrom: "visual")),
            makeCandidate("other-canvas-region", descriptor: makeDescriptor(
                label: "",
                role: "AXImage",
                id: nil,
                ancestors: ["AXWindow: Design", "AXCanvas: Sidebar"],
                neighbors: [],
                frame: "4,4,3,2",
                subtree: nil,
                visualPatchHash: "canvas-help-icon",
                createdFrom: "visual")),
        ]

        let ranked = AXElementResolver.rank(recorded: recorded, candidates: candidates)
        #expect(ranked.map { $0.candidate.id } == ["visual-patch", "other-canvas-region"])
        #expect(ranked[0].confidence >= AXElementResolver.automaticHealMinimumConfidence)
    }

    @Test func semanticSimilarityClosureCanBridgePhraseChangesDeterministically() {
        let recorded = makeDescriptor(
            label: "Send",
            id: nil,
            ancestors: ["AXWindow: Compose"],
            neighbors: ["Cancel"],
            subtree: "send-button-v1",
            semantic: "send-action",
            windowTitle: "Compose")
        let candidates = [
            makeCandidate("semantic", descriptor: makeDescriptor(
                label: "Enviar",
                id: nil,
                ancestors: ["AXWindow: Compose"],
                neighbors: ["Cancel"],
                subtree: "send-button-v1",
                semantic: "translated-send-action",
                windowTitle: "Redactar")),
            makeCandidate("literal", descriptor: makeDescriptor(
                label: "Send",
                id: nil,
                ancestors: ["AXWindow: Sidebar"],
                neighbors: ["Share"],
                subtree: nil,
                semantic: "share-action")),
        ]

        let ranked = AXElementResolver.rank(recorded: recorded, candidates: candidates) { recordedPhrase, candidatePhrase in
            candidatePhrase.contains("Enviar") ? 0.95 : 0.10
        }

        #expect(ranked.first?.candidate.id == "semantic")
        #expect(ranked.first?.components.semanticText == 0.95)
    }

    @Test func candidateRetainsFrameSourceAndScoreMetadata() {
        let recorded = makeDescriptor(label: "Save", id: "save")
        let frame = CGRect(x: 10, y: 20, width: 80, height: 30)
        let candidate = makeCandidate(
            "save",
            descriptor: makeDescriptor(label: "Save", id: "save"),
            center: CGPoint(x: 50, y: 35),
            frame: frame,
            source: .synthetic)

        let ranked = AXElementResolver.rank(recorded: recorded, candidates: [candidate], near: CGPoint(x: 50, y: 35))
        #expect(ranked[0].candidate.frame == frame)
        #expect(ranked[0].candidate.source == .synthetic)
        #expect(ranked[0].candidate.totalScore == ranked[0].score)
        #expect(ranked[0].candidate.confidence == ranked[0].confidence)
        #expect(ranked[0].components.availableWeight > 0)
    }

    @Test func v2OptionalStateFieldsRoundTrip() throws {
        let descriptor = AXTargetDescriptorV2(
            label: "Save",
            role: "AXButton",
            identifier: "save",
            frameBucket: "1,2,3,4",
            frame: "8,16,24,32",
            valueHash: "value-hash",
            enabled: true,
            selected: false,
            focused: true,
            pathHash: "path-hash",
            subtree: "nodes=3",
            subtreeHash: "subtree-hash"
        )

        let decoded = try #require(AXTargetDescriptorV2.decode(descriptor.encodedJSON()))
        #expect(decoded.valueHash == "value-hash")
        #expect(decoded.enabled == true)
        #expect(decoded.selected == false)
        #expect(decoded.focused == true)
        #expect(decoded.pathHash == "path-hash")
        #expect(decoded.frame == "8,16,24,32")
        #expect(decoded.subtree == "nodes=3")
    }

	    @Test func defaultScoreCapRejectsBelowThresholdCandidates() {
	        let recorded = AXTargetDescriptorV2(
	            label: "Submit",
	            role: "AXButton",
	            identifier: "primary.submit",
            frameBucket: "1,1,4,2"
        )
        let weak = makeCandidate("weak", descriptor: AXTargetDescriptorV2(
            label: "Submit",
            role: "AXButton"
        ))

	        #expect(AXElementResolver.find(recorded: recorded, candidates: [weak]) == nil)
	        #expect(AXElementResolver.find(recorded: recorded, candidates: [weak], minimumConfidence: 0.40)?.candidate.id == "weak")
	    }

    @Test func closeTopCandidateStaysBelowAutomaticThreshold() {
        let recorded = makeDescriptor(
            label: "Continue",
            id: nil,
            ancestors: ["AXWindow: Checkout", "AXGroup: Billing"],
            neighbors: ["Back"],
            subtree: nil,
            semantic: nil)
        let candidates = [
            makeCandidate("billing", descriptor: makeDescriptor(
                label: "Continue",
                id: nil,
                ancestors: ["AXWindow: Checkout", "AXGroup: Billing"],
                neighbors: ["Back"],
                subtree: nil,
                semantic: nil)),
            makeCandidate("help", descriptor: makeDescriptor(
                label: "Continue",
                id: nil,
                ancestors: ["AXWindow: Checkout", "AXGroup: Billing"],
                neighbors: ["Back"],
                subtree: nil,
                semantic: nil)),
        ]

        let ranked = AXElementResolver.rank(recorded: recorded, candidates: candidates)
        #expect(ranked[0].confidence >= AXElementResolver.automaticHealMinimumConfidence)
        #expect((ranked[0].confidence - ranked[1].confidence) <= 0.04)
    }

    @Test func syntheticMutationHarnessRanksMovedIdentifierRemovedAnchorAboveDuplicate() throws {
        let original = AXSyntheticNode(
            id: "send",
            label: "Send",
            identifier: "compose.send",
            frame: CGRect(x: 400, y: 500, width: 90, height: 32)
        )
        let recorded = try #require(original.candidates(ancestorPath: ["AXWindow: Compose"]).first?.descriptor)
        let movedWithoutIdentifier = AXSyntheticMutationHarness.move(
            AXSyntheticMutationHarness.removeIdentifier(original),
            by: CGVector(dx: 120, dy: -40)
        )
        let duplicate = AXSyntheticNode(
            id: "duplicate",
            label: "Send",
            identifier: nil,
            frame: CGRect(x: 40, y: 80, width: 90, height: 32)
        )

        let ranked = AXElementResolver.rank(
            recorded: recorded,
            candidates: movedWithoutIdentifier.candidates(ancestorPath: ["AXWindow: Compose"])
                + duplicate.candidates(ancestorPath: ["AXWindow: Sidebar"]),
            near: CGPoint(x: 445, y: 516)
        )

        #expect(ranked.first?.candidate.id == "send")
        #expect((ranked.first?.confidence ?? 0) >= AXElementResolver.rerankMinimumConfidence)
        #expect(ranked.first?.components.frameProximity ?? 0 > 0)
    }

	    private func makeCandidate(
	        _ id: String,
	        descriptor: AXTargetDescriptorV2,
	        center: CGPoint? = nil,
            frame: CGRect? = nil,
            source: AXElementResolver.CandidateSource = .unknown
	    ) -> AXElementResolver.Candidate {
	        AXElementResolver.Candidate(id: id, descriptor: descriptor, center: center, frame: frame, source: source)
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
	        semantic: String? = nil,
            windowTitle: String? = nil,
            visualPatchHash: String? = nil,
            createdFrom: String? = nil
	    ) -> AXTargetDescriptorV2 {
	        AXTargetDescriptorV2(
	            label: label,
	            role: role,
	            identifier: id,
	            container: ancestors.last,
                windowTitle: windowTitle,
	            ancestorPath: ancestors,
	            siblingIndex: sibling,
                siblingRoleIndex: sibling,
	            neighborLabels: neighbors,
	            frameBucket: frame,
                visualPatchHash: visualPatchHash,
	            subtreeHash: subtree,
	            semanticTextHash: semantic,
                semanticHash: semantic,
                createdFrom: createdFrom)
	    }
}
