@testable import CascadeMemory
import Foundation
import Testing

private func makeWorkGraphCaptureStore() throws -> CascadeStore {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("WorkGraphCaptureIntegrationTests-\(UUID().uuidString).sqlite")
        .path
    return try CascadeStore(path: path)
}

private func entityTimelineOrEmpty(
    _ store: CascadeStore,
    kind: WorkGraphEntityKind,
    canonicalValue: String
) async throws -> [WorkGraphTimelineEntry] {
    do {
        return try await store.entityTimeline(kind: kind, canonicalValue: canonicalValue)
    } catch CascadeStoreError.sqlite(let message) where message.contains("work graph entity not found") {
        return []
    }
}

private func workGraphCaptureContext(capturedAt: Date = Date(timeIntervalSince1970: 1_780_000_000)) -> RecordedContext {
    RecordedContext(
        capturedAt: capturedAt,
        source: .screen,
        appName: "Safari",
        bundleIdentifier: "com.apple.Safari",
        windowTitle: "Roadmap sync",
        ocrText: """
        Owner: Ada Lovelace reviewed https://example.com/pricing?token=1234 on 2026-06-26 \
        and saved /Users/khalidsh/Reports/Q2.csv
        """
    )
}

@Test
func defaultContextInsertsDoNotIndexWorkGraph() async throws {
    let store = try makeWorkGraphCaptureStore()

    _ = try await store.insertContexts([workGraphCaptureContext()])

    #expect(try await entityTimelineOrEmpty(store, kind: .app, canonicalValue: "com.apple.safari").isEmpty)
    #expect(try await entityTimelineOrEmpty(store, kind: .window, canonicalValue: "roadmap sync").isEmpty)
    #expect(try await entityTimelineOrEmpty(store, kind: .url, canonicalValue: "https://example.com/pricing").isEmpty)
    #expect(try await entityTimelineOrEmpty(store, kind: .file, canonicalValue: "/Users/khalidsh/Reports/Q2.csv").isEmpty)
    #expect(try await entityTimelineOrEmpty(store, kind: .date, canonicalValue: "2026-06-26").isEmpty)
    #expect(try await entityTimelineOrEmpty(store, kind: .person, canonicalValue: "ada lovelace").isEmpty)
}

@Test
func optInContextInsertsIndexWorkGraphMentions() async throws {
    let store = try makeWorkGraphCaptureStore()

    let inserted = try await store.insertContexts([workGraphCaptureContext()], indexWorkGraph: true)
    let contextID = try #require(inserted.first?.id)

    #expect(try await entityTimelineOrEmpty(store, kind: .app, canonicalValue: "com.apple.safari").map(\.contextID) == [contextID])
    #expect(try await entityTimelineOrEmpty(store, kind: .window, canonicalValue: "roadmap sync").map(\.contextID) == [contextID])
    #expect(try await entityTimelineOrEmpty(store, kind: .url, canonicalValue: "https://example.com/pricing").map(\.contextID) == [contextID])
    #expect(try await entityTimelineOrEmpty(store, kind: .file, canonicalValue: "/Users/khalidsh/Reports/Q2.csv").map(\.contextID) == [contextID])
    #expect(try await entityTimelineOrEmpty(store, kind: .folder, canonicalValue: "/Users/khalidsh/Reports").map(\.contextID) == [contextID])
    #expect(try await entityTimelineOrEmpty(store, kind: .date, canonicalValue: "2026-06-26").map(\.contextID) == [contextID])
    #expect(try await entityTimelineOrEmpty(store, kind: .person, canonicalValue: "ada lovelace").map(\.contextID) == [contextID])
    #expect(try await entityTimelineOrEmpty(store, kind: .organization, canonicalValue: "example").map(\.contextID) == [contextID])
    #expect(try await entityTimelineOrEmpty(store, kind: .project, canonicalValue: "reports").map(\.contextID) == [contextID])
}

@Test
func optInURLAliasesAndTimelineDoNotPersistQuerySecrets() async throws {
    let store = try makeWorkGraphCaptureStore()

    _ = try await store.insertContexts([workGraphCaptureContext()], indexWorkGraph: true)

    let entity = try await store.graphEntity(kind: .url, canonicalValue: "https://example.com/pricing")
    let canonicalAlias = try await store.graphEntityAlias(
        entityID: entity.id,
        normalizedAlias: "https://example.com/pricing"
    )
    let displayAlias = try await store.graphEntityAlias(
        entityID: entity.id,
        normalizedAlias: "example.com/pricing"
    )
    let timeline = try await store.entityTimeline(entityID: entity.id)

    let persistedValues = [
        entity.canonicalValue,
        entity.displayName,
        canonicalAlias.alias,
        canonicalAlias.normalizedAlias,
        displayAlias.alias,
        displayAlias.normalizedAlias
    ] + timeline.map(\.evidenceSnippet)

    for value in persistedValues {
        #expect(!value.contains("token=1234"))
        #expect(!value.contains("?token=1234"))
        #expect(!value.contains("pricing?token"))
    }
}

@Test
func sensitiveOptInContextInsertsDoNotIndexWorkGraph() async throws {
    let store = try makeWorkGraphCaptureStore()
    let sensitive = RecordedContext(
        source: .screen,
        appName: "Safari",
        bundleIdentifier: "com.apple.Safari",
        windowTitle: "Roadmap sync",
        ocrText: "Owner: Ada Lovelace opened https://example.com/pricing for password review on 2026-06-26"
    )

    _ = try await store.insertContexts([sensitive], indexWorkGraph: true)

    #expect(try await entityTimelineOrEmpty(store, kind: .app, canonicalValue: "com.apple.safari").isEmpty)
    #expect(try await entityTimelineOrEmpty(store, kind: .person, canonicalValue: "ada lovelace").isEmpty)
    #expect(try await entityTimelineOrEmpty(store, kind: .url, canonicalValue: "https://example.com/pricing").isEmpty)
}

@Test
func optInBatchRollbackRemovesPartialWorkGraphLinks() async throws {
    let store = try makeWorkGraphCaptureStore()
    await store.setBatchBindFailureInjector { table, rowIndex in
        if case .recordedContext = table, rowIndex == 1 {
            throw CascadeStoreError.sqlite("injected bind failure")
        }
    }

    do {
        _ = try await store.insertContexts([
            workGraphCaptureContext(),
            workGraphCaptureContext(capturedAt: Date(timeIntervalSince1970: 1_780_000_060))
        ], indexWorkGraph: true)
        #expect(Bool(false), "Expected injected context bind failure")
    } catch {
        #expect(error is CascadeStoreError)
    }

    #expect(try await store.recentContexts(limit: 10).isEmpty)
    #expect(try await entityTimelineOrEmpty(store, kind: .app, canonicalValue: "com.apple.safari").isEmpty)
    #expect(try await entityTimelineOrEmpty(store, kind: .url, canonicalValue: "https://example.com/pricing").isEmpty)
    #expect(try await entityTimelineOrEmpty(store, kind: .file, canonicalValue: "/Users/khalidsh/Reports/Q2.csv").isEmpty)
    #expect(try await entityTimelineOrEmpty(store, kind: .person, canonicalValue: "ada lovelace").isEmpty)
    #expect(try await store.currentGraphEdges(limit: 10).isEmpty)
}
