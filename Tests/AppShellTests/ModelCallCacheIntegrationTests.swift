import AgentOrchestrator
import CascadeMemory
import Foundation
import ProviderKit
import SandboxKit
import Testing
import WasteDetection

@testable import AppShell

private actor ModelCacheCountingClient {
    private let reply: String
    private(set) var count = 0

    init(reply: String) {
        self.reply = reply
    }

    func complete() async throws -> String {
        count += 1
        return reply
    }
}

private struct ModelCacheCountingCompleter: MessageCompleting {
    let client: ModelCacheCountingClient

    func complete(system: String?, user: String, model: String, maxTokens: Int) async throws -> String {
        try await client.complete()
    }
}

@MainActor @Test
func experimentalModelCallCacheDefaultsOffAndLeavesPureCallsUncached() async throws {
    let defaults = UserDefaults(suiteName: "CascadeModelCallCacheOff-\(UUID().uuidString)")!
    let cache = CascadeAppModel.experimentalModelCallCache(defaults: defaults)
    #expect(cache == nil)

    let plannerClient = ModelCacheCountingClient(reply: validModelCacheStepJSON)
    let planner = ClaudeSingleStepPlanner(client: ModelCacheCountingCompleter(client: plannerClient), cache: cache)
    _ = try await planner.proposeNextStep(goal: "open the menu", contexts: [])
    _ = try await planner.proposeNextStep(goal: "open the menu", contexts: [])
    #expect(await plannerClient.count == 2)

    let curatorClient = ModelCacheCountingClient(reply: validModelCacheCuratorJSON)
    let curator = WorkflowCurator(client: ModelCacheCountingCompleter(client: curatorClient), cache: cache)
    let waste = modelCacheWaste()
    _ = await curator.curate([waste])
    _ = await curator.curate([waste])
    #expect(await curatorClient.count == 2)

    let taskClient = ModelCacheCountingClient(reply: validModelCacheTaskPlanJSON)
    let taskPlanner = AgentTaskPlanner(client: ModelCacheCountingCompleter(client: taskClient), cache: cache)
    _ = await taskPlanner.plan(for: "book lunch", in: .webSandbox)
    _ = await taskPlanner.plan(for: "book lunch", in: .webSandbox)
    #expect(await taskClient.count == 2)

    let routeClient = ModelCacheCountingClient(reply: validModelCacheSearchRouteJSON)
    let routePlanner = AgentTaskPlanner(client: ModelCacheCountingCompleter(client: routeClient), cache: cache)
    _ = await routePlanner.routeSearch(
        for: "look up the latest exchange rate",
        in: .onScreen,
        conversationContext: "Frontmost app: Safari\nWindow: Exchange rates"
    )
    _ = await routePlanner.routeSearch(
        for: "look up the latest exchange rate",
        in: .onScreen,
        conversationContext: "Frontmost app: Safari\nWindow: Exchange rates"
    )
    #expect(await routeClient.count == 2)
}

@MainActor @Test
func experimentalModelCallCacheEnabledDedupesPlannerCuratorAndTaskPlannerCalls() async throws {
    let defaults = UserDefaults(suiteName: "CascadeModelCallCacheOn-\(UUID().uuidString)")!
    defaults.set(true, forKey: CascadeAppModel.experimentalModelCallCacheKey)
    _ = try #require(CascadeAppModel.experimentalModelCallCache(defaults: defaults))
    // A full package run can suspend this MainActor test for longer than the
    // production cache's 30-second TTL while other suites execute. Keep this
    // integration focused on request deduplication rather than scheduler load.
    let cache = ModelCallCache(ttl: 5 * 60)

    let plannerClient = ModelCacheCountingClient(reply: validModelCacheStepJSON)
    let planner = ClaudeSingleStepPlanner(client: ModelCacheCountingCompleter(client: plannerClient), cache: cache)
    _ = try await planner.proposeNextStep(goal: "open the menu", contexts: [])
    _ = try await planner.proposeNextStep(goal: "open the menu", contexts: [])
    #expect(await plannerClient.count == 1)

    let curatorClient = ModelCacheCountingClient(reply: validModelCacheCuratorJSON)
    let curator = WorkflowCurator(client: ModelCacheCountingCompleter(client: curatorClient), cache: cache)
    let waste = modelCacheWaste()
    _ = await curator.curate([waste])
    _ = await curator.curate([waste])
    #expect(await curatorClient.count == 1)

    let taskClient = ModelCacheCountingClient(reply: validModelCacheTaskPlanJSON)
    let taskPlanner = AgentTaskPlanner(client: ModelCacheCountingCompleter(client: taskClient), cache: cache)
    _ = await taskPlanner.plan(for: "book lunch", in: .webSandbox)
    _ = await taskPlanner.plan(for: "book lunch", in: .webSandbox)
    #expect(await taskClient.count == 1)

    let routeClient = ModelCacheCountingClient(reply: validModelCacheSearchRouteJSON)
    let routePlanner = AgentTaskPlanner(client: ModelCacheCountingCompleter(client: routeClient), cache: cache)
    _ = await routePlanner.routeSearch(
        for: "look up the latest exchange rate",
        in: .onScreen,
        conversationContext: "Frontmost app: Safari\nWindow: Exchange rates"
    )
    _ = await routePlanner.routeSearch(
        for: "look up the latest exchange rate",
        in: .onScreen,
        conversationContext: "Frontmost app: Safari\nWindow: Exchange rates"
    )
    #expect(await routeClient.count == 1)
}

@Test
func sourcesDoNotDiscardCacheRequestResults() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let sourceRoot = packageRoot.appendingPathComponent("Sources")
    let offenders = try swiftFiles(under: sourceRoot).flatMap { file -> [String] in
        let text = try String(contentsOf: file, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false).enumerated().compactMap { index, line in
            let compact = line.filter { !$0.isWhitespace }
            guard compact.contains("_="), compact.contains("cacheRequest(") else { return nil }
            let relative = file.path.replacingOccurrences(of: packageRoot.path + "/", with: "")
            return "\(relative):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))"
        }
    }

    #expect(offenders.isEmpty, "discarded cacheRequest calls:\n\(offenders.joined(separator: "\n"))")
}

private let validModelCacheStepJSON = #"{"rationale":"open it","confidence":0.8,"action":{"kind":"click","x":12,"y":34}}"#
private let validModelCacheCuratorJSON = #"{"agents":[{"index":0,"name":"File invoices","why":"Avoids repeated filing","goal":"File new invoices into the tracker","value":0.82}]}"#
private let validModelCacheTaskPlanJSON = #"{"subtasks":[{"task":"Book lunch","startURL":"https://opentable.com","web":true,"note":""}]}"#
private let validModelCacheSearchRouteJSON = #"{"routingIntent":"web","candidateSources":["web"],"cleanQuery":"latest exchange rate"}"#

private func modelCacheWaste() -> DetectedWaste {
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

private func swiftFiles(under root: URL) throws -> [URL] {
    guard let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else {
        return []
    }

    return try enumerator.compactMap { item in
        guard let url = item as? URL, url.pathExtension == "swift" else { return nil }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        return values.isRegularFile == true ? url : nil
    }
}
