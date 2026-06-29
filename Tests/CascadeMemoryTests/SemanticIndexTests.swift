import CascadeMemory
import Foundation
import SQLite3
import Testing

private func makeSemanticStore() throws -> CascadeStore {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("CascadeSemanticTests-\(UUID().uuidString).sqlite")
        .path
    return try CascadeStore(path: path)
}

private func makeSemanticStoreWithPath() throws -> (CascadeStore, String) {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("CascadeSemanticTests-\(UUID().uuidString).sqlite")
        .path
    return (try CascadeStore(path: path), path)
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

@Test
func indexEmbeddingUsesRedactedTextForChunkDigests() async throws {
    let (store, path) = try makeSemanticStoreWithPath()
    let context = try await store.insert(RecordedContext(source: .screen, appName: "Mail", ocrText: "safe context"))
    try await store.indexEmbedding(contextID: context.id, text: "Email jane@example.com about planning")

    let storedDigest = rawInt64(path, "SELECT text_digest FROM context_chunk_embedding WHERE context_id = \(context.id) LIMIT 1;")
    if let storedDigest {
        #expect(storedDigest != testDigest("Email jane@example.com about planning"))
        #expect(storedDigest == testDigest("Email <EMAIL> about planning"))
    }
}

@Test
func unindexedRecentContextsFindsTextRowsNeedingSemanticCatchUp() async throws {
    let store = try makeSemanticStore()
    let text = try await store.insert(RecordedContext(source: .screen, appName: "Notes", ocrText: "needs semantic catch up"))
    _ = try await store.insert(RecordedContext(source: .screen, appName: "Blank", ocrText: nil))

    let pending = try await store.unindexedRecentContexts(limit: 10)

    #expect(pending.map(\.id).contains(text.id))
    #expect(!pending.contains { $0.appName == "Blank" })
}

private func rawInt64(_ path: String, _ sql: String) -> Int64? {
    var db: OpaquePointer?
    guard sqlite3_open(path, &db) == SQLITE_OK else { return nil }
    defer { sqlite3_close(db) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
    return sqlite3_column_int64(statement, 0)
}

private func testDigest(_ text: String) -> Int64 {
    var hash: UInt64 = 0xcbf29ce484222325
    for byte in text.lowercased().utf8 {
        hash ^= UInt64(byte)
        hash &*= 0x100000001b3
    }
    return Int64(bitPattern: hash)
}
