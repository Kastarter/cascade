import CascadeMemory
import Testing

@Test
func deterministicFallbackEmbeddingsHaveFixedDimension() async throws {
    let provider = DeterministicHashSemanticEmbeddingProvider(dimension: 16)

    let embedding = try await provider.embedding(for: "Quarterly calibration follow-up") ?? []

    #expect(embedding.count == 16)
    #expect(embedding.contains { $0 != 0 })
}

@Test
func normalizedTextHashesAreStable() {
    let first = SemanticEmbeddingText.stableHashHex(for: "Résumé: Project   Alpha!")
    let second = SemanticEmbeddingText.stableHashHex(for: "resume project alpha")

    #expect(SemanticEmbeddingText.normalized("Résumé: Project   Alpha!") == "resume project alpha")
    #expect(first == second)
    #expect(first == "4fd629392313b803")
    #expect(SemanticEmbeddingText.stableHashHex(for: "Candidate follow-up") == "82f4fa9a72a4ec64")
}

@Test
func vectorDistanceMetricsRankExpectedVectors() {
    let query: [Float] = [1, 0]
    let near: [Float] = [0.9, 0.1]
    let orthogonal: [Float] = [0, 1]
    let opposite: [Float] = [-1, 0]

    for metric in VectorDistanceMetric.allCases {
        let ranked = [
            ("orthogonal", orthogonal),
            ("near", near),
            ("opposite", opposite)
        ].sorted {
            metric.rankScore(query: query, candidate: $0.1) > metric.rankScore(query: query, candidate: $1.1)
        }

        #expect(ranked.first?.0 == "near")
        #expect(metric.distance(between: query, and: near) < metric.distance(between: query, and: orthogonal))
        #expect(metric.distance(between: query, and: orthogonal) < metric.distance(between: query, and: opposite))
    }
}

@Test
func modelMetadataChangesCacheKeys() {
    let textHash = SemanticEmbeddingText.stableHashHex(for: "risk review packet")
    let base = SemanticEmbeddingModelMetadata(modelID: "fallback-a", dimension: 8, distanceMetric: .cosine)
    let modelChanged = SemanticEmbeddingModelMetadata(modelID: "fallback-b", dimension: 8, distanceMetric: .cosine)
    let dimensionChanged = SemanticEmbeddingModelMetadata(modelID: "fallback-a", dimension: 16, distanceMetric: .cosine)
    let metricChanged = SemanticEmbeddingModelMetadata(modelID: "fallback-a", dimension: 8, distanceMetric: .dot)

    let keys = [
        base.cacheKey(forNormalizedTextHash: textHash),
        modelChanged.cacheKey(forNormalizedTextHash: textHash),
        dimensionChanged.cacheKey(forNormalizedTextHash: textHash),
        metricChanged.cacheKey(forNormalizedTextHash: textHash)
    ]

    #expect(Set(keys).count == keys.count)
}

@Test
func fallbackOutputIsDeterministicAcrossProviderInstances() async throws {
    let firstProvider = DeterministicHashSemanticEmbeddingProvider(dimension: 32)
    let secondProvider = DeterministicHashSemanticEmbeddingProvider(dimension: 32)

    let first = try await firstProvider.embedding(for: "Manager review calibration")
    let second = try await secondProvider.embedding(for: "Manager review calibration")

    #expect(first == second)
    #expect(firstProvider.metadata.cacheKey(forText: "Manager review calibration") == secondProvider.metadata.cacheKey(forText: "Manager review calibration"))
}

@Test
func localSemanticVectorNormalizesAndKeysDeterministically() {
    let first = LocalSemanticVector.normalizedText("  Résumé  Project — Alpha!  ")
    let second = LocalSemanticVector.normalizedText("resume project alpha")

    #expect(first == "resume project alpha")
    #expect(first == second)
    #expect(LocalSemanticVector.cacheKey(for: "Résumé Project Alpha") == LocalSemanticVector.cacheKey(for: "resume project alpha"))
}

@Test
func localSemanticVectorCosineAndBlobRoundTrip() {
    let query: [Float] = [1, 0, 0]
    let near: [Float] = [0.9, 0.1, 0]
    let far: [Float] = [0, 1, 0]
    let blob = LocalSemanticVector.blob(from: near)

    #expect(LocalSemanticVector.vector(from: blob) == near)
    #expect(LocalSemanticVector.cosine(query, near) > LocalSemanticVector.cosine(query, far))
    #expect(LocalSemanticVector.rankScore(query: query, candidate: near) > LocalSemanticVector.rankScore(query: query, candidate: far))
}

@Test
func localSemanticVectorReturnsNilForEmptyText() async throws {
    let provider = LocalSemanticEmbeddingProvider()

    #expect(LocalSemanticVector.vector(for: " \n\t ") == nil)
    #expect(try await provider.embedding(for: " \n\t ") == nil)
}

@Test
func localSemanticProviderWrapsSyncHelper() async throws {
    let provider = LocalSemanticEmbeddingProvider()
    let text = "Quarterly planning review"

    #expect(try await provider.embedding(for: text) == LocalSemanticVector.vector(for: text))
}
