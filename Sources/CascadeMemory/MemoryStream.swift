import Foundation
import SQLite3

public struct MemoryEvent: Identifiable, Codable, Equatable, Sendable {
    public var id: Int64 { contextID }

    public let contextID: Int64
    public let capturedAt: Date
    public let appName: String
    public let summary: String
    public let entitiesJSON: String
    public let importance: Double
    public let lastAccessedAt: Date?
    public let accessCount: Int
    public let linksJSON: String
    public let metadataJSON: String

    public init(
        contextID: Int64,
        capturedAt: Date,
        appName: String,
        summary: String,
        entitiesJSON: String,
        importance: Double,
        lastAccessedAt: Date?,
        accessCount: Int,
        linksJSON: String,
        metadataJSON: String
    ) {
        self.contextID = contextID
        self.capturedAt = capturedAt
        self.appName = appName
        self.summary = summary
        self.entitiesJSON = entitiesJSON
        self.importance = importance
        self.lastAccessedAt = lastAccessedAt
        self.accessCount = accessCount
        self.linksJSON = linksJSON
        self.metadataJSON = metadataJSON
    }
}

public extension CascadeStore {
    func upsertMemoryEvent(for context: RecordedContext) throws {
        guard context.id > 0 else { return }
        guard !PrivacyRules.isSensitive(context) else {
            try withStatement("DELETE FROM memory_event WHERE context_id = ?;") { statement in
                sqlite3_bind_int64(statement, 1, context.id)
                try stepDone(statement)
            }
            return
        }

        let mentions = WorkGraphExtractor.mentions(in: context)
        let entitiesJSON = MemoryStreamJSON.entities(mentions)
        let linksJSON = MemoryStreamJSON.links(mentions)
        let metadataJSON = MemoryStreamJSON.metadata(for: context)
        let summary = MemoryStreamHeuristics.summary(for: context)
        let importance = MemoryStreamHeuristics.importance(for: context, mentions: mentions)

        try withStatement("""
        INSERT INTO memory_event
            (context_id, captured_at, app_name, summary, entities_json, importance,
             last_accessed_at, access_count, links_json, metadata_json)
        VALUES (?, ?, ?, ?, ?, ?, NULL, 0, ?, ?)
        ON CONFLICT(context_id) DO UPDATE SET
            captured_at = excluded.captured_at,
            app_name = excluded.app_name,
            summary = excluded.summary,
            entities_json = excluded.entities_json,
            importance = excluded.importance,
            links_json = excluded.links_json,
            metadata_json = excluded.metadata_json;
        """) { statement in
            sqlite3_bind_int64(statement, 1, context.id)
            memoryBind(MemoryStreamDateCodec.string(from: context.capturedAt), at: 2, in: statement)
            memoryBind(context.appName, at: 3, in: statement)
            memoryBind(summary, at: 4, in: statement)
            memoryBind(entitiesJSON, at: 5, in: statement)
            sqlite3_bind_double(statement, 6, importance)
            memoryBind(linksJSON, at: 7, in: statement)
            memoryBind(metadataJSON, at: 8, in: statement)
            try stepDone(statement)
        }
    }

    func memoryEvent(contextID: Int64) throws -> MemoryEvent? {
        try withStatement("""
        SELECT context_id, captured_at, app_name, summary, entities_json, importance,
               last_accessed_at, access_count, links_json, metadata_json
        FROM memory_event
        WHERE context_id = ?
        LIMIT 1;
        """) { statement in
            sqlite3_bind_int64(statement, 1, contextID)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return memoryDecodeEvent(statement)
        }
    }

    func memoryEvents(limit: Int = 40) throws -> [MemoryEvent] {
        try withStatement("""
        SELECT context_id, captured_at, app_name, summary, entities_json, importance,
               last_accessed_at, access_count, links_json, metadata_json
        FROM memory_event
        ORDER BY captured_at DESC, context_id DESC
        LIMIT ?;
        """) { statement in
            sqlite3_bind_int(statement, 1, Int32(limit))
            var rows: [MemoryEvent] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(memoryDecodeEvent(statement))
            }
            return rows
        }
    }

    func memoryRankedIDs(matching query: String, limit: Int, now: Date = Date()) throws -> [Int64] {
        guard limit > 0 else { return [] }
        let queryTokens = MemoryStreamTokens.tokens(in: query)
        guard !queryTokens.isEmpty else { return [] }

        let rows: [(id: Int64, capturedAt: Date, appName: String, summary: String, entities: String, importance: Double, accessCount: Int, linkCount: Int)] = try withStatement("""
        SELECT m.context_id, m.captured_at, m.app_name, m.summary, m.entities_json,
               m.importance, m.access_count, COALESCE(COUNT(l.id), 0)
        FROM memory_event m
        LEFT JOIN context_entity_link l ON l.context_id = m.context_id
        GROUP BY m.context_id
        ORDER BY m.captured_at DESC, m.context_id DESC
        LIMIT 5000;
        """) { statement in
            var rows: [(Int64, Date, String, String, String, Double, Int, Int)] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append((
                    sqlite3_column_int64(statement, 0),
                    MemoryStreamDateCodec.date(from: memoryText(statement, 1)) ?? Date(timeIntervalSince1970: 0),
                    memoryText(statement, 2) ?? "",
                    memoryText(statement, 3) ?? "",
                    memoryText(statement, 4) ?? "",
                    sqlite3_column_double(statement, 5),
                    Int(sqlite3_column_int(statement, 6)),
                    Int(sqlite3_column_int(statement, 7))
                ))
            }
            return rows
        }

        return rows.compactMap { row -> (id: Int64, score: Double)? in
            let candidateTokens = MemoryStreamTokens.tokens(in: [row.appName, row.summary, row.entities].joined(separator: " "))
            let overlap = queryTokens.intersection(candidateTokens).count
            guard overlap > 0 else { return nil }

            let relevance = Double(overlap) / Double(max(queryTokens.count, 1))
            let age = max(0, now.timeIntervalSince(row.capturedAt))
            let recency = exp(-age / (14 * 24 * 60 * 60))
            let continuity = min(1.0, Double(row.linkCount) / 4.0)
            let access = log1p(Double(max(0, row.accessCount))) / 4.0
            let score = (4.0 * relevance)
                + (1.5 * recency)
                + (2.0 * row.importance)
                + (0.75 * continuity)
                + (0.5 * access)
            return (row.id, score)
        }
        .sorted { lhs, rhs in lhs.score == rhs.score ? lhs.id > rhs.id : lhs.score > rhs.score }
        .prefix(limit)
        .map(\.id)
    }

    func markMemoryEventsAccessed(_ contextIDs: [Int64], at date: Date = Date()) throws {
        let unique = Array(Set(contextIDs.filter { $0 > 0 })).sorted()
        guard !unique.isEmpty else { return }
        let accessedAt = MemoryStreamDateCodec.string(from: date)
        try withStatement("""
        UPDATE memory_event
        SET last_accessed_at = ?, access_count = access_count + 1
        WHERE context_id = ?;
        """) { statement in
            for id in unique {
                memoryBind(accessedAt, at: 1, in: statement)
                sqlite3_bind_int64(statement, 2, id)
                try stepDone(statement)
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
            }
        }
    }
}

private enum MemoryStreamHeuristics {
    static func summary(for context: RecordedContext) -> String {
        let title = context.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = context.ocrText?
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = [context.appName, title].compactMap { value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return value
        }.joined(separator: " - ")
        let text = [prefix, body].filter { $0?.isEmpty == false }.compactMap { $0 }.joined(separator: ": ")
        return String(text.prefix(320))
    }

    static func importance(for context: RecordedContext, mentions: [WorkGraphMention]) -> Double {
        var score: Double
        switch context.source {
        case .input: score = 0.35
        case .accessibility: score = 0.32
        case .screen: score = 0.28
        case .app: score = 0.22
        case .system: score = 0.16
        }

        let text = [context.windowTitle, context.ocrText, context.metadataJSON]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        if context.windowTitle?.isEmpty == false { score += 0.08 }
        if text.contains("http://") || text.contains("https://") { score += 0.12 }
        if text.range(of: #"(?:~|/Users|/Volumes|/private|/var|/tmp)/"#, options: .regularExpression) != nil { score += 0.12 }
        if text.contains("clipboard") || text.contains("copied") { score += 0.12 }
        if text.range(of: #"\b(owner|assignee|reviewer|status|deadline|due|amount|total|invoice|form)\b"#, options: .regularExpression) != nil {
            score += 0.14
        }
        if (context.ocrText?.count ?? 0) > 240 { score += 0.08 }
        if !mentions.isEmpty { score += min(0.22, Double(mentions.count) * 0.04) }
        return min(1.0, max(0.0, score))
    }
}

private enum MemoryStreamTokens {
    private static let stopwords: Set<String> = [
        "the", "and", "was", "were", "what", "when", "where", "which", "who", "why",
        "how", "did", "does", "doing", "done", "have", "has", "had", "you", "your",
        "about", "with", "from", "that", "this", "these", "those", "for", "are",
        "show", "tell", "give", "find", "get", "see", "look", "today", "yesterday",
        "earlier", "morning", "afternoon", "evening", "tonight", "day", "week",
        "time", "thing", "things", "summary", "summarize", "recap"
    ]

    static func tokens(in value: String) -> Set<String> {
        Set(value.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 && !stopwords.contains($0) })
    }
}

private enum MemoryStreamJSON {
    static func entities(_ mentions: [WorkGraphMention]) -> String {
        let rows = mentions.map {
            [
                "kind": $0.kind.rawValue,
                "canonical": $0.canonicalValue,
                "display": $0.displayName,
            ]
        }
        return json(rows)
    }

    static func links(_ mentions: [WorkGraphMention]) -> String {
        let rows = mentions.map {
            [
                "kind": $0.kind.rawValue,
                "canonical": $0.canonicalValue,
                "source": $0.source,
            ]
        }
        return json(rows)
    }

    static func metadata(for context: RecordedContext) -> String {
        var row: [String: String] = [
            "source": context.source.rawValue,
            "app_name": context.appName,
        ]
        if let bundle = context.bundleIdentifier { row["bundle_identifier"] = bundle }
        if let title = context.windowTitle, !PrivacyRules.isSensitiveText(title) { row["window_title"] = title }
        return json(row)
    }

    private static func json(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return text
    }
}

private enum MemoryStreamDateCodec {
    private static func formatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    static func string(from date: Date) -> String {
        formatter().string(from: date)
    }

    static func date(from string: String?) -> Date? {
        guard let string else { return nil }
        return formatter().date(from: string)
    }
}

private func memoryDecodeEvent(_ statement: OpaquePointer) -> MemoryEvent {
    MemoryEvent(
        contextID: sqlite3_column_int64(statement, 0),
        capturedAt: MemoryStreamDateCodec.date(from: memoryText(statement, 1)) ?? Date(),
        appName: memoryText(statement, 2) ?? "",
        summary: memoryText(statement, 3) ?? "",
        entitiesJSON: memoryText(statement, 4) ?? "[]",
        importance: sqlite3_column_double(statement, 5),
        lastAccessedAt: MemoryStreamDateCodec.date(from: memoryText(statement, 6)),
        accessCount: Int(sqlite3_column_int(statement, 7)),
        linksJSON: memoryText(statement, 8) ?? "[]",
        metadataJSON: memoryText(statement, 9) ?? "{}"
    )
}

private func memoryBind(_ value: String, at index: Int32, in statement: OpaquePointer) {
    sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
}

private func memoryText(_ statement: OpaquePointer, _ index: Int32) -> String? {
    guard let cString = sqlite3_column_text(statement, index) else { return nil }
    return String(cString: cString)
}
