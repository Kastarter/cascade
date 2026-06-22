import Foundation
import NaturalLanguage
import SQLite3

/// Local sentence embeddings (Apple NLEmbedding — on-device, no network) for
/// fuzzy recall: "that pricing page from last week" finds the moment even when
/// no keyword matches. Vectors live in SQLite next to the moments; search is a
/// brute-force cosine scan, which at rewind scale (thousands of moments) costs
/// single-digit milliseconds.
enum SemanticEmbedder {
    /// Embedding of `text` as the average of its word vectors, or nil when the
    /// model/asset is unavailable. Word-vector averaging beats Apple's sentence
    /// model decisively for retrieval (measured: "cheap plane tickets to japan"
    /// ranks a Tokyo-flights moment 0.72 vs 0.49 for an unrelated one, while the
    /// sentence model gets it backwards). NLEmbedding is not Sendable — load per
    /// call and confine to the calling actor (CascadeStore serializes anyway).
    static func vector(for text: String) -> [Float]? {
        let trimmed = String(text.prefix(1_000)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let embedding = NLEmbedding.wordEmbedding(for: .english) else { return nil }

        var sum = [Double](repeating: 0, count: embedding.dimension)
        var words = 0
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = trimmed
        tokenizer.enumerateTokens(in: trimmed.startIndex..<trimmed.endIndex) { range, _ in
            if let wordVector = embedding.vector(for: String(trimmed[range]).lowercased()) {
                for i in wordVector.indices { sum[i] += wordVector[i] }
                words += 1
            }
            return true
        }
        guard words > 0 else { return nil }
        return sum.map { Float($0 / Double(words)) }
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, magA: Float = 0, magB: Float = 0
        for i in a.indices {
            dot += a[i] * b[i]
            magA += a[i] * a[i]
            magB += b[i] * b[i]
        }
        let denominator = (magA * magB).squareRoot()
        return denominator > 0 ? dot / denominator : 0
    }

    static func blob(from vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func vector(from blob: Data) -> [Float] {
        blob.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}

public extension CascadeStore {
    /// Indexes a moment's text for semantic recall. Non-fatal best-effort —
    /// a missing embedding asset just means keyword search carries that moment.
    func indexEmbedding(contextID: Int64, text: String) throws {
        guard let vector = SemanticEmbedder.vector(for: text) else { return }
        try withStatement("INSERT OR REPLACE INTO context_embedding (context_id, vector) VALUES (?, ?);") { statement in
            sqlite3_bind_int64(statement, 1, contextID)
            let blob = SemanticEmbedder.blob(from: vector)
            _ = blob.withUnsafeBytes {
                sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32(blob.count), nil)
            }
            try stepDone(statement)
        }
    }

    /// Moments semantically closest to `query`, best first — recall without
    /// keyword overlap. Scans all stored vectors (cheap at rewind scale).
    func semanticContexts(matching query: String, limit: Int = 8) throws -> [RecordedContext] {
        try semanticRankedIDs(matching: query, limit: limit).compactMap { try context(id: $0) }
    }

    /// The semantic lane's ranking as bare moment ids (best cosine first), for
    /// RankFusion to merge with the keyword lane in `hybridContexts`. Same scan
    /// and 0.55 cosine floor as `semanticContexts`; returning ids (not hydrated
    /// rows) keeps the fusion cheap — only the fused top-N is hydrated.
    func semanticRankedIDs(matching query: String, limit: Int) throws -> [Int64] {
        guard let queryVector = SemanticEmbedder.vector(for: query) else { return [] }
        var scored: [(id: Int64, score: Float)] = []
        try withStatement("SELECT context_id, vector FROM context_embedding;") { statement in
            while sqlite3_step(statement) == SQLITE_ROW {
                let id = sqlite3_column_int64(statement, 0)
                guard let pointer = sqlite3_column_blob(statement, 1) else { continue }
                let count = Int(sqlite3_column_bytes(statement, 1))
                let blob = Data(bytes: pointer, count: count)
                let score = SemanticEmbedder.cosine(queryVector, SemanticEmbedder.vector(from: blob))
                if score > 0.55 { scored.append((id, score)) }
            }
        }
        return scored.sorted { $0.score > $1.score }.prefix(limit).map(\.id)
    }
}
