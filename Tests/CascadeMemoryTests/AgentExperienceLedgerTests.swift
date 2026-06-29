import CascadeMemory
import Foundation
import SQLite3
import Testing

private func makeExperienceStore() throws -> CascadeStore {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("CascadeAgentExperienceTests-\(UUID().uuidString).sqlite")
        .path
    return try CascadeStore(path: path)
}

private func rawLedgerExec(_ path: String, _ sql: String) {
    var db: OpaquePointer?
    guard sqlite3_open(path, &db) == SQLITE_OK else { return }
    defer { sqlite3_close(db) }
    sqlite3_exec(db, sql, nil, nil, nil)
}

private func expectValidationError(
    _ expected: AgentExperienceValidationError,
    _ body: () async throws -> Void
) async {
    do {
        try await body()
        #expect(Bool(false))
    } catch let error as AgentExperienceValidationError {
        #expect(error == expected)
    } catch {
        #expect(Bool(false))
    }
}

@Test
func successesRequireVerifiedOrCompletedSignal() async throws {
    let store = try makeExperienceStore()
    await expectValidationError(.missingVerifiedCompletionSignal) {
        _ = try await store.recordAgentExperience(AgentExperienceCase(
            appName: "Mail",
            goalPattern: "copy invoice",
            recipeSignature: "mail>numbers",
            outcome: .success,
            evidenceIDs: [101],
            actionCount: 3
        ))
    }

    #expect(try await store.agentExperienceCases().isEmpty)

    let saved = try await store.recordAgentExperience(AgentExperienceCase(
        appName: "Mail",
        goalPattern: "copy invoice",
        recipeSignature: "mail>numbers",
        skillSlug: "mail",
        outcome: .success,
        verificationSignal: .completed,
        evidenceIDs: [101, 102],
        actionCount: 4
    ))

    #expect(saved.id > 0)
    #expect(saved.verificationSignal == .completed)
    #expect(saved.failureKind == nil)
    #expect(saved.evidenceIDs == [101, 102])
    #expect(saved.retainedScore > 0.8)
}

@Test
func failuresRequireFailureKindAndBecomeAvoidCandidates() async throws {
    let store = try makeExperienceStore()
    await expectValidationError(.missingFailureKind) {
        _ = try await store.recordAgentExperience(AgentExperienceCase(
            appName: "Finder",
            goalPattern: "organize downloads",
            recipeSignature: "finder-cleanup",
            outcome: .failure,
            evidenceIDs: [20],
            actionCount: 5
        ))
    }

    let saved = try await store.recordAgentExperience(AgentExperienceCase(
        appName: "Finder",
        goalPattern: "organize downloads",
        recipeSignature: "finder-cleanup",
        outcome: .failure,
        failureKind: .targetNotFound,
        evidenceIDs: [20, 21],
        actionCount: 5
    ))

    #expect(saved.failureKind == .targetNotFound)
    #expect(saved.retainedScore < 0)
    #expect(saved.createsAvoidRule)
    #expect(try await store.agentExperienceAvoidRules().map(\.id) == [saved.id])
}

@Test
func safeRefusalsAreRetainedButNotFailures() async throws {
    let store = try makeExperienceStore()
    let refusal = try await store.recordAgentExperience(AgentExperienceCase(
        appName: "System Settings",
        goalPattern: "disable security",
        recipeSignature: "settings-security",
        outcome: .refusal,
        evidenceIDs: [7],
        actionCount: 0
    ))

    #expect(refusal.failureKind == nil)
    #expect(refusal.retainedScore > 0)
    #expect(!refusal.createsAvoidRule)
    #expect(try await store.agentExperienceCases(matching: AgentExperienceQuery(failureKind: .unsafeAction)).isEmpty)
    #expect(try await store.agentExperienceCases(matching: AgentExperienceQuery(outcome: .refusal)).count == 1)
}

@Test
func userStopsDoNotCreateAvoidRulesWithoutFeedback() async throws {
    let store = try makeExperienceStore()
    let stoppedWithoutFeedback = try await store.recordAgentExperience(AgentExperienceCase(
        appName: "Safari",
        goalPattern: "file benefits form",
        recipeSignature: "safari-form",
        outcome: .userStop,
        evidenceIDs: [31],
        actionCount: 2
    ))
    #expect(stoppedWithoutFeedback.retainedScore == 0)
    #expect(!stoppedWithoutFeedback.createsAvoidRule)
    #expect(try await store.agentExperienceAvoidRules().isEmpty)

    let stoppedWithFeedback = try await store.recordAgentExperience(AgentExperienceCase(
        appName: "Safari",
        goalPattern: "file benefits form",
        recipeSignature: "safari-form",
        outcome: .userStop,
        evidenceIDs: [31],
        actionCount: 2,
        userFeedback: "Clicked the wrong account menu."
    ))

    #expect(stoppedWithFeedback.retainedScore < 0)
    #expect(stoppedWithFeedback.createsAvoidRule)
    #expect(try await store.agentExperienceAvoidRules().map(\.id) == [stoppedWithFeedback.id])
}

@Test
func queryFiltersByAppGoalAndFailureKind() async throws {
    let store = try makeExperienceStore()
    _ = try await store.recordAgentExperience(AgentExperienceCase(
        appName: "Mail",
        goalPattern: "copy invoice",
        recipeSignature: "mail-invoice",
        outcome: .failure,
        failureKind: .targetNotFound,
        evidenceIDs: [1],
        actionCount: 3
    ))
    _ = try await store.recordAgentExperience(AgentExperienceCase(
        appName: "Safari",
        goalPattern: "copy invoice",
        recipeSignature: "safari-invoice",
        outcome: .failure,
        failureKind: .loginRequired,
        evidenceIDs: [2],
        actionCount: 3
    ))
    _ = try await store.recordAgentExperience(AgentExperienceCase(
        appName: "Mail",
        goalPattern: "schedule outreach",
        recipeSignature: "mail-outreach",
        outcome: .failure,
        failureKind: .targetNotFound,
        evidenceIDs: [3],
        actionCount: 6
    ))

    let mailCases = try await store.agentExperienceCases(matching: AgentExperienceQuery(appName: "Mail"))
    #expect(mailCases.count == 2)

    let invoiceCases = try await store.agentExperienceCases(matching: AgentExperienceQuery(goalPattern: "copy invoice"))
    #expect(invoiceCases.count == 2)

    let targetFailures = try await store.agentExperienceCases(matching: AgentExperienceQuery(failureKind: .targetNotFound))
    #expect(targetFailures.count == 2)

    let exact = try await store.agentExperienceCases(matching: AgentExperienceQuery(
        appName: "Mail",
        goalPattern: "copy invoice",
        failureKind: .targetNotFound
    ))
    #expect(exact.map(\.recipeSignature) == ["mail-invoice"])
}

@Test
func failureMemoryPersistsStateSummaryAndRedactsRawText() async throws {
    let store = try makeExperienceStore()

    let saved = try await store.recordAgentFailureMemory(AgentFailureMemory(
        appName: "Safari",
        normalizedGoalTokens: ["submit", "invoice"],
        failureKind: .noEffect,
        firstBadAction: "click",
        screenSignatureHash: "screen-hash",
        targetHash: "target-hash",
        stateSummary: "status unchanged for jane.private@example.com after click",
        repairHint: "Choose another visible submit control.",
        recoveryEvidenceHash: "evidence-hash"
    ))
    let fetched = try #require(try await store.agentFailureMemories().first)

    #expect(saved.stateSummary?.contains("<EMAIL>") == true)
    #expect(saved.stateSummary?.contains("jane.private@example.com") == false)
    #expect(fetched.stateSummary == saved.stateSummary)
    #expect(fetched.recoveryEvidenceHash == "evidence-hash")
}

@Test
func failureMemoryMigrationAddsStateSummaryColumnToExistingStore() async throws {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("CascadeAgentFailureMemoryMigration-\(UUID().uuidString).sqlite")
        .path
    rawLedgerExec(path, """
    CREATE TABLE agent_failure_memory (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        created_at TEXT NOT NULL,
        app_name TEXT NOT NULL,
        goal_tokens_json TEXT NOT NULL,
        failure_kind TEXT NOT NULL,
        first_bad_action TEXT,
        screen_signature_hash TEXT,
        target_hash TEXT,
        repair_hint TEXT NOT NULL,
        recovery_evidence_hash TEXT,
        retained_score REAL NOT NULL
    );
    """)
    let store = try CascadeStore(path: path)

    let saved = try await store.recordAgentFailureMemory(AgentFailureMemory(
        appName: "Numbers",
        normalizedGoalTokens: ["paste", "totals"],
        failureKind: .groundingMiss,
        stateSummary: "target hash changed after re-harvest",
        repairHint: "Re-ground before clicking."
    ))

    #expect(saved.stateSummary == "target hash changed after re-harvest")
    #expect(try await store.agentFailureMemories().first?.stateSummary == saved.stateSummary)
}

@Test
func failureMemoryDecodesLegacyPayloadWithoutStateSummary() throws {
    let json = """
    {
      "id": 7,
      "appName": "Safari",
      "normalizedGoalTokens": ["submit"],
      "failureKind": "no_effect",
      "repairHint": "Use another target.",
      "retainedScore": -0.7
    }
    """

    let memory = try JSONDecoder().decode(AgentFailureMemory.self, from: Data(json.utf8))

    #expect(memory.id == 7)
    #expect(memory.stateSummary == nil)
    #expect(memory.failureKind == .noEffect)
}
