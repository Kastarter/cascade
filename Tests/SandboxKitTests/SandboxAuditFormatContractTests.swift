import AgentOrchestrator
import Foundation
import Testing

@testable import SandboxKit

// MARK: - Emitter ↔ reader contracts for the sandbox surface
//
// Mirrors Tests/AppShellTests/AuditFormatContractTests.swift for the
// backgroundWeb emitters: FailureLedger parses the PERSISTED `sandbox.ground`
// / `sandbox.verify` details, so the exact emitter outputs — not raw
// pre-sanitization strings — must carry the tokens the readers need.

@Test
func sandboxGroundDescriptorPersistsTheStructuredSourceToken() {
    let raw = "hit \"search field\" source=dom confidence=0.95 @(200,80)"
    let detail = BackgroundWebAgent.sandboxGroundAuditDescriptor(raw)
    #expect(detail.contains("status=hit"))
    #expect(detail.contains("targetHash="))
    #expect(detail.hasSuffix(" source=dom"))
    // Sanitization is preserved: no raw page/target text survives.
    #expect(!detail.contains("search field"))
}

@Test
func sandboxGroundDescriptorWithoutASourceIsUnchanged() {
    let detail = BackgroundWebAgent.sandboxGroundAuditDescriptor("matched Email")
    #expect(!detail.contains("source="))
    #expect(detail.contains("status=hit"))
    #expect(!detail.contains("Email"))
}

@Test
func sandboxVerifyIncompleteClassifiesAsValidatorIncomplete() {
    // The persisted incomplete-verification format must classify; the
    // verified format must NOT read as a failure.
    let incomplete = BackgroundWebAgent.sandboxVerifyAuditDescriptor(
        status: "incomplete", detail: "form not submitted"
    )
    #expect(
        AgentOrchestrator.AgentFailureKind(auditAction: "sandbox.verify", detail: incomplete)
            == .validatorIncomplete
    )
    let verified = BackgroundWebAgent.sandboxVerifyAuditDescriptor(
        status: "verified", detail: "form submitted"
    )
    #expect(AgentOrchestrator.AgentFailureKind(auditAction: "sandbox.verify", detail: verified) == nil)
}
