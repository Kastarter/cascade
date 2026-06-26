import Foundation

/// A typed taxonomy of the ways an agent action / replay / assist turn can fail.
///
/// Cascade already emits rich audit events (`recipe.pause.modal`, `assist.noeffect`,
/// `agent.action.refused`, …) and has strong per-step safeguards, but failures were
/// never *aggregatable*: you couldn't ask "what fraction failed, and why." This enum
/// gives every failure a stable kind so reliability becomes a number, not a vibe.
/// Seeded from the agent-eval literature (OSWorld / WebArena failure analyses,
/// SEQ-06).
public enum AgentFailureKind: String, Sendable, Equatable, CaseIterable, Codable {
    case wrongStartState        // replay began in the wrong app/window/state
    case permissionMissing      // Screen Recording / Accessibility / Input not granted
    case secureInput            // macOS Secure Input blocked synthetic keystrokes
    case targetNotFound         // the element to act on couldn't be located at all
    case groundingMiss          // located the wrong element / low-confidence ground
    case noEffect               // the action posted but the UI didn't change
    case staleFrameBatch        // batched actions raced ahead of a slow repaint
    case unexpectedModal        // an unanticipated sheet/dialog interrupted the run
    case verificationUnavailable // couldn't read state to verify the step
    case validatorIncomplete    // a completion verifier couldn't confirm the goal
    case transportFailure       // network/model/IPC transport error
    case unsafeActionRefused    // a guardrail refused an irreversible/destructive act
    case parameterNeedsLiveValue // a replay step needed a fresh value it couldn't trust
    case stepLimit              // hit the per-episode step cap
    case timeout                // wall-clock budget exceeded
    case userStop               // the user pressed STOP
    case artifactWrongLane      // file work leaked onto the screen lane (or vice versa)

    /// Broad grouping for reporting and dashboards.
    public var category: Category {
        switch self {
        case .wrongStartState, .permissionMissing, .secureInput: .environment
        case .targetNotFound, .groundingMiss: .grounding
        case .noEffect, .staleFrameBatch: .effect
        case .unexpectedModal: .modal
        case .verificationUnavailable, .validatorIncomplete: .verification
        case .transportFailure: .transport
        case .unsafeActionRefused: .safety
        case .parameterNeedsLiveValue, .artifactWrongLane: .policy
        case .stepLimit, .timeout: .limit
        case .userStop: .user
        }
    }

    public enum Category: String, Sendable, Codable {
        case environment, grounding, effect, modal, verification, transport, safety, policy, limit, user
    }

    /// Refusing an unsafe action or honoring STOP is a *correct* terminal outcome,
    /// not a reliability defect — reports must not count these against success.
    public var isDesirableTerminal: Bool {
        self == .unsafeActionRefused || self == .userStop
    }

    /// Map a Cascade audit `action` string to a failure kind, when it denotes one.
    /// Returns nil for audit actions that aren't failures (e.g. `agent.run.completed`).
    public init?(auditAction: String) {
        switch auditAction {
        case "recipe.pause.wrongstate": self = .wrongStartState
        case "recipe.pause.modal": self = .unexpectedModal
        case "recipe.unverified", "assist.noeffect", "sandbox.noeffect": self = .noEffect
        case "recipe.verify.unavailable": self = .verificationUnavailable
        case "recipe.parameter": self = .parameterNeedsLiveValue
        case "assist.stalled", "sandbox.stalled": self = .stepLimit
        case "agent.action.refused": self = .unsafeActionRefused
        case "agent.ground.miss", "sandbox.ground.miss": self = .groundingMiss
        case "agent.stop", "sandbox.stopped": self = .userStop
        default: return nil
        }
    }
}
