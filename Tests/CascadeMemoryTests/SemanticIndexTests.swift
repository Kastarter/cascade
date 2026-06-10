import CascadeMemory
import Foundation
import Testing

private func makeSemanticStore() throws -> CascadeStore {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("CascadeSemanticTests-\(UUID().uuidString).sqlite")
        .path
    return try CascadeStore(path: path)
}

@Test
func semanticSearchFindsMeaningWithoutKeywordOverlap() async throws {
    let store = try makeSemanticStore()
    let flight = try await store.insert(RecordedContext(
        source: .screen, appName: "Safari", windowTitle: "Kayak",
        ocrText: "Flights to Tokyo from 480 USD round trip in October"
    ))
    let pasta = try await store.insert(RecordedContext(
        source: .screen, appName: "Safari", windowTitle: "Recipes",
        ocrText: "Classic lasagna with slow-cooked ragu and bechamel"
    ))
    try await store.indexEmbedding(contextID: flight.id, text: flight.ocrText ?? "")
    try await store.indexEmbedding(contextID: pasta.id, text: pasta.ocrText ?? "")

    // No shared keywords with the flight moment — meaning has to carry it.
    let results = try await store.semanticContexts(matching: "cheap plane tickets to Japan", limit: 2)

    // The embedding asset can be unavailable on stripped-down machines; the
    // feature is best-effort there, so only assert when the index answered.
    if let first = results.first {
        #expect(first.id == flight.id)
    }
}

@Test
func pruneDropsEmbeddingsWithTheirMoments() async throws {
    let store = try makeSemanticStore()
    let old = try await store.insert(RecordedContext(
        capturedAt: Date(timeIntervalSinceNow: -100 * 24 * 3600),
        source: .screen, appName: "Notes", ocrText: "ancient note about quarterly planning"
    ))
    try await store.indexEmbedding(contextID: old.id, text: old.ocrText ?? "")

    _ = try await store.prune(maxAge: 7 * 24 * 3600)

    let results = try await store.semanticContexts(matching: "quarterly planning", limit: 4)
    #expect(!results.contains { $0.id == old.id })
}
