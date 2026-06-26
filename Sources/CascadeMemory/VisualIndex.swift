import Foundation
import SQLite3

public struct VisualEmbeddingDescriptor: Equatable, Hashable, Sendable {
    public let provider: String
    public let model: String
    public let revision: String
    public let dimension: Int

    public init(provider: String, model: String, revision: String, dimension: Int) {
        self.provider = provider
        self.model = model
        self.revision = revision
        self.dimension = dimension
    }
}

public enum VisualVectorMetric: Equatable, Sendable {
    case cosine
    case l2
}

public struct VisualIndexMatch: Equatable, Sendable {
    public let contextID: Int64
    public let score: Float
    public let descriptor: VisualEmbeddingDescriptor

    public init(contextID: Int64, score: Float, descriptor: VisualEmbeddingDescriptor) {
        self.contextID = contextID
        self.score = score
        self.descriptor = descriptor
    }
}

private enum VisualVectorCodec {
    static func blob(from vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func vector(from blob: Data) -> [Float] {
        guard blob.count.isMultiple(of: MemoryLayout<Float>.stride) else { return [] }
        return blob.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var magA: Float = 0
        var magB: Float = 0
        for i in a.indices {
            dot += a[i] * b[i]
            magA += a[i] * a[i]
            magB += b[i] * b[i]
        }
        let denominator = (magA * magB).squareRoot()
        return denominator > 0 ? dot / denominator : 0
    }

    static func l2Distance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return Float.infinity }
        var sum: Float = 0
        for i in a.indices {
            let delta = a[i] - b[i]
            sum += delta * delta
        }
        return sum.squareRoot()
    }

    static func validate(_ vector: [Float]) throws {
        guard !vector.isEmpty else {
            throw CascadeStoreError.sqlite("visual embedding vector cannot be empty")
        }
        guard vector.allSatisfy(\.isFinite) else {
            throw CascadeStoreError.sqlite("visual embedding vector must contain only finite values")
        }
    }
}

public extension CascadeStore {
    /// Stores a visual embedding for a recorded moment. This is intentionally only
    /// the exact-scan persistence layer; screenshot/Vision extraction is added by a
    /// later integration item.
    func upsertVisualEmbedding(
        contextID: Int64,
        vector: [Float],
        provider: String,
        model: String,
        revision: String
    ) throws {
        try VisualVectorCodec.validate(vector)
        let sql = """
        INSERT OR REPLACE INTO context_visual_embedding
            (context_id, provider, model, revision, dimension, vector)
        VALUES (?, ?, ?, ?, ?, ?);
        """
        try withStatement(sql) { statement in
            sqlite3_bind_int64(statement, 1, contextID)
            bind(provider, at: 2, in: statement)
            bind(model, at: 3, in: statement)
            bind(revision, at: 4, in: statement)
            sqlite3_bind_int(statement, 5, Int32(vector.count))
            let blob = VisualVectorCodec.blob(from: vector)
            _ = blob.withUnsafeBytes {
                sqlite3_bind_blob(statement, 6, $0.baseAddress, Int32(blob.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            try stepDone(statement)
        }
    }

    func deleteVisualEmbedding(
        contextID: Int64,
        provider: String,
        model: String,
        revision: String
    ) throws {
        let sql = """
        DELETE FROM context_visual_embedding
        WHERE context_id = ? AND provider = ? AND model = ? AND revision = ?;
        """
        try withStatement(sql) { statement in
            sqlite3_bind_int64(statement, 1, contextID)
            bind(provider, at: 2, in: statement)
            bind(model, at: 3, in: statement)
            bind(revision, at: 4, in: statement)
            try stepDone(statement)
        }
    }

    func visualContexts(
        matching queryVector: [Float],
        provider: String,
        model: String,
        revision: String,
        metric: VisualVectorMetric = .cosine,
        limit: Int = 8
    ) throws -> [RecordedContext] {
        try visualRankedIDs(
            matching: queryVector,
            provider: provider,
            model: model,
            revision: revision,
            metric: metric,
            limit: limit
        ).compactMap { try context(id: $0) }
    }

    func visualRankedIDs(
        matching queryVector: [Float],
        provider: String,
        model: String,
        revision: String,
        metric: VisualVectorMetric = .cosine,
        limit: Int = 8
    ) throws -> [Int64] {
        try visualMatches(
            matching: queryVector,
            provider: provider,
            model: model,
            revision: revision,
            metric: metric,
            limit: limit
        ).map(\.contextID)
    }

    func visualMatches(
        matching queryVector: [Float],
        provider: String,
        model: String,
        revision: String,
        metric: VisualVectorMetric = .cosine,
        limit: Int = 8
    ) throws -> [VisualIndexMatch] {
        guard limit > 0 else { return [] }
        try VisualVectorCodec.validate(queryVector)

        let sql = """
        SELECT v.context_id, v.provider, v.model, v.revision, v.dimension, v.vector
        FROM context_visual_embedding v
        JOIN recorded_context c ON c.id = v.context_id
        WHERE v.provider = ? AND v.model = ? AND v.revision = ? AND v.dimension = ?;
        """
        let matches = try withStatement(sql) { statement in
            bind(provider, at: 1, in: statement)
            bind(model, at: 2, in: statement)
            bind(revision, at: 3, in: statement)
            sqlite3_bind_int(statement, 4, Int32(queryVector.count))

            var scored: [VisualIndexMatch] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let pointer = sqlite3_column_blob(statement, 5) else { continue }
                let byteCount = Int(sqlite3_column_bytes(statement, 5))
                let vector = VisualVectorCodec.vector(from: Data(bytes: pointer, count: byteCount))
                guard vector.count == queryVector.count else { continue }

                let score: Float
                switch metric {
                case .cosine:
                    score = VisualVectorCodec.cosine(queryVector, vector)
                case .l2:
                    score = -VisualVectorCodec.l2Distance(queryVector, vector)
                }

                scored.append(VisualIndexMatch(
                    contextID: sqlite3_column_int64(statement, 0),
                    score: score,
                    descriptor: VisualEmbeddingDescriptor(
                        provider: String(cString: sqlite3_column_text(statement, 1)),
                        model: String(cString: sqlite3_column_text(statement, 2)),
                        revision: String(cString: sqlite3_column_text(statement, 3)),
                        dimension: Int(sqlite3_column_int(statement, 4))
                    )
                ))
            }
            return scored
        }

        return matches
            .sorted { lhs, rhs in
                lhs.score == rhs.score ? lhs.contextID > rhs.contextID : lhs.score > rhs.score
            }
            .prefix(limit)
            .map { $0 }
    }

    private func bind(_ value: String, at index: Int32, in statement: OpaquePointer) {
        sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
}
