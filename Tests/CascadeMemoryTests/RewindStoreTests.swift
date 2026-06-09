import CascadeMemory
import Foundation
import Testing

private func makeStore() throws -> CascadeStore {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("CascadeRewindTests-\(UUID().uuidString).sqlite")
        .path
    return try CascadeStore(path: path)
}

@Test
func searchFindsMomentByOcrText() async throws {
    let store = try makeStore()
    _ = try await store.insert(RecordedContext(source: .screen, appName: "Safari", ocrText: "quarterly revenue projections"))
    _ = try await store.insert(RecordedContext(source: .screen, appName: "Mail", ocrText: "lunch plans tomorrow"))

    let hits = try await store.searchContexts(query: "revenue")
    #expect(hits.count == 1)
    #expect(hits.first?.appName == "Safari")
}

@Test
func searchMatchesAppNameAndWindowTitle() async throws {
    let store = try makeStore()
    _ = try await store.insert(RecordedContext(source: .screen, appName: "Figma", windowTitle: "Onboarding flow"))

    #expect(try await store.searchContexts(query: "figma").count == 1)
    #expect(try await store.searchContexts(query: "onboarding").count == 1)
}

@Test
func searchEmptyOrPunctuationOnlyQueryReturnsNothing() async throws {
    let store = try makeStore()
    _ = try await store.insert(RecordedContext(source: .screen, appName: "Safari", ocrText: "hello world"))

    #expect(try await store.searchContexts(query: "   ").isEmpty)
    #expect(try await store.searchContexts(query: "!!! @@@").isEmpty)
}

@Test
func searchWithPunctuationDoesNotThrow() async throws {
    let store = try makeStore()
    _ = try await store.insert(RecordedContext(source: .screen, appName: "Mail", ocrText: "ping user@example.com today"))

    // Tokenizes to user/example/com — all present — without an FTS syntax error.
    let hits = try await store.searchContexts(query: "user@example.com")
    #expect(hits.count == 1)
}

@Test
func frameHashRoundTrips() async throws {
    let store = try makeStore()
    let hash = Int64(bitPattern: UInt64.max) // exercises the full 64-bit pattern (-1)
    let inserted = try await store.insert(RecordedContext(source: .screen, appName: "Safari", frameHash: hash))
    #expect(inserted.frameHash == hash)

    let recent = try await store.recentContexts(limit: 1)
    #expect(recent.first?.frameHash == hash)
}

@Test
func pruneDropsOldMomentsAndSyncsSearchIndex() async throws {
    let store = try makeStore()
    let old = try await store.insert(RecordedContext(
        capturedAt: Date(timeIntervalSinceNow: -100 * 24 * 3600),
        source: .screen,
        appName: "OldApp",
        ocrText: "ancient artifact",
        imagePath: "/tmp/cascade-old.jpg"
    ))
    let fresh = try await store.insert(RecordedContext(
        source: .screen,
        appName: "NewApp",
        ocrText: "recent activity"
    ))

    let removed = try await store.prune(maxAge: 7 * 24 * 3600)

    // The old moment's frame path is returned for file deletion; the row is gone.
    #expect(removed.contains("/tmp/cascade-old.jpg"))
    let recent = try await store.recentContexts(limit: 10)
    #expect(recent.contains { $0.id == fresh.id })
    #expect(!recent.contains { $0.id == old.id })

    // The FTS `_ad` trigger removed the pruned row from the index too.
    #expect(try await store.searchContexts(query: "ancient").isEmpty)
    #expect(try await store.searchContexts(query: "recent").count == 1)
}
