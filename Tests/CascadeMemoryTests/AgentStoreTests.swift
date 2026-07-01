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
func inputEventTargetDescriptorRoundTrips() async throws {
    // B1: the stable AX locator recorded with a click must survive insert→read so the
    // replay cascade can rank on it (proves the column + migration + decode).
    let store = try makeAgentStore()
    let descriptor = AXTargetDescriptor.encode(role: "AXButton", identifier: "composeSend", container: "AXSheet: Export")
    try await store.insertInputEvents([
        InputEvent(kind: .click, x: 5, y: 6, text: "Send", appName: "Mail", targetDescriptor: descriptor),
        InputEvent(kind: .key, key: "c", modifiers: ["command"], appName: "Mail"),
    ])

    let events = try await store.recentInputEvents(limit: 10)
    let click = try #require(events.first { $0.kind == .click })
    #expect(click.targetDescriptor == descriptor)
    let decoded = AXTargetDescriptor.decode(click.targetDescriptor)
    #expect(decoded.role == "AXButton")
    #expect(decoded.identifier == "composeSend")
    #expect(decoded.container == "AXSheet: Export")
    // Non-click events carry no descriptor.
    #expect(events.first { $0.kind == .key }?.targetDescriptor == nil)
}

@Test
func axTargetDescriptorEncodesDecodesAndToleratesLegacy() {
    // Round-trip both fields, role-only, and the legacy/empty cases.
    let both = AXTargetDescriptor.encode(role: "AXButton", identifier: "send")
    #expect(AXTargetDescriptor.decode(both).role == "AXButton")
    #expect(AXTargetDescriptor.decode(both).identifier == "send")

    let roleOnly = AXTargetDescriptor.encode(role: "AXMenuItem", identifier: nil)
    #expect(AXTargetDescriptor.decode(roleOnly).role == "AXMenuItem")
    #expect(AXTargetDescriptor.decode(roleOnly).identifier == nil)

    // Both empty → nothing worth recording.
    #expect(AXTargetDescriptor.encode(role: nil, identifier: nil) == nil)
    #expect(AXTargetDescriptor.encode(role: "  ", identifier: "") == nil)
    // Legacy unseparated string / nil decode to (nil, nil), never crash.
    #expect(AXTargetDescriptor.decode("just a label").role == nil)
    #expect(AXTargetDescriptor.decode(nil).identifier == nil)
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
	        evidenceCount: 4,
	        evidenceIDs: [11, 12, 13, 14]
	    ))

    #expect(saved.id > 0)
    let reread = try await store.agent(id: saved.id)
    #expect(reread?.recipe == recipe)
	    #expect(reread?.apps == ["Mail", "Numbers"])
	    #expect(reread?.estimatedSeconds == 90)
	    #expect(reread?.evidenceIDs == [11, 12, 13, 14])
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
	        evidenceCount: 9,
	        evidenceIDs: [41, 42]
	    ))

    #expect(first.id == second.id) // same row, not a duplicate
    let all = try await store.agents()
	    #expect(all.count == 1)
	    #expect(all.first?.name == "Updated")
	    #expect(all.first?.evidenceCount == 9)
	    #expect(all.first?.evidenceIDs == [41, 42])
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
func scheduleRoundTripsAndSurvivesRedetect() async throws {
    let store = try makeAgentStore()
    let agent = try await store.upsertAgent(CascadeAgent(name: "A", source: .detected, signature: "s", recipe: AgentRecipe(steps: [])))
    #expect(agent.schedule == nil)

    try await store.setAgentSchedule(id: agent.id, schedule: "daily@09:05")
    #expect(try await store.agent(id: agent.id)?.schedule == "daily@09:05")

    // A re-detect refresh must not clear the user's schedule.
    _ = try await store.upsertAgent(CascadeAgent(name: "A v2", source: .detected, signature: "s", recipe: AgentRecipe(steps: [])))
    #expect(try await store.agent(id: agent.id)?.schedule == "daily@09:05")

    try await store.setAgentSchedule(id: agent.id, schedule: nil)
    #expect(try await store.agent(id: agent.id)?.schedule == nil)
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

@Test
func recipeActionKeysIgnoreCoordinatesAndTypedText() {
    let first = RecipeStep(
        order: 1,
        kind: .click,
        x: 10,
        y: 20,
        appName: "Mail",
        bundleIdentifier: "com.apple.mail",
        windowTitleHint: "Inbox",
        ocrAnchor: "Send",
        targetDescriptor: AXTargetDescriptor.encode(role: "AXButton", identifier: "send")
    )
    let moved = RecipeStep(
        order: 1,
        kind: .click,
        x: 90,
        y: 120,
        appName: "Mail",
        bundleIdentifier: "com.apple.mail",
        windowTitleHint: "Inbox",
        ocrAnchor: "Send",
        targetDescriptor: AXTargetDescriptor.encode(role: "AXButton", identifier: "send")
    )
    let differentLabel = RecipeStep(
        order: 1,
        kind: .click,
        x: 10,
        y: 20,
        appName: "Mail",
        bundleIdentifier: "com.apple.mail",
        windowTitleHint: "Inbox",
        ocrAnchor: "Archive",
        targetDescriptor: AXTargetDescriptor.encode(role: "AXButton", identifier: "archive")
    )
    let typedSecret = RecipeStep(order: 2, kind: .type, text: "secret offer 123-45-6789", appName: "Mail")
    let typedOther = RecipeStep(order: 2, kind: .type, text: "different private text", appName: "Mail")

    #expect(first.idempotentActionKey == moved.idempotentActionKey)
    #expect(first.idempotentActionKey != differentLabel.idempotentActionKey)
    #expect(typedSecret.idempotentActionKey == typedOther.idempotentActionKey)
    #expect(!typedSecret.idempotentActionKey.contains("secret"))
    #expect(!typedSecret.idempotentActionKey.contains("123"))
}

@Test
func curatedGoalRoundTripsAndSurvivesRedetect() async throws {
    let store = try makeAgentStore()
    let goal = "Copy the latest invoice totals out of Mail into the Numbers tracker."
    let agent = try await store.upsertAgent(CascadeAgent(
        name: "Copy invoice totals into Numbers",
        source: .detected, signature: "s", recipe: AgentRecipe(steps: []), goal: goal
    ))
    #expect(agent.goal == goal)

    // A re-detect refresh supplies no goal — the curated goal (like run history
    // and schedule) belongs to the approved agent and must survive.
    _ = try await store.upsertAgent(CascadeAgent(
        name: "Copy invoice totals into Numbers v2",
        source: .detected, signature: "s", recipe: AgentRecipe(steps: [])
    ))
    let refreshed = try await store.agent(id: agent.id)
    #expect(refreshed?.goal == goal)
    #expect(refreshed?.name == "Copy invoice totals into Numbers v2") // name still refreshes
}

@Test
func agentDemoSketchesRoundTripAndSurviveRedetect() async throws {
    let store = try makeAgentStore()
    let demo = AgentDemoSketch(
        id: "mail-send",
        appName: "Mail",
        windowTitle: "Inbox",
        normalizedGoalTokens: ["send", "reply"],
        promptText: "TRAJECTORY SKETCH\napp: Mail\nfirst_actions:\n1. click \"Send\"",
        actionCount: 1,
        anchorCount: 1,
        checkCount: 0
    )
    let agent = try await store.upsertAgent(CascadeAgent(
        name: "Send reply",
        source: .detected,
        signature: "mail-send",
        recipe: AgentRecipe(steps: []),
        demoSketches: [demo]
    ))

    #expect(try await store.agent(id: agent.id)?.demoSketches == [demo])

    _ = try await store.upsertAgent(CascadeAgent(
        name: "Send reply v2",
        source: .detected,
        signature: "mail-send",
        recipe: AgentRecipe(steps: [])
    ))

    let refreshed = try #require(await store.agent(id: agent.id))
    #expect(refreshed.demoSketches == [demo])
}

@Test
func cascadeAgentDecodesLegacyPayloadWithoutDemoSketches() throws {
    let json = """
    {
      "id": 1,
      "name": "Legacy",
      "source": "detected",
      "signature": "legacy",
      "recipe": { "steps": [] }
    }
    """
    let agent = try JSONDecoder().decode(CascadeAgent.self, from: Data(json.utf8))

    #expect(agent.demoSketches.isEmpty)
    #expect(agent.apps.isEmpty)
    #expect(agent.enabled)
}
