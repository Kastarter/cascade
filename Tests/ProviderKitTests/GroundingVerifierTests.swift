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
