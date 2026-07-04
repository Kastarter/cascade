// LEAF TARGET — no package dependencies. See Geometry.swift header.
//
// NAME-COLLISION NOTE (deliberate): ProviderKit declares its own GroundingSource and
// GroundingCandidate (VisualGrounder.swift). Module-local declarations SHADOW imported
// ones in Swift, so any ProviderKit file that imports PerceptionCore and uses these
// names unqualified silently gets the ProviderKit type. Router work must use qualified
// `PerceptionCore.GroundingCandidate` etc. until the old types are retired.

/// Where a grounding candidate came from (plan §3.3 vocabulary).
public enum GroundingSource: String, Sendable, Hashable, Codable {
    case anchor
    case ax
    case syntheticAX
    case ocr
    case visual
    case dom
}

/// Why the grounding router chose the route it did.
public enum RouteReason: String, Sendable, Hashable, Codable {
    case axHit
    case anchorHit
    case canvas
    case ownUI
    case axUnreliable
    case sparse
    case stale
}

/// Structural evidence supporting a grounding candidate.
public enum GroundingEvidence: String, Sendable, Hashable, Codable {
    case roleMatch
    case labelExact
    case ocrOverlap
    case sourceAgreement
}

/// A single candidate location for a named target, in captured-frame space.
public struct GroundingCandidate: Sendable, Equatable, Codable {
    public let point: Point<FrameSpace>
    public let rect: Rect<FrameSpace>?
    public let role: String?
    public let label: String?
    public let targetText: String
    public let source: GroundingSource
    public let confidence: Confidence
    public let evidence: [GroundingEvidence]

    public init(
        point: Point<FrameSpace>,
        rect: Rect<FrameSpace>? = nil,
        role: String? = nil,
        label: String? = nil,
        targetText: String,
        source: GroundingSource,
        confidence: Confidence,
        evidence: [GroundingEvidence] = []
    ) {
        self.point = point
        self.rect = rect
        self.role = role
        self.label = label
        self.targetText = targetText
        self.source = source
        self.confidence = confidence
        self.evidence = evidence
    }
}

/// The router's decision: which candidate (if any) was selected, all candidates
/// considered, and why the route was taken.
public struct GroundingVerdict: Sendable, Equatable, Codable {
    public let selected: GroundingCandidate?
    public let candidates: [GroundingCandidate]
    public let reason: RouteReason

    public init(
        selected: GroundingCandidate?,
        candidates: [GroundingCandidate],
        reason: RouteReason
    ) {
        self.selected = selected
        self.candidates = candidates
        self.reason = reason
    }
}
