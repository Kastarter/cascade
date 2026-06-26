import CascadeMemory
import Foundation
import ProviderKit
import Testing
import WasteDetection

@testable import AgentOrchestrator

private actor CountingCuratorClient {
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

private struct CountingCuratorCompleter: MessageCompleting {
    let client: CountingCuratorClient

    func complete(system: String?, user: String, model: String, maxTokens: Int) async throws -> String {
        try await client.complete()
    }
}

@Test
func workflowCuratorEnabledCacheDedupesIdenticalInFlightRequests() async {
    let client = CountingCuratorClient(replies: [validCuratorJSON], delayNanos: 50_000_000)
    let curator = WorkflowCurator(
        client: CountingCuratorCompleter(client: client),
        cache: ModelCallCache(ttl: 60)
    )
    let candidate = cacheWaste()

    async let first = curator.curate([candidate])
    async let second = curator.curate([candidate])
    async let third = curator.curate([candidate])

    let results = await [first, second, third]

    #expect(results.map { $0.first?.name } == ["File invoices", "File invoices", "File invoices"])
    #expect(await client.count == 1)
}

@Test
func workflowCuratorParseFailuresAreNotCachedAsCuratedAgents() async {
    let client = CountingCuratorClient(replies: ["not json", validCuratorJSON])
    let curator = WorkflowCurator(
        client: CountingCuratorCompleter(client: client),
        cache: ModelCallCache(ttl: 60)
    )
    let candidate = cacheWaste()

    let fallback = await curator.curate([candidate])
    #expect(fallback.first?.name == candidate.title)

    let recovered = await curator.curate([candidate])
    #expect(recovered.first?.name == "File invoices")
    #expect(await client.count == 2)
}

private let validCuratorJSON = #"{"agents":[{"index":0,"name":"File invoices","why":"Avoids repeated filing","goal":"File new invoices into the tracker","value":0.82}]}"#

private func cacheWaste() -> DetectedWaste {
    DetectedWaste(
        title: "Repeated invoice filing",
        apps: ["Mail", "Numbers"],
        occurrences: 3,
        estimatedSecondsPerRun: 25,
        estimatedTotalSeconds: 75,
        recipe: AgentRecipe(steps: [
            RecipeStep(order: 0, kind: .activateApp, appName: "Mail"),
            RecipeStep(order: 1, kind: .key, key: "c", modifiers: ["command"], appName: "Mail"),
            RecipeStep(order: 2, kind: .activateApp, appName: "Numbers"),
            RecipeStep(order: 3, kind: .key, key: "v", modifiers: ["command"], appName: "Numbers"),
        ]),
        evidence: [1, 2, 3],
        confidence: 0.7,
        signature: "mail-copy:numbers-paste",
        lastSeenAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
}
