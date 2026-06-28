import CoreGraphics
import Foundation
import ProviderKit
import Testing

struct GroundingVerifierTests {
    @Test func highEvidenceCandidateAccepts() {
        let result = verifier.verify(
            [
                evidence(
                    id: "send",
                    point: CGPoint(x: 420, y: 320),
                    confidence: 0.92,
                    role: "AXButton",
                    label: "Send",
                    nearbyOCRText: "Send",
                    ocrDistancePoints: 5,
                    agreeingSources: [.accessibility, .ocr]
                )
            ],
            context: context(target: "the Send button")
        )

        #expect(result.verdict == .accept)
        #expect(result.selectedCandidateID == "send")
        #expect(result.confidence >= 0.9)
        #expect(result.failureKind == nil)
    }

    @Test func offscreenAndPassiveCandidatesReject() {
        let offscreen = verifier.verify(
            [
                evidence(
                    id: "offscreen-send",
                    point: CGPoint(x: 1400, y: 320),
                    confidence: 0.95,
                    role: "AXButton",
                    label: "Send",
                    nearbyOCRText: "Send",
                    ocrDistancePoints: 4,
                    agreeingSources: [.accessibility, .ocr]
                )
            ],
            context: context(target: "Send")
        )
        #expect(offscreen.verdict == .reject)
        #expect(offscreen.failureKind == .offscreen)
        #expect(offscreen.selectedCandidateID == nil)

        let offscreenPointWithIntersectingRegion = verifier.verify(
            [
                evidence(
                    id: "offscreen-point-region-send",
                    point: CGPoint(x: 1400, y: 320),
                    region: CGRect(x: 900, y: 300, width: 300, height: 60),
                    confidence: 0.95,
                    role: "AXButton",
                    label: "Send",
                    nearbyOCRText: "Send",
                    ocrDistancePoints: 4,
                    agreeingSources: [.accessibility, .ocr]
                )
            ],
            context: context(target: "Send")
        )
        #expect(offscreenPointWithIntersectingRegion.verdict == .reject)
        #expect(offscreenPointWithIntersectingRegion.failureKind == .offscreen)
        #expect(offscreenPointWithIntersectingRegion.selectedCandidateID == nil)

        let passive = verifier.verify(
            [
                evidence(
                    id: "passive-label",
                    point: CGPoint(x: 420, y: 320),
                    confidence: 0.99,
                    role: "AXStaticText",
                    label: "Send",
                    nearbyOCRText: "Send",
                    ocrDistancePoints: 4,
                    agreeingSources: [.accessibility, .ocr]
                )
            ],
            context: context(target: "Send")
        )
        #expect(passive.verdict == .reject)
        #expect(passive.failureKind == .passiveRole)
        #expect(passive.selectedCandidateID == nil)
    }

    @Test func closeAmbiguousCandidatesAbstain() {
        let result = verifier.verify(
            [
                evidence(
                    id: "a-send",
                    point: CGPoint(x: 420, y: 320),
                    confidence: 0.91,
                    role: "AXButton",
                    label: "Send",
                    nearbyOCRText: "Send",
                    ocrDistancePoints: 8,
                    agreeingSources: [.accessibility, .ocr]
                ),
                evidence(
                    id: "b-send",
                    point: CGPoint(x: 470, y: 320),
                    confidence: 0.91,
                    role: "AXButton",
                    label: "Send",
                    nearbyOCRText: "Send",
                    ocrDistancePoints: 8,
                    agreeingSources: [.accessibility, .ocr]
                ),
            ],
            context: context(target: "Send")
        )

        #expect(result.verdict == .abstain)
        #expect(result.failureKind == .ambiguous)
        #expect(result.selectedCandidateID == "a-send")
    }

    @Test func agreeingCandidatesAtSamePointAcceptNotAbstain() {
        // AX and the visual grounder both resolving the named control to the same
        // spot is corroboration, not ambiguity (regression pin: the verifier abstained
        // on every AX+visual hit at confidence 0.98, candidates=2, failure=ambiguous).
        let result = verifier.verify(
            [
                evidence(
                    id: "ax-new-doc",
                    point: CGPoint(x: 459, y: 481),
                    confidence: 0.95,
                    role: "AXButton",
                    label: "New Document",
                    nearbyOCRText: "New Document",
                    ocrDistancePoints: 4,
                    source: .accessibility,
                    agreeingSources: [.uiTars]
                ),
                GroundingVerifierCandidate(
                    id: "visual-new-doc",
                    candidate: GroundingCandidate(
                        point: CGPoint(x: 462, y: 483),
                        confidence: 1,
                        source: .uiTars,
                        coordinateSpace: .displayLocalAppKitPoints
                    )
                ),
            ],
            context: context(target: "New Document")
        )
        #expect(result.verdict == .accept)
        #expect(result.failureKind == nil)
        #expect(result.selectedCandidateID == "ax-new-doc")
    }

    @Test func randomizedCandidateOrderDoesNotChangeSelection() {
        let candidates = [
            evidence(
                id: "secondary-send",
                point: CGPoint(x: 480, y: 320),
                confidence: 0.62,
                role: "AXButton",
                label: "Send",
                nearbyOCRText: "Send",
                ocrDistancePoints: 18,
                agreeingSources: [.accessibility]
            ),
            evidence(
                id: "primary-send",
                point: CGPoint(x: 420, y: 320),
                confidence: 0.94,
                role: "AXButton",
                label: "Send",
                nearbyOCRText: "Send",
                ocrDistancePoints: 3,
                agreeingSources: [.accessibility, .ocr]
            ),
            evidence(
                id: "cancel",
                point: CGPoint(x: 520, y: 320),
                confidence: 0.91,
                role: "AXButton",
                label: "Cancel"
            ),
        ]
        let orders = [
            candidates,
            [candidates[2], candidates[0], candidates[1]],
            [candidates[1], candidates[2], candidates[0]],
        ]

        let selected = orders.map {
            verifier.verify($0, context: context(target: "the Send button")).selectedCandidateID
        }

        #expect(selected == ["primary-send", "primary-send", "primary-send"])
    }

    @Test func confidentVisualOnlyCandidateAccepts() {
        // UI-TARS returns a bare confident point with no role/label/OCR — the exact
        // case the visual grounder exists for. It must NOT floor-reject (regression
        // pin: the verifier shipped rejecting every visual ground at constant 0.42).
        let result = verifier.verify(
            [
                GroundingVerifierCandidate(
                    id: "visual",
                    candidate: GroundingCandidate(
                        point: CGPoint(x: 420, y: 320),
                        confidence: 1,
                        source: .compatibility,
                        coordinateSpace: .displayLocalAppKitPoints
                    )
                )
            ],
            context: context(target: "New Document")
        )
        #expect(result.verdict == .accept)
        #expect(result.selectedCandidateID == "visual")
    }

    @Test func metadataLessNonVisualCandidateStillRejects() {
        // An AX-sourced candidate with no role and no label/OCR is genuinely
        // low-evidence — the visual-trust path must not hand it a free pass.
        let result = verifier.verify(
            [
                GroundingVerifierCandidate(
                    id: "bare-ax",
                    candidate: GroundingCandidate(
                        point: CGPoint(x: 420, y: 320),
                        confidence: 1,
                        source: .accessibility,
                        coordinateSpace: .displayLocalAppKitPoints
                    )
                )
            ],
            context: context(target: "Send")
        )
        #expect(result.verdict == .reject)
        #expect(result.failureKind == .lowEvidence)
        #expect(result.selectedCandidateID == nil)
    }

    @Test func canvasCandidatesRejectUnlessExplicitlyAllowed() {
        let candidate = evidence(
            id: "canvas-hit",
            point: CGPoint(x: 420, y: 320),
            confidence: 0.97,
            role: "AXCanvas",
            label: "Send",
            nearbyOCRText: "Send",
            ocrDistancePoints: 4,
            agreeingSources: [.visualModel, .ocr]
        )

        let skipped = verifier.verify([candidate], context: context(target: "Send"))
        #expect(skipped.verdict == .reject)
        #expect(skipped.failureKind == .canvasSkipped)

        let allowed = verifier.verify(
            [candidate],
            context: context(target: "Send", allowCanvasCandidates: true)
        )
        #expect(allowed.verdict == .accept)
        #expect(allowed.selectedCandidateID == "canvas-hit")
    }
}

private let verifier = GroundingVerifier()

private func context(
    target: String,
    allowCanvasCandidates: Bool = false
) -> GroundingVerifierContext {
    GroundingVerifierContext(
        targetText: target,
        displayWidthPoints: 1000,
        displayHeightPoints: 700,
        allowCanvasCandidates: allowCanvasCandidates
    )
}

private func evidence(
    id: String,
    point: CGPoint,
    region: CGRect? = nil,
    confidence: Double,
    role: String? = nil,
    label: String? = nil,
    nearbyOCRText: String? = nil,
    ocrDistancePoints: Double? = nil,
    source: GroundingSource = .accessibility,
    agreeingSources: [GroundingSource] = []
) -> GroundingVerifierCandidate {
    GroundingVerifierCandidate(
        id: id,
        candidate: GroundingCandidate(
            point: point,
            region: region,
            confidence: confidence,
            source: source,
            coordinateSpace: .displayLocalAppKitPoints
        ),
        role: role,
        label: label,
        nearbyOCRText: nearbyOCRText,
        ocrDistancePoints: ocrDistancePoints,
        agreeingSources: agreeingSources
    )
}
