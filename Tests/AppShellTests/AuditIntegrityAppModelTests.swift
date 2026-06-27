import AgentOrchestrator
import CascadeMemory
import Foundation
import SQLite3
import Testing

@testable import AppShell

private func rawAuditIntegrityExec(_ path: String, _ sql: String) {
    var db: OpaquePointer?
    guard sqlite3_open(path, &db) == SQLITE_OK else { return }
    defer { sqlite3_close(db) }
    sqlite3_exec(db, sql, nil, nil, nil)
}

@MainActor
private func makeAuditIntegrityModel(enforcing: Bool) throws -> (model: CascadeAppModel, store: CascadeStore, path: String) {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("CascadeAuditIntegrity-\(UUID().uuidString).sqlite").path
    let store = try CascadeStore(path: path)
    let defaults = UserDefaults(suiteName: "CascadeAuditIntegrity-\(UUID().uuidString)")!
    defaults.set(enforcing, forKey: CascadeAppModel.auditIntegrityEnforcementKey)
    let model = try CascadeAppModel(
        store: store,
        orchestrator: CascadeOrchestrator(store: store),
        defaults: defaults,
        startsSubsystems: false
    )
    return (model, store, path)
}

private func auditDependentAgent() -> CascadeAgent {
    CascadeAgent(
        id: 1,
        name: "Audit dependent",
        source: .detected,
        signature: "audit-dependent",
        recipe: AgentRecipe(steps: [
            RecipeStep(order: 0, kind: .key, key: "a", modifiers: ["command"], appName: "Notes")
        ]),
        apps: ["Notes"],
        goal: "Run an audit-dependent action"
    )
}

@MainActor @Test
func auditIntegrityEnforcementHidesTamperedRowsAndBlocksAgentWork() async throws {
    let (model, store, path) = try makeAuditIntegrityModel(enforcing: true)
    _ = try await store.appendAudit(AuditEvent(actor: "employee", action: "first", detail: "ok"))
    let tampered = try await store.appendAudit(AuditEvent(actor: "agent", action: "second", detail: "ok"))
    rawAuditIntegrityExec(path, "UPDATE audit_event SET detail='tampered' WHERE id=\(tampered.id);")

    await model.refreshAll()
    model.deployAgent(auditDependentAgent())

    #expect(!model.auditIntegrityStatus.isTrusted)
    #expect(model.audit.isEmpty)
    #expect(!model.agentRunning)
    #expect(model.agentMessage.contains("Audit history is untrusted"))
}

@MainActor @Test
func auditIntegrityEnforcementPreservesUntamperedActivityFeed() async throws {
    let (model, store, _) = try makeAuditIntegrityModel(enforcing: true)
    _ = try await store.appendAudit(AuditEvent(actor: "employee", action: "first", detail: "ok"))
    _ = try await store.appendAudit(AuditEvent(actor: "agent", action: "second", detail: "ok"))

    await model.refreshAll()

    #expect(model.auditIntegrityStatus.isTrusted)
    #expect(model.audit.map(\.action) == ["second", "first"])
}

@MainActor @Test
func auditIntegrityEnforcementHidesUnchainedOnlyRows() async throws {
    let (model, _, path) = try makeAuditIntegrityModel(enforcing: true)
    rawAuditIntegrityExec(path, """
    INSERT INTO audit_event (created_at, actor, action, detail)
    VALUES ('2026-06-26T00:00:00.000Z','legacy','legacy.only','one');
    INSERT INTO audit_event (created_at, actor, action, detail)
    VALUES ('2026-06-26T00:00:01.000Z','legacy','legacy.only','two');
    """)

    await model.refreshAll()
    model.deployAgent(auditDependentAgent())

    #expect(!model.auditIntegrityStatus.isTrusted)
    #expect(model.audit.isEmpty)
    #expect(!model.agentRunning)
    #expect(model.agentMessage.contains("Audit history is untrusted"))
}

@MainActor @Test
func auditIntegrityEnforcementFiltersLegacyPrefixBeforeValidChain() async throws {
    let (model, store, path) = try makeAuditIntegrityModel(enforcing: true)
    rawAuditIntegrityExec(path, """
    INSERT INTO audit_event (created_at, actor, action, detail)
    VALUES ('2026-06-26T00:00:00.000Z','legacy','legacy.prefix','legacy');
    """)
    _ = try await store.appendAudit(AuditEvent(actor: "agent", action: "chained", detail: "ok"))

    await model.refreshAll()

    #expect(model.auditIntegrityStatus.isTrusted)
    #expect(model.audit.map(\.action) == ["chained"])
}

@MainActor @Test
func auditIntegrityDefaultOffStillPublishesRowsButRecordsStatus() async throws {
    let (model, store, path) = try makeAuditIntegrityModel(enforcing: false)
    let original = try await store.appendAudit(AuditEvent(actor: "employee", action: "first", detail: "ok"))
    rawAuditIntegrityExec(path, "UPDATE audit_event SET detail='tampered' WHERE id=\(original.id);")

    await model.refreshAll()

    #expect(!model.auditIntegrityStatus.isTrusted)
    #expect(model.audit.map(\.action) == ["first"])
}
