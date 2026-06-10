import ProviderKit
import Testing

@testable import SandboxKit

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

@Test
func plannerSplitsMultiPartJobs() async throws {
    let canned = """
    {"subtasks":[
      {"task":"Find the cheapest flight to Tokyo in July","startURL":"https://www.google.com/travel/flights","web":true,"note":""},
      {"task":"Email the flight details to Sam","startURL":"https://mail.google.com","web":true,"note":""}
    ]}
    """
    let planner = AgentTaskPlanner(client: FakeCompleter(canned: canned))
    let plan = await planner.plan(for: "find the cheapest flight to Tokyo and email it to Sam", in: .webSandbox)
    #expect(plan.count == 2)
    #expect(plan[0].startURL == "https://www.google.com/travel/flights")
    #expect(plan[1].task == "Email the flight details to Sam")
    #expect(plan[1].web)
}

@Test
func plannerFlagsNativeOnlyParts() throws {
    let canned = """
    {"subtasks":[
      {"task":"Find the repair shop's phone number","startURL":"https://www.google.com/maps","web":true,"note":""},
      {"task":"Add the number to the Contacts app","startURL":"","web":false,"note":"local desktop app"}
    ]}
    """
    let plan = try #require(AgentTaskPlanner.parse(canned))
    #expect(plan.count == 2)
    #expect(!plan[1].web)
    #expect(plan[1].note == "local desktop app")
}

@Test
func plannerParsesOnScreenAppParts() throws {
    let canned = """
    {"subtasks":[
      {"task":"Copy the latest invoice total from the inbox","app":"Mail","url":""},
      {"task":"Paste the total into a new note titled Invoices","app":"Notes","url":""}
    ]}
    """
    let plan = try #require(AgentTaskPlanner.parse(canned))
    #expect(plan.count == 2)
    #expect(plan[0].app == "Mail")
    #expect(plan[1].app == "Notes")
    #expect(plan[0].startURL.isEmpty)
}

@Test
func plannerToleratesFencedJSON() throws {
    let canned = """
    Sure, here's the plan:
    ```json
    {"subtasks":[{"task":"Book a table for two at 7pm","startURL":"https://www.opentable.com","web":true,"note":""}]}
    ```
    """
    let plan = try #require(AgentTaskPlanner.parse(canned))
    #expect(plan.count == 1)
    #expect(plan[0].startURL == "https://www.opentable.com")
}

@Test
func plannerNormalizesSchemelessURLs() throws {
    let canned = #"{"subtasks":[{"task":"Check the inbox","startURL":"mail.google.com","web":true,"note":""}]}"#
    let plan = try #require(AgentTaskPlanner.parse(canned))
    #expect(plan[0].startURL == "https://mail.google.com")
}

@Test
func plannerRejectsGarbage() {
    #expect(AgentTaskPlanner.parse("no json here") == nil)
    #expect(AgentTaskPlanner.parse(#"{"subtasks":[]}"#) == nil)
    #expect(AgentTaskPlanner.parse(#"{"subtasks":[{"task":"  "}]}"#) == nil)
}

@Test
func webSandboxFallbackIsSingleSearchSubtask() async {
    let planner = AgentTaskPlanner(client: FailingCompleter())
    let plan = await planner.plan(for: "book a table for two", in: .webSandbox)
    #expect(plan.count == 1)
    #expect(plan[0].web)
    #expect(plan[0].task == "book a table for two")
    #expect(plan[0].startURL.hasPrefix("https://www.google.com/search?q="))
}

@Test
func onScreenFallbackIsTheBareTask() async {
    let planner = AgentTaskPlanner(client: FailingCompleter())
    let plan = await planner.plan(for: "open Notes and write hello", in: .onScreen)
    #expect(plan.count == 1)
    #expect(plan[0].task == "open Notes and write hello")
    #expect(plan[0].app.isEmpty)
    #expect(plan[0].startURL.isEmpty)
}

@Test
func plannerCapsSubtaskCount() async {
    let items = (1...7)
        .map { #"{"task":"part \#($0)","startURL":"https://example.com","web":true,"note":""}"# }
        .joined(separator: ",")
    let planner = AgentTaskPlanner(client: FakeCompleter(canned: #"{"subtasks":[\#(items)]}"#))
    let plan = await planner.plan(for: "a very long job", in: .webSandbox)
    #expect(plan.count == AgentTaskPlanner.maxSubtasks)
}

@Test
func goalCarriesFindingsForward() {
    let goal = AgentTaskPlanner.goal(
        for: AgentSubtask(task: "Email the price to Sam", startURL: "https://mail.google.com"),
        index: 1, total: 2, job: "find the price and email Sam",
        findings: [(task: "Find the price", result: "$420 on Delta, June 12")],
        firmer: false
    )
    #expect(goal.contains("part 2 of 2"))
    #expect(goal.contains("$420 on Delta, June 12"))
    #expect(goal.contains("Do ONLY this part now: Email the price to Sam"))
}

@Test
func singlePartGoalIsJustTheTask() {
    let goal = AgentTaskPlanner.goal(
        for: AgentSubtask(task: "Find the cheapest flight to Tokyo"),
        index: 0, total: 1, job: "Find the cheapest flight to Tokyo",
        findings: [], firmer: false
    )
    #expect(goal == "Find the cheapest flight to Tokyo")
}

@Test
func firmerGoalDemandsAction() {
    let goal = AgentTaskPlanner.goal(
        for: AgentSubtask(task: "Book the table"),
        index: 0, total: 1, job: "Book the table",
        findings: [], firmer: true
    )
    #expect(goal.contains("CARRY OUT"))
}

@Test
func singleFindingSummaryIsJustTheFinding() {
    let summary = AgentTaskPlanner.summary(
        findings: [(task: "Find the price", result: "$420 on Delta, June 12")],
        skipped: [], ranLongOn: nil
    )
    #expect(summary == "$420 on Delta, June 12")
}

@Test
func summaryReportsSkippedNativeParts() {
    let summary = AgentTaskPlanner.summary(
        findings: [(task: "Find the price", result: "$420 on Delta")],
        skipped: [AgentSubtask(task: "Add it to Reminders", web: false, note: "local desktop app")],
        ranLongOn: nil
    )
    #expect(summary.contains("$420 on Delta"))
    #expect(summary.contains("Add it to Reminders (local desktop app)"))
}

@Test
func summaryMentionsRunningLong() {
    let summary = AgentTaskPlanner.summary(
        findings: [(task: "Find the price", result: "$420 on Delta")],
        skipped: [], ranLongOn: "Email the price to Sam"
    )
    #expect(summary.contains("Ran out of steps"))
    #expect(summary.contains("Email the price to Sam"))
    #expect(summary.contains("$420 on Delta"))
}
