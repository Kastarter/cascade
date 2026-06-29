import CascadeMemory
import CryptoKit
import Foundation
import OSLog

/// Read-only recall over the user's local screen record — the OCR/app/window
/// timeline plus the FTS and semantic indexes that Cascade builds while it
/// records. Three tools resolve in-process against the local SQLite store, so a
/// search→inspect chain costs milliseconds, never a screenshot:
///
/// - `search_record`   — full-text + semantic lookup, returns `[#id] time app — title | text` lines
/// - `get_timeframe`   — everything between two timestamps, oldest first
/// - `inspect_moment`  — one moment's full text plus its immediate neighbours
/// - `inspect_structure` — structured reading order, key-values, and tables for one moment
///
/// This is the single implementation of those tools. Both the Ask panel's
/// `RecordSearchAnswerer` (which answers questions about the record) and the
/// on-screen cursor agent (which ACTS on it) route through here, so the
/// retrieval behaviour and the `[#id]` line format stay identical across both.
public struct RecordRecall: Sendable {
    private let store: CascadeStore
    private let reranker: (any RecordReranker)?
    private static let logger = Logger(subsystem: "com.humain.cascade", category: "record-recall")

    public init(store: CascadeStore, reranker: (any RecordReranker)? = nil) {
        self.store = store
        self.reranker = reranker
    }

    public var hasReranker: Bool { reranker != nil }

    /// The recall tool names, for routing a tool call to `perform`.
    public static func toolNames(includeStructuredContent: Bool = false) -> Set<String> {
        var names: Set<String> = ["search_record", "get_timeframe", "inspect_moment", "list_sessions"]
        if includeStructuredContent { names.insert("inspect_structure") }
        return names
    }

    public static func isRecallTool(_ name: String, includeStructuredContent: Bool = false) -> Bool {
        toolNames(includeStructuredContent: includeStructuredContent).contains(name)
    }

    /// One parsed recall call — `Sendable`, so a `@MainActor` caller can extract
    /// it from the model's raw `[String: Any]` tool input and hand it to the
    /// nonisolated executor without crossing isolation with an untyped dictionary
    /// (the same pattern as `HarnessCall`). Validation of empty/missing fields
    /// stays in `perform`, so the teaching messages are identical to before.
    public enum Call: Sendable, Equatable {
        case search(query: String)
        case timeframe(startISO: String?, endISO: String?)
        case inspect(id: Int64?)
        case inspectStructure(id: Int64?)
        case sessions(startISO: String?, endISO: String?)
        case unknown(String)

        public init(name: String, input: [String: Any]) {
            switch name {
            case "search_record":
                self = .search(query: (input["query"] as? String ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines))
            case "get_timeframe":
                self = .timeframe(startISO: input["start_iso"] as? String, endISO: input["end_iso"] as? String)
            case "inspect_moment":
                self = .inspect(id: (input["id"] as? NSNumber)?.int64Value ?? (input["id"] as? Int).map(Int64.init))
            case "inspect_structure":
                self = .inspectStructure(id: (input["id"] as? NSNumber)?.int64Value ?? (input["id"] as? Int).map(Int64.init))
            case "list_sessions":
                self = .sessions(startISO: input["start_iso"] as? String, endISO: input["end_iso"] as? String)
            default:
                self = .unknown(name)
            }
        }

        /// The safe call descriptor for persisted audit/dock surfaces. Raw queries
        /// stay inside the local recall execution path only.
        public var auditDetail: String {
            let detail: String
            switch self {
            case .search(let query):
                detail = "tool=search_record queryLength=\(query.count) queryHash=\(Self.hash(query))"
            case .timeframe(let start, let end):
                detail = "tool=get_timeframe start=\(Self.normalizedTimestamp(start)) end=\(Self.normalizedTimestamp(end))"
            case .inspect(let id):
                detail = "tool=inspect_moment id=\(id.map(String.init) ?? "missing")"
            case .inspectStructure(let id):
                detail = "tool=inspect_structure id=\(id.map(String.init) ?? "missing")"
            case .sessions(let start, let end):
                detail = "tool=list_sessions start=\(Self.normalizedTimestamp(start)) end=\(Self.normalizedTimestamp(end))"
            case .unknown(let name):
                detail = "tool=\(Self.safeToken(name))"
            }
            return String(detail.prefix(240))
        }

        private static func hash(_ value: String) -> String {
            SHA256.hash(data: Data(value.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        }

        private static func normalizedTimestamp(_ value: String?) -> String {
            guard let value else { return "missing" }
            guard let date = RecordRecall.date(from: value) else { return "invalid" }
            let formatter = ISO8601DateFormatter()
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.string(from: date)
        }

        private static func safeToken(_ value: String) -> String {
            let token = value.filter { character in
                character.isLetter || character.isNumber || character == "." || character == "_" || character == "-"
            }
            return token.isEmpty ? "unknown" : token
        }
    }

    // MARK: - Tool definitions

    /// The Messages-API tool definitions. A function, not a stored static —
    /// `[[String: Any]]` isn't Sendable, so a global constant trips strict
    /// concurrency. Descriptions are framed for an agent that RESOLVES references
    /// to the past, so it reaches for these when the goal points at something not
    /// on screen now ("the email I was reading", "what I started this morning").
    public static func toolDefinitions(includeStructuredContent: Bool = false) -> [[String: Any]] {
        var definitions: [[String: Any]] = [
        [
            "name": "search_record",
            "description": "Search everything the user has already seen on screen — every app, window title, and on-screen text Cascade recorded earlier. Use this to resolve references to past work (\"the email I was reading\", \"the doc from this morning\", \"that figure I had open\") before acting. Returns matching moments as [#id] time app — title | text. Search again with different words if the first try misses.",
            "input_schema": [
                "type": "object",
                "properties": ["query": ["type": "string", "description": "Keywords to search for"]],
                "required": ["query"],
            ],
        ],
        [
            "name": "get_timeframe",
            "description": "Everything the user saw between two times, oldest first — for resolving \"what I was doing around 2pm\" style references.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "start_iso": ["type": "string", "description": "ISO-8601 start, e.g. 2026-06-10T14:00:00Z"],
                    "end_iso": ["type": "string", "description": "ISO-8601 end"],
                ],
                "required": ["start_iso", "end_iso"],
            ],
        ],
        [
            "name": "inspect_moment",
            "description": "The full recorded text of one moment by its id, plus its immediate neighbors — use after a search hit to read the details before acting on them.",
            "input_schema": [
                "type": "object",
                "properties": ["id": ["type": "integer", "description": "Moment id from a search result"]],
                "required": ["id"],
            ],
        ],
        ]
        if includeStructuredContent {
            definitions.append([
            "name": "inspect_structure",
            "description": "Structured content for one recorded moment by id — reading-order text, key-value pairs, and markdown/CSV-safe tables when the recorder captured structured metadata. Use after search_record or inspect_moment when the user asks to extract fields or tables.",
            "input_schema": [
                "type": "object",
                "properties": ["id": ["type": "integer", "description": "Moment id from a search result"]],
                "required": ["id"],
            ],
            ])
        }
        definitions.append([
            "name": "list_sessions",
            "description": "The user's work SESSIONS between two times — each session is a contiguous stretch in one app, with its duration and what was open, instead of individual frames. Use this for \"what did I work on this morning / between 2 and 4\" style questions: it returns [#id] start–end (duration) app — title · N moments. Then inspect_moment or search_record to drill into one.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "start_iso": ["type": "string", "description": "ISO-8601 start, e.g. 2026-06-10T09:00:00Z"],
                    "end_iso": ["type": "string", "description": "ISO-8601 end"],
                ],
                "required": ["start_iso", "end_iso"],
            ],
        ])
        return definitions
    }

    // MARK: - Execution (resolves in-process against the local store)

    /// Convenience for same-isolation callers (the Ask panel's answerer, which
    /// already holds the raw input in its own async context) — parses the call
    /// and runs it. A `@MainActor` caller must parse `Call` itself and use
    /// `perform(_:)` so the untyped dictionary never crosses isolation.
    public func perform(tool: String, input: [String: Any]) async -> String {
        await perform(Call(name: tool, input: input))
    }

    /// Runs one recall call and returns the text to feed back to the model.
    /// Sensitive moments (`PrivacyRules.isSensitive`) are filtered out — the
    /// record never surfaces what privacy rules excluded.
    public func perform(_ call: Call) async -> String {
        switch call {
        case .search(let query):
            guard !query.isEmpty else { return "search_record needs a query." }
            let visible = await searchContexts(query: query, limit: 12, candidatePool: reranker == nil ? 40 : 80)
            guard !visible.isEmpty else { return "No recorded moments match “\(query)”. Try different words or a timeframe." }
            try? await store.markMemoryEventsAccessed(visible.map(\.id))
            return Self.enveloped(
                visible.map { Self.line(for: $0, textCap: 240) }.joined(separator: "\n"),
                source: "record search",
                tool: "search_record"
            )

        case .timeframe(let startISO, let endISO):
            guard let start = Self.date(from: startISO),
                  let end = Self.date(from: endISO), end > start else {
                return "get_timeframe needs start_iso and end_iso (ISO-8601, end after start)."
            }
            let rows = ((try? await store.contexts(between: start, and: end, limit: 60)) ?? [])
                .filter { !PrivacyRules.isSensitive($0) }
            guard !rows.isEmpty else { return "Nothing recorded in that window." }
            return Self.enveloped(
                rows.map { Self.line(for: $0, textCap: 160) }.joined(separator: "\n"),
                source: "record timeframe",
                tool: "get_timeframe"
            )

        case .inspect(let id):
            guard let id else { return "inspect_moment needs a numeric id." }
            guard let moment = try? await store.context(id: id), !PrivacyRules.isSensitive(moment) else {
                return "No accessible moment #\(id)."
            }
            try? await store.markMemoryEventsAccessed([moment.id])
            var out = Self.line(for: moment, textCap: 2_000)
            // Neighbors give the model the surrounding story without another hop.
            let neighbors = ((try? await store.contexts(
                between: moment.capturedAt.addingTimeInterval(-90),
                and: moment.capturedAt.addingTimeInterval(90),
                limit: 8
            )) ?? []).filter { $0.id != id && !PrivacyRules.isSensitive($0) }
            if !neighbors.isEmpty {
                out += "\nNearby: " + neighbors.map { "[#\($0.id)] \(Self.time($0.capturedAt)) \($0.appName)" }.joined(separator: ", ")
            }
            return Self.enveloped(out, source: "record moment #\(id)", tool: "inspect_moment")

        case .inspectStructure(let id):
            guard let id else { return "inspect_structure needs a numeric id." }
            guard let moment = try? await store.context(id: id), !PrivacyRules.isSensitive(moment) else {
                return "No accessible moment #\(id)."
            }
            guard let metadata = moment.metadataJSON,
                  let structured = Self.structuredMetadata(from: metadata) else {
                return "No structured metadata recorded for moment #\(id). Capture structured content must be enabled first."
            }
            try? await store.markMemoryEventsAccessed([moment.id])
            return Self.enveloped(
                Self.structureLine(for: moment, structured: structured),
                source: "record structure #\(id)",
                tool: "inspect_structure"
            )

        case .sessions(let startISO, let endISO):
            guard let start = Self.date(from: startISO),
                  let end = Self.date(from: endISO), end > start else {
                return "list_sessions needs start_iso and end_iso (ISO-8601, end after start)."
            }
            // Refresh materialized sessions from the deterministic segmenter, then
            // read that session layer back. Sensitive frames are already dropped at
            // recording time; this path keeps recall at the session level first.
            let refreshed = try? await store.refreshTimelineEpisodes(between: start, and: end, limit: 5_000)
            let episodes: [TimelineEpisode]
            if let refreshed {
                episodes = refreshed
            } else {
                episodes = (try? await store.timelineEpisodes(between: start, and: end)) ?? []
            }
            let visible = episodes.filter { !Self.isSensitive($0) }
            guard !visible.isEmpty else { return "No sessions recorded in that window." }
            return Self.enveloped(
                visible.map { Self.sessionLine(for: $0) }.joined(separator: "\n"),
                source: "record sessions",
                tool: "list_sessions"
            )

        case .unknown(let name):
            return "Unknown recall tool \(name)."
        }
    }

    // MARK: - Formatting (the [#id] line the model reads and cites)

    private func searchContexts(query: String, limit: Int, candidatePool: Int) async -> [RecordedContext] {
        guard let candidates = try? await store.hybridContextCandidates(matching: query, limit: candidatePool, candidatePool: candidatePool) else {
            return []
        }
        let visible = candidates
            .map { ($0.candidate, $0.context) }
            .filter { !PrivacyRules.isSensitive($0.1) }
        guard let reranker else {
            return Array(visible.prefix(limit).map { $0.1 })
        }

        let contextsByID = Dictionary(uniqueKeysWithValues: visible.map { ($0.1.id, $0.1) })
        let chunkCandidates = visible.enumerated().map { index, pair in
            let context = pair.1
            return RecordChunkCandidate(
                contextID: context.id,
                text: context.ocrText ?? "",
                title: context.windowTitle,
                appName: context.appName,
                capturedAt: context.capturedAt,
                baseRank: index,
                baseScore: pair.0.finalScore
            )
        }
        return reranker.rerank(query: query, candidates: chunkCandidates, limit: limit)
            .compactMap { contextsByID[$0.candidate.contextID] }
    }

    /// "[#42] 14:03 Mail — Inbox | text…" — the id the model can cite or inspect.
    static func line(for context: RecordedContext, textCap: Int) -> String {
        let title = context.windowTitle.map { " — \($0)" } ?? ""
        let text = (context.ocrText ?? "").replacingOccurrences(of: "\n", with: " · ")
        let trimmed = text.isEmpty ? "" : " | \(String(text.prefix(textCap)))"
        let trust = " [trust=\(context.sourceTrust) safeForControl=\(context.safeForControl)]"
        return "[#\(context.id)] \(time(context.capturedAt)) \(context.appName)\(title)\(trust)\(trimmed)"
    }

    /// "[#42] 09:12–09:48 (36m) Keynote — Q1 Deck · 42 moments" — the anchor id
    /// the model can inspect or the Reel can jump to.
    static func sessionLine(for episode: Episode) -> String {
        let title = episode.title.map { " — \($0)" } ?? ""
        return "[#\(episode.id)] \(time(episode.startedAt))–\(time(episode.endedAt)) "
            + "(\(duration(episode.duration))) \(episode.appName)\(title) · \(episode.momentCount) moments"
    }

    static func sessionLine(for episode: TimelineEpisode) -> String {
        let title = episode.windowTitleHint.map { " — \($0)" } ?? ""
        return "[#\(episode.representativeContextID)] \(time(episode.startAt))–\(time(episode.endAt)) "
            + "(\(duration(max(0, episode.endAt.timeIntervalSince(episode.startAt))))) \(episode.appName)\(title) · \(episode.contextCount) moments"
    }

    static func isSensitive(_ episode: TimelineEpisode) -> Bool {
        PrivacyRules.isSensitive(
            appName: episode.appName,
            bundleIdentifier: episode.bundleIdentifier,
            windowTitle: episode.windowTitleHint
        ) || episode.summaryText.map(PrivacyRules.isSensitiveText) == true
    }

    /// Human session length: "<1m", "36m", "1h 04m".
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        guard total >= 60 else { return "<1m" }
        let minutes = total / 60
        let hours = minutes / 60
        return hours > 0 ? "\(hours)h \(String(format: "%02dm", minutes % 60))" : "\(minutes)m"
    }

    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    static func date(from value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string)
    }

    private struct StructuredEnvelope: Decodable {
        let structured: StructuredMetadata?
    }

    private struct StructuredMetadata: Decodable {
        let summary: String
        let readingOrder: String
        let keyValues: [StructuredKeyValue]
        let markdownTables: [String]
        let csvTables: [String]

        enum CodingKeys: String, CodingKey {
            case summary
            case readingOrder = "reading_order"
            case keyValues = "key_values"
            case markdownTables = "markdown_tables"
            case csvTables = "csv_tables"
        }
    }

    private struct StructuredKeyValue: Decodable {
        let key: String
        let value: String
    }

    private static func structuredMetadata(from json: String) -> StructuredMetadata? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(StructuredEnvelope.self, from: data).structured
    }

    private static func structureLine(for context: RecordedContext, structured: StructuredMetadata) -> String {
        var lines = ["[#\(context.id)] \(time(context.capturedAt)) \(context.appName) structured content [trust=\(context.sourceTrust) safeForControl=\(context.safeForControl)]"]
        lines.append("Summary: \(structured.summary)")
        let readingOrder = structured.readingOrder.trimmingCharacters(in: .whitespacesAndNewlines)
        if !readingOrder.isEmpty {
            lines.append("")
            lines.append("Reading order:")
            lines.append(readingOrder)
        }
        if !structured.keyValues.isEmpty {
            lines.append("")
            lines.append("Key-values:")
            for pair in structured.keyValues {
                lines.append("- **\(pair.key)**: \(pair.value)")
            }
        }
        if !structured.markdownTables.isEmpty {
            lines.append("")
            lines.append("Markdown tables:")
            for table in structured.markdownTables {
                lines.append(table)
            }
        }
        if !structured.csvTables.isEmpty {
            lines.append("")
            lines.append("CSV-safe tables:")
            for table in structured.csvTables {
                lines.append("```csv")
                lines.append(table)
                lines.append("```")
            }
        }
        return bounded(lines, maxBytes: 12_000, maxLines: 180)
    }

    private static func enveloped(_ payload: String, source: String, tool: String) -> String {
        InjectionGuard.renderEnvelope(
            trust: .untrustedRecord,
            source: source,
            acquiredByTool: tool,
            payload: payload
        )
    }

    private static func bounded(_ lines: [String], maxBytes: Int, maxLines: Int) -> String {
        let marker = "[truncated]"
        guard maxBytes > 0, maxLines > 0 else { return "" }
        var kept = Array(lines.prefix(maxLines))
        while !kept.isEmpty && kept.joined(separator: "\n").utf8.count > maxBytes {
            kept.removeLast()
        }
        if kept.count < lines.count || kept.joined(separator: "\n").utf8.count > maxBytes {
            if kept.count == maxLines { kept.removeLast() }
            kept.append(marker)
        }
        var text = kept.joined(separator: "\n")
        while text.utf8.count > maxBytes, !text.isEmpty {
            text.removeLast()
        }
        return text
    }
}
