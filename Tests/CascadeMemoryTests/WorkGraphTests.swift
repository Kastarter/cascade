import CascadeMemory
import Foundation
import Testing

private func makeWorkGraphStore() throws -> CascadeStore {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("CascadeWorkGraphTests-\(UUID().uuidString).sqlite")
        .path
    return try CascadeStore(path: path)
}

@Test
func inMemoryStoreMigrationCreatesWorkGraphTables() async throws {
    let store = try CascadeStore(path: ":memory:")
    let source = try await store.upsertGraphEntity(kind: .app, canonicalValue: "com.apple.notes", displayName: "Notes")
    let target = try await store.upsertGraphEntity(kind: .file, canonicalValue: "/Users/khalidsh/Reports/Q2.csv", displayName: "Q2.csv")

    let edge = try await store.upsertGraphEdge(
        sourceEntityID: source.id,
        targetEntityID: target.id,
        relation: "opened",
        evidence: "Notes opened /Users/khalidsh/Reports/Q2.csv"
    )

    #expect(source.id > 0)
    #expect(target.id > 0)
    #expect(edge?.sourceEntityID == source.id)
}

@Test
func repeatedAliasesUpsertByNormalizedValue() async throws {
    let store = try makeWorkGraphStore()
    let entity = try await store.upsertGraphEntity(kind: .window, canonicalValue: "Weekly Review", displayName: "Weekly Review")

    let first = try await store.upsertGraphEntityAlias(entityID: entity.id, alias: "Q2 Roadmap", source: "test")
    let second = try await store.upsertGraphEntityAlias(entityID: entity.id, alias: "  q2   roadmap  ", source: "test")

    #expect(first.id == second.id)
    #expect(second.normalizedAlias == "q2 roadmap")
    #expect(second.mentionCount == first.mentionCount + 1)
}

@Test
func extractorFindsDeterministicWorkGraphEntityKinds() {
    let context = RecordedContext(
        source: .screen,
        appName: "Safari",
        bundleIdentifier: "com.apple.Safari",
        windowTitle: "Roadmap sync",
        ocrText: """
        Owner: Ada Lovelace visited https://example.com/pricing?token=1234 on 2026-06-26 \
        and saved /Users/khalidsh/Reports/Q2.csv
        """
    )

    let mentions = WorkGraphExtractor.mentions(in: context)
    let kinds = Set(mentions.map(\.kind))

    #expect(kinds.isSuperset(of: [.app, .window, .url, .file, .date, .person]))
    #expect(mentions.contains { $0.kind == .url && $0.canonicalValue == "https://example.com/pricing" })
    #expect(mentions.contains { $0.kind == .file && $0.canonicalValue == "/Users/khalidsh/Reports/Q2.csv" })
    #expect(mentions.contains { $0.kind == .date && $0.canonicalValue == "2026-06-26" })
    #expect(mentions.contains { $0.kind == .person && $0.canonicalValue == "ada lovelace" })
}

@Test
func urlFileAppAndDateEntitiesLinkToMoments() async throws {
    let store = try makeWorkGraphStore()
    let capturedAt = Date(timeIntervalSince1970: 1_780_000_000)
    let context = try await store.insert(RecordedContext(
        capturedAt: capturedAt,
        source: .screen,
        appName: "Safari",
        bundleIdentifier: "com.apple.Safari",
        windowTitle: "Finance dashboard",
        ocrText: "Review https://example.com/report and /Users/khalidsh/Reports/Q2.csv by 2026-06-26"
    ))

    let entries = try await store.linkWorkGraphEntities(for: context)
    let kinds = Set(entries.map(\.kind))

    #expect(kinds.isSuperset(of: [.app, .url, .file, .date]))
    #expect(try await store.entityTimeline(kind: .url, canonicalValue: "https://example.com/report").map(\.contextID) == [context.id])
    #expect(try await store.entityTimeline(kind: .file, canonicalValue: "/Users/khalidsh/Reports/Q2.csv").map(\.contextID) == [context.id])
    #expect(try await store.entityTimeline(kind: .app, canonicalValue: "com.apple.safari").map(\.contextID) == [context.id])
    #expect(try await store.entityTimeline(kind: .date, canonicalValue: "2026-06-26").map(\.contextID) == [context.id])
}

@Test
func sensitiveEvidenceIsRefusedOrRedactedBeforeStorage() async throws {
    let store = try makeWorkGraphStore()
    let context = try await store.insert(RecordedContext(
        source: .screen,
        appName: "Mail",
        ocrText: "Contact alex@example.com about the launch."
    ))
    let person = try await store.upsertGraphEntity(kind: .person, canonicalValue: "alex@example.com", displayName: "alex")

    let redacted = try await store.linkGraphEntity(
        contextID: context.id,
        entityID: person.id,
        evidence: "alex@example.com"
    )
    let refused = try await store.linkGraphEntity(
        contextID: context.id,
        entityID: person.id,
        relation: "sensitive",
        evidence: "password reset for bank account"
    )
    let timeline = try await store.entityTimeline(entityID: person.id)

    #expect(redacted?.evidenceSnippet == "[email]")
    #expect(refused == nil)
    #expect(timeline.map(\.relation) == ["observed"])
}

@Test
func entityTimelineReturnsCitedContextsInTimeOrder() async throws {
    let store = try makeWorkGraphStore()
    let base = Date(timeIntervalSince1970: 1_780_000_000)
    let newer = try await store.insert(RecordedContext(capturedAt: base.addingTimeInterval(30), source: .screen, appName: "Safari", ocrText: "newer"))
    let older = try await store.insert(RecordedContext(capturedAt: base, source: .screen, appName: "Safari", ocrText: "older"))
    let entity = try await store.upsertGraphEntity(kind: .url, canonicalValue: "https://example.com/report", displayName: "example.com/report")

    try await store.linkGraphEntity(contextID: newer.id, entityID: entity.id, evidence: "newer example.com/report", observedAt: newer.capturedAt)
    let olderLink = try await store.linkGraphEntity(contextID: older.id, entityID: entity.id, evidence: "older example.com/report", observedAt: older.capturedAt)

    let timeline = try await store.entityTimeline(entityID: entity.id)

    #expect(olderLink?.contextID == older.id)
    #expect(olderLink?.evidenceSnippet == "older example.com/report")
    #expect(timeline.map(\.contextID) == [older.id, newer.id])
    #expect(timeline.map(\.evidenceSnippet) == ["older example.com/report", "newer example.com/report"])
}

@Test
func planningPriorsIndexSkillsAndExperienceOutcomes() async throws {
    let store = try makeWorkGraphStore()
    try await store.indexPlanningSkill(
        name: "Mail Reply",
        appNames: ["Mail"],
        useWhen: "reply to customer email",
        dangerous: false
    )
    try await store.indexAgentExperienceOutcome(AgentExperienceCase(
        appName: "Mail",
        goalPattern: "reply to customer email",
        recipeSignature: "mail-reply-recipe",
        skillSlug: "Mail Reply",
        outcome: .success,
        verificationSignal: .verified,
        actionCount: 4
    ))
    try await store.indexAgentExperienceOutcome(AgentExperienceCase(
        appName: "Mail",
        goalPattern: "send message from wrong thread",
        recipeSignature: "bad-thread-recipe",
        outcome: .failure,
        failureKind: .groundingMiss,
        actionCount: 2
    ))

    let priors = try await store.planningPriors(goal: "send message from wrong thread in Mail", appName: "Mail", limit: 8)
    let relations = Set(priors.map(\.relation))

    #expect(priors.contains { $0.kind == .skill && $0.displayName == "Mail Reply" })
    #expect(relations.contains("uses_skill") || relations.contains("covers_app"))
    #expect(priors.contains { $0.kind == .recipe && $0.weight > 0 })
    #expect(priors.contains { $0.kind == .expectedEffect && $0.weight < 0 })
}
