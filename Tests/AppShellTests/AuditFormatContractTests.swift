import AgentOrchestrator
import CascadeMemory
import Foundation
import Testing

@testable import AppShell

// MARK: - Emitter ↔ reader contracts for the reliability baseline
//
// FailureLedger (AgentOrchestrator) derives its Phase-0 baseline metrics by
// parsing the PERSISTED audit detail formats. These pins tie the shipped
// emitters to the exact tokens the readers parse, so a sanitizer change can
// never again ship a metric that tests green against a raw pre-sanitization
// fixture while reading 100% `unknown` on the user's real audit_event rows
// (the e6e5275 dormant-module shape).

@Test
func groundAuditDetailPersistsTheStructuredSourceToken() {
    // The in-agent ground log (ComputerUseAgent/ScoutAgent appendGroundLog
    // format) is hashed by P7-05/P7-07; the grounding SOURCE must survive as
    // the structured safe-token FailureLedger.groundingSourceShares reads.
    let raw = "hit \"title field\" source=accessibility confidence=0.92 risk=low @(120,340) alternatives=1"
    #expect(
        CascadeAppModel.groundAuditDetail(raw)
            == "\(AuditIdentity.descriptor("ground", raw)) source=accessibility"
    )
}

@Test
func groundAuditDetailWithoutASourceStaysAPureDescriptor() {
    // A miss with no candidate carries no source= token — the persisted row
    // must stay byte-identical to the pre-source format (readers degrade to
    // `unknown`, never guess).
    let raw = "miss \"author box\" risk=low alternatives=0"
    #expect(CascadeAppModel.groundAuditDetail(raw) == AuditIdentity.descriptor("ground", raw))
}

@Test
func groundAuditDetailNeverLeaksRawLogText() {
    let raw = "hit \"Quarterly Payroll — Dr. Amina\" source=ocr confidence=0.61 risk=low @(10,20) alternatives=2"
    let detail = CascadeAppModel.groundAuditDetail(raw)
    #expect(!detail.contains("Quarterly"))
    #expect(!detail.contains("Amina"))
    #expect(detail.hasSuffix("source=ocr"))
}

@Test
func assistValidationAuditDetailClassifiesAsValidatorIncomplete() {
    // THE contract that silently broke between the P7-era sanitized emitter
    // ("status=incomplete …") and the classifier's legacy INCOMPLETE-prefix
    // check: the exact persisted emitter output must classify, or the
    // baseline under-reports every validator failure.
    let detail = CascadeAppModel.assistValidationAuditDetail("subtitle still empty")
    #expect(
        AgentOrchestrator.AgentFailureKind(auditAction: "assist.validate", detail: detail)
            == .validatorIncomplete
    )
    #expect(!detail.contains("subtitle"))
}
