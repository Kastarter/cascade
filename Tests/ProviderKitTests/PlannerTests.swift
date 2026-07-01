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

@Test
func plannedActionShortLabelSanitizesInvalidCoordinates() {
    #expect(PlannedAction.click(x: .nan, y: .infinity).shortLabel == "click ?, ?")
    #expect(PlannedAction.scroll(deltaX: .greatestFiniteMagnitude, deltaY: -.infinity).shortLabel == "scroll 1000000, ?")
    #expect(PlannedAction.move(x: 12.9, y: -34.2).shortLabel == "move to 12, -34")
    #expect(PlannedAction.doubleClick(x: 1, y: 2).shortLabel == "double-click 1, 2")
    #expect(PlannedAction.rightClick(x: -3, y: 4).shortLabel == "right-click -3, 4")
}
