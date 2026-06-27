import AgentOrchestrator
import CascadeMemory
import Foundation
import ProviderKit
import SandboxKit
import Testing

@testable import AppShell

private struct ExperienceFakeCompleter: MessageCompleting {
    func complete(system: String?, user: String, model: String, maxTokens: Int) async throws -> String {
        #"{"agents":[]}"#
    }
}

@MainActor
private func makeExperienceModel(ledgerEnabled: Bool = false) throws -> (model: CascadeAppModel, store: CascadeStore) {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("CascadeExperienceLedgerIT-\(UUID().uuidString).sqlite")
        .path
    let store = try CascadeStore(path: path)
    let orchestrator = CascadeOrchestrator(store: store, curator: WorkflowCurator(client: ExperienceFakeCompleter()))
    let defaults = UserDefaults(suiteName: "CascadeExperienceLedgerIT-\(UUID().uuidString)")!
    defaults.set(ledgerEnabled, forKey: CascadeAppModel.experimentalExperienceLedgerKey)
    let model = try CascadeAppModel(store: store, orchestrator: orchestrator, defaults: defaults, startsSubsystems: false)
    return (model, store)
}

private func experienceRecipe() -> AgentRecipe {
    AgentRecipe(steps: [
        RecipeStep(order: 0, kind: .activateApp, appName: "Mail"),
        RecipeStep(order: 1, kind: .key, key: "c", modifiers: ["command"], appName: "Mail")
    ])
}

private func noOpOnScreenRecipe() -> AgentRecipe {
    AgentRecipe(steps: [
        RecipeStep(order: 0, kind: .type, appName: "Mail")
    ])
}

private func completedExperienceUpdate(_ result: String) -> BackgroundWebAgent.Update {
    BackgroundWebAgent.Update(status: result, snapshotPNG: nil, url: "", done: true, result: result, completed: true)
}

private func stoppedExperienceUpdate() -> BackgroundWebAgent.Update {
    BackgroundWebAgent.Update(status: "Stopped.", snapshotPNG: nil, url: "", done: true, result: nil)
}

private func failedExperienceUpdate(_ reason: String) -> BackgroundWebAgent.Update {
    BackgroundWebAgent.Update(status: reason, snapshotPNG: nil, url: "", done: true, result: nil)
}

private func stepLimitExperienceUpdate(_ summary: String) -> BackgroundWebAgent.Update {
    BackgroundWebAgent.Update(status: summary, snapshotPNG: nil, url: "", done: true, result: summary)
}

@MainActor
private func savedExperienceAgent(in store: CascadeStore, recipe: AgentRecipe = experienceRecipe()) async throws -> CascadeAgent {
    try await store.upsertAgent(CascadeAgent(
        name: "Copy invoice totals",
        source: .detected,
        signature: "mail-invoice-copy",
        recipe: recipe,
        apps: ["Mail"],
        estimatedSecondsPerRun: 45,
        goal: "Copy invoice totals into the tracker."
    ))
}

@MainActor
private func finishSandboxRun(
    _ model: CascadeAppModel,
    agent: CascadeAgent,
    update: BackgroundWebAgent.Update,
    task: String = "copy invoice totals"
) async {
    let id = UUID()
    let entry = BackgroundAgentRun(id: id, task: task, agentID: agent.id)
    let completion = model.finishSandboxRun(id: id, entry: entry, update: update)
    await completion.value
}

@MainActor @Test
func defaultOffSandboxCompletionOnlyIncrementsRunCount() async throws {
    let (model, store) = try makeExperienceModel()
    let agent = try await savedExperienceAgent(in: store)

    await finishSandboxRun(model, agent: agent, update: completedExperienceUpdate("Copied invoice totals."))

    #expect(try await store.agent(id: agent.id)?.runCount == 1)
    #expect(try await store.agentExperienceCases().isEmpty)
}

@MainActor @Test
func enabledLedgerRecordsSandboxSuccess() async throws {
    let (model, store) = try makeExperienceModel(ledgerEnabled: true)
    let agent = try await savedExperienceAgent(in: store)

    await finishSandboxRun(model, agent: agent, update: completedExperienceUpdate("Copied invoice totals."))

    let cases = try await store.agentExperienceCases()
    #expect(try await store.agent(id: agent.id)?.runCount == 1)
    #expect(cases.count == 1)
    #expect(cases.first?.outcome == .success)
    #expect(cases.first?.verificationSignal == .completed)
    #expect(cases.first?.failureKind == nil)
    #expect(cases.first?.appName == "Mail")
    #expect(cases.first?.goalPattern == "Copy invoice totals into the tracker.")
    #expect(cases.first?.recipeSignature == "mail-invoice-copy")
}

@MainActor @Test
func enabledLedgerRecordsOnScreenSuccess() async throws {
    let (model, store) = try makeExperienceModel(ledgerEnabled: true)
    let agent = try await savedExperienceAgent(in: store, recipe: noOpOnScreenRecipe())

    await model.runAgentRecipe(agent)

    let cases = try await store.agentExperienceCases()
    #expect(try await store.agent(id: agent.id)?.runCount == 1)
    #expect(cases.count == 1)
    #expect(cases.first?.outcome == .success)
    #expect(cases.first?.verificationSignal == .completed)
    #expect(cases.first?.goalPattern == "Copy invoice totals into the tracker.")
}

@MainActor @Test
func enabledLedgerRecordsStoppedFailedRefusedModalNoEffectAndStepLimitSandboxRuns() async throws {
    let (model, store) = try makeExperienceModel(ledgerEnabled: true)
    let agent = try await savedExperienceAgent(in: store)

    await finishSandboxRun(model, agent: agent, update: stoppedExperienceUpdate())
    await finishSandboxRun(model, agent: agent, update: failedExperienceUpdate("Browser failed."))
    await finishSandboxRun(model, agent: agent, update: failedExperienceUpdate("Refused unsafe delete action."))
    await finishSandboxRun(model, agent: agent, update: failedExperienceUpdate("Unexpected modal blocked the run."))
    await finishSandboxRun(model, agent: agent, update: failedExperienceUpdate("My actions stopped changing the page, so I stopped."))
    await finishSandboxRun(model, agent: agent, update: stepLimitExperienceUpdate("Ran out of steps."))

    #expect(try await store.agent(id: agent.id)?.runCount == 0)
    let cases = try await store.agentExperienceCases()
    #expect(cases.count == 6)
    #expect(cases.filter { $0.outcome == .userStop && $0.failureKind == .userStop }.count == 1)
    #expect(cases.filter { $0.outcome == .failure && $0.failureKind == .toolError }.count == 1)
    #expect(cases.filter { $0.outcome == .refusal && $0.failureKind == .unsafeAction }.count == 1)
    #expect(cases.filter { $0.outcome == .failure && $0.failureKind == .modalBlocked }.count == 1)
    #expect(cases.filter { $0.outcome == .failure && $0.failureKind == .noEffect }.count == 1)
    #expect(cases.filter { $0.outcome == .failure && $0.failureKind == .stepLimit }.count == 1)
}

@MainActor @Test
func enabledLedgerRecordsSandboxStallAsStepLimitFailure() async throws {
    let (model, store) = try makeExperienceModel(ledgerEnabled: true)
    let agent = try await savedExperienceAgent(in: store)

    await finishSandboxRun(
        model,
        agent: agent,
        update: failedExperienceUpdate("I kept looking without making progress, so I stopped.")
    )

    let cases = try await store.agentExperienceCases()
    #expect(cases.count == 1)
    #expect(cases.first?.outcome == .failure)
    #expect(cases.first?.failureKind == .stepLimit)
}

@Test
func appShellMapsEveryOrchestratorFailureKindToLedgerFailureKind() {
    let expected: [AgentOrchestrator.AgentFailureKind: CascadeMemory.AgentFailureKind] = [
        .wrongStartState: .wrongStartState,
        .permissionMissing: .permissionDenied,
        .secureInput: .secureInput,
        .targetNotFound: .targetNotFound,
        .groundingMiss: .groundingMiss,
        .noEffect: .noEffect,
        .staleFrameBatch: .staleFrameBatch,
        .unexpectedModal: .modalBlocked,
        .verificationUnavailable: .verificationUnavailable,
        .validatorIncomplete: .verifierRejected,
        .transportFailure: .toolError,
        .unsafeActionRefused: .unsafeAction,
        .parameterNeedsLiveValue: .parameterNeedsLiveValue,
        .stepLimit: .stepLimit,
        .timeout: .timeout,
        .userStop: .userStop,
        .artifactWrongLane: .artifactWrongLane
    ]

    #expect(expected.count == AgentOrchestrator.AgentFailureKind.allCases.count)
    for failure in AgentOrchestrator.AgentFailureKind.allCases {
        #expect(CascadeAppModel.experienceFailureKind(for: failure) == expected[failure])
    }
}
