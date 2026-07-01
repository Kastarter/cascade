import AgentOrchestrator
import CascadeMemory
import ComputerUseKit
import Foundation
import ProviderKit
import SandboxKit
import Testing
import WasteDetection

@testable import AppShell

private struct RankingFakeCompleter: MessageCompleting {
    let canned: String
    func complete(system: String?, user: String, model: String, maxTokens: Int) async throws -> String {
        canned
    }
}

private let rankingBase = Date(timeIntervalSince1970: 1_720_000_000)

@MainActor
private func makeRankingModel(curatorReply: String) throws -> (model: CascadeAppModel, store: CascadeStore, defaults: UserDefaults) {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("CascadeSuggestionRanking-\(UUID().uuidString).sqlite").path
    let store = try CascadeStore(path: path)
    let orchestrator = CascadeOrchestrator(
        store: store,
        curator: WorkflowCurator(client: RankingFakeCompleter(canned: curatorReply))
    )
    let defaults = UserDefaults(suiteName: "CascadeSuggestionRanking-\(UUID().uuidString)")!
    let model = try CascadeAppModel(store: store, orchestrator: orchestrator, defaults: defaults, startsSubsystems: false)
    return (model, store, defaults)
}

private func rankingWorkflowEvents() -> [InputEvent] {
    var events: [InputEvent] = []
    var i = 0
    func appendRun(run: Int, app: String, first: String, second: String) {
        let start = TimeInterval(run * 300)
        events.append(InputEvent(id: Int64(i), capturedAt: rankingBase.addingTimeInterval(start), kind: .click, x: 10, y: 10, text: first, appName: app)); i += 1
        events.append(InputEvent(id: Int64(i), capturedAt: rankingBase.addingTimeInterval(start + 10), kind: .key, key: "a", modifiers: ["command"], appName: app)); i += 1
        events.append(InputEvent(id: Int64(i), capturedAt: rankingBase.addingTimeInterval(start + 20), kind: .click, x: 30, y: 30, text: second, appName: app)); i += 1
        events.append(InputEvent(id: Int64(i), capturedAt: rankingBase.addingTimeInterval(start + 30), kind: .key, key: "Return", modifiers: ["command"], appName: app)); i += 1
    }
    for run in 0..<3 { appendRun(run: run, app: "Safari", first: "Refund", second: "Send") }
    for run in 3..<6 { appendRun(run: run, app: "Mail", first: "Invoice", second: "Archive") }
    return events
}

private func descriptorBackedRankingEvents() throws -> (events: [InputEvent], descriptor: String) {
    let descriptor = try #require(AXTargetDescriptorV2.encode(
        label: "Approve Request",
        role: "AXButton",
        identifier: "approve.request",
        container: "AXGroup: Review actions",
        ancestorPath: ["AXWindow: Request Review", "AXGroup: Review actions"],
        siblingIndex: 2,
        neighborLabels: ["Reject", "More"]
    ))
    var events: [InputEvent] = []
    var i = 0
    func at() -> Date { rankingBase.addingTimeInterval(Double(i) * 4) }
    func appendRun(includeNextAction: Bool) {
        events.append(InputEvent(id: Int64(i), capturedAt: at(), kind: .click, x: 10, y: 10, text: "Review Request", appName: "Safari")); i += 1
        events.append(InputEvent(id: Int64(i), capturedAt: at(), kind: .key, key: "a", modifiers: ["command"], appName: "Safari")); i += 1
        if includeNextAction {
            events.append(InputEvent(id: Int64(i), capturedAt: at(), kind: .click, x: 30, y: 30, appName: "Safari", targetDescriptor: descriptor)); i += 1
        }
    }
    appendRun(includeNextAction: true)
    appendRun(includeNextAction: true)
    appendRun(includeNextAction: false)
    return (events, descriptor)
}

private let rankingCuratorKeepsTwo = """
{"agents":[{"index":0,"name":"First workflow","why":"Repeated work.","goal":"Do the first workflow.","value":0.7},{"index":1,"name":"Second workflow","why":"Repeated work.","goal":"Do the second workflow.","value":0.7}]}
"""

private func manualCurated(_ signature: String, app: String = "Mail") -> CuratedAgent {
    let waste = DetectedWaste(
        title: signature,
        apps: [app],
        occurrences: 3,
        estimatedSecondsPerRun: 20,
        estimatedTotalSeconds: 60,
        recipe: AgentRecipe(steps: [
            RecipeStep(order: 0, kind: .click, text: "Open", appName: app),
            RecipeStep(order: 1, kind: .key, key: "return", modifiers: ["command"], appName: app),
        ]),
        evidence: [1, 2, 3],
        confidence: 0.8,
        signature: signature,
        lastSeenAt: rankingBase
    )
    return CuratedAgent(
        source: waste,
        name: "Handle \(signature)",
        why: "Repeated work.",
        goal: "Handle the workflow.",
        value: 0.75
    )
}

@MainActor
private func waitForRanking(_ condition: () -> Bool, maxTries: Int = 500) async throws {
    var tries = 0
    while !condition(), tries < maxTries {
        try await Task.sleep(for: .milliseconds(10))
        tries += 1
    }
}

@MainActor
private func waitForAuditAction(_ action: String, in store: CascadeStore, maxTries: Int = 500) async throws {
    var tries = 0
    while tries < maxTries {
        let audit = (try? await store.recentAudit(limit: 40)) ?? []
        if audit.contains(where: { $0.action == action }) { return }
        try await Task.sleep(for: .milliseconds(10))
        tries += 1
    }
}

@MainActor
private func waitForPreferenceKind(_ kind: PreferenceEventKind, in store: CascadeStore, maxTries: Int = 500) async throws {
    var tries = 0
    while tries < maxTries {
        let events = (try? await store.recentPreferenceEvents(limit: 100)) ?? []
        if events.contains(where: { $0.kind == kind }) { return }
        try await Task.sleep(for: .milliseconds(10))
        tries += 1
    }
}

@MainActor @Test
func explicitOptOutRefreshPreservesCuratedOrderAndDisablesProactiveOffer() async throws {
    let (model, store, defaults) = try makeRankingModel(curatorReply: rankingCuratorKeepsTwo)
    try await store.insertInputEvents(rankingWorkflowEvents())
    defaults.set(false, forKey: CascadeAppModel.experimentalSuggestionRankingKey)

    await model.refreshAll()
    let firstOrder = model.curatedWaste.map(\.signature)
    await model.refreshAll()

    #expect(firstOrder.count == 2)
    #expect(model.curatedWaste.map(\.signature) == firstOrder)
    #expect(model.proactiveNextActionOffer == nil)
}

@MainActor @Test
func defaultRefreshRanksAcceptedAndKeepsDeclinedOutOfReviewQueue() async throws {
    let (model, store, _) = try makeRankingModel(curatorReply: rankingCuratorKeepsTwo)
    try await store.insertInputEvents(rankingWorkflowEvents())
    await model.refreshAll()
    let original = model.curatedWaste
    #expect(original.count == 2)
    let declined = original[0]
    let accepted = original[1]

    model.approveCurated(accepted)
    try await waitForRanking { model.agents.contains { $0.signature == accepted.signature } }
    model.declineCurated(declined)

    await model.refreshAll()
    let ranked = model.curatedWaste.map(\.signature)

    #expect(model.detectedWaste.map(\.signature).contains(declined.signature))
    #expect(ranked.count == 1)
    #expect(ranked.first == accepted.signature)
    #expect(!ranked.contains(declined.signature))
}

@MainActor @Test
func approveDeclineScheduleDisableAndDeleteWritePreferenceEvents() async throws {
    let (model, store, _) = try makeRankingModel(curatorReply: rankingCuratorKeepsTwo)
    let declined = manualCurated("declined-flow", app: "Mail")
    let accepted = manualCurated("accepted-flow", app: "Safari")

    model.approveCurated(accepted)
    try await waitForPreferenceKind(.agentApproved, in: store)
    try await waitForRanking { model.agents.contains { $0.signature == accepted.signature } }
    let agent = try #require(model.agents.first { $0.signature == accepted.signature })

    model.declineCurated(declined)
    try await waitForPreferenceKind(.agentDeclined, in: store)
    model.setAgentSchedule(agent, schedule: "daily@09:05")
    try await waitForPreferenceKind(.agentScheduleSet, in: store)
    model.setAgentEnabled(agent, enabled: false)
    try await waitForPreferenceKind(.agentDisabled, in: store)
    model.deleteAgent(agent)
    try await waitForPreferenceKind(.agentDeleted, in: store)

    let acceptedEvents = try await store.preferenceEvents(workflowSignature: accepted.signature, limit: 20)
    let approved = try #require(acceptedEvents.first { $0.kind == .agentApproved })

    #expect(acceptedEvents.contains { $0.kind == .agentScheduleSet })
    #expect(acceptedEvents.contains { $0.kind == .agentDisabled })
    #expect(acceptedEvents.contains { $0.kind == .agentDeleted })
    #expect(approved.evidenceJSON?.contains(accepted.name) != true)
    #expect(approved.evidenceJSON?.contains("nameHash") == true)
}

@MainActor @Test
func defaultRefreshSurfacesDismissibleProactiveNextActionOffer() async throws {
    let (model, store, defaults) = try makeRankingModel(curatorReply: rankingCuratorKeepsTwo)
    try await store.insertInputEvents(rankingWorkflowEvents())

    await model.refreshAll()
    let offer = try #require(model.proactiveNextActionOffer)
    let selectedSignature = model.proactiveOffer?.signature ?? offer.token
    let suppressionKey = CascadeAppModel.nextActionOfferDismissalKey(for: selectedSignature)

    #expect(defaults.stringArray(forKey: CascadeAppModel.dismissedNextActionOffersKey)?.contains(suppressionKey) != true)

    model.dismissProactiveNextActionOffer()

    #expect(model.proactiveNextActionOffer == nil)
    #expect(defaults.stringArray(forKey: CascadeAppModel.dismissedNextActionOffersKey)?.contains(suppressionKey) == true)
    try await waitForAuditAction("proactive.dismiss", in: store)
}

@MainActor @Test
func defaultProactiveNextActionOfferUsesDescriptorHumanLabel() async throws {
    let (model, store, _) = try makeRankingModel(curatorReply: rankingCuratorKeepsTwo)
    let fixture = try descriptorBackedRankingEvents()
    try await store.insertInputEvents(fixture.events)

    await model.refreshAll()
    let offer = try #require(model.proactiveNextActionOffer)

    #expect(offer.token.contains("Approve Request"))
    #expect(!offer.token.contains(fixture.descriptor))
    #expect(!offer.token.contains("schemaVersion"))
    #expect(!offer.token.contains("{"))
}

@Test
func proactiveHelpSelectorRanksSavedAgentPrefixBeforeGenericNextAction() {
    let recipe = AgentRecipe(steps: [
        RecipeStep(order: 0, kind: .click, text: "Refund", appName: "Safari"),
        RecipeStep(order: 1, kind: .key, key: "a", modifiers: ["command"], appName: "Safari"),
        RecipeStep(order: 2, kind: .click, text: "Send", appName: "Safari"),
    ])
    let agent = CascadeAgent(
        id: 42,
        name: "Refund reply",
        source: .detected,
        signature: "refund-reply",
        recipe: recipe,
        apps: ["Safari"],
        estimatedSeconds: 90,
        estimatedSecondsPerRun: 45,
        evidenceCount: 3
    )
    let recent = [
        InputEvent(id: 1, capturedAt: rankingBase, kind: .click, text: "Refund", appName: "Safari"),
        InputEvent(id: 2, capturedAt: rankingBase.addingTimeInterval(1), kind: .key, key: "a", modifiers: ["command"], appName: "Safari"),
    ]
    let prediction = NextActionPredictor.Prediction(token: "click:Send@Safari", confidence: 0.92, support: 3)

    var preference = PreferenceModel()
    preference.record(agent.signature, accepted: true)
    let candidates = ProactiveHelpSelector().candidates(
        prediction: prediction,
        liveRepetition: nil,
        struggle: nil,
        recentEvents: recent,
        agents: [agent],
        appSkills: AppSkillRegistry(),
        preferenceModel: preference
    )

    #expect(candidates.first?.kind == .savedAgent)
    #expect(candidates.contains { $0.kind == .nextAction })
}

@MainActor @Test
func proactiveAcceptAndSnoozeWriteAuditRows() async throws {
    let (acceptModel, acceptStore, _) = try makeRankingModel(curatorReply: rankingCuratorKeepsTwo)
    try await acceptStore.insertInputEvents(rankingWorkflowEvents())
    await acceptModel.refreshAll()
    _ = try #require(acceptModel.proactiveOffer)

    acceptModel.acceptProactiveOffer()
    try await waitForAuditAction("proactive.accept", in: acceptStore)

    let (snoozeModel, snoozeStore, defaults) = try makeRankingModel(curatorReply: rankingCuratorKeepsTwo)
    try await snoozeStore.insertInputEvents(rankingWorkflowEvents())
    await snoozeModel.refreshAll()
    let offer = try #require(snoozeModel.proactiveOffer)

    snoozeModel.snoozeProactiveOffer()
    try await waitForAuditAction("proactive.snooze", in: snoozeStore)

    #expect(defaults.stringArray(forKey: CascadeAppModel.snoozedProactiveOffersKey)?.contains(CascadeAppModel.nextActionOfferDismissalKey(for: offer.signature)) == true)
}

@MainActor @Test
func liveRepetitionAcceptUsesCurateRangeFallbackWindow() async throws {
    let (model, store, _) = try makeRankingModel(curatorReply: "")
    try await store.insertInputEvents(rankingWorkflowEvents())

    await model.refreshAll()
    let offer = try #require(model.proactiveOffer)
    #expect(offer.source == .liveRepetition)

    model.acceptProactiveOffer()
    try await waitForRanking { !model.taughtForReview.isEmpty }

    #expect(model.taughtForReview.first?.source.evidence.isEmpty == false)
}
