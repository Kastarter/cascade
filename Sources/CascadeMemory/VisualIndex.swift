import Foundation
import SQLite3

public struct VisualEmbeddingDescriptor: Equatable, Hashable, Sendable {
    public let provider: String
    public let model: String
    public let revision: String
    public let dimension: Int
    public let metric: String

    public init(provider: String, model: String, revision: String, dimension: Int, metric: String = VisualVectorMetric.cosine.rawValue) {
        self.provider = provider
        self.model = model
        self.revision = revision
        self.dimension = dimension
        self.metric = metric
    }
}

public enum VisualVectorMetric: String, Equatable, Sendable {
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

    static func norm(_ vector: [Float]) -> Double {
        Double(vector.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot())
    }

    static func validate(_ vector: [Float]) throws {
        guard !vector.isEmpty else {
            throw CascadeStoreError.sqlite("visual embedding vector cannot be empty")
        }
        guard vector.allSatisfy(\.isFinite) else {
            throw CascadeStoreError.sqlite("visual embedding vector must contain only finite values")
        }
    }

    static func validateMetric(_ metric: String) throws -> String {
        let normalized = metric.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard VisualVectorMetric(rawValue: normalized) != nil else {
            throw CascadeStoreError.sqlite("unsupported visual embedding metric: \(metric)")
        }
        return normalized
    }
}

private struct StoredVisualEmbedding {
    let contextID: Int64
    let descriptor: VisualEmbeddingDescriptor
    let vector: [Float]
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
        try indexVisualFeature(
            contextID: contextID,
            provider: provider,
            model: model,
            revision: revision,
            dimension: vector.count,
            metric: VisualVectorMetric.cosine.rawValue,
            vector: vector
        )
    }

    func indexVisualFeature(
        contextID: Int64,
        provider: String,
        model: String,
        revision: String,
        dimension: Int,
        metric: String = VisualVectorMetric.cosine.rawValue,
        vector: [Float]
    ) throws {
        try VisualVectorCodec.validate(vector)
        guard dimension == vector.count else {
            throw CascadeStoreError.sqlite("visual embedding dimension \(dimension) does not match vector count \(vector.count)")
        }
        let normalizedMetric = try VisualVectorCodec.validateMetric(metric)
        let norm = VisualVectorCodec.norm(vector)
        let sql = """
        INSERT OR REPLACE INTO context_visual_embedding
            (context_id, provider, model, revision, dimension, metric, vector, norm)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?);
        """
        try withStatement(sql) { statement in
            sqlite3_bind_int64(statement, 1, contextID)
            bind(provider, at: 2, in: statement)
            bind(model, at: 3, in: statement)
            bind(revision, at: 4, in: statement)
            sqlite3_bind_int(statement, 5, Int32(dimension))
            bind(normalizedMetric, at: 6, in: statement)
            let blob = VisualVectorCodec.blob(from: vector)
            _ = blob.withUnsafeBytes {
                sqlite3_bind_blob(statement, 7, $0.baseAddress, Int32(blob.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            sqlite3_bind_double(statement, 8, norm)
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
        similarTo contextID: Int64,
        descriptor requestedDescriptor: VisualEmbeddingDescriptor? = nil,
        limit: Int = 8
    ) throws -> [VisualIndexMatch] {
        guard limit > 0 else { return [] }
        guard let referenceContext = try context(id: contextID),
              Self.isVisualRecallVisible(referenceContext) else { return [] }
        guard let reference = try visualEmbedding(contextID: contextID, descriptor: requestedDescriptor) else { return [] }
        guard let metric = VisualVectorMetric(rawValue: reference.descriptor.metric) else { return [] }

        let candidateLimit = max(limit + 16, limit * 8)
        let matches = try visualMatches(
            matching: reference.vector,
            provider: reference.descriptor.provider,
            model: reference.descriptor.model,
            revision: reference.descriptor.revision,
            metric: metric,
            limit: candidateLimit
        )

        var filtered: [VisualIndexMatch] = []
        filtered.reserveCapacity(limit)
        for match in matches where match.contextID != contextID {
            guard let row = try context(id: match.contextID),
                  Self.isVisualRecallVisible(row) else { continue }
            filtered.append(match)
            if filtered.count == limit { break }
        }
        return filtered
    }

    func visualContexts(similarTo contextID: Int64, limit: Int = 20) throws -> [RecordedContext] {
        try visualMatches(similarTo: contextID, limit: limit)
            .compactMap { try context(id: $0.contextID) }
    }

    func visualContexts(similarToImageAt path: String, limit: Int = 20) throws -> [RecordedContext] {
        guard limit > 0,
              let contextID = try visualContextID(imagePath: path) else { return [] }
        return try visualContexts(similarTo: contextID, limit: limit)
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
        SELECT v.context_id, v.provider, v.model, v.revision, v.dimension, v.metric, v.vector
        FROM context_visual_embedding v
        JOIN recorded_context c ON c.id = v.context_id
        WHERE v.provider = ? AND v.model = ? AND v.revision = ? AND v.dimension = ? AND v.metric = ?;
        """
        let matches = try withStatement(sql) { statement in
            bind(provider, at: 1, in: statement)
            bind(model, at: 2, in: statement)
            bind(revision, at: 3, in: statement)
            sqlite3_bind_int(statement, 4, Int32(queryVector.count))
            bind(metric.rawValue, at: 5, in: statement)

            var scored: [VisualIndexMatch] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let pointer = sqlite3_column_blob(statement, 6) else { continue }
                let byteCount = Int(sqlite3_column_bytes(statement, 6))
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
                        dimension: Int(sqlite3_column_int(statement, 4)),
                        metric: String(cString: sqlite3_column_text(statement, 5))
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

    func visualEmbeddingDescriptors() throws -> [VisualEmbeddingDescriptor] {
        let sql = """
        SELECT provider, model, revision, dimension, metric
        FROM context_visual_embedding
        GROUP BY provider, model, revision, dimension, metric
        ORDER BY provider ASC, model ASC, revision ASC, dimension ASC, metric ASC;
        """
        return try withStatement(sql) { statement in
            var descriptors: [VisualEmbeddingDescriptor] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                descriptors.append(VisualEmbeddingDescriptor(
                    provider: String(cString: sqlite3_column_text(statement, 0)),
                    model: String(cString: sqlite3_column_text(statement, 1)),
                    revision: String(cString: sqlite3_column_text(statement, 2)),
                    dimension: Int(sqlite3_column_int(statement, 3)),
                    metric: String(cString: sqlite3_column_text(statement, 4))
                ))
            }
            return descriptors
        }
    }

    func visualEmbeddingCount(for descriptor: VisualEmbeddingDescriptor? = nil) throws -> Int {
        let sql: String
        if descriptor == nil {
            sql = "SELECT COUNT(*) FROM context_visual_embedding;"
        } else {
            sql = """
            SELECT COUNT(*) FROM context_visual_embedding
            WHERE provider = ? AND model = ? AND revision = ? AND dimension = ? AND metric = ?;
            """
        }
        return try withStatement(sql) { statement in
            if let descriptor {
                try bind(descriptor, in: statement)
            }
            return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int(statement, 0)) : 0
        }
    }

    @discardableResult
    func deleteVisualEmbeddings(for descriptor: VisualEmbeddingDescriptor) throws -> Int {
        let removed = try visualEmbeddingCount(for: descriptor)
        let sql = """
        DELETE FROM context_visual_embedding
        WHERE provider = ? AND model = ? AND revision = ? AND dimension = ? AND metric = ?;
        """
        try withStatement(sql) { statement in
            try bind(descriptor, in: statement)
            try stepDone(statement)
        }
        return removed
    }

    func unindexedVisualContexts(for descriptor: VisualEmbeddingDescriptor, limit: Int = 24) throws -> [RecordedContext] {
        guard limit > 0 else { return [] }
        let sql = """
        SELECT \(Self.contextColumns(prefix: "c"))
        FROM recorded_context c
        WHERE c.image_path IS NOT NULL
          AND NOT EXISTS (
            SELECT 1 FROM context_visual_embedding v
            WHERE v.context_id = c.id
              AND v.provider = ?
              AND v.model = ?
              AND v.revision = ?
              AND v.dimension = ?
              AND v.metric = ?
          )
        ORDER BY c.captured_ms DESC, c.id DESC
        LIMIT ?;
        """
        return try withStatement(sql) { statement in
            try bind(descriptor, in: statement)
            sqlite3_bind_int(statement, 6, Int32(max(0, min(limit, Int(Int32.max)))))
            var rows: [RecordedContext] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(decodeContext(statement))
            }
            return rows
        }
    }

    private func bind(_ value: String, at index: Int32, in statement: OpaquePointer) {
        sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    private func bind(_ descriptor: VisualEmbeddingDescriptor, in statement: OpaquePointer) throws {
        let metric = try VisualVectorCodec.validateMetric(descriptor.metric)
        bind(descriptor.provider, at: 1, in: statement)
        bind(descriptor.model, at: 2, in: statement)
        bind(descriptor.revision, at: 3, in: statement)
        sqlite3_bind_int(statement, 4, Int32(descriptor.dimension))
        bind(metric, at: 5, in: statement)
    }

    private func visualEmbedding(contextID: Int64, descriptor: VisualEmbeddingDescriptor?) throws -> StoredVisualEmbedding? {
        var clauses = ["context_id = ?"]
        if descriptor != nil {
            clauses.append("provider = ?")
            clauses.append("model = ?")
            clauses.append("revision = ?")
            clauses.append("dimension = ?")
            clauses.append("metric = ?")
        }
        let sql = """
        SELECT context_id, provider, model, revision, dimension, metric, vector
        FROM context_visual_embedding
        WHERE \(clauses.joined(separator: " AND "))
        ORDER BY created_at DESC, provider ASC, model ASC, revision ASC, dimension ASC, metric ASC
        LIMIT 1;
        """
        return try withStatement(sql) { statement in
            sqlite3_bind_int64(statement, 1, contextID)
            if let descriptor {
                let metric = try VisualVectorCodec.validateMetric(descriptor.metric)
                bind(descriptor.provider, at: 2, in: statement)
                bind(descriptor.model, at: 3, in: statement)
                bind(descriptor.revision, at: 4, in: statement)
                sqlite3_bind_int(statement, 5, Int32(descriptor.dimension))
                bind(metric, at: 6, in: statement)
            }
            guard sqlite3_step(statement) == SQLITE_ROW,
                  let pointer = sqlite3_column_blob(statement, 6) else { return nil }
            let byteCount = Int(sqlite3_column_bytes(statement, 6))
            let vector = VisualVectorCodec.vector(from: Data(bytes: pointer, count: byteCount))
            let descriptor = VisualEmbeddingDescriptor(
                provider: String(cString: sqlite3_column_text(statement, 1)),
                model: String(cString: sqlite3_column_text(statement, 2)),
                revision: String(cString: sqlite3_column_text(statement, 3)),
                dimension: Int(sqlite3_column_int(statement, 4)),
                metric: String(cString: sqlite3_column_text(statement, 5))
            )
            guard vector.count == descriptor.dimension else { return nil }
            return StoredVisualEmbedding(
                contextID: sqlite3_column_int64(statement, 0),
                descriptor: descriptor,
                vector: vector
            )
        }
    }

    private func visualContextID(imagePath: String) throws -> Int64? {
        let trimmed = imagePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let sql = """
        SELECT id FROM recorded_context
        WHERE image_path = ?
        ORDER BY captured_ms DESC, id DESC
        LIMIT 1;
        """
        return try withStatement(sql) { statement in
            bind(trimmed, at: 1, in: statement)
            return sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int64(statement, 0) : nil
        }
    }

    private static func isVisualRecallVisible(_ context: RecordedContext) -> Bool {
        context.safeToShow && context.safeToSummarize && !PrivacyRules.isSensitive(context)
    }
}
