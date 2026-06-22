import CascadeMemory
import Foundation
import Testing

private func makeHybridStore() throws -> CascadeStore {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("CascadeHybridTests-\(UUID().uuidString).sqlite")
        .path
    return try CascadeStore(path: path)
}

@Test
func hybridSearchReturnsKeywordMatches() async throws {
    let store = try makeHybridStore()
    let revenue = try await store.insert(RecordedContext(
        source: .screen, appName: "Safari", windowTitle: "Inbox",
        ocrText: "quarterly revenue projections"))
    _ = try await store.insert(RecordedContext(
        source: .screen, appName: "Mail", ocrText: "lunch plans tomorrow"))

    let hits = try await store.hybridContexts(matching: "revenue", limit: 12)
    #expect(hits.contains { $0.id == revenue.id })          // keyword lane carries it
    #expect(!hits.contains { $0.ocrText == "lunch plans tomorrow" })
}

@Test
func hybridSearchNoMatchReturnsEmpty() async throws {
    let store = try makeHybridStore()
    _ = try await store.insert(RecordedContext(source: .screen, appName: "Mail", ocrText: "hello"))
    let hits = try await store.hybridContexts(matching: "zzzzneverrecorded", limit: 12)
    #expect(hits.isEmpty)
}

@Test
func hybridSearchSurfacesSemanticMatchAlongsideAKeywordHit() async throws {
    let store = try makeHybridStore()
    // A literal keyword hit on "japan"…
    let keyword = try await store.insert(RecordedContext(
        source: .screen, appName: "Notes", ocrText: "japan trip checklist"))
    // …and a semantically-related moment with NO keyword overlap with "japan".
    let semantic = try await store.insert(RecordedContext(
        source: .screen, appName: "Safari", windowTitle: "Kayak",
        ocrText: "Flights to Tokyo from 480 USD round trip in October"))
    try await store.indexEmbedding(contextID: keyword.id, text: keyword.ocrText ?? "")
    try await store.indexEmbedding(contextID: semantic.id, text: semantic.ocrText ?? "")

    let hits = try await store.hybridContexts(matching: "japan", limit: 12)
    // The keyword lane always finds the literal "japan" moment.
    #expect(hits.contains { $0.id == keyword.id })

    // The whole point of fusing instead of falling back: when the embedding asset
    // is available, the OLD cascade would NOT have consulted the semantic lane
    // (keyword already returned a hit), so the Tokyo-flights moment would be
    // invisible. RRF consults both, so it surfaces. Guarded because the embedding
    // asset can be absent on stripped-down machines (feature is best-effort there).
    let semanticIDs = try await store.semanticRankedIDs(matching: "japan", limit: 40)
    if semanticIDs.contains(semantic.id) {
        #expect(hits.contains { $0.id == semantic.id })
    }
}
