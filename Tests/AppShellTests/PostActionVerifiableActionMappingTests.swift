import CoreGraphics
import Foundation
import Testing

@testable import AgentOrchestrator
@testable import AppShell
@testable import CascadeMemory
@testable import ComputerUseKit
@testable import ProviderKit

/// Guards the ProviderKit↔ComputerUseKit token drift: the CUAction →
/// VerifiableAction mapping lives in AppShell (ComputerUseKit cannot import
/// ProviderKit), so these pins are the only thing that keeps the ladder's kind
/// tokens equal to `CUStep.kindToken`. The 320×160pt target rect centered on
/// the action's display-local coordinates is pinned too — a wrong rect OCRs
/// the wrong screen region.
struct PostActionVerifiableActionMappingTests {
    private let display = CGSize(width: 1728, height: 1117)

    @Test func clickMapsToKindTokenAndCenteredTargetRect() {
        let mapped = CascadeAppModel.postActionVerifiableAction(
            for: .click(x: 600, y: 400),
            displaySize: display
        )
        #expect(mapped.kindToken == "click")
        #expect(mapped.typedText == nil)
        #expect(mapped.expectedApp == nil)
        #expect(mapped.targetRect == CGRect(x: 440, y: 320, width: 320, height: 160))
        #expect(mapped.predictedEffect == .visualDelta)
    }

    @Test func edgeClickTargetRectClampsToDisplay() {
        let mapped = CascadeAppModel.postActionVerifiableAction(
            for: .click(x: 10, y: 10),
            displaySize: display
        )
        // Centered rect would start at (-150, -70) — the display clamp keeps
        // the OCR crop on-screen.
        #expect(mapped.targetRect == CGRect(x: 0, y: 0, width: 170, height: 90))
    }

    @Test func typeMapsToTypedTextWithoutTargetRect() {
        let mapped = CascadeAppModel.postActionVerifiableAction(
            for: .type("hello world"),
            displaySize: display
        )
        #expect(mapped.kindToken == "type")
        #expect(mapped.typedText == "hello world")
        #expect(mapped.targetRect == nil)
        #expect(mapped.predictedEffect == .axValue)
    }

    @Test func openAppMapsToExpectedApp() {
        let mapped = CascadeAppModel.postActionVerifiableAction(
            for: .openApp("Keynote"),
            displaySize: display
        )
        #expect(mapped.kindToken == "open_app")
        #expect(mapped.expectedApp == "Keynote")
        #expect(mapped.predictedEffect == .frontmostApp)
    }

    @Test func exemptKindsMapToRungZeroExemption() {
        let exempt: [(CUAction, String)] = [
            (.wait, "wait"),
            (.screenshot, "screenshot"),
            (.zoom(nx: 0, ny: 0, nw: 0.5, nh: 0.5), "zoom"),
            (.highlight(x: 1, y: 1, width: 10, height: 10, label: "here"), "highlight"),
            (.move(x: 5, y: 5), "move"),
        ]
        for (action, token) in exempt {
            let mapped = CascadeAppModel.postActionVerifiableAction(for: action, displaySize: display)
            #expect(mapped.kindToken == token)
            #expect(mapped.predictedEffect == PredictedEffect.none)
        }
    }

    // A ladder FAILED row must carry the SAME postEffect token the shipped
    // OFF-path emits for the identical failure (`mismatch`) so the
    // FailureLedger's detail parser bins it as .effectMismatch — the ledger
    // contract these assist.verify.* rows feed. `postEffect=failed` would
    // silently misclassify AX-readback / frontmost failures as
    // .preconditionFailed.
    @Test func ladderFailedRowClassifiesAsEffectMismatch() {
        let failed = PostActionVerdict(
            status: .failed,
            rung: 1,
            mechanism: "ax_value",
            failureKind: CascadeMemory.AgentFailureKind.verifierRejected,
            evidenceSummary: "typedChars=5 valueChars=20"
        )
        let detail = CascadeAppModel.assistVerifyLadderAuditDetail(
            verdict: failed,
            actionKind: "type",
            evidenceName: "text",
            evidence: "hello",
            skill: nil
        )
        #expect(detail.contains("status=failed"))
        #expect(detail.contains("postEffect=mismatch"))
        #expect(detail.contains("rung=1"))
        #expect(
            AgentOrchestrator.AgentFailureKind(auditAction: "assist.verify.action", detail: detail)
                == .effectMismatch
        )
    }

    // Non-failed ladder verdicts keep their own status token as postEffect and
    // never register as failures in the ledger's detail parser.
    @Test func ladderNonFailedRowsAreNotLedgerFailures() {
        let cases: [(PostActionVerdictStatus, String)] = [
            (.verified, "verified"),
            (.unclear, "unclear"),
            (.exempt, "exempt"),
        ]
        for (status, token) in cases {
            let verdict = PostActionVerdict(
                status: status,
                rung: status == .exempt ? 0 : 3,
                mechanism: status == .exempt ? "predicted_effect" : "image_diff",
                failureKind: nil,
                evidenceSummary: "regions=9"
            )
            let detail = CascadeAppModel.assistVerifyLadderAuditDetail(
                verdict: verdict,
                actionKind: "click",
                evidenceName: "ladder",
                evidence: verdict.evidenceSummary,
                skill: nil
            )
            #expect(detail.contains("postEffect=\(token)"), "status \(token)")
            #expect(
                AgentOrchestrator.AgentFailureKind(auditAction: "assist.verify.action", detail: detail) == nil,
                "status \(token) must not classify as a ledger failure"
            )
        }
    }
}
