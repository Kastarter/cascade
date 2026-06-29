import AgentOrchestrator
import CascadeMemory
import Foundation
import ProviderKit
import Testing
import WasteDetection

@testable import AppShell

private struct EpisodeMiningFakeCompleter: MessageCompleting {
    func complete(system: String?, user: String, model: String, maxTokens: Int) async throws -> String {
        """
        {"agents":[{"index":0,"name":"First workflow","why":"Repeated work.","goal":"Do the first workflow.","value":0.7},{"index":1,"name":"Second workflow","why":"Repeated work.","goal":"Do the second workflow.","value":0.7}]}
        """
    }
}

private let episodeMiningIntegrationBase = Date(timeIntervalSince1970: 1_760_100_000)

@MainActor
private func makeEpisodeMiningModel() throws -> (model: CascadeAppModel, store: CascadeStore, defaults: UserDefaults) {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("CascadeEpisodeMining-\(UUID().uuidString).sqlite").path
    let store = try CascadeStore(path: path)
    let orchestrator = CascadeOrchestrator(
        store: store,
        curator: WorkflowCurator(client: EpisodeMiningFakeCompleter())
    )
    let defaults = UserDefaults(suiteName: "CascadeEpisodeMining-\(UUID().uuidString)")!
    let model = try CascadeAppModel(store: store, orchestrator: orchestrator, defaults: defaults, startsSubsystems: false)
    return (model, store, defaults)
}

private func episodeMiningInput(
    _ id: Int,
    at seconds: TimeInterval,
    kind: InputEventKind = .click,
    text: String? = nil,
    key: String? = nil,
    modifiers: [String] = [],
    app: String
) -> InputEvent {
    InputEvent(
        id: Int64(id),
        capturedAt: episodeMiningIntegrationBase.addingTimeInterval(seconds),
        kind: kind,
        x: kind == .click ? 10 : nil,
        y: kind == .click ? 10 : nil,
        text: text,
        key: key,
        modifiers: modifiers,
        appName: app
    )
}

private func divergentEpisodeMiningEvents() -> [InputEvent] {
    var events: [InputEvent] = []
    var id = 0

    for run in 0..<2 {
        let start = TimeInterval(run * 300)
        events.append(episodeMiningInput(id, at: start, text: "Open Invoice", app: "Mail")); id += 1
        events.append(episodeMiningInput(id, at: start + 1, kind: .key, key: "c", modifiers: ["command"], app: "Mail")); id += 1
    }

    for (run, fillerKey) in ["down", "right", "left"].enumerated() {
        let start = TimeInterval(1_000 + run * 300)
        events.append(episodeMiningInput(id, at: start, text: "Open", app: "Books")); id += 1
        events.append(episodeMiningInput(id, at: start + 1, kind: .key, key: fillerKey, app: "Books")); id += 1
        events.append(episodeMiningInput(id, at: start + 2, kind: .key, key: "c", modifiers: ["command"], app: "Books")); id += 1
        events.append(episodeMiningInput(id, at: start + 3, kind: .key, key: fillerKey, app: "Books")); id += 1
    }

    return events
}

@MainActor @Test
func refreshAllUsesEpisodeMiningByDefaultAndAllowsOptOut() async throws {
    let events = divergentEpisodeMiningEvents()
    let oldSignatures = WasteDetector().detect(contexts: [], inputEvents: events, useEpisodeMining: false).map(\.signature)
    let episodeSignatures = WasteDetector().detect(contexts: [], inputEvents: events, useEpisodeMining: true).map(\.signature)
    let contiguousSignature = "click:open invoice@Mail|key:command+c@Mail"
    let gappedSignature = "click:open@Books|key:command+c@Books"

    #expect(oldSignatures.contains(contiguousSignature))
    #expect(!oldSignatures.contains(gappedSignature))
    #expect(episodeSignatures.contains(gappedSignature))
    #expect(oldSignatures != episodeSignatures)

    let (model, store, defaults) = try makeEpisodeMiningModel()
    try await store.insertInputEvents(events)

    await model.refreshAll()
    #expect(model.detectedWaste.map(\.signature) == episodeSignatures)
    #expect(model.detectedWaste.map(\.signature).contains(gappedSignature))

    defaults.set(false, forKey: CascadeAppModel.experimentalEpisodeMiningKey)
    await model.refreshAll()

    #expect(model.detectedWaste.map(\.signature) == oldSignatures)
    #expect(!model.detectedWaste.map(\.signature).contains(gappedSignature))
}
