import CoreGraphics
import Foundation

import CascadeMemory
import MacContextKit

// MARK: - §4a VERIFY — the cheapest-first post-action verification ladder.
//
// Pure logic + injected probes: the verifier itself never captures the screen,
// never touches AppKit, and never persists anything. The caller (AppShell)
// builds the real probes and appends the assist.verify.* audit rows — those
// rows ARE the FailureLedger's feed.
//
// Ladder (first definitive verdict wins):
//   0. STRUCTURAL predicted-effect exemption — from the action KIND, never a
//      model self-report (152df62). wait/screenshot/zoom/highlight/move change
//      nothing by design, so "unchanged" is correct, not a failure.
//   1. MECHANISM — AX value read-back for typing (.verified REQUIRES the value
//      reflect the text, abd97e6), frontmost fingerprint for app switches,
//      file-exists for saves. Free, exact, AX-first (LAW 2).
//   2. OCR text delta on the target rect — bounded on-demand Vision, zero
//      model calls.
//   3. Image diff LAST — ambiguous ⇒ "unclear", NEVER "failed" (85f945a);
//      degrade to MISSED, never FALSE (LAW 7).

/// The verification contract — shaped exactly like the plan's §3 protocol so a
/// future PerceptionCore can adopt it verbatim.
public protocol VerificationOracle: Sendable {
    func verify(_ action: VerifiableAction, evidence: PostActionEvidence) async -> PostActionVerdict
}

/// Module-neutral descriptor of the action just executed. Every field is
/// derived STRUCTURALLY from the action itself by the caller — NO field can
/// carry a model-reported effect (152df62: the model must never grade its own
/// homework).
public struct VerifiableAction: Sendable, Equatable {
    /// Same tokens as `CUStep.kindToken`: click / double_click / triple_click /
    /// right_click / drag / type / key / scroll / wait / screenshot / open_app /
    /// open_url / zoom / highlight / move.
    public let kindToken: String
    /// The literal text a `type` action delivered — read back via AX at rung 1.
    public let typedText: String?
    /// The app an `open_app` action named — matched against the frontmost
    /// fingerprint at rung 1.
    public let expectedApp: String?
    /// A file a save-shaped action should have produced — checked with
    /// FileManager at rung 1. Presence is structural (set by the caller from
    /// known context), never model-claimed.
    public let expectedFileURL: URL?
    /// Display-local AppKit rect (bottom-left origin) around the action's
    /// coordinates — the bounded region rung 2 OCRs.
    public let targetRect: CGRect?

    public init(
        kindToken: String,
        typedText: String? = nil,
        expectedApp: String? = nil,
        expectedFileURL: URL? = nil,
        targetRect: CGRect? = nil
    ) {
        self.kindToken = kindToken
        self.typedText = typedText
        self.expectedApp = expectedApp
        self.expectedFileURL = expectedFileURL
        self.targetRect = targetRect
    }
}

/// What kind of observable effect an action kind predicts — the STRUCTURAL
/// rung-0/rung-1 source (152df62). Derived from the action kind alone.
public enum PredictedEffect: Sendable, Equatable {
    case none
    case axValue
    case frontmostApp
    case fileExists
    case visualDelta
}

extension VerifiableAction {
    /// Pure switch on the kind token — TOTAL over every token `CUStep` emits.
    /// This is the structural rung-0 source: an exempt kind is exempt because
    /// of what the action IS, never because the model said so.
    public static func predictedEffect(forKind kindToken: String) -> PredictedEffect {
        switch kindToken {
        case "wait", "screenshot", "zoom", "highlight", "move":
            return .none
        case "type":
            return .axValue
        case "open_app":
            return .frontmostApp
        default:
            // click / double_click / triple_click / right_click / drag / key /
            // scroll / open_url — and any future kind — predict a visual delta.
            return .visualDelta
        }
    }

    /// The effect this specific descriptor predicts. A structural save target
    /// (expectedFileURL) upgrades the mechanism to a file-exists probe.
    public var predictedEffect: PredictedEffect {
        if expectedFileURL != nil { return .fileExists }
        return Self.predictedEffect(forKind: kindToken)
    }
}

/// The ladder never produces an "unavailable" status: a missing/unreadable
/// probe is not a verdict, it degrades DOWN the ladder, and rung-3 ambiguity
/// (including no evidence at all) terminates as `unclear` (LAW 7 — degrade to
/// MISSED, never FALSE).
public enum PostActionVerdictStatus: String, Sendable, Equatable {
    case verified
    case failed
    case unclear
    case exempt
}

public struct PostActionVerdict: Sendable, Equatable {
    public let status: PostActionVerdictStatus
    /// Which ladder rung produced the verdict (0–3).
    public let rung: Int
    /// The mechanism that decided: predicted_effect / ax_value /
    /// frontmost_fingerprint / file_exists / ocr_delta / image_diff.
    public let mechanism: String
    public let failureKind: CascadeMemory.AgentFailureKind?
    /// Audit-safe summary — counts and tokens only, never raw screen text.
    public let evidenceSummary: String

    public init(
        status: PostActionVerdictStatus,
        rung: Int,
        mechanism: String,
        failureKind: CascadeMemory.AgentFailureKind?,
        evidenceSummary: String
    ) {
        self.status = status
        self.rung = rung
        self.mechanism = mechanism
        self.failureKind = failureKind
        self.evidenceSummary = evidenceSummary
    }
}

/// Injected probes — the caller decides HOW to observe; the verifier decides
/// WHAT the observations mean. Probe errors surface as nil and degrade DOWN
/// the ladder (MISSED, never FALSE — LAW 7). `ocrBefore` is captured
/// pre-action and held in-memory only, never persisted (§7 carve-out).
public struct PostActionEvidence: Sendable {
    public let readFocusedAXValue: @Sendable () async -> String?
    public let frontmostFingerprint: @Sendable () -> (name: String?, bundle: String?)
    public let fileExists: @Sendable (URL) -> Bool
    public let ocrBefore: String?
    public let ocrAfter: @Sendable (CGRect) async -> String?
    public let gridHashesBefore: [UInt64]?
    public let gridHashesAfter: [UInt64]?

    public init(
        readFocusedAXValue: @escaping @Sendable () async -> String? = { nil },
        frontmostFingerprint: @escaping @Sendable () -> (name: String?, bundle: String?) = { (nil, nil) },
        fileExists: @escaping @Sendable (URL) -> Bool = { _ in false },
        ocrBefore: String? = nil,
        ocrAfter: @escaping @Sendable (CGRect) async -> String? = { _ in nil },
        gridHashesBefore: [UInt64]? = nil,
        gridHashesAfter: [UInt64]? = nil
    ) {
        self.readFocusedAXValue = readFocusedAXValue
        self.frontmostFingerprint = frontmostFingerprint
        self.fileExists = fileExists
        self.ocrBefore = ocrBefore
        self.ocrAfter = ocrAfter
        self.gridHashesBefore = gridHashesBefore
        self.gridHashesAfter = gridHashesAfter
    }
}

/// The ladder. Cheapest-first, first definitive verdict wins, rung-3 ambiguity
/// is "unclear" NEVER "failed" (85f945a).
public struct PostActionVerifier: VerificationOracle {
    public init() {}

    public func verify(_ action: VerifiableAction, evidence: PostActionEvidence) async -> PostActionVerdict {
        // Rung 0 — structural exemption. Decided from the kind alone, BEFORE
        // any probe runs (an exempt action must cost zero observation work).
        if VerifiableAction.predictedEffect(forKind: action.kindToken) == .none {
            return PostActionVerdict(
                status: .exempt,
                rung: 0,
                mechanism: "predicted_effect",
                failureKind: nil,
                evidenceSummary: "kind=\(action.kindToken)"
            )
        }

        // Rung 1 — mechanism probes (free + exact; AX-first, LAW 2).
        switch action.predictedEffect {
        case .fileExists:
            if let url = action.expectedFileURL {
                let exists = evidence.fileExists(url)
                return PostActionVerdict(
                    status: exists ? .verified : .failed,
                    rung: 1,
                    mechanism: "file_exists",
                    failureKind: exists ? nil : .verifierRejected,
                    evidenceSummary: "kind=\(action.kindToken) fileExists=\(exists)"
                )
            }
        case .axValue:
            let trimmed = (action.typedText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, let value = await evidence.readFocusedAXValue() {
                // abd97e6: .verified REQUIRES the read-back value reflect the
                // text — an accepted-but-invisible write is a FAILURE here,
                // because the value WAS readable and does not contain it.
                let reflected = value.contains(trimmed)
                return PostActionVerdict(
                    status: reflected ? .verified : .failed,
                    rung: 1,
                    mechanism: "ax_value",
                    failureKind: reflected ? nil : .verifierRejected,
                    evidenceSummary: "typedChars=\(trimmed.count) valueChars=\(value.count)"
                )
            }
            // Unreadable focused value (canvas app, no AX) → the mechanism is
            // MISSING, not failed — fall to rung 2.
        case .frontmostApp:
            if let expected = action.expectedApp {
                let front = evidence.frontmostFingerprint()
                if front.name != nil || front.bundle != nil {
                    let matched = Self.fingerprintMatches(
                        name: front.name,
                        bundle: front.bundle,
                        expectedApp: expected
                    )
                    return PostActionVerdict(
                        status: matched ? .verified : .failed,
                        rung: 1,
                        mechanism: "frontmost_fingerprint",
                        failureKind: matched ? nil : .wrongStartState,
                        evidenceSummary: "expectedChars=\(expected.count) matched=\(matched)"
                    )
                }
                // No frontmost readable at all → fall down the ladder.
            }
        case .none, .visualDelta:
            break
        }

        // Rung 2 — bounded OCR text delta on the target rect (zero model
        // calls). Either probe missing → fall through; identical text also
        // falls through (a real change can be non-textual).
        if let before = evidence.ocrBefore,
           let rect = action.targetRect,
           let after = await evidence.ocrAfter(rect) {
            if after != before {
                return PostActionVerdict(
                    status: .verified,
                    rung: 2,
                    mechanism: "ocr_delta",
                    failureKind: nil,
                    evidenceSummary: "beforeChars=\(before.count) afterChars=\(after.count)"
                )
            }
        }

        // Rung 3 — image diff LAST. A changed frame verifies; an unchanged or
        // unhashable frame is AMBIGUOUS (render lag, off-rect change, missing
        // capture) ⇒ "unclear", NEVER "failed" (85f945a / LAW 7).
        if let before = evidence.gridHashesBefore, let after = evidence.gridHashesAfter {
            if !PerceptualHash.isDuplicateGrid(after, of: before, threshold: 2) {
                return PostActionVerdict(
                    status: .verified,
                    rung: 3,
                    mechanism: "image_diff",
                    failureKind: nil,
                    evidenceSummary: "regions=\(before.count) changed=true"
                )
            }
            return PostActionVerdict(
                status: .unclear,
                rung: 3,
                mechanism: "image_diff",
                failureKind: nil,
                evidenceSummary: "regions=\(before.count) changed=false"
            )
        }
        return PostActionVerdict(
            status: .unclear,
            rung: 3,
            mechanism: "image_diff",
            failureKind: nil,
            evidenceSummary: "hashes=missing"
        )
    }

    /// Containment either direction, the proven `openApp` poll semantics —
    /// "Keynote" vs "Keynote Creator Studio" must match.
    static func fingerprintMatches(name: String?, bundle: String?, expectedApp: String) -> Bool {
        let expected = expectedApp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expected.isEmpty else { return false }
        if let name, !name.isEmpty,
           name.localizedCaseInsensitiveContains(expected) || expected.localizedCaseInsensitiveContains(name) {
            return true
        }
        if let bundle, bundle.caseInsensitiveCompare(expected) == .orderedSame {
            return true
        }
        return false
    }
}
