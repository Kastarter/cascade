import CascadeMemory
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
