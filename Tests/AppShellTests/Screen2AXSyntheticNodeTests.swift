import CoreGraphics
import Foundation
import ProviderKit
import Testing

@testable import AppShell
@testable import ComputerUseKit

/// d17 (Screen2AX): visual-grounder output must leave the mixture as synthetic
/// AX-like nodes — `{source: vision, role, label, frame, confidence, actions}`
/// on the SAME structural fields native AX candidates populate — while native
/// AX keeps outranking synthetic in the d13 trust order. These pin the node
/// builder, the candidate/result enrichment, the flag gate (off = byte-
/// identical), the `vax:` id namespace isolation from d12 mark picking, and
/// the Match conversion that closes the structural-interface loop.
struct Screen2AXSyntheticNodeTests {
    // MARK: - Node synthesis

    @Test func barePointVisionCandidateBecomesAStructuralNode() throws {
        let bare = visionCandidate(point: CGPoint(x: 640, y: 400), confidence: 0.87)

        let node = try #require(Screen2AX.syntheticNode(
            from: bare,
            target: "the New Note button",
            displayWidthPoints: 1_440,
            displayHeightPoints: 900
        ))

        #expect(node.source == .vision)
        #expect(node.role == "AXButton")
        #expect(node.label == "the New Note button")
        #expect(node.confidence == 0.87)
        #expect(node.actions == ["AXPress"])
        #expect(node.stableID.hasPrefix("vax:"))
        // No region/displayBounds on the candidate → control-sized default
        // frame centered on the point, on screen.
        #expect(node.frame == CGRect(x: 592, y: 386, width: 96, height: 28))
    }

    @Test func roleAndActionsFollowTheTargetWords() {
        #expect(SyntheticAXNode.inferredRole(forTarget: "the search field") == "AXTextField")
        #expect(SyntheticAXNode.inferredRole(forTarget: "the Wi-Fi toggle") == "AXCheckBox")
        #expect(SyntheticAXNode.inferredRole(forTarget: "the View menu") == "AXMenuItem")
        #expect(SyntheticAXNode.inferredRole(forTarget: "the Privacy tab") == "AXTab")
        #expect(SyntheticAXNode.inferredRole(forTarget: "the volume slider") == "AXSlider")
        #expect(SyntheticAXNode.inferredRole(forTarget: "the Sign up link") == "AXLink")
        #expect(SyntheticAXNode.inferredRole(forTarget: "the blue rectangle") == "AXButton")

        #expect(SyntheticAXNode.actions(forRole: "AXTextField") == ["AXConfirm"])
        #expect(SyntheticAXNode.actions(forRole: "AXSlider") == ["AXIncrement", "AXDecrement"])
        #expect(SyntheticAXNode.actions(forRole: "AXButton") == ["AXPress"])
    }

    @Test func syntheticIdentityIsDeterministicAndJitterTolerant() {
        let frame = CGRect(x: 100, y: 200, width: 96, height: 28)
        let a = SyntheticAXNode(role: "AXButton", label: "Send", frame: frame, confidence: 0.9)
        // 4pt of jitter stays inside the 16pt identity bucket.
        let jittered = SyntheticAXNode(
            role: "AXButton", label: "Send",
            frame: frame.offsetBy(dx: 4, dy: 4), confidence: 0.7
        )
        let renamed = SyntheticAXNode(role: "AXButton", label: "Reply", frame: frame, confidence: 0.9)

        #expect(a.stableID == jittered.stableID)
        #expect(a.stableID != renamed.stableID)
    }

    @Test func syntheticIdsCanNeverBePickedAsNativeAXMarks() {
        let node = SyntheticAXNode(
            role: "AXButton", label: "Send",
            frame: CGRect(x: 100, y: 200, width: 96, height: 28), confidence: 0.9
        )
        // The d12 mark-token regex must refuse the vax: namespace outright —
        // a synthetic node must never resolve as a native AX Set-of-Marks pick.
        #expect(AXCompressedObservation.markToken(in: "[\(node.stableID)] the Send button") == nil)
        // Sanity: a real ax: id in the same sentence still parses.
        #expect(AXCompressedObservation.markToken(in: "[ax:0123abcd] the Send button") == "ax:0123abcd")
    }

    // MARK: - Result enrichment

    @Test func enrichmentFillsOnlyVisionCandidatesAndPreservesSelection() throws {
        let ax = axCandidate(id: "ax:sendbtn", point: CGPoint(x: 200, y: 300), label: "Send")
        let vision = visionCandidate(point: CGPoint(x: 600, y: 400), confidence: 0.83)
        let result = GroundingResult(
            candidates: [ax, vision],
            selectedIndex: 1,
            verifierVerdict: .accept
        )

        let enriched = Screen2AX.enriched(
            result, target: "the Send button", displayWidthPoints: 1_440, displayHeightPoints: 900
        )

        // Selection metadata and order carry over.
        #expect(enriched.selectedIndex == 1)
        #expect(enriched.verifierVerdict == .accept)
        #expect(enriched.candidates.count == 2)
        // The structural (AX) candidate is untouched.
        #expect(enriched.candidates[0] == ax)
        // The vision candidate gained the AX-shaped structural fields…
        let converted = try #require(enriched.candidates.last)
        #expect(converted.role == "AXButton")
        #expect(converted.label == "the Send button")
        #expect(converted.candidateID?.hasPrefix("vax:") == true)
        #expect(converted.region != nil)
        #expect(converted.displayBounds != nil)
        #expect(converted.reason?.contains("screen2ax") == true)
        // …while everything observed is untouched: provenance, confidence,
        // point — so the d13 trust order still ranks native AX above it.
        #expect(converted.source == .uiTars)
        #expect(converted.confidence == 0.83)
        #expect(converted.point == vision.point)
    }

    @Test func nonDisplayLocalOrPointlessCandidatesRefuseSynthesis() {
        // A UI-TARS parse miss: no point, screenshot-pixel space.
        let parseMiss = GroundingCandidate(
            point: nil,
            confidence: 0,
            source: .uiTars,
            coordinateSpace: .screenshotPixelsTopLeft,
            rawModel: "no box"
        )
        // Structural sources are never synthetic material.
        let ocr = GroundingCandidate(
            point: CGPoint(x: 100, y: 100),
            confidence: 0.8,
            source: .ocr,
            coordinateSpace: .displayLocalAppKitPoints,
            label: "Send"
        )
        for candidate in [parseMiss, ocr] {
            #expect(Screen2AX.syntheticNode(
                from: candidate, target: "Send", displayWidthPoints: 1_440, displayHeightPoints: 900
            ) == nil)
            #expect(Screen2AX.enrichedCandidate(
                candidate, target: "Send", displayWidthPoints: 1_440, displayHeightPoints: 900
            ) == candidate)
        }
    }

    @Test func flagOffIsByteIdentical() {
        let result = GroundingResult(
            candidates: [visionCandidate(point: CGPoint(x: 640, y: 400), confidence: 0.9)],
            selectedIndex: 0
        )

        let off = MixtureGrounder.synthesizedAXResult(
            result, target: "the Send button",
            displayWidthPoints: 1_440, displayHeightPoints: 900, enabled: false
        )
        let on = MixtureGrounder.synthesizedAXResult(
            result, target: "the Send button",
            displayWidthPoints: 1_440, displayHeightPoints: 900, enabled: true
        )

        #expect(off == result)
        #expect(on != result)
        #expect(on.selectedCandidate?.role == "AXButton")
        #expect(on.selectedPoint == result.selectedPoint)
    }

    // MARK: - Trust order

    @Test func enrichedVisionCandidateStillLosesToViableNativeAX() {
        let ax = GroundingVerifierCandidate(
            id: "ax:sendbtn",
            candidate: axCandidate(id: "ax:sendbtn", point: CGPoint(x: 200, y: 300), label: "Send"),
            role: "AXButton",
            label: "Send",
            nearbyOCRText: "Send",
            ocrDistancePoints: 0
        )
        let enrichedVision = Screen2AX.enrichedCandidate(
            visionCandidate(point: CGPoint(x: 600, y: 400), confidence: 0.97),
            target: "Send",
            displayWidthPoints: 1_000,
            displayHeightPoints: 700
        )

        let selection = MixtureGrounder.selectVerifiedCandidate(
            axCandidate: ax,
            baseResult: GroundingResult(candidates: [enrichedVision], selectedIndex: 0),
            target: "Send",
            displayWidthPoints: 1_000,
            displayHeightPoints: 700,
            trustOrderGateEnabled: true
        )

        #expect(selection.result.selectedCandidate?.source == .accessibility)
        #expect(selection.result.selectedPoint == CGPoint(x: 200, y: 300))
    }

    // MARK: - The shared structural interface (Match conversion)

    @Test func asMatchProducesACGGlobalStructuralMatch() throws {
        let node = SyntheticAXNode(
            role: "AXButton",
            label: "Send",
            frame: CGRect(x: 100, y: 200, width: 96, height: 28),
            confidence: 0.8
        )

        let match = try #require(node.asMatch(
            displayCGBounds: CGRect(x: 0, y: 0, width: 1_440, height: 900)
        ))

        // Display-local bottom-left frame → CG-global top-left Match geometry.
        #expect(match.center == CGPoint(x: 148, y: 686))
        #expect(match.frame == CGRect(x: 100, y: 672, width: 96, height: 28))
        #expect(match.role == "AXButton")
        #expect(match.title == "Send")
        // AX label-match scale (3 = exact): synthetic never exceeds native.
        #expect(abs(match.score - 2.4) < 0.0001)
        let actionable = try #require(match.actionableNode)
        #expect(actionable.stableID == node.stableID)
        #expect(actionable.supportedActions == ["AXPress"])
        #expect(node.asMatch(displayCGBounds: .zero) == nil)
    }

    // MARK: - Fixtures

    /// The shape UI-TARS returns for a successful ground: a confident point,
    /// no role/label/region/id.
    private func visionCandidate(point: CGPoint, confidence: Double) -> GroundingCandidate {
        GroundingCandidate(
            point: point,
            confidence: confidence,
            source: .uiTars,
            coordinateSpace: .displayLocalAppKitPoints,
            rawModel: "(x,y)",
            reason: "ui-tars coordinate"
        )
    }

    private func axCandidate(id: String, point: CGPoint, label: String) -> GroundingCandidate {
        GroundingCandidate(
            point: point,
            confidence: 0.95,
            source: .accessibility,
            coordinateSpace: .displayLocalAppKitPoints,
            rawModel: label,
            candidateID: id,
            displayBounds: CGRect(x: point.x - 48, y: point.y - 14, width: 96, height: 28),
            role: "AXButton",
            label: label,
            nearbyOCRText: label,
            ocrDistancePoints: 0
        )
    }
}
