import CoreGraphics
import Foundation
import PerceptionCore

// MARK: - PerceptionSource adapters over today's grounder output
//
// Bridges ProviderKit's live grounding shapes (GroundingCandidate/GroundingSource
// from VisualGrounder.swift) into PerceptionCore's typed vocabulary so the
// GroundingRouter can route over the SAME evidence the live path scored.
//
// ┌─────────────────────────────────────────────────────────────────────────────┐
// │ SHADOW-ONLY FrameSpace TAGGING CARVE-OUT (named risk — read before reuse):  │
// │ PerceptionCore.GroundingCandidate pins its geometry to Point<FrameSpace>,   │
// │ but the live MixtureGrounder candidates carry display-local AppKit points   │
// │ (bottom-left origin). This bridge NUMERICALLY RE-TAGS those values into     │
// │ FrameSpace without converting. That is safe ONLY because the router's       │
// │ verdict is audit-only (never actuated) and BOTH sides of the shadow parity  │
// │ comparison come from the same numbers, so the comparison is internally      │
// │ consistent. Before the router ever ROUTES live, these points must be        │
// │ re-plumbed through the real CoordinateTransform at the actuator boundary.   │
// └─────────────────────────────────────────────────────────────────────────────┘
//
// NAME-COLLISION NOTE: inside ProviderKit, unqualified GroundingCandidate /
// GroundingSource bind ProviderKit's OWN types (module-local declarations shadow
// imports) — every PerceptionCore reference below is fully qualified on purpose.

/// Static bridging from ProviderKit grounding shapes to PerceptionCore's.
public enum PerceptionCandidateBridge {
    /// Maps a ProviderKit source lane to the plan's §3.3 vocabulary. Lanes with
    /// no faithful perception meaning (cache/compatibility/unknown) map to nil —
    /// degrade to MISSED, never FALSE (LAW 7).
    public static func perceptionSource(
        _ source: GroundingSource
    ) -> PerceptionCore.GroundingSource? {
        switch source {
        case .accessibility:
            return .ax
        case .dom:
            return .dom
        case .ocr:
            return .ocr
        case .uiTars, .claude, .visualModel:
            return .visual
        case .cache, .compatibility, .unknown:
            return nil
        }
    }

    /// Bridges one live candidate. Returns nil when the source has no perception
    /// lane or the candidate carries no point (nothing to route on).
    public static func perceptionCandidate(
        from candidate: GroundingCandidate,
        targetText: String
    ) -> PerceptionCore.GroundingCandidate? {
        guard let source = perceptionSource(candidate.source) else { return nil }
        guard let point = candidate.point else { return nil }
        // SHADOW-ONLY re-tag: display-local numbers stamped as FrameSpace — see
        // the carve-out box in this file's header.
        let framePoint = PerceptionCore.Point<PerceptionCore.FrameSpace>(
            x: Double(point.x),
            y: Double(point.y)
        )
        let frameRect: PerceptionCore.Rect<PerceptionCore.FrameSpace>? =
            (candidate.displayBounds ?? candidate.region).map { rect in
                PerceptionCore.Rect<PerceptionCore.FrameSpace>(
                    x: Double(rect.origin.x),
                    y: Double(rect.origin.y),
                    width: Double(rect.width),
                    height: Double(rect.height)
                )
            }
        var evidence: [PerceptionCore.GroundingEvidence] = []
        if !candidate.agreeingSources.isEmpty { evidence.append(.sourceAgreement) }
        return PerceptionCore.GroundingCandidate(
            point: framePoint,
            rect: frameRect,
            role: candidate.role,
            label: candidate.label ?? candidate.rawModel,
            targetText: targetText,
            source: source,
            confidence: PerceptionCore.Confidence(clamping: candidate.confidence),
            evidence: evidence
        )
    }
}

/// A `PerceptionSource` over the ALREADY-COMPUTED candidate array from the live
/// `groundResult` call, filtered to one lane. The shadow router deliberately
/// consumes the SAME frozen evidence the live path scored, so a divergence row
/// measures ROUTING POLICY, never AX re-sample flicker (b40ede8 discipline).
public struct FrozenCandidatePerceptionSource: PerceptionCore.PerceptionSource {
    private let frozen: [PerceptionCore.GroundingCandidate]

    private init(frozen: [PerceptionCore.GroundingCandidate]) {
        self.frozen = frozen
    }

    /// AX lane: candidates whose bridged source is `.ax`.
    public static func ax(
        _ candidates: [GroundingCandidate],
        target: String
    ) -> FrozenCandidatePerceptionSource {
        lane([.ax], candidates: candidates, target: target)
    }

    /// OCR lane: candidates whose bridged source is `.ocr`.
    public static func ocr(
        _ candidates: [GroundingCandidate],
        target: String
    ) -> FrozenCandidatePerceptionSource {
        lane([.ocr], candidates: candidates, target: target)
    }

    /// Visual lane: candidates whose bridged source is `.visual`
    /// (uiTars/claude/visualModel).
    public static func visual(
        _ candidates: [GroundingCandidate],
        target: String
    ) -> FrozenCandidatePerceptionSource {
        lane([.visual], candidates: candidates, target: target)
    }

    private static func lane(
        _ sources: Set<PerceptionCore.GroundingSource>,
        candidates: [GroundingCandidate],
        target: String
    ) -> FrozenCandidatePerceptionSource {
        FrozenCandidatePerceptionSource(
            frozen: candidates
                .compactMap { PerceptionCandidateBridge.perceptionCandidate(from: $0, targetText: target) }
                .filter { sources.contains($0.source) }
        )
    }

    public func candidates(
        for query: PerceptionCore.TargetQuery,
        in snapshot: PerceptionCore.PerceptionSnapshot
    ) async -> [PerceptionCore.GroundingCandidate] {
        frozen
    }
}

extension GroundingRouter {
    /// Shadow entry point for MixtureGrounder: wraps the live call's frozen
    /// candidate array in the three lane adapters and routes. Lives in ProviderKit
    /// so AppShell callers never have to name PerceptionCore types (which would
    /// collide with ProviderKit's own GroundingCandidate/GroundingSource at every
    /// existing unqualified use site).
    public static func shadowDecision(
        candidates: [GroundingCandidate],
        target: String,
        context: RouteContext
    ) async -> RouteDecision {
        let router = GroundingRouter(sources: [
            FrozenCandidatePerceptionSource.ax(candidates, target: target),
            FrozenCandidatePerceptionSource.ocr(candidates, target: target),
            FrozenCandidatePerceptionSource.visual(candidates, target: target),
        ])
        return await router.route(
            query: PerceptionCore.TargetQuery(text: target),
            snapshot: PerceptionCore.PerceptionSnapshot(),
            context: context
        )
    }
}
