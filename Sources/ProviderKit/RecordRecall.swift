import CascadeMemory
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
///
/// This is the single implementation of those tools. Both the Ask panel's
/// `RecordSearchAnswerer` (which answers questions about the record) and the
/// on-screen cursor agent (which ACTS on it) route through here, so the
/// retrieval behaviour and the `[#id]` line format stay identical across both.
public struct RecordRecall: Sendable {
    private let store: CascadeStore
    private static let logger = Logger(subsystem: "com.humain.cascade", category: "record-recall")

    public init(store: CascadeStore) {
        self.store = store
    }

    /// The three recall tool names, for routing a tool call to `perform`.
    public static let toolNames: Set<String> = ["search_record", "get_timeframe", "inspect_moment"]

    public static func isRecallTool(_ name: String) -> Bool { toolNames.contains(name) }

    /// One parsed recall call — `Sendable`, so a `@MainActor` caller can extract
    /// it from the model's raw `[String: Any]` tool input and hand it to the
    /// nonisolated executor without crossing isolation with an untyped dictionary
    /// (the same pattern as `HarnessCall`). Validation of empty/missing fields
    /// stays in `perform`, so the teaching messages are identical to before.
    public enum Call: Sendable, Equatable {
        case search(query: String)
        case timeframe(startISO: String?, endISO: String?)
        case inspect(id: Int64?)
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
            default:
                self = .unknown(name)
            }
        }

        /// The verbatim call for the audit log — query, time window, or moment id.
        public var auditDetail: String {
            let detail: String
            switch self {
            case .search(let query): detail = "search_record: \(query)"
            case .timeframe(let start, let end): detail = "get_timeframe: \(start ?? "?") → \(end ?? "?")"
            case .inspect(let id): detail = "inspect_moment: #\(id.map(String.init) ?? "?")"
            case .unknown(let name): detail = name
            }
            return String(detail.prefix(240))
        }
    }

    // MARK: - Tool definitions

    /// The Messages-API tool definitions. A function, not a stored static —
    /// `[[String: Any]]` isn't Sendable, so a global constant trips strict
    /// concurrency. Descriptions are framed for an agent that RESOLVES references
    /// to the past, so it reaches for these when the goal points at something not
    /// on screen now ("the email I was reading", "what I started this morning").
    public static func toolDefinitions() -> [[String: Any]] { [
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
    ] }

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
            // Run the keyword (BM25) and semantic (cosine) lanes in parallel and
            // fuse with Reciprocal Rank Fusion — NOT a fallback chain. A moment the
            // keyword lane missed but meaning ranked highly surfaces even when
            // keyword search also returned hits; the model shouldn't have to know
            // our retrieval quirks.
            let hits = (try? await store.hybridContexts(matching: query, limit: 12)) ?? []
            let visible = hits.filter { !PrivacyRules.isSensitive($0) }
            guard !visible.isEmpty else { return "No recorded moments match “\(query)”. Try different words or a timeframe." }
            return visible.map { Self.line(for: $0, textCap: 240) }.joined(separator: "\n")

        case .timeframe(let startISO, let endISO):
            guard let start = Self.date(from: startISO),
                  let end = Self.date(from: endISO), end > start else {
                return "get_timeframe needs start_iso and end_iso (ISO-8601, end after start)."
            }
            let rows = ((try? await store.contexts(between: start, and: end, limit: 60)) ?? [])
                .filter { !PrivacyRules.isSensitive($0) }
            guard !rows.isEmpty else { return "Nothing recorded in that window." }
            return rows.map { Self.line(for: $0, textCap: 160) }.joined(separator: "\n")

        case .inspect(let id):
            guard let id else { return "inspect_moment needs a numeric id." }
            guard let moment = try? await store.context(id: id), !PrivacyRules.isSensitive(moment) else {
                return "No accessible moment #\(id)."
            }
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
            return out

        case .unknown(let name):
            return "Unknown recall tool \(name)."
        }
    }

    // MARK: - Formatting (the [#id] line the model reads and cites)

    /// "[#42] 14:03 Mail — Inbox | text…" — the id the model can cite or inspect.
    static func line(for context: RecordedContext, textCap: Int) -> String {
        let title = context.windowTitle.map { " — \($0)" } ?? ""
        let text = (context.ocrText ?? "").replacingOccurrences(of: "\n", with: " · ")
        let trimmed = text.isEmpty ? "" : " | \(String(text.prefix(textCap)))"
        return "[#\(context.id)] \(time(context.capturedAt)) \(context.appName)\(title)\(trimmed)"
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
}
