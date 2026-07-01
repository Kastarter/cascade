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
    case lowConfidenceGrounding // verifier could not trust the selected target
    case preconditionFailed     // pre-action verifier found the action's precondition false
    case effectMismatch         // process verifier saw the wrong/no post-action effect
    case verifierDisagreement   // independent verifier evidence disagreed
    case stepLimit              // hit the per-episode step cap
    case timeout                // wall-clock budget exceeded
    case userStop               // the user pressed STOP
    case artifactWrongLane      // file work leaked onto the screen lane (or vice versa)

    /// Broad grouping for reporting and dashboards.
    public var category: Category {
        switch self {
        case .wrongStartState, .permissionMissing, .secureInput: .environment
        case .targetNotFound, .groundingMiss, .lowConfidenceGrounding: .grounding
        case .noEffect, .staleFrameBatch, .effectMismatch: .effect
        case .unexpectedModal: .modal
        case .verificationUnavailable, .validatorIncomplete, .preconditionFailed, .verifierDisagreement: .verification
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
        case "recipe.unverified", "assist.noeffect", "sandbox.noeffect", "assist.noeffect.verifier": self = .noEffect
        case "recipe.verify.unavailable": self = .verificationUnavailable
        case "recipe.parameter": self = .parameterNeedsLiveValue
        case "assist.stalled", "sandbox.stalled": self = .stepLimit
        case "agent.action.refused": self = .unsafeActionRefused
        case "agent.ground.miss", "sandbox.ground.miss": self = .groundingMiss
        case "agent.stop", "sandbox.stopped": self = .userStop
        case "agent.secure_input": self = .secureInput
        default: return nil
        }
    }

    /// Detail-aware mapping for audit actions that are emitted for BOTH success and
    /// failure and can only be classified by their detail. `assist.validate` /
    /// `sandbox.verify` carry an `INCOMPLETE: …` detail on failure and `verified: …`
    /// on success; the latter is not a failure. Falls back to the action-only map.
    public init?(auditAction: String, detail: String) {
        switch auditAction {
        case "assist.validate", "sandbox.verify":
            guard detail.uppercased().hasPrefix("INCOMPLETE") else { return nil }
            self = .validatorIncomplete
        case "assist.verify.action":
            guard detail.contains("status=failed") || detail.contains("postEffect=mismatch") else { return nil }
            if detail.contains("failureKind=no_effect") || detail.contains("postEffect=mismatch") {
                self = .effectMismatch
            } else {
                self = .preconditionFailed
            }
        case "grounding.verifier":
            guard detail.contains("verdict=reject") || detail.contains("verdict=abstain") else { return nil }
            if detail.contains("failure=ambiguous") {
                self = .verifierDisagreement
            } else {
                self = .lowConfidenceGrounding
            }
        default:
            guard let kind = AgentFailureKind(auditAction: auditAction) else { return nil }
            self = kind
        }
    }
}
