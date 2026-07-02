import ApplicationServices
import CascadeMemory
import Foundation
import MacContextKit
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

    @Test func decodeAXPointAcceptsOnlyAXPointValues() {
        var point = CGPoint(x: 12.5, y: -4.25)
        let value = AXValueCreate(.cgPoint, &point)

        #expect(AXElementResolver.decodeAXPoint(value) == point)
        #expect(AXElementResolver.decodeAXPoint("not an AXValue" as CFString) == nil)
        #expect(AXElementResolver.decodeAXPoint(NSNumber(value: 7)) == nil)
    }

    @Test func decodeAXSizeAcceptsOnlyAXSizeValues() {
        var size = CGSize(width: 640.5, height: 480.25)
        let value = AXValueCreate(.cgSize, &size)

        #expect(AXElementResolver.decodeAXSize(value) == size)
        #expect(AXElementResolver.decodeAXSize("not an AXValue" as CFString) == nil)
        #expect(AXElementResolver.decodeAXSize(NSNumber(value: 7)) == nil)
    }

    @Test func axErrorsMapToGroundingTaxonomy() {
        #expect(AXElementResolver.errorKind(for: AXError.cannotComplete) == .timeout)
        #expect(AXElementResolver.errorKind(for: AXError.attributeUnsupported) == .unsupportedAttribute)
        #expect(AXElementResolver.errorKind(for: AXError.actionUnsupported) == .unsupportedAttribute)
        #expect(AXElementResolver.errorKind(for: AXError.invalidUIElement) == .staleNode)
        #expect(AXElementResolver.errorKind(for: AXError.apiDisabled) == .permissionDenied)
    }

    @Test func axReadErrorsMapToGroundingTaxonomy() {
        #expect(AXElementResolver.errorKind(for: AXReadError.copyFailed(attribute: "AXChildren", error: .cannotComplete)) == .timeout)
        #expect(AXElementResolver.errorKind(for: AXReadError.missingValue(attribute: "AXTitle")) == .unsupportedAttribute)
        #expect(AXElementResolver.errorKind(for: AXReadError.typeMismatch(attribute: "AXRole", expected: "String", actual: "Number")) == .unsupportedAttribute)
        #expect(AXElementResolver.errorKind(for: AXReadError.invalidFrame(attribute: "AXFrame", rect: .zero)) == .staleNode)
        #expect(AXElementResolver.errorKind(for: AXReadError.copyFailed(attribute: "AXWindows", error: .apiDisabled)) == .permissionDenied)
    }

    @Test func axErrorSummaryAuditDetailUsesOnlyCounts() {
        var summary = AXElementResolver.AXErrorSummary()
        summary.record(.timeout)
        summary.record(.unsupportedAttribute)
        summary.record(.unsupportedAttribute)
        summary.record(.staleNode)
        summary.record(.permissionDenied)

        #expect(summary.totalCount == 5)
        #expect(summary.safeAuditDetail == "axTimeouts=1 axUnsupportedAttrs=2 axStaleNodes=1 axPermissionDenied=1")
    }

    // MARK: - B1 ranked locator: rank(recorded:candidate:)

    private func desc(_ label: String, role: String? = nil, id: String? = nil, container: String? = nil) -> AXElementResolver.Descriptor {
        AXElementResolver.Descriptor(label: label, role: role, identifier: id, container: container)
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

    // MARK: - B2 structural heal: container disambiguates identical labels

    @Test func containerDisambiguatesIdenticalLabelAndRole() {
        // Two identical "OK" buttons; the recorded one lived in the "Export" sheet.
        // Same label + same role tie; the container breaks it toward the right sheet.
        let recorded = desc("OK", role: "AXButton", container: "AXSheet: Export")
        let inExport = AXElementResolver.rank(recorded: recorded,
            candidate: desc("OK", role: "AXButton", container: "AXSheet: Export"))
        let inOther = AXElementResolver.rank(recorded: recorded,
            candidate: desc("OK", role: "AXButton", container: "AXSheet: Print"))
        #expect(inExport > inOther)
    }

    @Test func containerComparesAfterNormalization() {
        // Recorder and replay may format casing/whitespace slightly differently;
        // normalization must bridge them so the container still matches.
        let score = AXElementResolver.rank(
            recorded: desc("OK", role: "AXButton", container: "AXSheet: Export"),
            candidate: desc("OK", role: "AXButton", container: "axsheet:  export "))
        #expect(score == 3 + 0.25 + 0.1) // exact label + same role + same container
    }

    @Test func containerIsASubTiebreakUnderRole() {
        // Container (±0.1) must not outweigh role (±0.25): a same-ROLE candidate in the
        // wrong container still beats a different-role candidate in the right container.
        let recorded = desc("Item", role: "AXButton", container: "AXGroup: A")
        let rightRoleWrongContainer = AXElementResolver.rank(recorded: recorded,
            candidate: desc("Item", role: "AXButton", container: "AXGroup: B"))   // 3 +0.25 -0.1 = 3.15
        let wrongRoleRightContainer = AXElementResolver.rank(recorded: recorded,
            candidate: desc("Item", role: "AXMenuItem", container: "AXGroup: A")) // 3 -0.25 +0.1 = 2.85
        #expect(rightRoleWrongContainer > wrongRoleRightContainer)
    }

    @Test func containerFormatterIsNilWhenEmpty() {
        #expect(AXTargetDescriptor.container(role: "  ", title: "") == nil)
        #expect(AXTargetDescriptor.container(role: "AXRow", title: "Overdue") == "AXRow: Overdue")
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

    @Test func interactableSummaryReusesDescriptorHintsWhenPresent() {
        let summary = AXElementResolver.interactableSummary([
            AXElementResolver.Match(
                center: .zero,
                role: "AXGroup",
                title: "Stale",
                score: 0,
	                descriptor: AXTargetDescriptorV2(
	                    label: "Approve",
	                    role: "AXButton",
	                    identifier: "expense.approve",
	                    container: "AXRow: Q2 Expense",
	                    siblingIndex: 8,
	                    siblingRoleIndex: 3,
	                    frameBucket: "1,2,3,4",
	                    enabled: false,
	                    selected: true,
	                    focused: true,
                        createdFrom: "fixture"
	                )
	            )
	        ])
        #expect(summary == "“Approve” (button; id expense.approve; in AXRow: Q2 Expense; disabled; selected; focused; roleSibling 3; frame 1,2,3,4; source fixture)")
    }

    @Test func interactableSummaryIncludesRicherActionableNodeHints() {
        let node = AXElementResolver.ActionableNode(
            stableID: "ax:close",
            role: "AXButton",
            subrole: "AXCloseButton",
            identifier: "window.close",
            title: "Close",
            axDescription: "Close the private document",
            value: "private document title",
            supportedActions: ["AXShowMenu", "AXPress"],
            enabled: true,
            focused: false,
            selected: false
        )
        let summary = AXElementResolver.interactableSummary([
            AXElementResolver.Match(
                id: node.stableID,
                center: .zero,
                role: "AXButton",
                title: "Close",
                score: 1,
                descriptor: AXTargetDescriptorV2(label: "Close", role: "AXButton"),
                actionableNode: node
            )
        ])

        #expect(summary == "“Close” (button; id window.close; subrole AXCloseButton; actions press/showmenu)")
        #expect(summary?.contains("private document") == false)
    }

    @Test func stableNodeIDPrefersIdentifierOverMovingFrame() {
        let before = AXTargetDescriptorV2(
            label: "Send",
            role: "AXButton",
            identifier: "compose.send",
            frame: "10,20,90,32",
            pathHash: "path-a"
        )
        let after = AXTargetDescriptorV2(
            label: "Send Now",
            role: "AXButton",
            identifier: "compose.send",
            frame: "500,600,90,32",
            pathHash: "path-b"
        )

        #expect(AXElementResolver.stableNodeID(descriptor: before) == AXElementResolver.stableNodeID(descriptor: after))
    }

    @Test func stableNodeIDUsesStructuralHashWithoutIdentifier() {
        let first = AXTargetDescriptorV2(label: "OK", role: "AXButton", pathHash: "same-path")
        let second = AXTargetDescriptorV2(label: "OK", role: "AXButton", pathHash: "same-path")
        let moved = AXTargetDescriptorV2(label: "OK", role: "AXButton", pathHash: "other-path")

        #expect(AXElementResolver.stableNodeID(descriptor: first) == AXElementResolver.stableNodeID(descriptor: second))
        #expect(AXElementResolver.stableNodeID(descriptor: first) != AXElementResolver.stableNodeID(descriptor: moved))
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

    @Test func runtimeProfileSparseThresholds() {
        let sparse = AXRuntimeProfile(
            bundleIdentifier: "com.example.Canvas",
            appName: "Canvas",
            sampledNodeCount: 8,
            actionableRoleCount: 1,
            labeledActionableCount: 0,
            identifierCount: 0,
            frameFailureCount: 0,
            timeoutOrErrorCount: 0,
            canvasSizedElementRatio: 0
        )
        let rich = AXRuntimeProfile(
            bundleIdentifier: "com.example.Native",
            appName: "Native",
            sampledNodeCount: 80,
            actionableRoleCount: 20,
            labeledActionableCount: 15,
            identifierCount: 6,
            frameFailureCount: 1,
            timeoutOrErrorCount: 0,
            canvasSizedElementRatio: 0.05
        )

        #expect(sparse.isSparse)
        #expect(sparse.shouldRetryManualAccessibility)
        #expect(!rich.isSparse)
        #expect(!rich.shouldRetryManualAccessibility)
    }

    @Test func runtimeProfileAuditDetailIsSanitized() {
        let profile = AXRuntimeProfile(
            bundleIdentifier: "com.secret.App",
            appName: "Secret App",
            sampledNodeCount: 20,
            actionableRoleCount: 2,
            labeledActionableCount: 1,
            identifierCount: 0,
            frameFailureCount: 9,
            timeoutOrErrorCount: 0,
            axErrorSummary: AXElementResolver.AXErrorSummary(
                timeoutCount: 1,
                unsupportedAttributeCount: 2,
                staleNodeCount: 3,
                permissionDeniedCount: 4
            ),
            canvasSizedElementRatio: 0.50,
            manualAccessibilityAttempted: true
        )

        #expect(profile.safeAuditDetail.contains("sparse=true"))
        #expect(profile.safeAuditDetail.contains("manualAccessibility=true"))
        #expect(profile.safeAuditDetail.contains("axTimeouts=1"))
        #expect(profile.safeAuditDetail.contains("axUnsupportedAttrs=2"))
        #expect(profile.safeAXErrorAuditDetail?.contains("axPermissionDenied=4") == true)
        #expect(!profile.safeAuditDetail.contains("Secret App"))
        #expect(!profile.safeAuditDetail.contains("com.secret.App"))
        #expect(profile.safeAXErrorAuditDetail?.contains("Secret App") == false)
        #expect(profile.safeAXErrorAuditDetail?.contains("com.secret.App") == false)
    }
}
