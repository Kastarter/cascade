import ProviderKit
import Testing

@testable import SandboxKit

private actor CountingTaskPlannerClient {
    private var replies: [String]
    private let delayNanos: UInt64
    private(set) var count = 0

    init(replies: [String], delayNanos: UInt64 = 0) {
        self.replies = replies
        self.delayNanos = delayNanos
    }

    func complete() async throws -> String {
        count += 1
        if delayNanos > 0 {
            try? await Task.sleep(nanoseconds: delayNanos)
        }
        if replies.count > 1 {
            return replies.removeFirst()
        }
        return replies[0]
    }
}

private struct CountingTaskPlannerCompleter: MessageCompleting {
    let client: CountingTaskPlannerClient

    func complete(system: String?, user: String, model: String, maxTokens: Int) async throws -> String {
        try await client.complete()
    }
}

@Test
func agentTaskPlannerEnabledCacheDedupesIdenticalInFlightRequests() async {
    let client = CountingTaskPlannerClient(replies: [validTaskPlanJSON], delayNanos: 50_000_000)
    let planner = AgentTaskPlanner(
        client: CountingTaskPlannerCompleter(client: client),
        cache: ModelCallCache(ttl: 60)
    )

    async let first = planner.plan(for: "book lunch and email Sam", in: .webSandbox)
    async let second = planner.plan(for: "book lunch and email Sam", in: .webSandbox)
    async let third = planner.plan(for: "book lunch and email Sam", in: .webSandbox)

    let results = await [first, second, third]

    #expect(results.map(\.first?.task) == ["Book lunch", "Book lunch", "Book lunch"])
    #expect(await client.count == 1)
}

@Test
func agentTaskPlannerModelChangesMissCache() async {
    let client = CountingTaskPlannerClient(replies: [validTaskPlanJSON])
    let cache = ModelCallCache(ttl: 60)
    let completer = CountingTaskPlannerCompleter(client: client)
    let sonnetPlanner = AgentTaskPlanner(client: completer, model: AnthropicModel.sonnet, cache: cache)
    let haikuPlanner = AgentTaskPlanner(client: completer, model: AnthropicModel.haiku, cache: cache)

    _ = await sonnetPlanner.plan(for: "book lunch", in: .webSandbox)
    _ = await sonnetPlanner.plan(for: "book lunch", in: .webSandbox)
    _ = await haikuPlanner.plan(for: "book lunch", in: .webSandbox)

    #expect(await client.count == 2)
}

@Test
func agentTaskPlannerParseFailuresAreNotCachedAsSubtasks() async {
    let client = CountingTaskPlannerClient(replies: ["not json", validTaskPlanJSON])
    let planner = AgentTaskPlanner(
        client: CountingTaskPlannerCompleter(client: client),
        cache: ModelCallCache(ttl: 60)
    )

    let fallback = await planner.plan(for: "book lunch", in: .webSandbox)
    #expect(fallback.first?.task == "book lunch")
    #expect(fallback.first?.startURL.hasPrefix("https://www.google.com/search?q=") == true)

    let recovered = await planner.plan(for: "book lunch", in: .webSandbox)
    #expect(recovered.first?.task == "Book lunch")
    #expect(await client.count == 2)
}

private let validTaskPlanJSON = #"{"subtasks":[{"task":"Book lunch","startURL":"https://opentable.com","web":true,"note":""}]}"#
