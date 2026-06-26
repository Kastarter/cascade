import CascadeMemory
import Foundation
import Testing

private func makeVisualStore() throws -> CascadeStore {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("CascadeVisualTests-\(UUID().uuidString).sqlite")
        .path
    return try CascadeStore(path: path)
}

@Test
func visualL2ScanReturnsNearestNeighborOrder() async throws {
    let store = try makeVisualStore()
    let near = try await store.insert(RecordedContext(source: .screen, appName: "Preview", ocrText: "near"))
    let mid = try await store.insert(RecordedContext(source: .screen, appName: "Preview", ocrText: "mid"))
    let far = try await store.insert(RecordedContext(source: .screen, appName: "Preview", ocrText: "far"))

    try await store.upsertVisualEmbedding(contextID: far.id, vector: [8, 8], provider: "fixture", model: "clip", revision: "r1")
    try await store.upsertVisualEmbedding(contextID: near.id, vector: [1, 1], provider: "fixture", model: "clip", revision: "r1")
    try await store.upsertVisualEmbedding(contextID: mid.id, vector: [3, 3], provider: "fixture", model: "clip", revision: "r1")

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
func visualCosineScanSkipsIncompatibleDimensionsAndRevisions() async throws {
    let store = try makeVisualStore()
    let compatible = try await store.insert(RecordedContext(source: .screen, appName: "Finder", ocrText: "compatible"))
    let wrongRevision = try await store.insert(RecordedContext(source: .screen, appName: "Finder", ocrText: "revision"))
    let wrongDimension = try await store.insert(RecordedContext(source: .screen, appName: "Finder", ocrText: "dimension"))

    try await store.upsertVisualEmbedding(contextID: compatible.id, vector: [1, 0, 0], provider: "fixture", model: "clip", revision: "r1")
    try await store.upsertVisualEmbedding(contextID: wrongRevision.id, vector: [1, 0, 0], provider: "fixture", model: "clip", revision: "r2")
    try await store.upsertVisualEmbedding(contextID: wrongDimension.id, vector: [1, 0], provider: "fixture", model: "clip", revision: "r1")

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
func pruneDropsVisualEmbeddingsWithTheirMoments() async throws {
    let store = try makeVisualStore()
    let old = try await store.insert(RecordedContext(
        capturedAt: Date(timeIntervalSinceNow: -100 * 24 * 3600),
        source: .screen,
        appName: "Keynote",
        ocrText: "old visual frame"
    ))
    let fresh = try await store.insert(RecordedContext(source: .screen, appName: "Keynote", ocrText: "fresh visual frame"))

    try await store.upsertVisualEmbedding(contextID: old.id, vector: [1, 0], provider: "fixture", model: "clip", revision: "r1")
    try await store.upsertVisualEmbedding(contextID: fresh.id, vector: [0.8, 0.2], provider: "fixture", model: "clip", revision: "r1")

    _ = try await store.prune(maxAge: 7 * 24 * 3600)
    let ids = try await store.visualRankedIDs(
        matching: [1, 0],
        provider: "fixture",
        model: "clip",
        revision: "r1",
        metric: .cosine,
        limit: 5
    )

    #expect(ids == [fresh.id])
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
