import CoreGraphics
import Foundation
import Testing

@testable import ProviderKit

struct GroundingEvalTests {
    @Test func summarizesHitRateLatencyDispersionMissesAndCoordCorrectness() {
        let hit = GroundingEval.observe(
            GroundingEvalCase(
                id: "ax-save",
                target: "Save",
                expectedPoint: CGPoint(x: 100, y: 200),
                tolerance: 12
            ),
            result: GroundingResult(
                candidates: [
                    GroundingCandidate(
                        point: CGPoint(x: 106, y: 196),
                        confidence: 0.96,
                        source: .accessibility,
                        coordinateSpace: .displayLocalAppKitPoints,
                        latency: 0.01,
                        dispersion: 0
                    )
                ],
                selectedIndex: 0
            )
        )
        let miss = GroundingEval.observe(
            GroundingEvalCase(
                id: "visual-send",
                target: "Send",
                expectedPoint: CGPoint(x: 50, y: 50),
                tolerance: 8
            ),
            result: GroundingResult(
                candidates: [
                    GroundingCandidate(
                        point: CGPoint(x: 120, y: 120),
                        confidence: 0.42,
                        source: .uiTars,
                        coordinateSpace: .normalizedThousandths,
                        latency: 0.21,
                        dispersion: 39,
                        reason: "low evidence"
                    )
                ],
                selectedIndex: 0
            )
        )

        let summary = GroundingEval.summarize([hit, miss])

        #expect(hit.hit)
        #expect(!miss.hit)
        #expect(summary.total == 2)
        #expect(summary.hitRateBySource[.accessibility] == 1)
        #expect(summary.hitRateBySource[.uiTars] == 0)
        #expect(abs((summary.medianLatency ?? 0) - 0.11) < 0.000_001)
        #expect(abs((summary.medianDispersion ?? 0) - 19.5) < 0.000_001)
        #expect(summary.missTypes["low evidence"] == 1)
        #expect(summary.coordinateSpaceCorrectRate == 0.5)
    }

    @Test func coordinateProbeCatchesWrongCoordinateSpace() {
        let passed = GrounderRegistry.probeCoordSpace(
            coordSpace: .sent,
            modelOutput: "click(start_box='(640,400)')"
        )
        let failed = GrounderRegistry.probeCoordSpace(
            coordSpace: .normalized,
            modelOutput: "click(start_box='(640,400)')"
        )

        #expect(passed.status == .passed)
        #expect(failed.status == .failed)
        #expect(GrounderRegistry.preset(id: "showui").coordinateSpace == .normalized)
    }

    @Test func cropLocalPointMapsBackToDisplayCoordinates() {
        let mapped = GroundingEval.cropLocalPointToDisplay(
            CGPoint(x: 25, y: 35),
            cropDisplayBounds: CGRect(x: 100, y: 200, width: 300, height: 300)
        )

        #expect(mapped == CGPoint(x: 125, y: 235))
    }
}
