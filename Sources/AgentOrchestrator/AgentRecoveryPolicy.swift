import Foundation

/// What to do next when an action fails. RPA self-healing systems recover by
/// ranked fallback (re-ground, re-capture, alternate locator) rather than one
/// brittle retry; safety failures must never "retry into" the unsafe act.
public enum RecoveryAction: String, Sendable, Equatable, Codable {
    case reharvestAX        // re-read the AX tree and re-rank descriptors
    case regroundVisual     // fall back to OCR / vision grounding
    case recapture          // late-render recapture before re-checking effect
    case alternateTarget    // try a different element / action for the same intent
    case safeDismiss        // dismiss only a KNOWN-safe modal
    case diagnosticProbe    // run a focused probe to disambiguate the failure
    case rerunVerifier      // re-run the completion verifier with focused evidence
    case backoffRetry       // exponential backoff + jitter, then retry
    case retryOnce          // a single bounded retry
    case escalate           // hand off to a stronger agent / assist loop
    case pauseForUser       // stop and surface evidence for a human
    case failWithReason     // give up cleanly with a stated reason
    case refuse             // refuse outright (safety) and audit
    case stop               // honor a user STOP
    case none               // no automatic recovery for this rung

    /// Whether this rung can actually turn a failure into success (used by the
    /// offline eval to model a healing environment). Terminal/refusal rungs can't.
    public var canRecover: Bool {
        switch self {
        case .reharvestAX, .regroundVisual, .recapture, .alternateTarget,
             .safeDismiss, .diagnosticProbe, .rerunVerifier, .backoffRetry, .retryOnce, .escalate:
            true
        case .pauseForUser, .failWithReason, .refuse, .stop, .none:
            false
        }
    }
}

/// The first/second/terminal recovery rungs for a failure kind.
public struct RecoveryPlan: Sendable, Equatable {
    public let first: RecoveryAction
    public let second: RecoveryAction
    public let terminal: RecoveryAction

    public init(first: RecoveryAction = .none, second: RecoveryAction = .none, terminal: RecoveryAction) {
        self.first = first
        self.second = second
        self.terminal = terminal
    }

    /// The ordered non-`none` retry rungs before the terminal action.
    public var retryRungs: [RecoveryAction] {
        [first, second].filter { $0 != .none }
    }
}

/// Maps each failure kind to a typed recovery plan, replacing scattered hard-coded
/// retry behavior with one auditable table (SEQ-06). Safety and user-stop failures
/// have NO retry rungs — they go straight to refuse/stop.
public enum AgentRecoveryPolicy {
    public static func plan(for kind: AgentFailureKind) -> RecoveryPlan {
        switch kind {
        case .targetNotFound:
            RecoveryPlan(first: .reharvestAX, second: .regroundVisual, terminal: .escalate)
        case .groundingMiss:
            RecoveryPlan(first: .reharvestAX, second: .regroundVisual, terminal: .pauseForUser)
        case .noEffect:
            RecoveryPlan(first: .recapture, second: .alternateTarget, terminal: .escalate)
        case .staleFrameBatch:
            RecoveryPlan(first: .recapture, terminal: .escalate)
        case .unexpectedModal:
            RecoveryPlan(first: .safeDismiss, terminal: .pauseForUser)
        case .validatorIncomplete:
            RecoveryPlan(first: .diagnosticProbe, second: .rerunVerifier, terminal: .failWithReason)
        case .verificationUnavailable:
            RecoveryPlan(first: .recapture, terminal: .failWithReason)
        case .transportFailure:
            RecoveryPlan(first: .backoffRetry, second: .retryOnce, terminal: .failWithReason)
        case .unsafeActionRefused:
            RecoveryPlan(terminal: .refuse)
        case .userStop:
            RecoveryPlan(terminal: .stop)
        case .wrongStartState, .permissionMissing, .secureInput:
            RecoveryPlan(terminal: .pauseForUser)
        case .parameterNeedsLiveValue, .artifactWrongLane:
            RecoveryPlan(terminal: .failWithReason)
        case .stepLimit, .timeout:
            RecoveryPlan(terminal: .failWithReason)
        }
    }
}
