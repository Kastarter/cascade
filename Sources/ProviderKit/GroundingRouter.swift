import CoreGraphics
import Foundation
import PerceptionCore

// MARK: - GroundingRouter (§3.2 perception layer, §4d routing ladder)
//
// Routes a target query across injected PerceptionSources (AX / OCR / visual
// adapters wrapping today's grounders) and produces a typed GroundingVerdict with
// an honest RouteReason. `sourceCounts` per decision IS the moat's dashboard
// number: what share of grounding decisions resolve from AX (free + exact) vs
// OCR vs the audited visual exception (LAW 2).
//
// SHADOW-FIRST (b40ede8 discipline): today the router is only invoked from
// MixtureGrounder's shadow hook, computing its verdict ALONGSIDE the live
// selection over the SAME frozen candidate evidence — it never changes what is
// actuated. `grounding.route.diverged` audit rows are the promotion gate (§6
// "GroundingRouter authoritative"): only live runs with zero divergence let a
// later, separately-gated task make the router route.
//
// CORROBORATION ACCEPTS (517699f): when an independent OCR/visual candidate
// agrees with the AX hit within the 24pt epsilon, confidence is BOOSTED and the
// candidate ACCEPTED with `.sourceAgreement` evidence — agreement can never
// abstain. Disagreement is not a veto either; the AX hit stands un-boosted.
//
// NAME-COLLISION NOTE: ProviderKit's own GroundingSource/GroundingCandidate
// (VisualGrounder.swift) SHADOW the PerceptionCore ones inside this module, so
// every PerceptionCore reference here is FULLY QUALIFIED (see the header of
// PerceptionCore/Grounding.swift).

/// Routes a target query through injected perception sources and selects a
/// grounding verdict via the §4d ladder. Pure policy — no capture, no AX walk,
/// no model call; the sources own all evidence production.
public struct GroundingRouter: Sendable {
    /// AX-skip context computed by the CALLER from the checks MixtureGrounder
    /// already owns (namesCanvasConcept / own-UI bundle / axUnreliable skill flag /
    /// sparse runtime profile). The router itself never probes the system.
    public struct RouteContext: Sendable, Equatable {
        public let canvasTarget: Bool
        public let ownUI: Bool
        public let axUnreliable: Bool
        public let axSparse: Bool

        public init(
            canvasTarget: Bool = false,
            ownUI: Bool = false,
            axUnreliable: Bool = false,
            axSparse: Bool = false
        ) {
            self.canvasTarget = canvasTarget
            self.ownUI = ownUI
            self.axUnreliable = axUnreliable
            self.axSparse = axSparse
        }
    }

    /// One routing decision. `sourceCounts` is the per-decision AX%/OCR%/visual%
    /// tally the moat dashboard aggregates from `grounding.route` audit rows.
    public struct RouteDecision: Sendable, Equatable {
        public let verdict: PerceptionCore.GroundingVerdict
        public let reason: PerceptionCore.RouteReason
        public let selectedSource: PerceptionCore.GroundingSource?
        public let sourceCounts: [PerceptionCore.GroundingSource: Int]
        public let corroborated: Bool

        public init(
            verdict: PerceptionCore.GroundingVerdict,
            reason: PerceptionCore.RouteReason,
            selectedSource: PerceptionCore.GroundingSource?,
            sourceCounts: [PerceptionCore.GroundingSource: Int],
            corroborated: Bool
        ) {
            self.verdict = verdict
            self.reason = reason
            self.selectedSource = selectedSource
            self.sourceCounts = sourceCounts
            self.corroborated = corroborated
        }

        // Collision-safe accessors: AppShell files that already use ProviderKit's
        // GroundingSource/GroundingCandidate unqualified cannot import
        // PerceptionCore without ambiguity errors at every existing use site, so
        // the shadow hook and audit formatting consume these instead of naming
        // PerceptionCore types.

        /// `reason.rawValue` without naming PerceptionCore.RouteReason.
        public var reasonToken: String { reason.rawValue }

        /// `selectedSource?.rawValue` without naming PerceptionCore.GroundingSource.
        public var selectedSourceToken: String? { selectedSource?.rawValue }

        /// Selected point as a CGPoint for the shadow parity comparison. The
        /// numeric value is display-local (see the FrameSpace carve-out in
        /// PerceptionSourceAdapters.swift) — audit/compare only, never actuated.
        public var selectedCGPoint: CGPoint? {
            verdict.selected.map { CGPoint(x: $0.point.x, y: $0.point.y) }
        }

        /// Fixed-lane share token for audit rows: "ax:N,ocr:N,visual:N"
        /// (+",dom:N"/",anchor:N" only when nonzero). Integers + fixed lane names
        /// only — no PII, safe to embed verbatim in audit detail.
        public var sourceCountsToken: String {
            let ax = sourceCounts[.ax, default: 0] + sourceCounts[.syntheticAX, default: 0]
            var token = "ax:\(ax),ocr:\(sourceCounts[.ocr, default: 0]),visual:\(sourceCounts[.visual, default: 0])"
            let dom = sourceCounts[.dom, default: 0]
            if dom > 0 { token += ",dom:\(dom)" }
            let anchor = sourceCounts[.anchor, default: 0]
            if anchor > 0 { token += ",anchor:\(anchor)" }
            return token
        }
    }

    /// Same 24pt epsilon `MixtureGrounder.pointsAgree` uses — the two sides of the
    /// shadow parity comparison must share one agreement definition.
    public static let agreementEpsilonPoints: Double = 24

    /// Minimum AX confidence to take the `.axHit` rung. 0.6 ≈ MixtureGrounder's
    /// minAXScore of 2 through `AXMatchScore.normalized()` (2/3): substring
    /// containment or better, never weak word-overlap.
    public static let axAcceptThreshold: Double = 0.6

    /// Corroboration boost (517699f): min(1, c + 0.1), clamped by Confidence.
    public static let corroborationBoost: Double = 0.1

    private let sources: [any PerceptionCore.PerceptionSource]

    public init(sources: [any PerceptionCore.PerceptionSource]) {
        self.sources = sources
    }

    /// Collects candidates from every injected source (in order) and selects the
    /// verdict via the pure ladder.
    public func route(
        query: PerceptionCore.TargetQuery,
        snapshot: PerceptionCore.PerceptionSnapshot,
        context: RouteContext
    ) async -> RouteDecision {
        var candidates: [PerceptionCore.GroundingCandidate] = []
        for source in sources {
            candidates.append(contentsOf: await source.candidates(for: query, in: snapshot))
        }
        return Self.selectVerdict(candidates: candidates, context: context)
    }

    /// The §4d ladder, pure and headless-testable:
    ///   1. anchor candidate → `.anchorHit` (empty in v1 — AnchorMemory is a later task);
    ///   2. AX candidate ≥ threshold (when context didn't skip AX) → `.axHit`;
    ///      an agreeing OCR/visual candidate BOOSTS confidence with
    ///      `.sourceAgreement` evidence and ACCEPTS (517699f — agreement can
    ///      never abstain);
    ///   3. AX skipped by context → the context's reason
    ///      (`.canvas`/`.ownUI`/`.axUnreliable`/`.sparse`) with the best
    ///      OCR-then-visual candidate;
    ///   4. AX ran but no match above threshold → `.axMiss` (honest residual —
    ///      `.sparse` here would be a FALSE audit, LAW 7);
    ///   5. nothing → selected nil, same reason.
    public static func selectVerdict(
        candidates: [PerceptionCore.GroundingCandidate],
        context: RouteContext
    ) -> RouteDecision {
        let counts = tally(candidates)

        // Rung 1: anchor (AnchorMemory lands in a later task; the rung is real so
        // its share shows up the moment anchors exist).
        if let anchor = best(candidates, from: [.anchor]) {
            return RouteDecision(
                verdict: PerceptionCore.GroundingVerdict(selected: anchor, candidates: candidates, reason: .anchorHit),
                reason: .anchorHit,
                selectedSource: anchor.source,
                sourceCounts: counts,
                corroborated: false
            )
        }

        // Rung 2: AX, unless context skipped the AX lane.
        let skipReason = axSkipReason(context)
        if skipReason == nil,
           let ax = best(candidates, from: [.ax, .syntheticAX]),
           ax.confidence.value >= axAcceptThreshold {
            let corroborated = candidates.contains { other in
                (other.source == .ocr || other.source == .visual || other.source == .dom)
                    && pointsAgree(ax.point, other.point)
            }
            let selected: PerceptionCore.GroundingCandidate
            if corroborated {
                var evidence = ax.evidence
                if !evidence.contains(.sourceAgreement) { evidence.append(.sourceAgreement) }
                selected = PerceptionCore.GroundingCandidate(
                    point: ax.point,
                    rect: ax.rect,
                    role: ax.role,
                    label: ax.label,
                    targetText: ax.targetText,
                    source: ax.source,
                    confidence: PerceptionCore.Confidence(clamping: ax.confidence.value + corroborationBoost),
                    evidence: evidence
                )
            } else {
                selected = ax
            }
            return RouteDecision(
                verdict: PerceptionCore.GroundingVerdict(selected: selected, candidates: candidates, reason: .axHit),
                reason: .axHit,
                selectedSource: selected.source,
                sourceCounts: counts,
                corroborated: corroborated
            )
        }

        // Rungs 3–5: context reason (AX skipped) or the honest axMiss residual,
        // with the best OCR-then-visual candidate — or nothing.
        let reason = skipReason ?? PerceptionCore.RouteReason.axMiss
        let fallback = best(candidates, from: [.ocr])
            ?? best(candidates, from: [.visual])
            ?? best(candidates, from: [.dom])
        return RouteDecision(
            verdict: PerceptionCore.GroundingVerdict(selected: fallback, candidates: candidates, reason: reason),
            reason: reason,
            selectedSource: fallback?.source,
            sourceCounts: counts,
            corroborated: false
        )
    }

    /// Same 24pt epsilon as `MixtureGrounder.pointsAgree`, over FrameSpace points.
    public static func pointsAgree(
        _ lhs: PerceptionCore.Point<PerceptionCore.FrameSpace>?,
        _ rhs: PerceptionCore.Point<PerceptionCore.FrameSpace>?
    ) -> Bool {
        guard let lhs, let rhs else { return false }
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return (dx * dx + dy * dy).squareRoot() <= agreementEpsilonPoints
    }

    private static func axSkipReason(_ context: RouteContext) -> PerceptionCore.RouteReason? {
        if context.canvasTarget { return .canvas }
        if context.ownUI { return .ownUI }
        if context.axUnreliable { return .axUnreliable }
        if context.axSparse { return .sparse }
        return nil
    }

    private static func best(
        _ candidates: [PerceptionCore.GroundingCandidate],
        from sources: Set<PerceptionCore.GroundingSource>
    ) -> PerceptionCore.GroundingCandidate? {
        candidates
            .filter { sources.contains($0.source) }
            .max { $0.confidence < $1.confidence }
    }

    private static func tally(
        _ candidates: [PerceptionCore.GroundingCandidate]
    ) -> [PerceptionCore.GroundingSource: Int] {
        candidates.reduce(into: [:]) { counts, candidate in
            counts[candidate.source, default: 0] += 1
        }
    }
}
