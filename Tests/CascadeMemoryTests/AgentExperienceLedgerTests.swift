import CascadeMemory
import Foundation
import Testing

private func makeExperienceStore() throws -> CascadeStore {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("CascadeAgentExperienceTests-\(UUID().uuidString).sqlite")
        .path
    return try CascadeStore(path: path)
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
