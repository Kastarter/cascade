import CoreGraphics
import Foundation
import PerceptionCore
import Testing

@testable import ProviderKit

// NOTE: this file imports BOTH ProviderKit and PerceptionCore, which declare
// colliding GroundingCandidate/GroundingSource names — every PerceptionCore
// reference is fully qualified (see the header of PerceptionCore/Grounding.swift).

struct GroundingRouterTests {
    // (a) 517699f pin: corroboration ACCEPTS — an agreeing OCR candidate BOOSTS
    // the AX hit's confidence with .sourceAgreement evidence; agreement can
    // never abstain.
    @Test func corroboratingOCRBoostsAndAcceptsAXHit() {
        let decision = GroundingRouter.selectVerdict(
            candidates: [
                perceptionCandidate(x: 100, y: 100, source: .ax, confidence: 0.7),
                perceptionCandidate(x: 105, y: 102, source: .ocr, confidence: 0.8),
            ],
            context: GroundingRouter.RouteContext()
        )

        #expect(decision.reason == .axHit)
        #expect(decision.selectedSource == PerceptionCore.GroundingSource.ax)
        #expect(decision.corroborated)
        #expect(decision.verdict.selected != nil)
        let boosted = decision.verdict.selected?.confidence.value ?? 0
        #expect(abs(boosted - 0.8) < 1e-9)
        #expect(decision.verdict.selected?.evidence.contains(.sourceAgreement) == true)
    }

    // Disagreement is not a veto: the AX hit still stands, un-boosted.
    @Test func disagreeingOCRDoesNotVetoAXHit() {
        let decision = GroundingRouter.selectVerdict(
            candidates: [
                perceptionCandidate(x: 100, y: 100, source: .ax, confidence: 0.7),
                perceptionCandidate(x: 400, y: 500, source: .ocr, confidence: 0.9),
            ],
            context: GroundingRouter.RouteContext()
        )

        #expect(decision.reason == .axHit)
        #expect(decision.selectedSource == PerceptionCore.GroundingSource.ax)
        #expect(!decision.corroborated)
        #expect(decision.verdict.selected?.confidence.value == 0.7)
    }

    // (b) canvas context skips AX entirely — visual candidate with reason .canvas.
    @Test func canvasContextRoutesToVisual() {
        let decision = GroundingRouter.selectVerdict(
            candidates: [
                perceptionCandidate(x: 100, y: 100, source: .ax, confidence: 0.95),
                perceptionCandidate(x: 300, y: 300, source: .visual, confidence: 0.6),
            ],
            context: GroundingRouter.RouteContext(canvasTarget: true)
        )

        #expect(decision.reason == .canvas)
        #expect(decision.selectedSource == PerceptionCore.GroundingSource.visual)
    }

    @Test func contextSkipReasonsMapOneToOne() {
        let cases: [(GroundingRouter.RouteContext, PerceptionCore.RouteReason)] = [
            (GroundingRouter.RouteContext(canvasTarget: true), .canvas),
            (GroundingRouter.RouteContext(ownUI: true), .ownUI),
            (GroundingRouter.RouteContext(axUnreliable: true), .axUnreliable),
            (GroundingRouter.RouteContext(axSparse: true), .sparse),
        ]
        for (context, expected) in cases {
            let decision = GroundingRouter.selectVerdict(
                candidates: [perceptionCandidate(x: 300, y: 300, source: .ocr, confidence: 0.6)],
                context: context
            )
            #expect(decision.reason == expected)
            #expect(decision.selectedSource == PerceptionCore.GroundingSource.ocr)
        }
    }

    // (c) AX-rich (context did NOT skip AX) but no AX match → the honest
    // .axMiss residual, never .sparse (LAW 7 — a .sparse row would be FALSE).
    @Test func axRanButMissedIsAxMissNotSparse() {
        let decision = GroundingRouter.selectVerdict(
            candidates: [
                perceptionCandidate(x: 210, y: 220, source: .ocr, confidence: 0.8),
                perceptionCandidate(x: 400, y: 410, source: .visual, confidence: 0.9),
            ],
            context: GroundingRouter.RouteContext()
        )

        #expect(decision.reason == .axMiss)
        #expect(decision.reason != .sparse)
        // OCR-then-visual fallback: OCR wins even at lower confidence.
        #expect(decision.selectedSource == PerceptionCore.GroundingSource.ocr)
    }

    // Weak AX (below threshold) is also an honest axMiss, not an axHit.
    @Test func belowThresholdAXIsAxMiss() {
        let decision = GroundingRouter.selectVerdict(
            candidates: [
                perceptionCandidate(x: 100, y: 100, source: .ax, confidence: 0.4),
                perceptionCandidate(x: 300, y: 300, source: .visual, confidence: 0.7),
            ],
            context: GroundingRouter.RouteContext()
        )

        #expect(decision.reason == .axMiss)
        #expect(decision.selectedSource == PerceptionCore.GroundingSource.visual)
    }

    // Anchor rung is real (v1 just never produces anchor candidates).
    @Test func anchorCandidateWinsTheLadder() {
        let decision = GroundingRouter.selectVerdict(
            candidates: [
                perceptionCandidate(x: 50, y: 60, source: .anchor, confidence: 0.9),
                perceptionCandidate(x: 100, y: 100, source: .ax, confidence: 0.95),
            ],
            context: GroundingRouter.RouteContext()
        )

        #expect(decision.reason == .anchorHit)
        #expect(decision.selectedSource == PerceptionCore.GroundingSource.anchor)
    }

    // (d) sourceCounts tally per source — the moat's dashboard number.
    @Test func sourceCountsTallyPerSource() {
        let decision = GroundingRouter.selectVerdict(
            candidates: [
                perceptionCandidate(x: 100, y: 100, source: .ax, confidence: 0.7),
                perceptionCandidate(x: 105, y: 102, source: .ocr, confidence: 0.8),
                perceptionCandidate(x: 300, y: 300, source: .ocr, confidence: 0.5),
                perceptionCandidate(x: 400, y: 400, source: .visual, confidence: 0.6),
            ],
            context: GroundingRouter.RouteContext()
        )

        #expect(decision.sourceCounts[.ax] == 1)
        #expect(decision.sourceCounts[.ocr] == 2)
        #expect(decision.sourceCounts[.visual] == 1)
        #expect(decision.sourceCountsToken == "ax:1,ocr:2,visual:1")
    }

    // (e) nothing to route on → selected nil, honest reason preserved.
    @Test func emptyCandidatesSelectNothing() {
        let empty = GroundingRouter.selectVerdict(
            candidates: [],
            context: GroundingRouter.RouteContext()
        )
        #expect(empty.verdict.selected == nil)
        #expect(empty.selectedSource == nil)
        #expect(empty.reason == .axMiss)
        #expect(empty.sourceCounts.isEmpty)

        let sparse = GroundingRouter.selectVerdict(
            candidates: [],
            context: GroundingRouter.RouteContext(axSparse: true)
        )
        #expect(sparse.verdict.selected == nil)
        #expect(sparse.reason == .sparse)
    }

    // Same 24pt epsilon MixtureGrounder.pointsAgree uses.
    @Test func pointsAgreeUses24PointEpsilon() {
        let origin = PerceptionCore.Point<PerceptionCore.FrameSpace>(x: 0, y: 0)
        #expect(GroundingRouter.pointsAgree(origin, PerceptionCore.Point<PerceptionCore.FrameSpace>(x: 24, y: 0)))
        #expect(!GroundingRouter.pointsAgree(origin, PerceptionCore.Point<PerceptionCore.FrameSpace>(x: 25, y: 0)))
        #expect(!GroundingRouter.pointsAgree(origin, nil))
        #expect(!GroundingRouter.pointsAgree(nil, nil))
    }

    // Bridge mapping: ProviderKit lanes → §3.3 vocabulary; non-perception lanes → nil.
    @Test func bridgeMapsProviderLanes() {
        #expect(PerceptionCandidateBridge.perceptionSource(.accessibility) == PerceptionCore.GroundingSource.ax)
        #expect(PerceptionCandidateBridge.perceptionSource(.dom) == PerceptionCore.GroundingSource.dom)
        #expect(PerceptionCandidateBridge.perceptionSource(.ocr) == PerceptionCore.GroundingSource.ocr)
        #expect(PerceptionCandidateBridge.perceptionSource(.uiTars) == PerceptionCore.GroundingSource.visual)
        #expect(PerceptionCandidateBridge.perceptionSource(.claude) == PerceptionCore.GroundingSource.visual)
        #expect(PerceptionCandidateBridge.perceptionSource(.visualModel) == PerceptionCore.GroundingSource.visual)
        #expect(PerceptionCandidateBridge.perceptionSource(.cache) == nil)
        #expect(PerceptionCandidateBridge.perceptionSource(.compatibility) == nil)
        #expect(PerceptionCandidateBridge.perceptionSource(.unknown) == nil)
    }

    // Bridge clamps confidence and drops point-less candidates.
    @Test func bridgeClampsConfidenceAndRequiresPoint() {
        let overconfident = providerCandidate(point: CGPoint(x: 10, y: 20), source: .ocr, confidence: 7.3)
        let bridged = PerceptionCandidateBridge.perceptionCandidate(from: overconfident, targetText: "t")
        #expect(bridged?.confidence.value == 1.0)
        #expect(bridged?.point.x == 10)
        #expect(bridged?.point.y == 20)

        let pointless = providerCandidate(point: nil, source: .ocr, confidence: 0.9)
        #expect(PerceptionCandidateBridge.perceptionCandidate(from: pointless, targetText: "t") == nil)
    }

    // End-to-end: route() over frozen lane adapters wrapping ProviderKit candidates.
    @Test func routeOverFrozenLaneAdapters() async {
        let live = [
            providerCandidate(point: CGPoint(x: 100, y: 100), source: .accessibility, confidence: 0.8),
            providerCandidate(point: CGPoint(x: 104, y: 103), source: .ocr, confidence: 0.7),
            providerCandidate(point: CGPoint(x: 500, y: 500), source: .uiTars, confidence: 0.6),
            providerCandidate(point: CGPoint(x: 1, y: 1), source: .cache, confidence: 0.99),
        ]
        let decision = await GroundingRouter.shadowDecision(
            candidates: live,
            target: "the Save button",
            context: GroundingRouter.RouteContext()
        )

        #expect(decision.reason == .axHit)
        #expect(decision.corroborated)
        #expect(decision.selectedSource == PerceptionCore.GroundingSource.ax)
        // Cache lane has no perception meaning — dropped, not miscounted.
        #expect(decision.sourceCounts[.ax] == 1)
        #expect(decision.sourceCounts[.ocr] == 1)
        #expect(decision.sourceCounts[.visual] == 1)
    }

    // MARK: - Fixtures

    private func perceptionCandidate(
        x: Double,
        y: Double,
        source: PerceptionCore.GroundingSource,
        confidence: Double
    ) -> PerceptionCore.GroundingCandidate {
        PerceptionCore.GroundingCandidate(
            point: PerceptionCore.Point<PerceptionCore.FrameSpace>(x: x, y: y),
            targetText: "target",
            source: source,
            confidence: PerceptionCore.Confidence(clamping: confidence)
        )
    }

    private func providerCandidate(
        point: CGPoint?,
        source: ProviderKit.GroundingSource,
        confidence: Double
    ) -> ProviderKit.GroundingCandidate {
        ProviderKit.GroundingCandidate(
            point: point,
            confidence: confidence,
            source: source,
            coordinateSpace: .displayLocalAppKitPoints,
            rawModel: "label"
        )
    }
}
