import CascadeMemory
import Foundation
import SQLite3
import Testing

private func makeStore() throws -> (CascadeStore, String) {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("CascadeAudit-\(UUID().uuidString).sqlite").path
    return (try CascadeStore(path: path), path)
}

/// Tampers with the DB file through a second connection, the way a local
/// attacker or compromised process would — bypassing the store's append path.
private func rawExec(_ path: String, _ sql: String) {
    var db: OpaquePointer?
    guard sqlite3_open(path, &db) == SQLITE_OK else { return }
    defer { sqlite3_close(db) }
    sqlite3_exec(db, sql, nil, nil, nil)
}

// MARK: - Pure chain math

@Test
func auditHashIsDeterministicAndSensitive() {
    let canonical = AuditChain.canonicalForm(createdAt: "t", actor: "x", action: "agent.run", detail: "d")
    let a = AuditChain.hash(prev: AuditChain.genesis, canonical: canonical)
    let b = AuditChain.hash(prev: AuditChain.genesis, canonical: canonical)
    let changed = AuditChain.canonicalForm(createdAt: "t", actor: "x", action: "agent.run", detail: "D")
    let c = AuditChain.hash(prev: AuditChain.genesis, canonical: changed)
    #expect(a == b)                 // deterministic
    #expect(a != c)                 // sensitive to any field
    #expect(a.count == 64)          // hex SHA-256
    // A different predecessor yields a different hash even for identical content.
    #expect(AuditChain.hash(prev: a, canonical: canonical) != a)
}

// MARK: - Store-level chain

@Test
func emptyAuditChainReportsEmpty() async throws {
    let (store, _) = try makeStore()
    #expect(try await store.verifyAuditChain() == .empty)
}

@Test
func unchainedOnlyAuditRowsAreUntrusted() async throws {
    let (_, path) = try makeStore()
    rawExec(path, """
    INSERT INTO audit_event (created_at, actor, action, detail)
    VALUES ('2026-06-26T00:00:00.000Z','legacy','legacy.only','one');
    INSERT INTO audit_event (created_at, actor, action, detail)
    VALUES ('2026-06-26T00:00:01.000Z','legacy','legacy.only','two');
    """)

    let fresh = try CascadeStore(path: path)
    if case .unchained(let firstID) = try await fresh.verifyAuditChain() {
        #expect(firstID == 1)
    } else {
        Issue.record("expected non-empty unchained rows to be untrusted, not empty")
    }
    #expect(try await fresh.recentChainedAudit(limit: 10).isEmpty)
}

@Test
func appendedAuditRowsFormAnIntactChain() async throws {
    let (store, _) = try makeStore()
    for detail in ["opened reel", "ran agent", "approved cascade", "exported audit"] {
        _ = try await store.appendAudit(AuditEvent(actor: "employee", action: "ui.action", detail: detail))
    }
    #expect(try await store.verifyAuditChain() == .intact(verified: 4))
    #expect(try await store.latestAuditHash() != nil)
}

@Test
func mutatingAnAuditRowBreaksTheChain() async throws {
    let (store, path) = try makeStore()
    var ids: [Int64] = []
    for detail in ["a", "b", "c"] {
        ids.append(try await store.appendAudit(AuditEvent(actor: "x", action: "y", detail: detail)).id)
    }
    rawExec(path, "UPDATE audit_event SET detail='HACKED' WHERE id=\(ids[1]);")

    let fresh = try CascadeStore(path: path)
    if case .broken(let atID) = try await fresh.verifyAuditChain() {
        #expect(atID == ids[1])
    } else {
        Issue.record("expected a broken chain after a row was mutated")
    }
}

// MARK: - External anchor (truncation / wholesale rewrite)

@Test
func canonicalFormIsUnambiguousAcrossFieldSplits() {
    // Length-prefixing must make these two distinct events hash differently even
    // though a naive separator-join would collide.
    let a = AuditChain.canonicalForm(createdAt: "t", actor: "x", action: "a", detail: "b\u{1f}c")
    let b = AuditChain.canonicalForm(createdAt: "t", actor: "x", action: "a\u{1f}b", detail: "c")
    #expect(a != b)
}

@Test
func truncatingTheChainTailIsDetectedViaAnchor() async throws {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("CascadeAnchor-\(UUID().uuidString).sqlite").path
    let anchor = InMemoryAuditAnchor()
    let store = try CascadeStore(path: path, auditAnchor: anchor)
    for detail in ["a", "b", "c"] {
        _ = try await store.appendAudit(AuditEvent(actor: "x", action: "y", detail: detail))
    }
    // Internal chain alone would still look intact after a tail delete.
    rawExec(path, "DELETE FROM audit_event WHERE id = (SELECT max(id) FROM audit_event);")

    let fresh = try CascadeStore(path: path, auditAnchor: anchor)
    if case .truncated(let expected, let found) = try await fresh.verifyAuditChain() {
        #expect(expected == 3)
        #expect(found == 2)
    } else {
        Issue.record("expected truncation to be caught by the out-of-band anchor")
    }
}

@Test
func forgedUnchainedRowAfterTheChainIsDetected() async throws {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("CascadeForge-\(UUID().uuidString).sqlite").path
    let anchor = InMemoryAuditAnchor()
    let store = try CascadeStore(path: path, auditAnchor: anchor)
    for detail in ["a", "b"] {
        _ = try await store.appendAudit(AuditEvent(actor: "x", action: "y", detail: detail))
    }
    // A row inserted with NULL hashes after the chain has begun is a forgery.
    rawExec(path, "INSERT INTO audit_event (created_at, actor, action, detail) VALUES ('2026-06-26T00:00:00Z','x','y','forged');")

    let fresh = try CascadeStore(path: path, auditAnchor: anchor)
    if case .broken = try await fresh.verifyAuditChain() {} else {
        Issue.record("expected a forged unchained row after the chain to be broken")
    }
}

@Test
func appendingRowsOutsideTheTrustedPathIsCaughtByTheAnchor() async throws {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("CascadeRewrite-\(UUID().uuidString).sqlite").path
    let anchor = InMemoryAuditAnchor()
    let store = try CascadeStore(path: path, auditAnchor: anchor)
    for detail in ["a", "b", "c"] {
        _ = try await store.appendAudit(AuditEvent(actor: "x", action: "y", detail: detail))
    }
    // An attacker appends an internally-VALID extra row, but without the anchor
    // (NullAuditAnchor default) — so the trusted head still says count == 3.
    let attacker = try CascadeStore(path: path)
    _ = try await attacker.appendAudit(AuditEvent(actor: "x", action: "y", detail: "forged-but-valid"))

    let fresh = try CascadeStore(path: path, auditAnchor: anchor)
    if case .truncated(let expected, let found) = try await fresh.verifyAuditChain() {
        #expect(expected == 3)
        #expect(found == 4)
    } else {
        Issue.record("expected the anchor to catch rows appended outside the trusted path")
    }
}

@Test
func deletingAnAuditRowBreaksTheChain() async throws {
    let (store, path) = try makeStore()
    var ids: [Int64] = []
    for detail in ["a", "b", "c"] {
        ids.append(try await store.appendAudit(AuditEvent(actor: "x", action: "y", detail: detail)).id)
    }
    rawExec(path, "DELETE FROM audit_event WHERE id=\(ids[1]);")

    let fresh = try CascadeStore(path: path)
    if case .broken(let atID) = try await fresh.verifyAuditChain() {
        #expect(atID == ids[2])   // the row after the deleted one no longer links back
    } else {
        Issue.record("expected a broken chain after a row was deleted")
    }
}
