import CascadeMemory
import Foundation
import Testing

@testable import AppShell

// §7 `cascade.encryptAtRest` flag WIRING tests (t13, LAW 6): the pure gate
// function and the boot-path branch decision are exercised with injected
// defaults, so a typo'd defaults key or an inverted condition fails in CI —
// without ever constructing a store at the production database path (tests
// inject a store, so `init`'s branch body never runs here; the decision it
// switches on does).

@Test
@MainActor
func encryptAtRestFlagIsDefaultOffAndReadsTheExactKey() {
    let suiteName = "EncryptAtRest-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    // Absent key ⇒ OFF (LAW 3: never registered ON; `bool(forKey:)` on an
    // absent key is false).
    #expect(!CascadeAppModel.encryptAtRestEnabled(defaults: defaults))

    // The LITERAL documented arm key must flip the gate — a typo in
    // `encryptAtRestKey` fails here.
    defaults.set(true, forKey: "cascade.encryptAtRest")
    #expect(CascadeAppModel.encryptAtRestEnabled(defaults: defaults))
    #expect(CascadeAppModel.encryptAtRestKey == "cascade.encryptAtRest")

    // Explicit false ⇒ OFF (no inverted condition).
    defaults.set(false, forKey: CascadeAppModel.encryptAtRestKey)
    #expect(!CascadeAppModel.encryptAtRestEnabled(defaults: defaults))
}

@Test
@MainActor
func encryptionBootDecisionSplitsStructurally() {
    let suiteName = "EncryptAtRestBoot-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    // Flag OFF ⇒ today's plaintext path, regardless of cipher linkage
    // (the shipped default is byte-identical to before the seam existed).
    #expect(CascadeAppModel.encryptionBootDecision(defaults: defaults, cipherLinked: false) == .plaintext)
    #expect(CascadeAppModel.encryptionBootDecision(defaults: defaults, cipherLinked: true) == .plaintext)

    defaults.set(true, forKey: CascadeAppModel.encryptAtRestKey)

    // Flag ON + cipher NOT linked ⇒ visible degradation (LAW 7): plaintext
    // store that structurally reports `.unavailable`.
    #expect(
        CascadeAppModel.encryptionBootDecision(defaults: defaults, cipherLinked: false)
            == .plaintextEncryptionUnavailable
    )

    // Flag ON + cipher linked ⇒ the cipher path — STRUCTURALLY (LAW 1) it can
    // never fall through to a silent plaintext store; today that path throws
    // at boot (SQLCipherEnvelope.prepareConnection) rather than pretend.
    #expect(CascadeAppModel.encryptionBootDecision(defaults: defaults, cipherLinked: true) == .cipher)

    // The production default argument tracks the pinned compile-time gate
    // (`isSQLCipherLinked == false` is pinned by EncryptionAtRestTests), so a
    // flag-ON boot today resolves to the visible-degrade path.
    #expect(
        CascadeAppModel.encryptionBootDecision(defaults: defaults)
            == .plaintextEncryptionUnavailable
    )
}
