import AgentOrchestrator
import CascadeMemory
import Foundation
import ProviderKit
import SuggestionEngine
import Testing

@testable import AppShell

private struct FakeCompleter: MessageCompleting {
    let canned: String
    func complete(system: String?, user: String, model: String, maxTokens: Int) async throws -> String {
        canned
    }
}

private let base = Date(timeIntervalSince1970: 1_700_000_000)

/// Builds the model in HEADLESS mode — injected temp store + orchestrator, no taps,
/// no capture, no audio, no scheduler — so the orchestration wiring can be exercised.
@MainActor
private func makeModel(curatorReply: String = #"{"agents":[]}"#) throws -> (model: CascadeAppModel, store: CascadeStore) {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("CascadeAppShellIT-\(UUID().uuidString).sqlite").path
    let store = try CascadeStore(path: path)
    let orchestrator = CascadeOrchestrator(store: store, curator: WorkflowCurator(client: FakeCompleter(canned: curatorReply)))
    let model = try CascadeAppModel(store: store, orchestrator: orchestrator, startsSubsystems: false)
    return (model, store)
}

/// A repeated Mail→Numbers copy/paste the detector catches as one workflow.
private func copyPasteEvents() -> [InputEvent] {
    var events: [InputEvent] = []
    var i = 0
    for _ in 0..<2 {
        events.append(InputEvent(id: Int64(i), capturedAt: base.addingTimeInterval(Double(i)), kind: .click, x: 10, y: 10, text: "Inbox", appName: "Mail")); i += 1
        events.append(InputEvent(id: Int64(i), capturedAt: base.addingTimeInterval(Double(i)), kind: .key, key: "c", modifiers: ["command"], appName: "Mail")); i += 1
        events.append(InputEvent(id: Int64(i), capturedAt: base.addingTimeInterval(Double(i)), kind: .click, x: 20, y: 20, text: "A1", appName: "Numbers")); i += 1
        events.append(InputEvent(id: Int64(i), capturedAt: base.addingTimeInterval(Double(i)), kind: .key, key: "v", modifiers: ["command"], appName: "Numbers")); i += 1
    }
    return events
}

/// Polls a MainActor condition until true or it times out (~5s), yielding so the
/// model's fire-and-forget Tasks can run.
@MainActor
private func waitUntil(_ condition: () -> Bool, maxTries: Int = 500) async throws {
    var tries = 0
    while !condition(), tries < maxTries {
        try await Task.sleep(for: .milliseconds(10))
        tries += 1
    }
}

private let curatorKeepsOne = """
{"agents":[{"index":0,"name":"Copy invoice totals into Numbers","why":"You do it by hand daily.","goal":"Copy the latest invoice totals out of Mail into the Numbers tracker.","value":0.9}]}
"""

@MainActor @Test
func modelBuildsHeadlessWithoutStartingHardware() throws {
    let (model, _) = try makeModel()
    // The point of C7: a real CascadeAppModel exists in a test, no hardware started.
    #expect(model.curatedWaste.isEmpty)
    #expect(model.agents.isEmpty)
    #expect(model.pendingCuratedAgents.isEmpty)
    #expect(!model.agentRunning)
}

@MainActor @Test
func refreshAllCuratesDetectedWorkflows() async throws {
    let (model, store) = try makeModel(curatorReply: curatorKeepsOne)
    try await store.insertInputEvents(copyPasteEvents())

    await model.refreshAll()

    // The whole R1 surface wiring: detector caught it → curator judged + renamed it →
    // it's what the review tab shows.
    #expect(model.detectedWaste.count == 1)
    #expect(model.curatedWaste.count == 1)
    #expect(model.curatedWaste.first?.name == "Copy invoice totals into Numbers")
    #expect(model.pendingCuratedAgents.count == 1) // nothing approved or declined yet
}

@MainActor @Test
func decliningHidesFromPendingImmediately() async throws {
    let (model, store) = try makeModel(curatorReply: curatorKeepsOne)
    try await store.insertInputEvents(copyPasteEvents())
    await model.refreshAll()
    let curated = try #require(model.pendingCuratedAgents.first)

    model.declineCurated(curated)

    #expect(model.pendingCuratedAgents.isEmpty) // filtered out at once
    #expect(model.curatedWaste.count == 1)      // still curated, just hidden
}

@MainActor @Test
func approvingCreatesAgentWithCuratedNameAndGoalThenLeavesPending() async throws {
    let (model, store) = try makeModel(curatorReply: curatorKeepsOne)
    try await store.insertInputEvents(copyPasteEvents())
    await model.refreshAll()
    let curated = try #require(model.pendingCuratedAgents.first)

    model.approveCurated(curated) // fire-and-forget: createAgent → refreshAll
    try await waitUntil { model.agents.contains { $0.signature == curated.signature } }

    let agent = try #require(model.agents.first { $0.signature == curated.signature })
    #expect(agent.name == "Copy invoice totals into Numbers")
    #expect(agent.goal == "Copy the latest invoice totals out of Mail into the Numbers tracker.")
    // Approved → it drops out of the review queue.
    #expect(!model.pendingCuratedAgents.contains { $0.signature == curated.signature })
}
