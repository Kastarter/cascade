import CascadeMemory
import Foundation
import ProviderKit
import SuggestionEngine
import Testing

@testable import AgentOrchestrator

private struct FakeCompleter: MessageCompleting {
    let canned: String
    func complete(system: String?, user: String, model: String, maxTokens: Int) async throws -> String {
        canned
    }
}

/// Counts how many times the model was asked — to prove the orchestrator caches.
private actor CallCounter {
    private(set) var calls = 0
    func bump() { calls += 1 }
}

private struct CountingCompleter: MessageCompleting {
    let canned: String
    let counter: CallCounter
    func complete(system: String?, user: String, model: String, maxTokens: Int) async throws -> String {
        await counter.bump()
        return canned
    }
}

private let base = Date(timeIntervalSince1970: 1_700_000_000)

private func makeStore() throws -> CascadeStore {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("CascadeCuratorIT-\(UUID().uuidString).sqlite").path
    return try CascadeStore(path: path)
}

/// A repeated Mail→Numbers copy/paste — the detector catches it as one workflow.
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

private struct FailingCompleter: MessageCompleting {
    func complete(system: String?, user: String, model: String, maxTokens: Int) async throws -> String {
        throw AnthropicError.missingKey
    }
}

private func waste(
    _ title: String, apps: [String], signature: String,
    occurrences: Int = 3, perRun: Int = 30, confidence: Double = 0.7
) -> DetectedWaste {
    DetectedWaste(
        title: title,
        apps: apps,
        occurrences: occurrences,
        estimatedSecondsPerRun: perRun,
        estimatedTotalSeconds: perRun * occurrences,
        recipe: AgentRecipe(steps: [
            RecipeStep(order: 0, kind: .activateApp, appName: apps.first ?? "App"),
            RecipeStep(order: 1, kind: .key, key: "c", modifiers: ["command"], appName: apps.first ?? "App"),
        ]),
        evidence: [1, 2],
        confidence: confidence,
        signature: signature
    )
}

@Test
func curatorKeepsRenamesAndDropsNoise() async {
    let candidates = [
        waste("Repeated steps in Mail", apps: ["Mail", "Numbers"], signature: "sig-a"),
        waste("Repeated steps in Safari", apps: ["Safari"], signature: "sig-b"),
    ]
    let canned = """
    {"agents":[
      {"index":0,"name":"Copy invoice totals from Mail into Numbers","why":"You do this every morning by hand.","goal":"Copy the latest invoice totals out of Mail and paste them into the Numbers tracker.","value":0.85}
    ]}
    """
    let result = await WorkflowCurator(client: FakeCompleter(canned: canned)).curate(candidates)
    #expect(result.count == 1) // the Safari "reading" candidate was dropped as noise
    #expect(result[0].name == "Copy invoice totals from Mail into Numbers")
    #expect(result[0].goal.contains("Numbers"))
    #expect(result[0].value == 0.85)
    // Carries the source workflow so approving still builds the real recipe.
    #expect(result[0].signature == "sig-a")
    #expect(result[0].source.apps == ["Mail", "Numbers"])
    #expect(result[0].evidence == [1, 2])
}

@Test
func curatorMayKeepNone() async {
    // The whole point of R1: if nothing is worth automating, show nothing — an
    // intentional empty answer must NOT be papered over by the raw-list fallback.
    let candidates = [waste("Repeated steps in Safari", apps: ["Safari"], signature: "sig-b")]
    let result = await WorkflowCurator(client: FakeCompleter(canned: #"{"agents":[]}"#)).curate(candidates)
    #expect(result.isEmpty)
}

@Test
func curatorFallsBackToRawListOnFailure() async {
    // Never worse than today: a missing key / dead network still shows every
    // detected workflow, in the curated shape, in the detector's order.
    let candidates = [
        waste("Copy from Mail into Numbers", apps: ["Mail", "Numbers"], signature: "sig-a", occurrences: 4),
        waste("Save the report in TextEdit", apps: ["TextEdit"], signature: "sig-b"),
    ]
    let result = await WorkflowCurator(client: FailingCompleter()).curate(candidates)
    #expect(result.count == 2)
    #expect(result.map(\.name) == ["Copy from Mail into Numbers", "Save the report in TextEdit"])
    #expect(result.allSatisfy { $0.goal == $0.name }) // mechanical goal == title
    #expect(result[0].signature == "sig-a")
}

@Test
func curatorIgnoresOutOfRangeAndEmptyPicks() async {
    let candidates = [waste("Copy from Mail into Numbers", apps: ["Mail", "Numbers"], signature: "sig-a")]
    let canned = """
    {"agents":[
      {"index":99,"name":"Bogus","why":"x","goal":"y","value":0.9},
      {"index":0,"name":"","why":"x","goal":"y","value":0.9},
      {"index":0,"name":"Copy invoice totals into Numbers","why":"tedious","goal":"Copy invoice totals into the Numbers tracker.","value":0.8}
    ]}
    """
    let result = await WorkflowCurator(client: FakeCompleter(canned: canned)).curate(candidates)
    #expect(result.count == 1) // out-of-range dropped, empty-name dropped, index not double-kept
    #expect(result[0].name == "Copy invoice totals into Numbers")
}

@Test
func curatorClampsValueAndOrdersStrongestFirst() async {
    let candidates = [
        waste("A", apps: ["Mail"], signature: "sig-a"),
        waste("B", apps: ["Numbers"], signature: "sig-b"),
        waste("C", apps: ["Safari"], signature: "sig-c"),
    ]
    let canned = """
    {"agents":[
      {"index":0,"name":"Low","why":"x","goal":"g","value":-0.5},
      {"index":1,"name":"High","why":"x","goal":"g","value":1.7},
      {"index":2,"name":"Mid","why":"x","goal":"g","value":0.5}
    ]}
    """
    let result = await WorkflowCurator(client: FakeCompleter(canned: canned)).curate(candidates)
    #expect(result.map(\.name) == ["High", "Mid", "Low"])
    #expect(result.first?.value == 1.0) // 1.7 clamped
    #expect(result.last?.value == 0.0)  // -0.5 clamped
}

@Test
func curatorToleratesFencedJSON() async {
    let candidates = [waste("Copy from Mail into Numbers", apps: ["Mail", "Numbers"], signature: "sig-a")]
    let canned = """
    Sure — here's what's worth automating:
    ```json
    {"agents":[{"index":0,"name":"Copy totals into Numbers","why":"tedious","goal":"Copy the totals into Numbers.","value":0.8}]}
    ```
    """
    let result = await WorkflowCurator(client: FakeCompleter(canned: canned)).curate(candidates)
    #expect(result.count == 1)
    #expect(result[0].name == "Copy totals into Numbers")
}

@Test
func curatorReturnsEmptyForNoCandidates() async {
    let result = await WorkflowCurator(client: FailingCompleter()).curate([])
    #expect(result.isEmpty)
}

// MARK: - End-to-end through the orchestrator (detect → curate → approve)

@Test
func curateThenApprovePersistsCuratedNameAndGoal() async throws {
    let store = try makeStore()
    try await store.insertInputEvents(copyPasteEvents())

    let canned = """
    {"agents":[{"index":0,"name":"Copy invoice totals into Numbers","why":"You do it by hand daily.","goal":"Copy the latest invoice totals out of Mail into the Numbers tracker.","value":0.9}]}
    """
    let orchestrator = CascadeOrchestrator(store: store, curator: WorkflowCurator(client: FakeCompleter(canned: canned)))

    // Detector caught the real repeated workflow…
    let candidates = try await orchestrator.detectedWaste()
    #expect(candidates.count == 1)

    // …the curator judged + renamed it…
    let curated = await orchestrator.curate(candidates)
    #expect(curated.count == 1)
    #expect(curated[0].name == "Copy invoice totals into Numbers")

    // …and approving persists the curated NAME and GOAL on an agent built from the
    // real recorded recipe (signature carries through). This is the whole chain.
    _ = try await orchestrator.createAgent(from: curated[0])
    let agents = try await orchestrator.agents()
    #expect(agents.count == 1)
    #expect(agents[0].name == "Copy invoice totals into Numbers")
    #expect(agents[0].goal == "Copy the latest invoice totals out of Mail into the Numbers tracker.")
    #expect(agents[0].signature == candidates[0].signature)
    #expect(!agents[0].recipe.steps.isEmpty)
}

@Test
func curateCacheRefreshesSourceCountsOnHit() async throws {
    // Same workflow, more occurrences later: the signature (token shape) is unchanged
    // so the cache hits — but the card's counts must still update, not freeze at first
    // curation. A signature excludes counts, so the cache key alone can't see growth.
    let v1 = [waste("Repeated in Mail", apps: ["Mail", "Numbers"], signature: "sig", occurrences: 2, perRun: 30)]
    let v2 = [waste("Repeated in Mail", apps: ["Mail", "Numbers"], signature: "sig", occurrences: 5, perRun: 30)]
    let canned = #"{"agents":[{"index":0,"name":"Copy into Numbers","why":"x","goal":"Copy into Numbers.","value":0.8}]}"#
    let store = try makeStore()
    let orchestrator = CascadeOrchestrator(store: store, curator: WorkflowCurator(client: FakeCompleter(canned: canned)))

    let first = await orchestrator.curate(v1)
    #expect(first.first?.source.occurrences == 2)

    let second = await orchestrator.curate(v2) // cache hit (same signature set)
    #expect(second.first?.source.occurrences == 5)              // refreshed, not frozen
    #expect(second.first?.source.estimatedTotalSeconds == 150)  // 30 × 5
    #expect(second.first?.name == "Copy into Numbers")          // curated fields preserved
}

@Test
func curateCachesByCandidateSet() async throws {
    let store = try makeStore()
    try await store.insertInputEvents(copyPasteEvents())
    let counter = CallCounter()
    let orchestrator = CascadeOrchestrator(
        store: store,
        curator: WorkflowCurator(client: CountingCompleter(canned: #"{"agents":[]}"#, counter: counter))
    )

    let candidates = try await orchestrator.detectedWaste()
    _ = await orchestrator.curate(candidates)
    _ = await orchestrator.curate(candidates)
    // Same candidate set → the model is asked once, not on every refresh.
    #expect(await counter.calls == 1)
}
