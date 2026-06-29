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
    _ = try await store.insert(RecordedContext(source: .screen, appName: "Mail", ocrText: "ping alpha.example today"))

    // Tokenizes to alpha/example — all present — without an FTS syntax error.
    let hits = try await store.searchContexts(query: "alpha.example")
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

@Test
func ocrStructureSidecarRoundTripsAndPrunesWithContext() async throws {
    let store = try makeStore()
    let old = try await store.insert(RecordedContext(
        capturedAt: Date(timeIntervalSinceNow: -100 * 24 * 3600),
        source: .screen,
        appName: "Numbers",
        ocrText: "flat text"
    ))
    let fresh = try await store.insert(RecordedContext(
        source: .screen,
        appName: "Numbers",
        ocrText: "new flat text"
    ))

    try await store.insertOCRStructure(
        contextID: old.id,
        version: 2,
        json: #"{"version":2,"fields":[{"key":"TOTAL DUE","value":"$443,355"}]}"#,
        searchableText: "TOTAL DUE $443,355"
    )
    try await store.insertOCRStructure(
        contextID: fresh.id,
        version: 2,
        json: #"{"version":2,"fields":[{"key":"Status","value":"Ready"}]}"#,
        searchableText: "Status Ready"
    )

    #expect(try await store.ocrStructure(contextID: old.id)?.version == 2)

    _ = try await store.prune(maxAge: 7 * 24 * 3600)

    #expect(try await store.ocrStructure(contextID: old.id) == nil)
    #expect(try await store.ocrStructure(contextID: fresh.id)?.searchableText == "Status Ready")
}

@Test
func hybridSearchUsesStructuredSidecarLane() async throws {
    let store = try makeStore()
    let moment = try await store.insert(RecordedContext(
        source: .screen,
        appName: "Preview",
        ocrText: "plain invoice frame"
    ))
    try await store.insertOCRStructure(
        contextID: moment.id,
        version: 2,
        json: #"{"version":2,"fields":[{"key":"Amount Due","value":"$443,355"}],"tables":[]}"#,
        searchableText: "Amount Due $443,355"
    )

    let hits = try await store.hybridContexts(matching: "amount due", limit: 5)

    #expect(hits.map(\.id).contains(moment.id))
}

@Test
func contextTimelineReturnsRowsSinceCutoffWithoutHeavyPayloads() async throws {
    let store = try makeStore()
    _ = try await store.insert(RecordedContext(
        capturedAt: Date(timeIntervalSinceNow: -48 * 3600),
        source: .screen,
        appName: "OldApp",
        ocrText: "stale text"
    ))
    _ = try await store.insert(RecordedContext(
        capturedAt: Date(timeIntervalSinceNow: -3600),
        source: .screen,
        appName: "RecentApp",
        windowTitle: "Today's window",
        ocrText: "fresh text",
        metadataJSON: "{\"k\":1}"
    ))

    let rows = try await store.contextTimeline(since: Date(timeIntervalSinceNow: -24 * 3600))

    #expect(rows.map(\.appName) == ["RecentApp"])
    // Identity and title survive; the heavy payloads are not decoded.
    #expect(rows.first?.windowTitle == "Today's window")
    #expect(rows.first?.ocrText == nil)
    #expect(rows.first?.metadataJSON == nil)
}

@Test
func contentSamplesPickTheRichestMomentPerAppPerHour() async throws {
    let store = try makeStore()
    let base = Date(timeIntervalSince1970: 1_700_000_000)  // 22:13:20 UTC
    _ = try await store.insert(RecordedContext(
        capturedAt: base, source: .screen, appName: "Chrome", ocrText: "tiny"
    ))
    _ = try await store.insert(RecordedContext(
        capturedAt: base.addingTimeInterval(60), source: .screen, appName: "Chrome",
        ocrText: "the long assignment page with the deadline details"
    ))
    _ = try await store.insert(RecordedContext(
        capturedAt: base.addingTimeInterval(120), source: .screen, appName: "Xcode", ocrText: "build output"
    ))
    _ = try await store.insert(RecordedContext(
        capturedAt: base.addingTimeInterval(4000), source: .screen, appName: "Chrome", ocrText: "later hour content"
    ))

    let samples = try await store.contentSamples(since: base.addingTimeInterval(-60), excerptLength: 20)

    // One row per app per hour: Chrome 22h (the richest of its two), Xcode 22h, Chrome 23h.
    #expect(samples.count == 3)
    let chromeEarly = samples.first { $0.appName == "Chrome" && $0.capturedAt < base.addingTimeInterval(3000) }
    #expect(chromeEarly?.capturedAt == base.addingTimeInterval(60))
    // The excerpt is trimmed to the requested length.
    #expect(chromeEarly?.ocrText == "the long assignment ")
}

@Test
func relevantContextsMatchNaturalLanguageQuestions() async throws {
    let store = try makeStore()
    _ = try await store.insert(RecordedContext(
        source: .screen, appName: "Chrome",
        ocrText: "Final Project Mental Health Action Plan due Jul 30"
    ))
    _ = try await store.insert(RecordedContext(
        source: .screen, appName: "Xcode", ocrText: "compiling swift sources"
    ))

    // A stopword-heavy question still recalls the moment via its content words.
    let hits = try await store.relevantContexts(to: "when is the final project due?")
    #expect(hits.map(\.appName) == ["Chrome"])

    // Nothing meaningful to match on → no recall, not an FTS error.
    #expect(try await store.relevantContexts(to: "what was the…?").isEmpty)
}
