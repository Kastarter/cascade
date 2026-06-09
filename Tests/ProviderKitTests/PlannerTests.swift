import CascadeMemory
import ProviderKit
import Testing

private struct FakeCompleter: MessageCompleting {
    let canned: String
    func complete(system: String?, user: String, model: String, maxTokens: Int) async throws -> String {
        canned
    }
}

@Test
func plannerParsesClick() async throws {
    let planner = ClaudeSingleStepPlanner(
        client: FakeCompleter(canned: #"{"rationale":"open it","confidence":0.8,"action":{"kind":"click","x":12,"y":34}}"#)
    )
    let step = try await planner.proposeNextStep(goal: "open the menu", contexts: [])
    #expect(step.action == .click(x: 12, y: 34))
    #expect(step.confidence == 0.8)
    #expect(step.action.isExecutable)
}

@Test
func plannerRejectsShellAsUnsupported() async throws {
    let planner = ClaudeSingleStepPlanner(
        client: FakeCompleter(canned: #"{"rationale":"nope","confidence":0.5,"action":{"kind":"shell","text":"rm -rf /"}}"#)
    )
    let step = try await planner.proposeNextStep(goal: "do something", contexts: [])
    #expect(step.action == .unsupported("shell"))
    #expect(!step.action.isExecutable)
}

@Test
func plannerHandlesFencedJSON() async throws {
    let canned = "Here you go:\n```json\n{\"rationale\":\"done\",\"confidence\":1,\"action\":{\"kind\":\"done\",\"summary\":\"all set\"}}\n```"
    let planner = ClaudeSingleStepPlanner(client: FakeCompleter(canned: canned))
    let step = try await planner.proposeNextStep(goal: "x", contexts: [])
    #expect(step.action == .done("all set"))
}

@Test
func plannerRejectsNonWebURL() async throws {
    let planner = ClaudeSingleStepPlanner(
        client: FakeCompleter(canned: #"{"rationale":"open","confidence":0.6,"action":{"kind":"open_url","url":"file:///etc/passwd"}}"#)
    )
    let step = try await planner.proposeNextStep(goal: "x", contexts: [])
    #expect(step.action == .unsupported("open_url"))
}
