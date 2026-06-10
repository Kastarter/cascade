import CascadeMemory
import Foundation
import Testing

private func makeAgentStore() throws -> CascadeStore {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("CascadeAgentTests-\(UUID().uuidString).sqlite")
        .path
    return try CascadeStore(path: path)
}

@Test
func inputEventsRoundTrip() async throws {
    let store = try makeAgentStore()
    try await store.insertInputEvents([
        InputEvent(kind: .click, x: 12, y: 34, appName: "Mail", bundleIdentifier: "com.apple.mail"),
        InputEvent(kind: .type, text: "hello", appName: "Mail"),
        InputEvent(kind: .key, key: "c", modifiers: ["command"], appName: "Mail"),
    ])

    let events = try await store.recentInputEvents(limit: 10)
    #expect(events.count == 3)
    #expect(events.contains { $0.kind == .click && $0.x == 12 && $0.y == 34 })
    #expect(events.contains { $0.kind == .key && $0.key == "c" && $0.modifiers == ["command"] })
}

@Test
func prunePurgesOldInputEvents() async throws {
    let store = try makeAgentStore()
    try await store.insertInputEvents([
        InputEvent(capturedAt: Date(timeIntervalSinceNow: -100 * 24 * 3600), kind: .click, x: 1, y: 1, appName: "OldApp"),
        InputEvent(kind: .click, x: 2, y: 2, appName: "NewApp"),
    ])

    _ = try await store.prune(maxAge: 7 * 24 * 3600)

    let events = try await store.recentInputEvents(limit: 10)
    #expect(events.count == 1)
    #expect(events.first?.appName == "NewApp")
}

@Test
func agentRecipeAndAppsRoundTrip() async throws {
    let store = try makeAgentStore()
    let recipe = AgentRecipe(steps: [
        RecipeStep(order: 0, kind: .activateApp, appName: "Mail", bundleIdentifier: "com.apple.mail"),
        RecipeStep(order: 1, kind: .click, x: 100, y: 200, appName: "Mail", ocrAnchor: "Copy"),
        RecipeStep(order: 2, kind: .type, text: "invoice", appName: "Numbers"),
    ])
    let saved = try await store.upsertAgent(CascadeAgent(
        name: "Copy invoice into Numbers",
        source: .detected,
        signature: "mail>numbers",
        recipe: recipe,
        apps: ["Mail", "Numbers"],
        estimatedSeconds: 90,
        evidenceCount: 4
    ))

    #expect(saved.id > 0)
    let reread = try await store.agent(id: saved.id)
    #expect(reread?.recipe == recipe)
    #expect(reread?.apps == ["Mail", "Numbers"])
    #expect(reread?.estimatedSeconds == 90)
}

@Test
func upsertDedupesBySignature() async throws {
    let store = try makeAgentStore()
    let base = CascadeAgent(name: "First", source: .detected, signature: "sig-x", recipe: AgentRecipe(steps: []))
    let first = try await store.upsertAgent(base)
    let second = try await store.upsertAgent(CascadeAgent(
        name: "Updated",
        source: .detected,
        signature: "sig-x",
        recipe: AgentRecipe(steps: [RecipeStep(order: 0, kind: .click, x: 5, y: 5, appName: "Safari")]),
        evidenceCount: 9
    ))

    #expect(first.id == second.id) // same row, not a duplicate
    let all = try await store.agents()
    #expect(all.count == 1)
    #expect(all.first?.name == "Updated")
    #expect(all.first?.evidenceCount == 9)
}

@Test
func markRunEnableAndDelete() async throws {
    let store = try makeAgentStore()
    let agent = try await store.upsertAgent(CascadeAgent(name: "A", source: .detected, signature: "s", recipe: AgentRecipe(steps: [])))
    #expect(agent.lastRunAt == nil)

    try await store.markAgentRun(id: agent.id)
    #expect(try await store.agent(id: agent.id)?.lastRunAt != nil)

    try await store.setAgentEnabled(id: agent.id, enabled: false)
    #expect(try await store.agent(id: agent.id)?.enabled == false)

    try await store.deleteAgent(id: agent.id)
    #expect(try await store.agents().isEmpty)
}

@Test
func runCountIsRealRunsNotApprovals() async throws {
    let store = try makeAgentStore()
    let agent = try await store.upsertAgent(CascadeAgent(
        name: "A", source: .detected, signature: "s",
        recipe: AgentRecipe(steps: []), estimatedSecondsPerRun: 45
    ))
    #expect(agent.runCount == 0)
    #expect(agent.estimatedSecondsPerRun == 45)

    try await store.markAgentRun(id: agent.id)
    try await store.markAgentRun(id: agent.id)
    let after = try await store.agent(id: agent.id)
    #expect(after?.runCount == 2)

    // A re-detect refreshing the recipe must not erase the run history.
    _ = try await store.upsertAgent(CascadeAgent(
        name: "A v2", source: .detected, signature: "s",
        recipe: AgentRecipe(steps: []), estimatedSecondsPerRun: 50
    ))
    let refreshed = try await store.agent(id: agent.id)
    #expect(refreshed?.runCount == 2)
    #expect(refreshed?.estimatedSecondsPerRun == 50)
}

@Test
func humanStepsReadLikeTheWorkflow() {
    let recipe = AgentRecipe(steps: [
        RecipeStep(order: 0, kind: .activateApp, appName: "Mail"),
        RecipeStep(order: 1, kind: .click, x: 1, y: 1, appName: "Mail", ocrAnchor: "Send Message"),
        RecipeStep(order: 2, kind: .key, key: "c", modifiers: ["command"], appName: "Mail"),
        RecipeStep(order: 3, kind: .key, key: "v", modifiers: ["shift", "command"], appName: "Numbers"),
        RecipeStep(order: 4, kind: .type, text: "secret draft text", appName: "Numbers"),
    ])
    #expect(recipe.humanSteps == [
        "switch to Mail",
        "click “Send Message”",
        "⌘C",
        "⇧⌘V",
        "type",  // never the recorded text itself
    ])
}
