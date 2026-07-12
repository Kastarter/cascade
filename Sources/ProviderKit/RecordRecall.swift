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
/// - `extract_table` / `extract_fields` — deterministic structured extraction
///
/// This is the single implementation of those tools. Both the Ask panel's
/// `RecordSearchAnswerer` (which answers questions about the record) and the
/// on-screen cursor agent (which ACTS on it) route through here, so the
/// retrieval behaviour and the `[#id]` line format stay identical across both.
public struct RecordRecall: Sendable {
    private let store: CascadeStore
    private let reranker: (any RecordReranker)?
    private let presentationTimeZone: TimeZone
    private static let logger = Logger(subsystem: "com.humain.cascade", category: "record-recall")

    public init(
        store: CascadeStore,
        reranker: (any RecordReranker)? = nil,
        presentationTimeZone: TimeZone = .autoupdatingCurrent
    ) {
        self.store = store
        self.reranker = reranker
        self.presentationTimeZone = presentationTimeZone
    }

    public var hasReranker: Bool { reranker != nil }

    /// The recall tool names, for routing a tool call to `perform`.
    public static func toolNames(includeStructuredContent: Bool = false) -> Set<String> {
        var names: Set<String> = ["search_record", "get_timeframe", "inspect_moment", "list_sessions"]
        if includeStructuredContent {
            names.formUnion(["inspect_structure", "extract_table", "extract_fields"])
        }
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
        case extractTable(id: Int64?, tableIndex: Int, format: String)
        case extractFields(id: Int64?, query: String?)
        case sessions(startISO: String?, endISO: String?)
        case unknown(String)

        public var toolName: String {
            switch self {
            case .search:
                "search_record"
            case .timeframe:
                "get_timeframe"
            case .inspect:
                "inspect_moment"
            case .inspectStructure:
                "inspect_structure"
            case .extractTable:
                "extract_table"
            case .extractFields:
                "extract_fields"
            case .sessions:
                "list_sessions"
            case .unknown(let name):
                name
            }
        }

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
            case "extract_table":
                self = .extractTable(
                    id: Self.idValue(input),
                    tableIndex: (input["table_index"] as? NSNumber)?.intValue ?? input["table_index"] as? Int ?? 0,
                    format: (input["format"] as? String ?? "markdown").lowercased()
                )
            case "extract_fields":
                self = .extractFields(
                    id: Self.idValue(input),
                    query: (input["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                )
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
            case .extractTable(let id, let tableIndex, let format):
                detail = "tool=extract_table id=\(id.map(String.init) ?? "missing") tableIndex=\(tableIndex) format=\(Self.safeToken(format))"
            case .extractFields(let id, let query):
                let q = query ?? ""
                detail = "tool=extract_fields id=\(id.map(String.init) ?? "missing") queryLength=\(q.count) queryHash=\(Self.hash(q))"
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

        private static func idValue(_ input: [String: Any]) -> Int64? {
            (input["id"] as? NSNumber)?.int64Value
                ?? (input["id"] as? Int).map(Int64.init)
                ?? (input["moment_id"] as? NSNumber)?.int64Value
                ?? (input["moment_id"] as? Int).map(Int64.init)
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
            definitions.append([
            "name": "extract_table",
            "description": "Deterministically extract a structured table from one recorded moment. Use this before visual fallback when the user asks to copy or transform a table they saw.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "id": ["type": "integer", "description": "Moment id from search_record or inspect_moment"],
                    "table_index": ["type": "integer", "description": "Zero-based table index; defaults to 0"],
                    "format": ["type": "string", "enum": ["markdown", "csv", "json"], "description": "Output format"],
                ],
                "required": ["id"],
            ],
            ])
            definitions.append([
            "name": "extract_fields",
            "description": "Deterministically extract structured fields from one recorded moment, optionally filtered by a query such as invoice total, due date, or vendor.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "id": ["type": "integer", "description": "Moment id from search_record or inspect_moment"],
                    "query": ["type": "string", "description": "Optional field filter"],
                ],
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
        return definitions.map { definition in
            StableToolDefinition.strict(
                definition,
                examples: inputExamples(for: definition["name"] as? String ?? "")
            )
        }
    }

    private static func inputExamples(for tool: String) -> [[String: Any]] {
        switch tool {
        case "search_record":
            [["query": "Q2 budget spreadsheet from this morning"]]
        case "get_timeframe":
            [["start_iso": "2026-06-10T14:00:00Z", "end_iso": "2026-06-10T15:00:00Z"]]
        case "inspect_moment":
            [["id": 42]]
        case "inspect_structure":
            [["id": 42]]
        case "extract_table":
            [["id": 42, "table_index": 0, "format": "csv"]]
        case "extract_fields":
            [["id": 42, "query": "invoice total due date"]]
        case "list_sessions":
            [["start_iso": "2026-06-10T09:00:00Z", "end_iso": "2026-06-10T12:00:00Z"]]
        default:
            []
        }
    }

    // MARK: - Execution (resolves in-process against the local store)

    /// Convenience for same-isolation callers (the Ask panel's answerer, which
    /// already holds the raw input in its own async context) — parses the call
    /// and runs it. A `@MainActor` caller must parse `Call` itself and use
    /// `perform(_:)` so the untyped dictionary never crosses isolation.
    public func perform(tool: String, input: [String: Any]) async -> String {
        await perform(Call(name: tool, input: input))
    }

    public func performEvidence(tool: String, input: [String: Any]) async -> SourceEvidence {
        await performEvidence(Call(name: tool, input: input))
    }

    public func performEvidence(_ call: Call) async -> SourceEvidence {
        let result = await perform(call)
        return SourceEvidence.fromToolResult(
            result,
            source: .recordedMemory,
            defaultTool: call.toolName
        )
    }

    /// Runs one recall call and returns the text to feed back to the model.
    /// Sensitive moments (`PrivacyRules.isSensitive`) are filtered out — the
    /// record never surfaces what privacy rules excluded.
    public func perform(_ call: Call) async -> String {
        switch call {
        case .search(let query):
            guard !query.isEmpty else { return Self.status(.error, tool: "search_record", kind: "validation_error", message: "search_record needs a query.") }
            let visible = await searchContexts(query: query, limit: 12, candidatePool: reranker == nil ? 40 : 80)
            let graphHits = ((try? await store.searchKnowledgeGraphs(matching: query, limit: 12)) ?? [])
            let graphProjections = graphHits.compactMap {
                Self.knowledgeGraphProjection(
                    for: $0.graph,
                    matching: query,
                    overlapping: nil,
                    excludingRawContexts: visible
                )
            }
            guard !visible.isEmpty || !graphProjections.isEmpty else {
                return Self.status(.noResult, tool: "search_record", kind: "no_matches", message: "No recorded moments match “\(query)”. Try different words or a timeframe.")
            }
            if !visible.isEmpty { try? await store.markMemoryEventsAccessed(visible.map(\.id)) }
            let lines = visible.map { Self.line(for: $0, textCap: 240, timeZone: presentationTimeZone) }
                + graphProjections.map { Self.knowledgeGraphLine(for: $0, timeZone: presentationTimeZone) }
            return Self.enveloped(
                lines.joined(separator: "\n"),
                source: "record search",
                tool: "search_record"
            )

        case .timeframe(let startISO, let endISO):
            guard let start = Self.date(from: startISO),
                  let end = Self.date(from: endISO), end > start else {
                return Self.status(.error, tool: "get_timeframe", kind: "validation_error", message: "get_timeframe needs start_iso and end_iso (ISO-8601, end after start).")
            }
            let rows = ((try? await store.contexts(between: start, and: end, limit: 60)) ?? [])
                .filter { !PrivacyRules.isSensitive($0) }
            let graphs = ((try? await store.knowledgeGraphs(between: start, and: end)) ?? [])
            let interval = Self.millisecondInterval(from: start, through: end)
            let graphProjections = graphs.compactMap {
                Self.knowledgeGraphProjection(
                    for: $0,
                    matching: nil,
                    overlapping: interval,
                    excludingRawContexts: rows
                )
            }
            guard !rows.isEmpty || !graphProjections.isEmpty else {
                return Self.status(.noResult, tool: "get_timeframe", kind: "empty_window", message: "Nothing recorded in that window.")
            }
            let lines = rows.map { Self.line(for: $0, textCap: 160, timeZone: presentationTimeZone) }
                + graphProjections.map { Self.knowledgeGraphLine(for: $0, timeZone: presentationTimeZone) }
            return Self.enveloped(
                lines.joined(separator: "\n"),
                source: "record timeframe",
                tool: "get_timeframe"
            )

        case .inspect(let id):
            guard let id else { return Self.status(.error, tool: "inspect_moment", kind: "validation_error", message: "inspect_moment needs a numeric id.") }
            guard let moment = try? await store.context(id: id), !PrivacyRules.isSensitive(moment) else {
                return Self.status(.noResult, tool: "inspect_moment", kind: "not_accessible", message: "No accessible moment #\(id).")
            }
            try? await store.markMemoryEventsAccessed([moment.id])
            var out = Self.line(for: moment, textCap: 2_000, timeZone: presentationTimeZone)
            // Neighbors give the model the surrounding story without another hop.
            let neighbors = ((try? await store.contexts(
                between: moment.capturedAt.addingTimeInterval(-90),
                and: moment.capturedAt.addingTimeInterval(90),
                limit: 8
            )) ?? []).filter { $0.id != id && !PrivacyRules.isSensitive($0) }
            if !neighbors.isEmpty {
                out += "\nNearby: " + neighbors.map {
                    "[#\($0.id)] \(Self.time($0.capturedAt, timeZone: presentationTimeZone)) \($0.appName)"
                }.joined(separator: ", ")
            }
            if let structured = await structuredMetadata(for: moment) {
                out += "\n\nSTRUCTURE:\n" + Self.structureSummaryLine(structured)
            }
            return Self.enveloped(out, source: "record moment #\(id)", tool: "inspect_moment")

        case .inspectStructure(let id):
            guard let id else { return Self.status(.error, tool: "inspect_structure", kind: "validation_error", message: "inspect_structure needs a numeric id.") }
            guard let moment = try? await store.context(id: id), !PrivacyRules.isSensitive(moment) else {
                return Self.status(.noResult, tool: "inspect_structure", kind: "not_accessible", message: "No accessible moment #\(id).")
            }
            guard let structured = await structuredMetadata(for: moment) else {
                return Self.status(.noResult, tool: "inspect_structure", kind: "missing_structured_metadata", message: "No structured metadata recorded for moment #\(id). Capture structured content must be enabled first.")
            }
            try? await store.markMemoryEventsAccessed([moment.id])
            return Self.enveloped(
                Self.structureLine(for: moment, structured: structured, timeZone: presentationTimeZone),
                source: "record structure #\(id)",
                tool: "inspect_structure"
            )

        case .extractTable(let id, let tableIndex, let format):
            guard let id else { return Self.status(.error, tool: "extract_table", kind: "validation_error", message: "extract_table needs a numeric id.") }
            guard let moment = try? await store.context(id: id), !PrivacyRules.isSensitive(moment) else {
                return Self.status(.noResult, tool: "extract_table", kind: "not_accessible", message: "No accessible moment #\(id).")
            }
            guard let structured = await structuredMetadata(for: moment), !structured.tables.isEmpty else {
                return Self.status(.noResult, tool: "extract_table", kind: "missing_table", message: "No structured table recorded for moment #\(id).")
            }
            guard structured.tables.indices.contains(tableIndex) else {
                return Self.status(.error, tool: "extract_table", kind: "validation_error", message: "Moment #\(id) has \(structured.tables.count) table(s); table_index \(tableIndex) is out of range.")
            }
            try? await store.markMemoryEventsAccessed([moment.id])
            let table = structured.tables[tableIndex]
            let output = TableExtraction(
                contextID: moment.id,
                tableIndex: tableIndex,
                format: ["markdown", "csv", "json"].contains(format) ? format : "markdown",
                rows: table.rows,
                markdown: Self.markdownTable(table.rows),
                csv: Self.csvTable(table.rows)
            )
            return Self.enveloped(Self.json(output), source: "record table #\(id)", tool: "extract_table")

        case .extractFields(let id, let query):
            guard let id else { return Self.status(.error, tool: "extract_fields", kind: "validation_error", message: "extract_fields needs a numeric id.") }
            guard let moment = try? await store.context(id: id), !PrivacyRules.isSensitive(moment) else {
                return Self.status(.noResult, tool: "extract_fields", kind: "not_accessible", message: "No accessible moment #\(id).")
            }
            guard let structured = await structuredMetadata(for: moment), !structured.keyValues.isEmpty else {
                return Self.status(.noResult, tool: "extract_fields", kind: "missing_fields", message: "No structured fields recorded for moment #\(id).")
            }
            try? await store.markMemoryEventsAccessed([moment.id])
            let filtered = Self.filteredFields(structured.keyValues, query: query)
            guard !filtered.isEmpty else {
                return Self.status(.noResult, tool: "extract_fields", kind: "no_matching_fields", message: "No structured fields in moment #\(id) match that query.")
            }
            let output = FieldExtraction(contextID: moment.id, query: query, fields: filtered)
            return Self.enveloped(Self.json(output), source: "record fields #\(id)", tool: "extract_fields")

        case .sessions(let startISO, let endISO):
            guard let start = Self.date(from: startISO),
                  let end = Self.date(from: endISO), end > start else {
                return Self.status(.error, tool: "list_sessions", kind: "validation_error", message: "list_sessions needs start_iso and end_iso (ISO-8601, end after start).")
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
            let interval = Self.millisecondInterval(from: start, through: end)
            let graphSessions = ((try? await store.knowledgeGraphs(between: start, and: end)) ?? [])
                .compactMap {
                    Self.knowledgeGraphProjection(
                        for: $0,
                        matching: nil,
                        overlapping: interval,
                        excludingRawContexts: []
                    )
                }
                .flatMap { projection in
                    projection.sessions
                        .filter { !Self.isCovered($0, by: visible) }
                        .map {
                            Self.knowledgeGraphSessionLine(
                                node: $0,
                                interval: projection.interval,
                                timeZone: presentationTimeZone
                            )
                        }
                }
            guard !visible.isEmpty || !graphSessions.isEmpty else {
                return Self.status(.noResult, tool: "list_sessions", kind: "empty_window", message: "No sessions recorded in that window.")
            }
            return Self.enveloped(
                (visible.map { Self.sessionLine(for: $0, timeZone: presentationTimeZone) } + graphSessions).joined(separator: "\n"),
                source: "record sessions",
                tool: "list_sessions"
            )

        case .unknown(let name):
            return Self.status(.error, tool: name, kind: "unknown_tool", message: "Unknown recall tool \(name).")
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

    private struct KnowledgeGraphProjection {
        let sessions: [ContextKnowledgeGraphNode]
        let relatedNodes: [ContextKnowledgeGraphNode]
        let interval: ClosedRange<Int64>
        let searchTerms: [String]
    }

    /// "[#42] 14:03 Mail — Inbox | text…" — the id the model can cite or inspect.
    static func line(for context: RecordedContext, textCap: Int, timeZone: TimeZone) -> String {
        let title = context.windowTitle.map { " — \($0)" } ?? ""
        let text = (context.ocrText ?? "").replacingOccurrences(of: "\n", with: " · ")
        let trimmed = text.isEmpty ? "" : " | \(String(text.prefix(textCap)))"
        let trust = " [trust=\(context.sourceTrust) safeForControl=\(context.safeForControl)]"
        return "[#\(context.id)] \(time(context.capturedAt, timeZone: timeZone)) \(context.appName)\(title)\(trust)\(trimmed)"
    }

    /// "[#42] 09:12–09:48 (36m) Keynote — Q1 Deck · 42 moments" — the anchor id
    /// the model can inspect or the Reel can jump to.
    static func sessionLine(for episode: Episode, timeZone: TimeZone) -> String {
        let title = episode.title.map { " — \($0)" } ?? ""
        return "[#\(episode.id)] \(time(episode.startedAt, timeZone: timeZone))–\(time(episode.endedAt, timeZone: timeZone)) "
            + "(\(duration(episode.duration))) \(episode.appName)\(title) · \(episode.momentCount) moments"
    }

    static func sessionLine(for episode: TimelineEpisode, timeZone: TimeZone) -> String {
        let title = episode.windowTitleHint.map { " — \($0)" } ?? ""
        return "[#\(episode.representativeContextID)] \(time(episode.startAt, timeZone: timeZone))–\(time(episode.endAt, timeZone: timeZone)) "
            + "(\(duration(max(0, episode.endAt.timeIntervalSince(episode.startAt))))) \(episode.appName)\(title) · \(episode.contextCount) moments"
    }

    /// Knowledge-graph evidence intentionally has no `[#id]` token: its source
    /// moment may already be pruned, so the answerer must not create a broken Reel
    /// jump or proof chip for it.
    private static func knowledgeGraphLine(
        for projection: KnowledgeGraphProjection,
        timeZone: TimeZone
    ) -> String {
        let apps = projection.relatedNodes.filter { $0.type == .app }
            .sorted {
                if $0.mentionCount != $1.mentionCount { return $0.mentionCount > $1.mentionCount }
                return $0.label < $1.label
            }
            .prefix(4)
            .map(\.label)
        let facts = projection.relatedNodes.filter {
            $0.type == .window || $0.type == .document || $0.type == .entity
        }
            .sorted {
                if $0.mentionCount != $1.mentionCount { return $0.mentionCount > $1.mentionCount }
                return $0.label < $1.label
            }
            .prefix(5)
            .map(\.label)
        var parts = [
            "[KG \(localDayLabel(for: projection.interval, timeZone: timeZone))] "
                + "\(time(projection.interval.lowerBound, timeZone: timeZone))–\(time(projection.interval.upperBound, timeZone: timeZone))",
        ]
        if !apps.isEmpty { parts.append(apps.joined(separator: ", ")) }
        if !facts.isEmpty { parts.append(facts.joined(separator: ", ")) }
        let sessionDetails = projection.sessions.prefix(6).map {
            knowledgeGraphSessionSummary(
                node: $0,
                interval: projection.interval,
                searchTerms: projection.searchTerms,
                timeZone: timeZone
            )
        }
        let count = projection.sessions.count
        let summary = "\(count) compacted \(count == 1 ? "session" : "sessions") in this interval: "
            + sessionDetails.joined(separator: " | ")
        return parts.joined(separator: " · ") + " | " + String(summary.prefix(560))
    }

    private static func knowledgeGraphSessionLine(
        node: ContextKnowledgeGraphNode,
        interval: ClosedRange<Int64>,
        timeZone: TimeZone
    ) -> String {
        let count = node.attributes["context_count"] ?? String(node.mentionCount)
        let clipped = clippedInterval(for: node, to: interval)
        let evidence = evidenceSnippet(for: node, searchTerms: [], includeOutsideInterval: false, interval: interval)
        let suffix = evidence.map { " | \(String($0.prefix(400)))" } ?? ""
        return "[KG \(localDayLabel(for: clipped, timeZone: timeZone))] "
            + "\(time(clipped.lowerBound, timeZone: timeZone))–\(time(clipped.upperBound, timeZone: timeZone)) "
            + "\(node.label) · \(count) compacted contexts in session\(suffix)"
    }

    private static func knowledgeGraphSessionSummary(
        node: ContextKnowledgeGraphNode,
        interval: ClosedRange<Int64>,
        searchTerms: [String],
        timeZone: TimeZone
    ) -> String {
        let clipped = clippedInterval(for: node, to: interval)
        var summary = "\(time(clipped.lowerBound, timeZone: timeZone))–\(time(clipped.upperBound, timeZone: timeZone)) \(node.label)"
        if let evidence = evidenceSnippet(
            for: node,
            searchTerms: searchTerms,
            includeOutsideInterval: !searchTerms.isEmpty,
            interval: interval
        ) {
            summary += " · \(evidence)"
        }
        return String(summary.prefix(400))
    }

    private static func evidenceSnippet(
        for session: ContextKnowledgeGraphNode,
        searchTerms: [String],
        includeOutsideInterval: Bool,
        interval: ClosedRange<Int64>
    ) -> String? {
        // Evidence snippets are session-scoped but not individually timestamped.
        // A narrow timeframe that clips a session therefore uses only its stable
        // app/window identity; otherwise an OCR fact from outside the requested
        // minutes could leak into the answer. Search has no requested interval, so
        // it can safely render the matching session-scoped snippet.
        let sessionIsContained = interval.lowerBound <= session.firstSeenMs
            && interval.upperBound >= session.lastSeenMs
        guard includeOutsideInterval || sessionIsContained else { return nil }
        if !searchTerms.isEmpty,
           let match = session.evidenceSnippets.first(where: { value in
               text(value, containsAny: searchTerms)
           }) {
            return match.replacingOccurrences(of: "\n", with: " · ")
        }
        let normalizedLabel = session.label.lowercased()
        let evidence = session.evidenceSnippets
            .filter { !normalizedLabel.contains($0.lowercased()) }
            .max {
                if $0.count != $1.count { return $0.count < $1.count }
                return $0.localizedStandardCompare($1) == .orderedDescending
            }
            ?? session.evidenceSnippets.max(by: { $0.count < $1.count })
        return evidence?.replacingOccurrences(of: "\n", with: " · ")
    }

    private static func time(_ milliseconds: Int64, timeZone: TimeZone) -> String {
        time(EventStoreLayout.date(fromCapturedMilliseconds: milliseconds), timeZone: timeZone)
    }

    private static func localDayLabel(for interval: ClosedRange<Int64>, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let start = formatter.string(from: EventStoreLayout.date(fromCapturedMilliseconds: interval.lowerBound))
        let end = formatter.string(from: EventStoreLayout.date(fromCapturedMilliseconds: interval.upperBound))
        return start == end ? start : "\(start)–\(end)"
    }

    private static func knowledgeGraphProjection(
        for graph: ContextKnowledgeGraph,
        matching query: String?,
        overlapping requestedInterval: ClosedRange<Int64>?,
        excludingRawContexts rawContexts: [RecordedContext]
    ) -> KnowledgeGraphProjection? {
        let terms = query.map { searchTerms(in: $0) } ?? []
        let allSessions = graph.nodes.filter { $0.type == .session }
        var selectedSessionIDs = Set(allSessions.map(\.id))

        if !terms.isEmpty {
            let matchingNodeIDs = Set(graph.nodes.compactMap { node in
                text(searchableText(for: node), containsAny: terms) ? node.id : nil
            })
            selectedSessionIDs = Set(allSessions.compactMap { session in
                matchingNodeIDs.contains(session.id) ? session.id : nil
            })
            for edge in graph.edges where edge.kind == .sessionMembership {
                if matchingNodeIDs.contains(edge.from) {
                    selectedSessionIDs.insert(edge.to)
                }
            }
        }

        let sessions = allSessions
            .filter { selectedSessionIDs.contains($0.id) }
            .filter { session in
                guard let requestedInterval else { return true }
                return overlaps(session.firstSeenMs...session.lastSeenMs, requestedInterval)
            }
            .filter { !isCovered($0, by: rawContexts) }
            .sorted {
                if $0.firstSeenMs != $1.firstSeenMs { return $0.firstSeenMs < $1.firstSeenMs }
                return $0.id < $1.id
            }
        guard let first = sessions.first else { return nil }

        let sessionIDs = Set(sessions.map(\.id))
        let membershipEdges = graph.edges.filter { edge in
            guard edge.kind == .sessionMembership, sessionIDs.contains(edge.to) else { return false }
            guard let requestedInterval else { return true }
            return overlaps(edge.firstSeenMs...edge.lastSeenMs, requestedInterval)
        }
        let relatedNodeIDs = Set(membershipEdges.map(\.from))
        let relatedNodes = graph.nodes
            .filter { relatedNodeIDs.contains($0.id) }
            .sorted {
                if $0.type.rawValue != $1.type.rawValue { return $0.type.rawValue < $1.type.rawValue }
                return $0.id < $1.id
            }

        let selectedStart = first.firstSeenMs
        let selectedEnd = sessions.map(\.lastSeenMs).max() ?? first.lastSeenMs
        let interval: ClosedRange<Int64>
        if let requestedInterval {
            let lower = max(selectedStart, requestedInterval.lowerBound)
            let upper = min(selectedEnd, requestedInterval.upperBound)
            guard lower <= upper else { return nil }
            interval = lower...upper
        } else {
            interval = selectedStart...selectedEnd
        }
        return KnowledgeGraphProjection(
            sessions: sessions,
            relatedNodes: relatedNodes,
            interval: interval,
            searchTerms: terms
        )
    }

    private static func isCovered(
        _ session: ContextKnowledgeGraphNode,
        by contexts: [RecordedContext]
    ) -> Bool {
        guard !contexts.isEmpty else { return false }
        let matching = contexts.filter { context in
            let milliseconds = EventStoreLayout.capturedMilliseconds(for: context.capturedAt)
            return milliseconds >= session.firstSeenMs
                && milliseconds <= session.lastSeenMs
                && sessionIdentityMatches(session, appName: context.appName, bundleIdentifier: context.bundleIdentifier)
        }
        let expectedCount = Int(session.attributes["context_count"] ?? "") ?? session.mentionCount
        guard matching.count >= max(1, expectedCount),
              let first = matching.map({ EventStoreLayout.capturedMilliseconds(for: $0.capturedAt) }).min(),
              let last = matching.map({ EventStoreLayout.capturedMilliseconds(for: $0.capturedAt) }).max() else {
            return false
        }
        return first <= session.firstSeenMs && last >= session.lastSeenMs
    }

    private static func isCovered(
        _ session: ContextKnowledgeGraphNode,
        by episodes: [TimelineEpisode]
    ) -> Bool {
        let expectedCount = Int(session.attributes["context_count"] ?? "") ?? session.mentionCount
        return episodes.contains { episode in
            let start = EventStoreLayout.capturedMilliseconds(for: episode.startAt)
            let end = EventStoreLayout.capturedMilliseconds(for: episode.endAt)
            return start <= session.firstSeenMs
                && end >= session.lastSeenMs
                && episode.contextCount >= max(1, expectedCount)
                && sessionIdentityMatches(
                    session,
                    appName: episode.appName,
                    bundleIdentifier: episode.bundleIdentifier
                )
        }
    }

    private static func sessionIdentityMatches(
        _ session: ContextKnowledgeGraphNode,
        appName: String,
        bundleIdentifier: String?
    ) -> Bool {
        let sessionBundle = session.attributes["bundle_identifier"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let candidateBundle = bundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let sessionBundle, !sessionBundle.isEmpty,
           let candidateBundle, !candidateBundle.isEmpty {
            return sessionBundle == candidateBundle
        }
        let sessionApp = session.attributes["app_name"] ?? session.aliases.first ?? session.label
        return normalizedIdentity(sessionApp) == normalizedIdentity(appName)
    }

    private static func normalizedIdentity(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func searchableText(for node: ContextKnowledgeGraphNode) -> String {
        ([node.label, node.canonicalValue]
            + node.aliases
            + node.keywords
            + node.evidenceSnippets
            + node.attributes.values)
            .joined(separator: "\n")
    }

    private static let projectionSearchStopwords: Set<String> = [
        "the", "and", "was", "were", "what", "when", "where", "which", "who", "whom",
        "why", "how", "did", "does", "doing", "done", "have", "has", "had", "you",
        "your", "yours", "about", "with", "from", "that", "this", "these", "those",
        "for", "are", "show", "tell", "give", "find", "get", "see", "look", "today",
        "yesterday", "earlier", "morning", "afternoon", "evening", "tonight", "day",
        "week", "time", "thing", "things", "summary", "summarize", "recap",
    ]

    private static func searchTerms(in query: String) -> [String] {
        Array(Set(query
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 && !projectionSearchStopwords.contains($0) }))
            .sorted()
    }

    private static func text(_ value: String, containsAny terms: [String]) -> Bool {
        guard !terms.isEmpty else { return false }
        let tokens = value
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        return terms.contains { term in tokens.contains(where: { $0.hasPrefix(term) }) }
    }

    private static func millisecondInterval(from start: Date, through end: Date) -> ClosedRange<Int64> {
        EventStoreLayout.capturedMilliseconds(for: start)...EventStoreLayout.capturedMilliseconds(for: end)
    }

    private static func clippedInterval(
        for node: ContextKnowledgeGraphNode,
        to interval: ClosedRange<Int64>
    ) -> ClosedRange<Int64> {
        max(node.firstSeenMs, interval.lowerBound)...min(node.lastSeenMs, interval.upperBound)
    }

    private static func overlaps(_ lhs: ClosedRange<Int64>, _ rhs: ClosedRange<Int64>) -> Bool {
        lhs.upperBound >= rhs.lowerBound && lhs.lowerBound <= rhs.upperBound
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

    static func time(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
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
        let blocks: [StructuredBlock]
        let lists: [StructuredList]
        let markdownTables: [String]
        let csvTables: [String]
        let tables: [StructuredTable]

        enum CodingKeys: String, CodingKey {
            case summary
            case readingOrder = "reading_order"
            case keyValues = "key_values"
            case blocks
            case lists
            case markdownTables = "markdown_tables"
            case csvTables = "csv_tables"
        }

        init(
            summary: String,
            readingOrder: String,
            keyValues: [StructuredKeyValue],
            blocks: [StructuredBlock] = [],
            lists: [StructuredList] = [],
            markdownTables: [String],
            csvTables: [String],
            tables: [StructuredTable]
        ) {
            self.summary = summary
            self.readingOrder = readingOrder
            self.keyValues = keyValues
            self.blocks = blocks
            self.lists = lists
            self.markdownTables = markdownTables
            self.csvTables = csvTables
            self.tables = tables
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            summary = try container.decode(String.self, forKey: .summary)
            readingOrder = try container.decode(String.self, forKey: .readingOrder)
            keyValues = try container.decodeIfPresent([StructuredKeyValue].self, forKey: .keyValues) ?? []
            blocks = try container.decodeIfPresent([StructuredBlock].self, forKey: .blocks) ?? []
            lists = try container.decodeIfPresent([StructuredList].self, forKey: .lists) ?? []
            markdownTables = try container.decodeIfPresent([String].self, forKey: .markdownTables) ?? []
            csvTables = try container.decodeIfPresent([String].self, forKey: .csvTables) ?? []
            tables = markdownTables.enumerated().map { index, _ in
                StructuredTable(index: index, rows: [])
            }
        }
    }

    private struct StructuredKeyValue: Codable {
        let key: String
        let value: String
        let kind: String?

        init(key: String, value: String, kind: String? = nil) {
            self.key = key
            self.value = value
            self.kind = kind
        }
    }

    private struct StructuredBlock: Decodable {
        let kind: String
        let text: String
    }

    private struct StructuredList: Decodable {
        let items: [StructuredListItem]
    }

    private struct StructuredListItem: Decodable {
        let text: String
    }

    private struct StructuredTable: Codable {
        let index: Int
        let rows: [[String]]
    }

    private struct SidecarStructure: Decodable {
        let version: Int
        let lines: [SidecarLine]
        let blocks: [StructuredBlock]
        let fields: [StructuredKeyValue]
        let lists: [StructuredList]
        let tables: [SidecarTable]

        private enum CodingKeys: String, CodingKey {
            case version
            case lines
            case blocks
            case fields
            case lists
            case tables
        }
    }

    private struct SidecarLine: Decodable {
        let text: String
    }

    private struct SidecarTable: Decodable {
        let rows: [[String]]
    }

    private struct TableExtraction: Encodable {
        let contextID: Int64
        let tableIndex: Int
        let format: String
        let rows: [[String]]
        let markdown: String
        let csv: String

        enum CodingKeys: String, CodingKey {
            case contextID = "context_id"
            case tableIndex = "table_index"
            case format
            case rows
            case markdown
            case csv
        }
    }

    private struct FieldExtraction: Encodable {
        let contextID: Int64
        let query: String?
        let fields: [StructuredKeyValue]

        enum CodingKeys: String, CodingKey {
            case contextID = "context_id"
            case query
            case fields
        }
    }

    private func structuredMetadata(for moment: RecordedContext) async -> StructuredMetadata? {
        if let sidecar = try? await store.ocrStructure(contextID: moment.id),
           let structured = Self.structuredMetadata(fromSidecar: sidecar.json) {
            return structured
        }
        guard let metadata = moment.metadataJSON else { return nil }
        return Self.structuredMetadata(from: metadata)
    }

    private static func structuredMetadata(from json: String) -> StructuredMetadata? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(StructuredEnvelope.self, from: data).structured
    }

    private static func structuredMetadata(fromSidecar json: String) -> StructuredMetadata? {
        guard let data = json.data(using: .utf8),
              let sidecar = try? JSONDecoder().decode(SidecarStructure.self, from: data) else {
            return nil
        }
        let readingOrder = sidecar.lines.map(\.text).joined(separator: "\n")
        let tables = sidecar.tables.enumerated().map { index, table in
            StructuredTable(index: index, rows: table.rows)
        }
        let markdown = tables.map { markdownTable($0.rows) }
        let csv = tables.map { csvTable($0.rows) }
        let lineCount = sidecar.lines.count
        let fieldCount = sidecar.fields.count
        var parts = [
            "\(lineCount) \(lineCount == 1 ? "line" : "lines")",
            "\(fieldCount) \(fieldCount == 1 ? "field" : "fields")",
            "\(tables.count) \(tables.count == 1 ? "table" : "tables")",
        ]
        if !sidecar.blocks.isEmpty {
            parts.append("\(sidecar.blocks.count) \(sidecar.blocks.count == 1 ? "block" : "blocks")")
        }
        if !sidecar.lists.isEmpty {
            parts.append("\(sidecar.lists.count) \(sidecar.lists.count == 1 ? "list" : "lists")")
        }
        return StructuredMetadata(
            summary: "Structured content: \(parts.joined(separator: ", ")).",
            readingOrder: readingOrder,
            keyValues: sidecar.fields,
            blocks: sidecar.blocks,
            lists: sidecar.lists,
            markdownTables: markdown,
            csvTables: csv,
            tables: tables
        )
    }

    private static func structureLine(
        for context: RecordedContext,
        structured: StructuredMetadata,
        timeZone: TimeZone
    ) -> String {
        var lines = ["[#\(context.id)] \(time(context.capturedAt, timeZone: timeZone)) \(context.appName) structured content [trust=\(context.sourceTrust) safeForControl=\(context.safeForControl)]"]
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
                let kind = pair.kind.map { " [\($0)]" } ?? ""
                lines.append("- **\(pair.key)**: \(pair.value)\(kind)")
            }
        }
        if !structured.blocks.isEmpty {
            lines.append("")
            lines.append("Blocks:")
            for block in structured.blocks.prefix(12) {
                lines.append("- \(block.kind): \(block.text)")
            }
        }
        if !structured.lists.isEmpty {
            lines.append("")
            lines.append("Lists:")
            for list in structured.lists.prefix(8) {
                lines.append("- " + list.items.map(\.text).joined(separator: "; "))
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

    private static func structureSummaryLine(_ structured: StructuredMetadata) -> String {
        var lines = [structured.summary]
        if !structured.keyValues.isEmpty {
            lines.append("Fields: " + structured.keyValues.prefix(8).map { "\($0.key)=\($0.value)" }.joined(separator: "; "))
        }
        if !structured.markdownTables.isEmpty {
            lines.append("Tables: " + structured.markdownTables.enumerated().map {
                "table \($0.offset): \($0.element.components(separatedBy: "\n").first ?? "")"
            }.joined(separator: "; "))
        }
        if !structured.lists.isEmpty {
            lines.append("Lists: " + structured.lists.prefix(4).map { $0.items.map(\.text).joined(separator: "; ") }.joined(separator: " | "))
        }
        return bounded(lines, maxBytes: 2_500, maxLines: 36)
    }

    private static func filteredFields(_ fields: [StructuredKeyValue], query: String?) -> [StructuredKeyValue] {
        let tokens = (query ?? "")
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
        guard !tokens.isEmpty else { return fields }
        return fields.filter { field in
            let haystack = "\(field.key) \(field.value) \(field.kind ?? "")".lowercased()
            return tokens.contains { haystack.contains($0) }
        }
    }

    private static func markdownTable(_ rows: [[String]]) -> String {
        let rows = normalizedRows(rows)
        guard let header = rows.first else { return "" }
        let separator = [String](repeating: "---", count: header.count)
        return ([header, separator] + rows.dropFirst()).map { row in
            "| " + row.map(markdownCell).joined(separator: " | ") + " |"
        }.joined(separator: "\n")
    }

    private static func csvTable(_ rows: [[String]]) -> String {
        normalizedRows(rows).map { row in
            row.map(csvCell).joined(separator: ",")
        }.joined(separator: "\n")
    }

    private static func normalizedRows(_ rows: [[String]]) -> [[String]] {
        let count = rows.map(\.count).max() ?? 0
        guard count > 0 else { return [] }
        return rows.map { $0 + [String](repeating: "", count: max(0, count - $0.count)) }
    }

    private static func markdownCell(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: "<br>")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return escaped.isEmpty ? " " : escaped
    }

    private static func csvCell(_ value: String) -> String {
        let normalized = value
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let safe = formulaEscaped(normalized)
        let escaped = safe.replacingOccurrences(of: "\"", with: "\"\"")
        if escaped.contains(",") || escaped.contains("\"") {
            return "\"\(escaped)\""
        }
        return escaped
    }

    private static func formulaEscaped(_ value: String) -> String {
        guard let first = value.drop(while: { $0.isWhitespace }).first else { return value }
        return ["=", "+", "-", "@"].contains(String(first)) ? "'" + value : value
    }

    private static func json<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    private static func enveloped(_ payload: String, source: String, tool: String) -> String {
        InjectionGuard.renderEnvelope(
            trust: .untrustedRecord,
            source: source,
            acquiredByTool: tool,
            payload: payload
        )
    }

    private static func status(
        _ status: ToolResultStatusEnvelope.Status,
        tool: String,
        kind: String,
        message: String
    ) -> String {
        ToolResultStatusEnvelope.render(status, kind: kind, message: message, tool: tool)
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
