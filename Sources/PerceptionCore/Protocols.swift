// LEAF TARGET — `import Foundation` is SDK-only (for Date), not a package dependency.
//
// NAME-COLLISION NOTE (deliberate): PerceptionCore.VerificationOracle collides with
// ComputerUseKit's VerificationOracle (PostActionVerifier.swift) by design; any file
// importing both must qualify. Only later boundary tasks will face this.

import Foundation

/// Minimal query shape a perception source resolves.
public struct TargetQuery: Sendable, Hashable, Codable {
    public let text: String
    public let role: String?

    public init(text: String, role: String? = nil) {
        self.text = text
        self.role = role
    }
}

/// A reference to a captured frame (fleshed out by later tasks).
public struct FrameRef: Sendable, Hashable, Codable {
    public let id: String
    public let capturedAt: Date?

    public init(id: String, capturedAt: Date? = nil) {
        self.id = id
        self.capturedAt = capturedAt
    }
}

/// Minimal snapshot of the perceived state a query runs against
/// (fleshed out by later tasks).
public struct PerceptionSnapshot: Sendable {
    public let app: AppTarget?
    public let frame: FrameRef?
    public let axRichness: Int?

    public init(app: AppTarget? = nil, frame: FrameRef? = nil, axRichness: Int? = nil) {
        self.app = app
        self.frame = frame
        self.axRichness = axRichness
    }
}

/// A cheap, comparable signature of the current UI state.
public struct StateSignature: Sendable, Hashable, Codable {
    public let kind: String
    public let value: String

    public init(kind: String, value: String) {
        self.kind = kind
        self.value = value
    }
}

/// What an action is expected to change on screen.
public struct PredictedEffect: Sendable, Equatable {
    public let detail: String
    public let targetRect: Rect<FrameSpace>?

    public init(detail: String, targetRect: Rect<FrameSpace>? = nil) {
        self.detail = detail
        self.targetRect = targetRect
    }
}

/// Outcome of a post-action verification pass.
public enum VerifyOutcome: Sendable, Hashable, Codable {
    case effect
    case noEffect
    case unclear
}

/// Produces grounding candidates for a named target against a snapshot.
public protocol PerceptionSource: Sendable {
    func candidates(for query: TargetQuery, in snapshot: PerceptionSnapshot) async -> [GroundingCandidate]
}

/// Provides UI state signatures, including the settle re-check seam
/// (the 336263d 400ms slow-render re-check). Sendable: providers are consumed
/// across async boundaries (e.g. a reliability kernel awaiting a signature).
public protocol StateSignatureProvider: Sendable {
    func signature() async -> StateSignature
    func settleRecheck(after: Duration) async -> Bool
}

/// Verifies whether an action produced its predicted effect.
/// NAME-collides with ComputerUseKit.VerificationOracle by design — qualify when both
/// modules are imported.
public protocol VerificationOracle: Sendable {
    func verify(
        action: ActionDescriptor,
        before: FrameRef,
        after: FrameRef,
        expectation: PredictedEffect?
    ) async -> VerifyOutcome
}
