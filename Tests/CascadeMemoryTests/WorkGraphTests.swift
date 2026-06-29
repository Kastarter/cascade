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
    #expect(source.confidence == 1.0)
    #expect(source.source == "manual")
    #expect(target.canonicalValue == "/Users/<user>/Reports/Q2.csv")
    #expect(edge?.sourceEntityID == source.id)
    #expect(edge?.confidence == 1.0)
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
        Owner: Ada Lovelace visited https://example.com/pricing?token=1234 on 2026-06-26.
        Action item: follow up with Ada Lovelace due 2026-06-26 #auditFlow CAS-42.
        Saved /Users/khalidsh/Reports/Q2.csv
        """
    )

    let mentions = WorkGraphExtractor.mentions(in: context)
    let kinds = Set(mentions.map(\.kind))

    #expect(kinds.isSuperset(of: [.app, .window, .url, .file, .folder, .date, .person, .organization, .project, .task, .topic]))
    #expect(mentions.contains { $0.kind == .url && $0.canonicalValue == "https://example.com/pricing" })
    #expect(mentions.contains { $0.kind == .file && $0.canonicalValue == "/Users/<user>/Reports/Q2.csv" })
    #expect(mentions.contains { $0.kind == .folder && $0.canonicalValue == "/Users/<user>/Reports" })
    #expect(mentions.contains { $0.kind == .date && $0.canonicalValue == "2026-06-26" })
    #expect(mentions.contains { $0.kind == .person && $0.canonicalValue == "ada lovelace" })
    #expect(mentions.contains { $0.kind == .organization && $0.canonicalValue == "example" })
    #expect(mentions.contains { $0.kind == .project && ($0.canonicalValue == "reports" || $0.canonicalValue == "cas") })
    #expect(mentions.contains { $0.kind == .task && !$0.relationHints.isEmpty })
    #expect(mentions.contains { $0.kind == .topic && $0.canonicalValue == "auditflow" })
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

    #expect(redacted?.evidenceSnippet == "<EMAIL>")
    #expect(refused == nil)
    #expect(timeline.map(\.relation) == ["observed"])
}

@Test
func privacyGateDoesNotPersistRawSecretsInGraphValues() async throws {
    let store = try makeWorkGraphStore()
    let context = try await store.insert(RecordedContext(
        source: .screen,
        appName: "Safari",
        bundleIdentifier: "com.apple.Safari",
        windowTitle: "Token Review",
        ocrText: """
        Visit https://example.com/report?api_key=sk-ant-abcdefghijklmnopqrstuvwxyz123456
        and save /Users/khalidsh/Reports/Q2.csv for alex@example.com.
        """
    ))

    _ = try await store.linkWorkGraphEntities(for: context)
    let url = try await store.graphEntity(kind: .url, canonicalValue: "https://example.com/report")
    let file = try await store.graphEntity(kind: .file, canonicalValue: "/Users/khalidsh/Reports/Q2.csv")
    let urlTimeline = try await store.entityTimeline(entityID: url.id)
    let fileTimeline = try await store.entityTimeline(entityID: file.id)
    let timeline = urlTimeline + fileTimeline
    let values = [url.canonicalValue, url.displayName, file.canonicalValue, file.displayName] + timeline.map(\.evidenceSnippet)

    for value in values {
        #expect(!value.contains("api_key"))
        #expect(!value.contains("sk-ant"))
        #expect(!value.contains("alex@example.com"))
        #expect(!value.contains("/Users/khalidsh"))
    }
}

@Test
func deterministicEdgesConnectFilesProjectsTasksAndDates() async throws {
    let store = try makeWorkGraphStore()
    let context = try await store.insert(RecordedContext(
        source: .screen,
        appName: "Safari",
        bundleIdentifier: "com.apple.Safari",
        windowTitle: "CAS-42 roadmap",
        ocrText: """
        Todo: follow up on CAS-42 due 2026-06-26
        Open https://example.com/CAS-42 and /Users/khalidsh/Reports/Q2.csv
        """
    ), indexWorkGraph: true)

    let edges = try await store.currentGraphEdges(limit: 50)
    let relations = Set(edges.map(\.relation))

    #expect(context.id > 0)
    #expect(relations.isSuperset(of: ["VISITED_URL", "OPENED_FILE", "IN_FOLDER", "BELONGS_TO_PROJECT", "DUE_ON"]))
    #expect(edges.contains { $0.relation == "IN_FOLDER" && $0.provenanceContextID == context.id && $0.extractor == "ocr" })
    #expect(edges.contains { $0.relation == "DUE_ON" && $0.provenanceContextID == context.id })
}

@Test
func bitemporalEdgesKeepHistoryAndCurrentProjection() async throws {
    let store = try makeWorkGraphStore()
    let file = try await store.upsertGraphEntity(kind: .file, canonicalValue: "/Users/khalidsh/Reports/Q2.csv", displayName: "Q2.csv")
    let drafts = try await store.upsertGraphEntity(kind: .folder, canonicalValue: "/Users/khalidsh/Reports/Drafts", displayName: "Drafts")
    let sent = try await store.upsertGraphEntity(kind: .folder, canonicalValue: "/Users/khalidsh/Reports/Sent", displayName: "Sent")

    _ = try await store.upsertGraphEdge(
        sourceEntityID: file.id,
        targetEntityID: drafts.id,
        relation: "IN_FOLDER",
        evidence: "Q2.csv in Drafts"
    )
    let afterFirst = Date()
    try await Task.sleep(nanoseconds: 20_000_000)
    _ = try await store.upsertGraphEdge(
        sourceEntityID: file.id,
        targetEntityID: sent.id,
        relation: "IN_FOLDER",
        evidence: "Q2.csv moved to Sent"
    )

    let historical = try await store.graphEdges(asOf: afterFirst, limit: 20)
    let current = try await store.currentGraphEdges(limit: 20)

    #expect(historical.contains { $0.relation == "IN_FOLDER" && $0.targetEntityID == drafts.id })
    #expect(current.contains { $0.relation == "IN_FOLDER" && $0.targetEntityID == sent.id })
    #expect(!current.contains { $0.relation == "IN_FOLDER" && $0.targetEntityID == drafts.id && $0.transactionTo == nil })
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
    #expect(olderLink?.evidenceSnippet == "older <URL>")
    #expect(timeline.map(\.contextID) == [older.id, newer.id])
    #expect(timeline.map(\.evidenceSnippet) == ["older <URL>", "newer <URL>"])
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
