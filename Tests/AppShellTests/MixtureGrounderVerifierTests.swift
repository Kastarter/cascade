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

    private func result(_ candidates: [GroundingCandidate]) -> GroundingResult {
        GroundingResult(candidates: candidates, selectedIndex: candidates.isEmpty ? nil : 0)
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
        label: String
    ) -> GroundingVerifierCandidate {
        GroundingVerifierCandidate(
            id: id,
            candidate: GroundingCandidate(
                point: point,
                confidence: 0.95,
                source: .accessibility,
                coordinateSpace: .displayLocalAppKitPoints
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
