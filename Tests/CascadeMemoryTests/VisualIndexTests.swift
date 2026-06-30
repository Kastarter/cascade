import CascadeMemory
import Foundation
import SQLite3
import Testing

private func makeVisualStore() throws -> CascadeStore {
    try makeVisualStoreWithPath().0
}

private func makeVisualStoreWithPath() throws -> (CascadeStore, String) {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("CascadeVisualTests-\(UUID().uuidString).sqlite")
        .path
    return (try CascadeStore(path: path), path)
}

@Test
func visualL2ScanReturnsNearestNeighborOrder() async throws {
    let store = try makeVisualStore()
    let near = try await store.insert(RecordedContext(source: .screen, appName: "Preview", ocrText: "near"))
    let mid = try await store.insert(RecordedContext(source: .screen, appName: "Preview", ocrText: "mid"))
    let far = try await store.insert(RecordedContext(source: .screen, appName: "Preview", ocrText: "far"))

    try await store.indexVisualFeature(contextID: far.id, provider: "fixture", model: "clip", revision: "r1", dimension: 2, metric: "l2", vector: [8, 8])
    try await store.indexVisualFeature(contextID: near.id, provider: "fixture", model: "clip", revision: "r1", dimension: 2, metric: "l2", vector: [1, 1])
    try await store.indexVisualFeature(contextID: mid.id, provider: "fixture", model: "clip", revision: "r1", dimension: 2, metric: "l2", vector: [3, 3])

    let ids = try await store.visualRankedIDs(
        matching: [1.1, 1.1],
        provider: "fixture",
        model: "clip",
        revision: "r1",
        metric: .l2,
        limit: 3
    )

    #expect(ids == [near.id, mid.id, far.id])
}

@Test
func visualCosineScanSkipsIncompatibleDescriptorRows() async throws {
    let store = try makeVisualStore()
    let compatible = try await store.insert(RecordedContext(source: .screen, appName: "Finder", ocrText: "compatible"))
    let wrongProvider = try await store.insert(RecordedContext(source: .screen, appName: "Finder", ocrText: "provider"))
    let wrongModel = try await store.insert(RecordedContext(source: .screen, appName: "Finder", ocrText: "model"))
    let wrongRevision = try await store.insert(RecordedContext(source: .screen, appName: "Finder", ocrText: "revision"))
    let wrongDimension = try await store.insert(RecordedContext(source: .screen, appName: "Finder", ocrText: "dimension"))
    let wrongMetric = try await store.insert(RecordedContext(source: .screen, appName: "Finder", ocrText: "metric"))

    try await store.indexVisualFeature(contextID: compatible.id, provider: "fixture", model: "clip", revision: "r1", dimension: 3, metric: "cosine", vector: [1, 0, 0])
    try await store.indexVisualFeature(contextID: wrongProvider.id, provider: "other", model: "clip", revision: "r1", dimension: 3, metric: "cosine", vector: [1, 0, 0])
    try await store.indexVisualFeature(contextID: wrongModel.id, provider: "fixture", model: "vision", revision: "r1", dimension: 3, metric: "cosine", vector: [1, 0, 0])
    try await store.indexVisualFeature(contextID: wrongRevision.id, provider: "fixture", model: "clip", revision: "r2", dimension: 3, metric: "cosine", vector: [1, 0, 0])
    try await store.indexVisualFeature(contextID: wrongDimension.id, provider: "fixture", model: "clip", revision: "r1", dimension: 2, metric: "cosine", vector: [1, 0])
    try await store.indexVisualFeature(contextID: wrongMetric.id, provider: "fixture", model: "clip", revision: "r1", dimension: 3, metric: "l2", vector: [1, 0, 0])

    let ids = try await store.visualRankedIDs(
        matching: [0.9, 0.1, 0],
        provider: "fixture",
        model: "clip",
        revision: "r1",
        metric: .cosine,
        limit: 5
    )

    #expect(ids == [compatible.id])
}

@Test
func indexVisualFeatureValidatesDimensionAndFiniteVectors() async throws {
    let store = try makeVisualStore()
    let context = try await store.insert(RecordedContext(source: .screen, appName: "Preview", imagePath: "/captures/a.png"))

    do {
        try await store.indexVisualFeature(contextID: context.id, provider: "fixture", model: "clip", revision: "r1", dimension: 3, vector: [1, 2])
        Issue.record("dimension mismatch should fail")
    } catch {}

    do {
        try await store.indexVisualFeature(contextID: context.id, provider: "fixture", model: "clip", revision: "r1", dimension: 1, vector: [Float.nan])
        Issue.record("non-finite vector should fail")
    } catch {}

    #expect(try await store.visualEmbeddingCount() == 0)
}

@Test
func metricNormPersistenceAndMetricFilteredRetrieval() async throws {
    let (store, path) = try makeVisualStoreWithPath()
    let cosine = try await store.insert(RecordedContext(source: .screen, appName: "Charts", imagePath: "/captures/cosine.png"))
    let l2 = try await store.insert(RecordedContext(source: .screen, appName: "Charts", imagePath: "/captures/l2.png"))

    try await store.indexVisualFeature(contextID: cosine.id, provider: "fixture", model: "clip", revision: "r1", dimension: 3, metric: "cosine", vector: [1, 2, 2])
    try await store.indexVisualFeature(contextID: l2.id, provider: "fixture", model: "clip", revision: "r1", dimension: 3, metric: "l2", vector: [1, 2, 2])

    #expect(rawStrings(path, "SELECT metric FROM context_visual_embedding WHERE context_id = \(cosine.id);").first == "cosine")
    #expect(rawDouble(path, "SELECT norm FROM context_visual_embedding WHERE context_id = \(cosine.id);") == 3.0)

    let cosineIDs = try await store.visualRankedIDs(matching: [1, 2, 2], provider: "fixture", model: "clip", revision: "r1", metric: .cosine, limit: 5)
    let l2IDs = try await store.visualRankedIDs(matching: [1, 2, 2], provider: "fixture", model: "clip", revision: "r1", metric: .l2, limit: 5)

    #expect(cosineIDs == [cosine.id])
    #expect(l2IDs == [l2.id])
}

@Test
func pruneAndDeleteDropVisualEmbeddingsAndClustersWithTheirMoments() async throws {
    let (store, path) = try makeVisualStoreWithPath()
    let old = try await store.insert(RecordedContext(
        capturedAt: Date(timeIntervalSinceNow: -100 * 24 * 3600),
        source: .screen,
        appName: "Keynote",
        ocrText: "old visual frame",
        imagePath: "/captures/old.png"
    ))
    let fresh = try await store.insert(RecordedContext(source: .screen, appName: "Keynote", ocrText: "fresh visual frame", imagePath: "/captures/fresh.png"))

    try await store.indexVisualFeature(contextID: old.id, provider: "fixture", model: "clip", revision: "r1", dimension: 2, metric: "cosine", vector: [1, 0])
    try await store.indexVisualFeature(contextID: fresh.id, provider: "fixture", model: "clip", revision: "r1", dimension: 2, metric: "cosine", vector: [0.8, 0.2])
    rawExec(path, """
    INSERT INTO visual_cluster (id, representative_context_id, provider, model, app_name, first_at, last_at, count, label)
    VALUES (101, \(old.id), 'fixture', 'clip', 'Keynote', '2026-06-01T00:00:00.000Z', '2026-06-01T00:00:01.000Z', 1, 'old');
    INSERT INTO context_visual_cluster (context_id, cluster_id, distance) VALUES (\(old.id), 101, 0.0);
    INSERT INTO visual_cluster (id, representative_context_id, provider, model, app_name, first_at, last_at, count, label)
    VALUES (102, \(fresh.id), 'fixture', 'clip', 'Keynote', '2026-06-02T00:00:00.000Z', '2026-06-02T00:00:01.000Z', 1, 'fresh');
    INSERT INTO context_visual_cluster (context_id, cluster_id, distance) VALUES (\(fresh.id), 102, 0.0);
    """)

    _ = try await store.prune(maxAge: 7 * 24 * 3600)
    let ids = try await store.visualRankedIDs(matching: [1, 0], provider: "fixture", model: "clip", revision: "r1", metric: .cosine, limit: 5)

    #expect(ids == [fresh.id])
    #expect(rawInt64(path, "SELECT COUNT(*) FROM visual_cluster WHERE id = 101;") == 0)
    #expect(rawInt64(path, "SELECT COUNT(*) FROM context_visual_cluster WHERE cluster_id = 101;") == 0)
    #expect(rawInt64(path, "SELECT COUNT(*) FROM visual_cluster WHERE id = 102;") == 1)

    rawExec(path, "DELETE FROM recorded_context WHERE id = \(fresh.id);")
    #expect(rawInt64(path, "SELECT COUNT(*) FROM visual_cluster WHERE id = 102;") == 0)
    #expect(rawInt64(path, "SELECT COUNT(*) FROM context_visual_cluster WHERE cluster_id = 102;") == 0)
    #expect(rawInt64(path, "SELECT COUNT(*) FROM context_visual_embedding WHERE context_id = \(fresh.id);") == 0)
}

@Test
func visualContextsSimilarToReferenceReturnsNearestWithoutReference() async throws {
    let store = try makeVisualStore()
    let reference = try await store.insert(RecordedContext(source: .screen, appName: "Preview", imagePath: "/captures/ref.png"))
    let near = try await store.insert(RecordedContext(source: .screen, appName: "Preview", imagePath: "/captures/near.png"))
    let far = try await store.insert(RecordedContext(source: .screen, appName: "Preview", imagePath: "/captures/far.png"))

    try await store.indexVisualFeature(contextID: reference.id, provider: "fixture", model: "clip", revision: "r1", dimension: 2, metric: "cosine", vector: [1, 0])
    try await store.indexVisualFeature(contextID: near.id, provider: "fixture", model: "clip", revision: "r1", dimension: 2, metric: "cosine", vector: [0.9, 0.1])
    try await store.indexVisualFeature(contextID: far.id, provider: "fixture", model: "clip", revision: "r1", dimension: 2, metric: "cosine", vector: [-1, 0])

    let matches = try await store.visualContexts(similarTo: reference.id, limit: 2)

    #expect(matches.map(\.id) == [near.id, far.id])
    #expect(!matches.map(\.id).contains(reference.id))
}

@Test
func visualContextsSimilarToImagePathResolvesExistingStoredPath() async throws {
    let store = try makeVisualStore()
    let reference = try await store.insert(RecordedContext(source: .screen, appName: "Preview", imagePath: "/captures/ref-path.png"))
    let near = try await store.insert(RecordedContext(source: .screen, appName: "Preview", imagePath: "/captures/near-path.png"))

    try await store.indexVisualFeature(contextID: reference.id, provider: "fixture", model: "clip", revision: "r1", dimension: 2, metric: "cosine", vector: [1, 0])
    try await store.indexVisualFeature(contextID: near.id, provider: "fixture", model: "clip", revision: "r1", dimension: 2, metric: "cosine", vector: [0.9, 0.1])

    let matches = try await store.visualContexts(similarToImageAt: "/captures/ref-path.png", limit: 4)

    #expect(matches.map(\.id) == [near.id])
}

@Test
func visualSimilarityMissingPathOrVectorReturnsEmpty() async throws {
    let store = try makeVisualStore()
    let noVector = try await store.insert(RecordedContext(source: .screen, appName: "Preview", imagePath: "/captures/no-vector.png"))

    #expect(try await store.visualContexts(similarTo: noVector.id, limit: 4).isEmpty)
    #expect(try await store.visualContexts(similarToImageAt: "/captures/missing.png", limit: 4).isEmpty)
}

@Test
func visualSimilarityFiltersUnsafeAndSensitiveRows() async throws {
    let store = try makeVisualStore()
    let reference = try await store.insert(RecordedContext(source: .screen, appName: "Preview", imagePath: "/captures/ref-safe.png"))
    let visible = try await store.insert(RecordedContext(source: .screen, appName: "Preview", imagePath: "/captures/visible.png"))
    let unsafe = try await store.insert(RecordedContext(source: .screen, appName: "Preview", imagePath: "/captures/unsafe.png", safeToShow: false))
    let unsummarizable = try await store.insert(RecordedContext(source: .screen, appName: "Preview", imagePath: "/captures/unsummarizable.png", safeToSummarize: false))
    let sensitive = try await store.insert(RecordedContext(source: .screen, appName: "Bank Portal", imagePath: "/captures/bank.png"))

    for (context, vector) in [
        (reference, [1, 0] as [Float]),
        (unsafe, [0.99, 0.01]),
        (unsummarizable, [0.98, 0.02]),
        (sensitive, [0.97, 0.03]),
        (visible, [0.7, 0.3]),
    ] {
        try await store.indexVisualFeature(contextID: context.id, provider: "fixture", model: "clip", revision: "r1", dimension: 2, metric: "cosine", vector: vector)
    }

    let matches = try await store.visualContexts(similarTo: reference.id, limit: 4)

    #expect(matches.map(\.id) == [visible.id])
}

@Test
func visualDescriptorManagementSupportsBackfillLanes() async throws {
    let store = try makeVisualStore()
    let first = try await store.insert(RecordedContext(source: .screen, appName: "Safari", imagePath: "/captures/first.png"))
    let second = try await store.insert(RecordedContext(source: .screen, appName: "Safari", imagePath: "/captures/second.png"))
    let noImage = try await store.insert(RecordedContext(source: .screen, appName: "Safari", ocrText: "no image"))
    let descriptorA = VisualEmbeddingDescriptor(provider: "fixture", model: "clip", revision: "r1", dimension: 2, metric: "cosine")
    let descriptorB = VisualEmbeddingDescriptor(provider: "fixture", model: "clip", revision: "r2", dimension: 2, metric: "l2")

    try await store.indexVisualFeature(contextID: first.id, provider: descriptorA.provider, model: descriptorA.model, revision: descriptorA.revision, dimension: descriptorA.dimension, metric: descriptorA.metric, vector: [1, 0])
    try await store.indexVisualFeature(contextID: first.id, provider: descriptorB.provider, model: descriptorB.model, revision: descriptorB.revision, dimension: descriptorB.dimension, metric: descriptorB.metric, vector: [1, 0])
    try await store.indexVisualFeature(contextID: second.id, provider: descriptorB.provider, model: descriptorB.model, revision: descriptorB.revision, dimension: descriptorB.dimension, metric: descriptorB.metric, vector: [0, 1])

    let descriptors = try await store.visualEmbeddingDescriptors()
    let unindexedForA = try await store.unindexedVisualContexts(for: descriptorA, limit: 10)
    let removedB = try await store.deleteVisualEmbeddings(for: descriptorB)

    #expect(descriptors.contains(descriptorA))
    #expect(descriptors.contains(descriptorB))
    #expect(try await store.visualEmbeddingCount(for: descriptorA) == 1)
    #expect(removedB == 2)
    #expect(try await store.visualEmbeddingCount(for: descriptorB) == 0)
    #expect(unindexedForA.map(\.id) == [second.id])
    #expect(!unindexedForA.map(\.id).contains(first.id))
    #expect(!unindexedForA.map(\.id).contains(noImage.id))
}

@Test
func visualLaneKeepsRrfFusionDeterministic() async throws {
    let keywordLane: [Int64] = [10, 20, 30]
    let visualLane: [Int64] = [30, 40, 10]

    let first = RankFusion.reciprocalRankFusion([keywordLane, visualLane], limit: 4)
    let second = RankFusion.reciprocalRankFusion([keywordLane, visualLane], limit: 4)

    #expect(first == [30, 10, 40, 20])
    #expect(second == first)
}

private func rawExec(_ path: String, _ sql: String) {
    var db: OpaquePointer?
    guard sqlite3_open(path, &db) == SQLITE_OK else { return }
    defer { sqlite3_close(db) }
    sqlite3_exec(db, "PRAGMA foreign_keys=ON;", nil, nil, nil)
    sqlite3_exec(db, sql, nil, nil, nil)
}

private func rawStrings(_ path: String, _ sql: String) -> [String] {
    var db: OpaquePointer?
    guard sqlite3_open(path, &db) == SQLITE_OK else { return [] }
    defer { sqlite3_close(db) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
    defer { sqlite3_finalize(statement) }
    var values: [String] = []
    while sqlite3_step(statement) == SQLITE_ROW {
        if let cString = sqlite3_column_text(statement, 0) {
            values.append(String(cString: cString))
        }
    }
    return values
}

private func rawDouble(_ path: String, _ sql: String) -> Double? {
    var db: OpaquePointer?
    guard sqlite3_open(path, &db) == SQLITE_OK else { return nil }
    defer { sqlite3_close(db) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW,
          sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
    return sqlite3_column_double(statement, 0)
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
