import CoreGraphics
import Foundation
import ProviderKit
import Testing

struct GroundingResultTests {
    @Test func candidatesRoundTripThroughCodableAndEquatableFixture() throws {
        let fixture = GroundingResult(
            candidates: [
                GroundingCandidate(
                    point: CGPoint(x: 128.5, y: 256.25),
                    region: CGRect(x: 120, y: 240, width: 40, height: 20),
                    confidence: 0.87,
                    source: .uiTars,
                    coordinateSpace: .displayLocalAppKitPoints,
                    rawModel: "click(start_box='(128.5,256.25)')",
                    latency: 0.142,
                    dispersion: 3.5,
                    candidateID: "se_1",
                    markNumber: 4,
                    displayBounds: CGRect(x: 120, y: 240, width: 40, height: 20)
                ),
                GroundingCandidate(
                    point: CGPoint(x: 130, y: 255),
                    confidence: 0.73,
                    source: .ocr,
                    coordinateSpace: .screenshotPixelsTopLeft,
                    rawModel: "OCR box near target",
                    latency: 0.009,
                    dispersion: 5.25
                ),
            ],
            selectedIndex: 0,
            selectedCandidateID: "se_1",
            verifierVerdict: .accept,
            alternativeCount: 1
        )

        let data = try JSONEncoder().encode(fixture)
        let decoded = try JSONDecoder().decode(GroundingResult.self, from: data)

        #expect(decoded == fixture)
        #expect(decoded.selectedCandidate == fixture.candidates[0])
        #expect(decoded.selectedCandidateID == "se_1")
        #expect(decoded.verifierVerdict == .accept)
    }

    @Test func legacyPointReturnsSelectedCandidatePoint() {
        let result = GroundingResult(
            candidates: [
                GroundingCandidate(
                    point: CGPoint(x: 10, y: 20),
                    confidence: 0.45,
                    source: .accessibility,
                    coordinateSpace: .displayLocalAppKitPoints
                ),
                GroundingCandidate(
                    point: CGPoint(x: 30, y: 40),
                    confidence: 0.91,
                    source: .dom,
                    coordinateSpace: .displayLocalAppKitPoints
                ),
            ],
            selectedIndex: 1
        )

        #expect(result.selectedPoint == CGPoint(x: 30, y: 40))
        #expect(result.legacyPoint == CGPoint(x: 30, y: 40))
    }

    @Test func pointOnlyGrounderWrapsLegacyPointAsSelectedResult() async {
        let point = CGPoint(x: 500, y: 600)
        let result = await StubPointGrounder(point: point).groundResult(
            screenshot: Data([0xFF, 0xD8]),
            target: "Save",
            displayWidthPoints: 1440,
            displayHeightPoints: 900
        )

        #expect(result.legacyPoint == point)
        #expect(result.selectedCandidate?.confidence == 1)
        #expect(result.selectedCandidate?.source == .compatibility)
        #expect(result.selectedCandidate?.coordinateSpace == .displayLocalAppKitPoints)
        #expect(result.selectedCandidate?.latency != nil)
    }

    @Test func lowConfidenceAndNoPointResultsAreRepresentedSafely() {
        let lowConfidenceMiss = GroundingCandidate(
            point: nil,
            region: nil,
            confidence: 0.12,
            source: .visualModel,
            coordinateSpace: .normalizedThousandths,
            rawModel: "not found",
            latency: 0.31,
            dispersion: 42
        )

        let result = GroundingResult(candidates: [lowConfidenceMiss], selectedIndex: 0)
        #expect(result.selectedCandidate == lowConfidenceMiss)
        #expect(result.selectedPoint == nil)
        #expect(result.legacyPoint == nil)

        let invalidSelection = GroundingResult(candidates: [lowConfidenceMiss], selectedIndex: 5)
        #expect(invalidSelection.selectedCandidate == nil)
        #expect(invalidSelection.legacyPoint == nil)

        let legacyMiss = GroundingResult.legacy(point: nil, latency: 0.01)
        #expect(legacyMiss.selectedCandidate?.point == nil)
        #expect(legacyMiss.selectedCandidate?.confidence == 0)
        #expect(legacyMiss.selectedCandidate?.latency == 0.01)
        #expect(legacyMiss.legacyPoint == nil)
    }

    @Test func rejectedAndLowConfidenceResultsAreNotActionable() {
        let candidate = GroundingCandidate(
            point: CGPoint(x: 10, y: 10),
            confidence: 0.9,
            source: .accessibility,
            coordinateSpace: .displayLocalAppKitPoints,
            candidateID: "ax-save"
        )
        let rejected = GroundingResult(
            candidates: [candidate],
            selectedIndex: 0,
            verifierVerdict: .reject,
            verifierFailureKind: .passiveRole
        )
        #expect(!rejected.isActionable())
        #expect(rejected.abstainReason == "passiveRole")

        let weak = GroundingResult(candidates: [
            GroundingCandidate(
                point: CGPoint(x: 10, y: 10),
                confidence: 0.1,
                source: .visualModel,
                coordinateSpace: .displayLocalAppKitPoints
            )
        ], selectedIndex: 0)
        #expect(!weak.isActionable())
    }
}

private struct StubPointGrounder: VisualGrounder {
    let point: CGPoint?

    func ground(
        screenshot: Data,
        target: String,
        displayWidthPoints: Int,
        displayHeightPoints: Int
    ) async -> CGPoint? {
        point
    }
}
