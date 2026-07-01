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
func agentTaskPlannerCachesValidatedRepairResponses() async {
    let client = CountingTaskPlannerClient(replies: ["not json", validTaskPlanJSON])
    let planner = AgentTaskPlanner(
        client: CountingTaskPlannerCompleter(client: client),
        cache: ModelCallCache(ttl: 60)
    )

    let repaired = await planner.plan(for: "book lunch", in: .webSandbox)
    #expect(repaired.first?.task == "Book lunch")
    #expect(repaired.first?.startURL == "https://opentable.com")

    let cached = await planner.plan(for: "book lunch", in: .webSandbox)
    #expect(cached.first?.task == "Book lunch")
    #expect(await client.count == 2)
}

@Test
func searchRouteWithoutCacheCallsClientTwice() async {
    let client = CountingTaskPlannerClient(replies: [validSearchRouteJSON])
    let planner = AgentTaskPlanner(client: CountingTaskPlannerCompleter(client: client), cache: nil)

    _ = await planner.routeSearch(
        for: "look up the latest exchange rate",
        in: .onScreen,
        conversationContext: "Frontmost app: Safari\nWindow: Exchange rates"
    )
    _ = await planner.routeSearch(
        for: "look up the latest exchange rate",
        in: .onScreen,
        conversationContext: "Frontmost app: Safari\nWindow: Exchange rates"
    )

    #expect(await client.count == 2)
}

@Test
func searchRouteEnabledCacheDedupesIdenticalInFlightRequests() async {
    let client = CountingTaskPlannerClient(replies: [validSearchRouteJSON], delayNanos: 50_000_000)
    let planner = AgentTaskPlanner(
        client: CountingTaskPlannerCompleter(client: client),
        cache: ModelCallCache(ttl: 60)
    )

    async let first = planner.routeSearch(
        for: "look up the latest exchange rate",
        in: .onScreen,
        conversationContext: "Frontmost app: Safari\nWindow: Exchange rates"
    )
    async let second = planner.routeSearch(
        for: "look up the latest exchange rate",
        in: .onScreen,
        conversationContext: "Frontmost app: Safari\nWindow: Exchange rates"
    )
    async let third = planner.routeSearch(
        for: "look up the latest exchange rate",
        in: .onScreen,
        conversationContext: "Frontmost app: Safari\nWindow: Exchange rates"
    )

    let results = await [first, second, third]

    #expect(results.map(\.routingIntent) == [.web, .web, .web])
    #expect(await client.count == 1)
}

@Test
func searchRouteModelAndContextChangesMissCache() async {
    let client = CountingTaskPlannerClient(replies: [validSearchRouteJSON])
    let cache = ModelCallCache(ttl: 60)
    let completer = CountingTaskPlannerCompleter(client: client)
    let sonnetPlanner = AgentTaskPlanner(client: completer, model: AnthropicModel.sonnet, cache: cache)
    let haikuPlanner = AgentTaskPlanner(client: completer, model: AnthropicModel.haiku, cache: cache)

    _ = await sonnetPlanner.routeSearch(
        for: "look up the latest exchange rate",
        in: .onScreen,
        conversationContext: "Frontmost app: Safari\nWindow: Exchange rates"
    )
    _ = await sonnetPlanner.routeSearch(
        for: "look up the latest exchange rate",
        in: .onScreen,
        conversationContext: "Frontmost app: Safari\nWindow: Exchange rates"
    )
    _ = await sonnetPlanner.routeSearch(
        for: "look up the latest exchange rate",
        in: .onScreen,
        conversationContext: "Frontmost app: Notes\nWindow: Draft"
    )
    _ = await haikuPlanner.routeSearch(
        for: "look up the latest exchange rate",
        in: .onScreen,
        conversationContext: "Frontmost app: Safari\nWindow: Exchange rates"
    )

    #expect(await client.count == 3)
}

@Test
func searchRouteParseFailuresAreNotCached() async {
    let client = CountingTaskPlannerClient(replies: ["not json", "still bad", validSearchRouteJSON])
    let planner = AgentTaskPlanner(
        client: CountingTaskPlannerCompleter(client: client),
        cache: ModelCallCache(ttl: 60, failureTTL: 0)
    )

    let fallback = await planner.routeSearch(
        for: "look up the latest exchange rate",
        in: .onScreen,
        conversationContext: "Frontmost app: Safari"
    )
    #expect(fallback.cleanQuery == "the latest exchange rate")
    #expect(await client.count == 2)

    let recovered = await planner.routeSearch(
        for: "look up the latest exchange rate",
        in: .onScreen,
        conversationContext: "Frontmost app: Safari"
    )
    #expect(recovered.routingIntent == .web)
    #expect(recovered.cleanQuery == "latest exchange rate")
    #expect(await client.count == 3)
}

private let validTaskPlanJSON = #"{"subtasks":[{"task":"Book lunch","startURL":"https://opentable.com","web":true,"note":""}]}"#
private let validSearchRouteJSON = #"{"routingIntent":"web","candidateSources":["web"],"cleanQuery":"latest exchange rate"}"#
