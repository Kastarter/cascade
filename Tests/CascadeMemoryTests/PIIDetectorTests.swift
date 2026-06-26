import CascadeMemory
import Foundation
import Testing

// MARK: - Detection

@Test
func detectsEmail() {
    let found = PIIDetector.findings(in: "Reach me at jane.doe+work@example.co.uk anytime.")
    #expect(found.contains { $0.type == .email && $0.text == "jane.doe+work@example.co.uk" })
}

@Test
func detectsCreditCardOnlyWhenLuhnValid() {
    // 4242 4242 4242 4242 is a canonical Luhn-valid test card.
    let valid = PIIDetector.findings(in: "card 4242 4242 4242 4242 exp 12/29")
    #expect(valid.contains { $0.type == .creditCard })
    // A same-length number that fails Luhn must NOT be flagged as a card.
    let invalid = PIIDetector.findings(in: "order 1234 5678 9012 3456 shipped")
    #expect(!invalid.contains { $0.type == .creditCard })
}

@Test
func detectsSSNAndIBANAndApiKey() {
    let ssn = PIIDetector.findings(in: "SSN 123-45-6789 on file")
    #expect(ssn.contains { $0.type == .ssn })
    let iban = PIIDetector.findings(in: "IBAN DE89370400440532013000 please")
    #expect(iban.contains { $0.type == .iban })
    let key = PIIDetector.findings(in: "export OPENAI_API_KEY=sk-abcdefghijklmnopqrstuvwxyz012345")
    #expect(key.contains { $0.type == .apiKey })
}

@Test
func detectsIPAddress() {
    let found = PIIDetector.findings(in: "server at 192.168.1.254 responded")
    #expect(found.contains { $0.type == .ipAddress })
    // 999.x is not a valid octet and must not match.
    let bad = PIIDetector.findings(in: "version 999.168.1.254 build")
    #expect(!bad.contains { $0.type == .ipAddress })
}

@Test
func plainTextHasNoFindings() {
    #expect(PIIDetector.findings(in: "Approved the quarterly cascade and ran agent twice.").isEmpty)
    #expect(!PIIDetector.containsHighConfidencePII("ran agent on Finder window"))
}

// MARK: - Redaction

@Test
func redactionReplacesWithTypedPlaceholdersAndLeavesNoRawPII() {
    let raw = "Email jane@example.com, card 4242 4242 4242 4242, key sk-abcdefghijklmnopqrstuvwxyz012345"
    let (redacted, findings) = PIIDetector.redact(raw)
    #expect(redacted.contains("<EMAIL>"))
    #expect(redacted.contains("<CREDIT_CARD>"))
    #expect(redacted.contains("<API_KEY>"))
    #expect(!redacted.contains("jane@example.com"))
    #expect(!redacted.contains("4242 4242 4242 4242"))
    #expect(!redacted.contains("sk-abcdefghijklmnopqrstuvwxyz012345"))
    #expect(findings.count == 3)
}

@Test
func redactionHighConfidenceOnlyLeavesLowConfidenceText() {
    // Names are low-confidence and off by default — ordinary prose is untouched.
    let (redacted, _) = PIIDetector.redact("Sarah opened the Notes app")
    #expect(redacted == "Sarah opened the Notes app")
}

@Test
func containsHighConfidenceDetectsSecretsButNotProse() {
    #expect(PIIDetector.containsHighConfidencePII("token sk-abcdefghijklmnopqrstuvwxyz012345"))
    #expect(!PIIDetector.containsHighConfidencePII("opened the spreadsheet and saved it"))
}

// MARK: - Audit integration

@Test
func auditDetailIsRedactedAndChainStillVerifies() async throws {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("CascadePII-\(UUID().uuidString).sqlite").path
    let store = try CascadeStore(path: path)
    let stored = try await store.appendAudit(
        AuditEvent(actor: "agent", action: "harness.read_file", detail: "leaked jane@example.com from notes")
    )
    #expect(stored.detail.contains("<EMAIL>"))
    #expect(!stored.detail.contains("jane@example.com"))
    let recent = try await store.recentAudit(limit: 5)
    #expect(recent.allSatisfy { !$0.detail.contains("jane@example.com") })
    #expect(try await store.verifyAuditChain() == .intact(verified: 1))
}
