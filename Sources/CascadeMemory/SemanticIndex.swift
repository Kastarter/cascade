import Foundation
import SQLite3

enum SemanticTextChunker {
    static let targetCharacters = 850
    static let hardLimit = 1_100

    static func chunks(text: String, visualLines: [String] = []) -> [String] {
        let sourceLines = visualLines.isEmpty ? text.components(separatedBy: .newlines) : visualLines
        var chunks: [String] = []
        var current = ""

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { chunks.append(trimmed) }
            current = ""
        }

        for rawLine in sourceLines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.count > hardLimit {
                flush()
                var start = line.startIndex
                while start < line.endIndex {
                    let end = line.index(start, offsetBy: hardLimit, limitedBy: line.endIndex) ?? line.endIndex
                    chunks.append(String(line[start..<end]))
                    start = end
                }
                continue
            }
            let separator = current.isEmpty ? "" : "\n"
            if current.count + separator.count + line.count > targetCharacters {
                flush()
            }
            current += (current.isEmpty ? "" : "\n") + line
        }
        flush()

        if chunks.isEmpty {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [String(trimmed.prefix(hardLimit))]
        }
        return chunks
    }

    static func digest(_ text: String) -> Int64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.lowercased().utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return Int64(bitPattern: hash)
    }
}

public extension CascadeStore {
    /// Indexes a moment's text for semantic recall. Non-fatal best-effort —
    /// a missing embedding asset just means keyword search carries that moment.
    func indexEmbedding(contextID: Int64, text: String) throws {
        let safeText = CascadeStore.sanitizeStoredText(text) ?? ""
        if let vector = LocalSemanticVector.vector(for: safeText) {
            try withStatement("INSERT OR REPLACE INTO context_embedding (context_id, vector) VALUES (?, ?);") { statement in
                sqlite3_bind_int64(statement, 1, contextID)
                let blob = LocalSemanticVector.blob(from: vector)
                _ = blob.withUnsafeBytes {
                    sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32(blob.count), nil)
                }
                try stepDone(statement)
            }
        }

        let visualLines = (try? ocrLines(contextID: contextID))
            .map { rows in
                rows
                    .filter { $0.source.hasPrefix("vision") }
                    .sorted { lhs, rhs in
                        lhs.lineIndex == rhs.lineIndex ? lhs.source < rhs.source : lhs.lineIndex < rhs.lineIndex
                    }
                    .compactMap { CascadeStore.sanitizeStoredText($0.text) }
            } ?? []
        let chunks = SemanticTextChunker.chunks(text: safeText, visualLines: visualLines)
        try withStatement("DELETE FROM context_chunk_embedding WHERE context_id = ?;") { statement in
            sqlite3_bind_int64(statement, 1, contextID)
            try stepDone(statement)
        }
        guard !chunks.isEmpty else { return }
        try withStatement("""
        INSERT OR REPLACE INTO context_chunk_embedding (context_id, chunk_index, text_digest, vector)
        VALUES (?, ?, ?, ?);
        """) { statement in
            for (index, chunk) in chunks.enumerated() {
                guard let vector = LocalSemanticVector.vector(for: chunk) else { continue }
                sqlite3_bind_int64(statement, 1, contextID)
                sqlite3_bind_int(statement, 2, Int32(index))
                sqlite3_bind_int64(statement, 3, SemanticTextChunker.digest(chunk))
                let blob = LocalSemanticVector.blob(from: vector)
                _ = blob.withUnsafeBytes {
                    sqlite3_bind_blob(statement, 4, $0.baseAddress, Int32(blob.count), nil)
                }
                try stepDone(statement)
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
            }
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
    func semanticRankedIDs(
        matching query: String,
        limit: Int,
        appName: String? = nil,
        bundleIdentifier: String? = nil,
        start: Date? = nil,
        end: Date? = nil
    ) throws -> [Int64] {
        guard let queryVector = LocalSemanticVector.vector(for: query) else { return [] }
        var bestScoreByContext: [Int64: Float] = [:]

        func bindFilters(_ statement: OpaquePointer, startingAt startIndex: Int32 = 1) {
            var index = startIndex
            if let appName {
                sqlite3_bind_text(statement, index, appName, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                index += 1
            }
            if let bundleIdentifier {
                sqlite3_bind_text(statement, index, bundleIdentifier, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                index += 1
            }
            if let start {
                sqlite3_bind_text(statement, index, semanticDateString(start), -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                index += 1
            }
            if let end {
                sqlite3_bind_text(statement, index, semanticDateString(end), -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
        }

        let filterClause = semanticFilterClause(
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            start: start,
            end: end
        )

        try withStatement("""
        SELECT e.context_id, e.vector
        FROM context_chunk_embedding e
        JOIN recorded_context c ON c.id = e.context_id
        \(filterClause)
        """) { statement in
            bindFilters(statement)
            while sqlite3_step(statement) == SQLITE_ROW {
                let id = sqlite3_column_int64(statement, 0)
                guard let pointer = sqlite3_column_blob(statement, 1) else { continue }
                let count = Int(sqlite3_column_bytes(statement, 1))
                let blob = Data(bytes: pointer, count: count)
                let score = LocalSemanticVector.cosine(queryVector, LocalSemanticVector.vector(from: blob))
                if score > 0.55 {
                    bestScoreByContext[id] = max(bestScoreByContext[id] ?? -.greatestFiniteMagnitude, score)
                }
            }
        }

        try withStatement("""
        SELECT e.context_id, e.vector
        FROM context_embedding e
        JOIN recorded_context c ON c.id = e.context_id
        \(filterClause)
        """) { statement in
            bindFilters(statement)
            while sqlite3_step(statement) == SQLITE_ROW {
                let id = sqlite3_column_int64(statement, 0)
                guard bestScoreByContext[id] == nil,
                      let pointer = sqlite3_column_blob(statement, 1) else { continue }
                let count = Int(sqlite3_column_bytes(statement, 1))
                let blob = Data(bytes: pointer, count: count)
                let score = LocalSemanticVector.cosine(queryVector, LocalSemanticVector.vector(from: blob))
                if score > 0.55 { bestScoreByContext[id] = score }
            }
        }

        return bestScoreByContext
            .sorted { lhs, rhs in lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value > rhs.value }
            .prefix(limit)
            .map(\.key)
    }

    private func semanticFilterClause(
        appName: String?,
        bundleIdentifier: String?,
        start: Date?,
        end: Date?
    ) -> String {
        var clauses: [String] = []
        if appName != nil { clauses.append("c.app_name = ?") }
        if bundleIdentifier != nil { clauses.append("c.bundle_identifier = ?") }
        if start != nil { clauses.append("c.captured_at >= ?") }
        if end != nil { clauses.append("c.captured_at <= ?") }
        return clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
    }

    private func semanticDateString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
