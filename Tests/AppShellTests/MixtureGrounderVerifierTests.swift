import CoreGraphics
import Foundation
import ProviderKit
import Testing

@testable import AppShell

struct MixtureGrounderVerifierTests {
    @Test func verificationDisabledReturnsLegacySelectedPoint() async {
        let point = CGPoint(x: 320, y: 240)
        let grounder = MixtureGrounder(
            base: StubGrounder(point: point),
            skills: .init(),
            verifyCandidates: false
        )

        let selected = await grounder.ground(
            screenshot: Data(),
            target: "the canvas placeholder",
            displayWidthPoints: 1000,
            displayHeightPoints: 700
        )

        #expect(selected == point)
    }

    @Test func verificationEnabledUsesStructuredGroundingResult() async {
        let offscreen = CGPoint(x: 1200, y: 320)
        let baseResult = result([
            candidate(point: offscreen, rawModel: "Send")
        ])
        let grounder = MixtureGrounder(
            base: StubGrounder(result: baseResult),
            skills: .init(),
            verifyCandidates: true
        )

        let selected = await grounder.ground(
            screenshot: Data(),
            target: "Send",
            displayWidthPoints: 1000,
            displayHeightPoints: 700
        )
        let verified = await grounder.groundResult(
            screenshot: Data(),
            target: "Send",
            displayWidthPoints: 1000,
            displayHeightPoints: 700
        )

        #expect(selected == nil)
        #expect(verified.selectedPoint == nil)
        #expect(verified.selectedIndex == nil)
        #expect(verified.candidates.first?.point == offscreen)
        #expect(verified.candidates.first?.rawModel == "Send")
        #expect(
            MixtureGrounder.selectVerifiedCandidate(
                axCandidate: nil,
                baseResult: verified,
                target: "Send",
                displayWidthPoints: 1000,
                displayHeightPoints: 700
            ).outcome == .rejected(.offscreen)
        )
    }

    @Test func verifierAcceptedCandidateUsesSingleDefaultSample() async {
        let recorder = RecordingGrounder(results: [
            result([
                candidate(point: CGPoint(x: 320, y: 240), rawModel: "Quarterly Budget title", dispersion: 3)
            ])
        ])
        let grounder = MixtureGrounder(
            base: recorder,
            skills: .init(),
            verifyCandidates: true
        )

        let result = await grounder.groundResult(
            screenshot: Data(),
            target: "Quarterly Budget title",
            displayWidthPoints: 1000,
            displayHeightPoints: 700
        )

        #expect(result.selectedPoint == CGPoint(x: 320, y: 240))
        #expect(await recorder.sampleCounts() == [1])
    }

    @Test func verifierRejectRetriesWithThreeSamples() async {
        let recorder = RecordingGrounder(results: [
            result([
                candidate(point: CGPoint(x: 1200, y: 240), rawModel: "Quarterly Budget title", dispersion: 3)
            ]),
            result([
                candidate(point: CGPoint(x: 320, y: 240), rawModel: "Quarterly Budget title", dispersion: 3)
            ]),
        ])
        let grounder = MixtureGrounder(
            base: recorder,
            skills: .init(),
            verifyCandidates: true
        )

        let result = await grounder.groundResult(
            screenshot: Data(),
            target: "Quarterly Budget title",
            displayWidthPoints: 1000,
            displayHeightPoints: 700
        )

        #expect(result.selectedPoint == CGPoint(x: 320, y: 240))
        #expect(await recorder.sampleCounts() == [1, 3])
    }

    @Test func priorGroundingFailureStartsWithThreeSamples() async {
        let recorder = RecordingGrounder(results: [
            result([
                candidate(point: CGPoint(x: 320, y: 240), rawModel: "Quarterly Budget title", dispersion: 3)
            ])
        ])
        let grounder = MixtureGrounder(
            base: recorder,
            skills: .init(),
            verifyCandidates: true,
            candidateFailureCounts: ["base:0": 1]
        )

        let result = await grounder.groundResult(
            screenshot: Data(),
            target: "Quarterly Budget title",
            displayWidthPoints: 1000,
            displayHeightPoints: 700
        )

        #expect(result.selectedPoint == CGPoint(x: 320, y: 240))
        #expect(await recorder.sampleCounts() == [3])
    }

    @Test func enabledRejectsOffscreenAndPassiveCandidates() {
        let offscreen = MixtureGrounder.selectVerifiedCandidate(
            axCandidate: nil,
            baseResult: result([
                candidate(point: CGPoint(x: 1200, y: 320), rawModel: "Send")
            ]),
            target: "Send",
            displayWidthPoints: 1000,
            displayHeightPoints: 700
        )

        #expect(offscreen.outcome == .rejected(.offscreen))
        #expect(offscreen.result.selectedPoint == nil)

        let passive = MixtureGrounder.selectVerifiedCandidate(
            axCandidate: verifierCandidate(
                id: "ax:label",
                point: CGPoint(x: 420, y: 320),
                role: "AXStaticText",
                label: "Send"
            ),
            baseResult: result([]),
            target: "Send",
            displayWidthPoints: 1000,
            displayHeightPoints: 700
        )

        #expect(passive.outcome == .rejected(.passiveRole))
        #expect(passive.result.selectedPoint == nil)
    }

    @Test func enabledAbstainsOnAmbiguousCandidates() {
        let selection = MixtureGrounder.selectVerifiedCandidate(
            axCandidate: nil,
            baseResult: result([
                candidate(point: CGPoint(x: 420, y: 320), rawModel: "Send"),
                candidate(point: CGPoint(x: 470, y: 320), rawModel: "Send"),
            ]),
            target: "Send",
            displayWidthPoints: 1000,
            displayHeightPoints: 700
        )

        #expect(selection.outcome == .abstained(.ambiguous))
        #expect(selection.result.selectedPoint == nil)
    }

    @Test func enabledAcceptsHighEvidenceCandidate() {
        let point = CGPoint(x: 420, y: 320)
        let selection = MixtureGrounder.selectVerifiedCandidate(
            axCandidate: nil,
            baseResult: result([
                candidate(point: point, rawModel: "Send", dispersion: 3)
            ]),
            target: "the Send button",
            displayWidthPoints: 1000,
            displayHeightPoints: 700
        )

        #expect(selection.outcome == .selected)
        #expect(selection.result.selectedPoint == point)
    }

    @Test func driftScoredFailuresRetryOrDemoteWithoutLiveAccessibility() {
        let now = Date(timeIntervalSinceReferenceDate: 2_000)
        let previous = MixtureGrounder.VerifiedGroundingAnchor(
            score: 0.80,
            source: .ocr,
            hash: "Send",
            verifiedAt: now.addingTimeInterval(-30)
        )

        let retry = MixtureGrounder.selectVerifiedCandidate(
            axCandidate: nil,
            baseResult: result([
                candidate(point: CGPoint(x: 420, y: 320), rawModel: "Send"),
                candidate(point: CGPoint(x: 470, y: 320), rawModel: "Send"),
            ]),
            target: "Send",
            displayWidthPoints: 1000,
            displayHeightPoints: 700,
            previousAnchor: previous,
            candidateFailureCounts: ["base:0": 1],
            now: now
        )

        #expect(retry.outcome == .retryNextCandidate)
        #expect(retry.result.selectedPoint == CGPoint(x: 470, y: 320))

        let demote = MixtureGrounder.selectVerifiedCandidate(
            axCandidate: nil,
            baseResult: result([
                candidate(point: CGPoint(x: 420, y: 320), rawModel: "Send")
            ]),
            target: "Send",
            displayWidthPoints: 1000,
            displayHeightPoints: 700,
            previousAnchor: previous,
            candidateFailureCounts: ["base:0": 3],
            now: now
        )

        #expect(demote.outcome == .demote)
        #expect(demote.result.selectedPoint == nil)
    }

    // MARK: - d13 disagreement/confidence gate

    @Test func crossSourceDisagreementResolvesByTrustOrderWhenGateEnabled() {
        let axPoint = CGPoint(x: 200, y: 300)
        let visionPoint = CGPoint(x: 600, y: 300)
        let selection = MixtureGrounder.selectVerifiedCandidate(
            axCandidate: verifierCandidate(
                id: "ax:send",
                point: axPoint,
                role: "AXButton",
                label: "Send",
                confidence: 0.9
            ),
            baseResult: result([barePointCandidate(point: visionPoint, source: .uiTars)]),
            target: "Send",
            displayWidthPoints: 1000,
            displayHeightPoints: 700,
            trustOrderGateEnabled: true
        )

        #expect(selection.outcome == .selected)
        #expect(selection.result.selectedPoint == axPoint)
        #expect(selection.result.selectedCandidate?.source == .accessibility)
        #expect(selection.verifierResult.verdict == .accept)
        let decision = selection.disagreement
        #expect(decision?.resolution == .trustOrder)
        #expect(decision?.winnerSource == .accessibility)
        #expect(decision?.sourceCount == 2)
        #expect(decision?.clusterCount == 2)
        #expect(decision?.losers.count == 1)
        #expect(decision?.losers.first?.source == .uiTars)
        #expect(decision?.losers.first?.x == Double(visionPoint.x))
        #expect(decision?.losers.first?.y == Double(visionPoint.y))
    }

    @Test func crossSourceDisagreementIsObservedOnlyWhenGateDisabled() {
        let selection = MixtureGrounder.selectVerifiedCandidate(
            axCandidate: verifierCandidate(
                id: "ax:send",
                point: CGPoint(x: 200, y: 300),
                role: "AXButton",
                label: "Send",
                confidence: 0.9
            ),
            baseResult: result([barePointCandidate(point: CGPoint(x: 600, y: 300), source: .uiTars)]),
            target: "Send",
            displayWidthPoints: 1000,
            displayHeightPoints: 700
        )

        #expect(selection.outcome == .abstained(.ambiguous))
        #expect(selection.result.selectedPoint == nil)
        #expect(selection.disagreement?.resolution == .observed)
        #expect(selection.disagreement?.winnerSource == .accessibility)
        #expect(selection.disagreement?.losers.count == 1)
    }

    @Test func sameSourceAmbiguityCarriesNoDisagreementDecision() {
        let selection = MixtureGrounder.selectVerifiedCandidate(
            axCandidate: nil,
            baseResult: result([
                candidate(point: CGPoint(x: 420, y: 320), rawModel: "Send"),
                candidate(point: CGPoint(x: 470, y: 320), rawModel: "Send"),
            ]),
            target: "Send",
            displayWidthPoints: 1000,
            displayHeightPoints: 700,
            trustOrderGateEnabled: true
        )

        #expect(selection.outcome == .abstained(.ambiguous))
        #expect(selection.disagreement == nil)
    }

    @Test func agreeingCrossSourceCandidatesAreCorroborationNotDisagreement() {
        let axPoint = CGPoint(x: 200, y: 300)
        let selection = MixtureGrounder.selectVerifiedCandidate(
            axCandidate: verifierCandidate(
                id: "ax:send",
                point: axPoint,
                role: "AXButton",
                label: "Send",
                confidence: 0.9
            ),
            baseResult: result([
                barePointCandidate(point: CGPoint(x: 210, y: 305), source: .uiTars)
            ]),
            target: "Send",
            displayWidthPoints: 1000,
            displayHeightPoints: 700,
            trustOrderGateEnabled: true
        )

        #expect(selection.disagreement == nil)
        #expect(selection.outcome == .selected)
    }

    private func result(_ candidates: [GroundingCandidate]) -> GroundingResult {
        GroundingResult(candidates: candidates, selectedIndex: candidates.isEmpty ? nil : 0)
    }

    /// A metadata-less visual-grounder hit: no role/label/OCR evidence, just a
    /// confident point — the shape UI-TARS returns for canvas targets.
    private func barePointCandidate(
        point: CGPoint,
        source: GroundingSource,
        confidence: Double = 0.95
    ) -> GroundingCandidate {
        GroundingCandidate(
            point: point,
            confidence: confidence,
            source: source,
            coordinateSpace: .displayLocalAppKitPoints
        )
    }

    private func candidate(
        point: CGPoint,
        rawModel: String,
        confidence: Double = 0.95,
        dispersion: Double? = 4
    ) -> GroundingCandidate {
        GroundingCandidate(
            point: point,
            confidence: confidence,
            source: .ocr,
            coordinateSpace: .displayLocalAppKitPoints,
            rawModel: rawModel,
            dispersion: dispersion
        )
    }

    private func verifierCandidate(
        id: String,
        point: CGPoint,
        role: String,
        label: String,
        confidence: Double = 0.95
    ) -> GroundingVerifierCandidate {
        GroundingVerifierCandidate(
            id: id,
            candidate: GroundingCandidate(
                point: point,
                confidence: confidence,
                source: .accessibility,
                coordinateSpace: .displayLocalAppKitPoints,
                candidateID: id
            ),
            role: role,
            label: label,
            nearbyOCRText: label,
            ocrDistancePoints: 0
        )
    }
}

private struct StubGrounder: VisualGrounder {
    let point: CGPoint?
    let result: GroundingResult?

    init(point: CGPoint? = nil, result: GroundingResult? = nil) {
        self.point = point
        self.result = result
    }

    func ground(
        screenshot: Data,
        target: String,
        displayWidthPoints: Int,
        displayHeightPoints: Int
    ) async -> CGPoint? {
        point ?? result?.selectedPoint
    }

    func groundResult(
        screenshot: Data,
        target: String,
        displayWidthPoints: Int,
        displayHeightPoints: Int
    ) async -> GroundingResult {
        result ?? GroundingResult.legacy(point: point)
    }
}

private actor RecordingGrounder: VisualGrounder {
    private var results: [GroundingResult]
    private var observedSampleCounts: [Int] = []

    init(results: [GroundingResult]) {
        self.results = results
    }

    func sampleCounts() -> [Int] {
        observedSampleCounts
    }

    func ground(
        screenshot: Data,
        target: String,
        displayWidthPoints: Int,
        displayHeightPoints: Int
    ) async -> CGPoint? {
        await groundResult(
            screenshot: screenshot,
            target: target,
            displayWidthPoints: displayWidthPoints,
            displayHeightPoints: displayHeightPoints
        ).selectedPoint
    }

    func groundResult(
        screenshot: Data,
        target: String,
        displayWidthPoints: Int,
        displayHeightPoints: Int
    ) async -> GroundingResult {
        await groundResult(
            screenshot: screenshot,
            target: target,
            displayWidthPoints: displayWidthPoints,
            displayHeightPoints: displayHeightPoints,
            options: .default
        )
    }

    func groundResult(
        screenshot: Data,
        target: String,
        displayWidthPoints: Int,
        displayHeightPoints: Int,
        options: GroundingRequestOptions
    ) async -> GroundingResult {
        observedSampleCounts.append(options.sampleCount)
        guard !results.isEmpty else { return GroundingResult() }
        return results.count == 1 ? results[0] : results.removeFirst()
    }
}
