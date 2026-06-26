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
