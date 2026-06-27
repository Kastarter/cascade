import AgentOrchestrator
import CascadeMemory
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
    func at() -> Date { rankingBase.addingTimeInterval(Double(i) * 4) }
    func appendRun(app: String, first: String, second: String) {
        events.append(InputEvent(id: Int64(i), capturedAt: at(), kind: .click, x: 10, y: 10, text: first, appName: app)); i += 1
        events.append(InputEvent(id: Int64(i), capturedAt: at(), kind: .key, key: "a", modifiers: ["command"], appName: app)); i += 1
        events.append(InputEvent(id: Int64(i), capturedAt: at(), kind: .click, x: 30, y: 30, text: second, appName: app)); i += 1
        events.append(InputEvent(id: Int64(i), capturedAt: at(), kind: .key, key: "Return", modifiers: ["command"], appName: app)); i += 1
    }
    for _ in 0..<3 { appendRun(app: "Safari", first: "Refund", second: "Send") }
    for _ in 0..<3 { appendRun(app: "Mail", first: "Invoice", second: "Archive") }
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

@MainActor
private func waitForRanking(_ condition: () -> Bool, maxTries: Int = 500) async throws {
    var tries = 0
    while !condition(), tries < maxTries {
        try await Task.sleep(for: .milliseconds(10))
        tries += 1
    }
}

@MainActor @Test
func defaultOffRefreshPreservesCuratedOrder() async throws {
    let (model, store, _) = try makeRankingModel(curatorReply: rankingCuratorKeepsTwo)
    try await store.insertInputEvents(rankingWorkflowEvents())

    await model.refreshAll()
    let firstOrder = model.curatedWaste.map(\.signature)
    await model.refreshAll()

    #expect(firstOrder.count == 2)
    #expect(model.curatedWaste.map(\.signature) == firstOrder)
    #expect(model.proactiveNextActionOffer == nil)
}

@MainActor @Test
func optInRefreshRanksAcceptedAboveDeclinedWithoutSuppressingCandidates() async throws {
    let (model, store, defaults) = try makeRankingModel(curatorReply: rankingCuratorKeepsTwo)
    try await store.insertInputEvents(rankingWorkflowEvents())
    await model.refreshAll()
    let original = model.curatedWaste
    #expect(original.count == 2)
    let declined = original[0]
    let accepted = original[1]

    model.approveCurated(accepted)
    try await waitForRanking { model.agents.contains { $0.signature == accepted.signature } }
    model.declineCurated(declined)
    defaults.set(true, forKey: CascadeAppModel.experimentalSuggestionRankingKey)

    await model.refreshAll()
    let ranked = model.curatedWaste.map(\.signature)

    #expect(ranked.count == 2)
    #expect(ranked.first == accepted.signature)
    #expect(ranked.last == declined.signature)
    #expect(ranked.contains(declined.signature))
}

@MainActor @Test
func optInRefreshSurfacesDismissibleProactiveNextActionOffer() async throws {
    let (model, store, defaults) = try makeRankingModel(curatorReply: rankingCuratorKeepsTwo)
    try await store.insertInputEvents(rankingWorkflowEvents())
    defaults.set(true, forKey: CascadeAppModel.experimentalSuggestionRankingKey)

    await model.refreshAll()
    let offer = try #require(model.proactiveNextActionOffer)
    let suppressionKey = CascadeAppModel.nextActionOfferDismissalKey(for: offer.token)

    #expect(defaults.stringArray(forKey: CascadeAppModel.dismissedNextActionOffersKey)?.contains(suppressionKey) != true)

    model.dismissProactiveNextActionOffer()

    #expect(model.proactiveNextActionOffer == nil)
    #expect(defaults.stringArray(forKey: CascadeAppModel.dismissedNextActionOffersKey)?.contains(suppressionKey) == true)
}

@MainActor @Test
func optInProactiveNextActionOfferUsesDescriptorHumanLabel() async throws {
    let (model, store, defaults) = try makeRankingModel(curatorReply: rankingCuratorKeepsTwo)
    let fixture = try descriptorBackedRankingEvents()
    try await store.insertInputEvents(fixture.events)
    defaults.set(true, forKey: CascadeAppModel.experimentalSuggestionRankingKey)

    await model.refreshAll()
    let offer = try #require(model.proactiveNextActionOffer)

    #expect(offer.token.contains("Approve Request"))
    #expect(!offer.token.contains(fixture.descriptor))
    #expect(!offer.token.contains("schemaVersion"))
    #expect(!offer.token.contains("{"))
}
