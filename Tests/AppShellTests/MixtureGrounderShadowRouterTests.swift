import CoreGraphics
import Foundation
import ProviderKit
import Testing

@testable import AppShell

/// EXERCISED ON-path pins for the shadow GroundingRouter hook
/// (cascade.perceptionRouter): parity with the live selection, exactly one
/// decision per verified ground call, honest divergence, and audit-detail PII
/// discipline. The OFF path (hook nil) is pinned byte-identical by the parity
/// test plus the untouched MixtureGrounderTests/MixtureGrounderVerifierTests.
struct MixtureGrounderShadowRouterTests {
    // (f) Shadow parity: a recording hook changes NOTHING about the returned
    // GroundingResult, and the hook fires exactly once with real source shares.
    @Test func shadowHookPreservesLiveResultAndFiresOnce() async {
        let baseResult = result([
            candidate(point: CGPoint(x: 320, y: 240), rawModel: "Quarterly Budget title", dispersion: 3)
        ])
        let recorder = ShadowOutcomeRecorder()
        let hooked = MixtureGrounder(
            base: StubGrounder(result: baseResult),
            skills: .init(),
            verifyCandidates: true,
            onRouteDecision: { await recorder.record($0) }
        )
        let hookless = MixtureGrounder(
            base: StubGrounder(result: baseResult),
            skills: .init(),
            verifyCandidates: true
        )

        let hookedResult = await hooked.groundResult(
            screenshot: Data(),
            target: "Quarterly Budget title",
            displayWidthPoints: 1000,
            displayHeightPoints: 700
        )
        let hooklessResult = await hookless.groundResult(
            screenshot: Data(),
            target: "Quarterly Budget title",
            displayWidthPoints: 1000,
            displayHeightPoints: 700
        )

        // Byte-equal live result: the shadow router never changes what is actuated.
        #expect(hookedResult == hooklessResult)
        #expect(hookedResult.selectedPoint == CGPoint(x: 320, y: 240))

        let outcomes = await recorder.all()
        #expect(outcomes.count == 1)
        let outcome = try! #require(outcomes.first)
        #expect(!outcome.decision.sourceCounts.isEmpty)
        #expect(outcome.decision.sourceCountsToken.contains("ocr:1"))
        #expect(outcome.candidateCount == 1)
        #expect(outcome.liveVerdict == "accept")
        // Live accepted the same OCR candidate the router routed to → parity.
        #expect(!outcome.diverged)
    }

    // (g) Honest divergence: the live verifier abstains on an ambiguous pair
    // while the router still selects its best OCR candidate → diverged == true.
    @Test func liveAbstainWhileRouterSelectsIsDivergence() async {
        let ambiguous = result([
            candidate(point: CGPoint(x: 420, y: 320), rawModel: "Send"),
            candidate(point: CGPoint(x: 470, y: 320), rawModel: "Send"),
        ])
        let recorder = ShadowOutcomeRecorder()
        let grounder = MixtureGrounder(
            base: StubGrounder(result: ambiguous),
            skills: .init(),
            verifyCandidates: true,
            onRouteDecision: { await recorder.record($0) }
        )

        let live = await grounder.groundResult(
            screenshot: Data(),
            target: "Send",
            displayWidthPoints: 1000,
            displayHeightPoints: 700
        )

        #expect(live.selectedPoint == nil)

        let outcomes = await recorder.all()
        #expect(outcomes.count == 1)
        let outcome = try! #require(outcomes.first)
        #expect(outcome.diverged)
        #expect(outcome.liveVerdict == "abstain")
        #expect(outcome.decision.selectedSourceToken == "ocr")
        #expect(outcome.decision.reasonToken == "axMiss")
    }

    // (h) Audit-detail PII discipline: targetHash present, raw target text never.
    @Test func auditDetailCarriesHashNeverRawTarget() async {
        let target = "Quarterly Confidential Ledger row"
        let decision = await GroundingRouter.shadowDecision(
            candidates: [
                candidate(point: CGPoint(x: 320, y: 240), rawModel: target, dispersion: 3)
            ],
            target: target,
            context: GroundingRouter.RouteContext()
        )
        let outcome = MixtureGrounder.ShadowRouteOutcome(
            target: target,
            decision: decision,
            diverged: false,
            liveSource: .ocr,
            liveVerdict: "accept",
            candidateCount: 1
        )

        let detail = CascadeAppModel.groundingRouteAuditDetail(outcome)

        #expect(detail.contains("targetHash="))
        #expect(detail.contains("lane=key"))
        #expect(detail.contains("reason="))
        #expect(detail.contains("sources=ax:0,ocr:1,visual:0"))
        #expect(!detail.contains("Confidential"))
        #expect(!detail.contains("Ledger"))
        #expect(!detail.contains(target))
    }

    // MARK: - Fixtures

    private func result(_ candidates: [ProviderKit.GroundingCandidate]) -> GroundingResult {
        GroundingResult(candidates: candidates, selectedIndex: candidates.isEmpty ? nil : 0)
    }

    private func candidate(
        point: CGPoint,
        rawModel: String,
        confidence: Double = 0.95,
        dispersion: Double? = 4
    ) -> ProviderKit.GroundingCandidate {
        ProviderKit.GroundingCandidate(
            point: point,
            confidence: confidence,
            source: .ocr,
            coordinateSpace: .displayLocalAppKitPoints,
            rawModel: rawModel,
            dispersion: dispersion
        )
    }
}

private actor ShadowOutcomeRecorder {
    private var outcomes: [MixtureGrounder.ShadowRouteOutcome] = []

    func record(_ outcome: MixtureGrounder.ShadowRouteOutcome) {
        outcomes.append(outcome)
    }

    func all() -> [MixtureGrounder.ShadowRouteOutcome] {
        outcomes
    }
}

private struct StubGrounder: VisualGrounder {
    let result: GroundingResult

    func ground(
        screenshot: Data,
        target: String,
        displayWidthPoints: Int,
        displayHeightPoints: Int
    ) async -> CGPoint? {
        result.selectedPoint
    }

    func groundResult(
        screenshot: Data,
        target: String,
        displayWidthPoints: Int,
        displayHeightPoints: Int
    ) async -> GroundingResult {
        result
    }
}
