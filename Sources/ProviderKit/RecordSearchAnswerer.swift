import CascadeMemory
import Foundation
import OSLog

/// An answer grounded in the record, with the moments it actually came from —
/// the citations are what let the chat render proof chips that jump the Reel.
public struct RecordAnswer: Sendable, Equatable {
    public let text: String
    public let citedMomentIDs: [Int64]

    public init(text: String, citedMomentIDs: [Int64]) {
        self.text = text
        self.citedMomentIDs = citedMomentIDs
    }
}

/// Q&A that can hunt through the record and report which moments it used.
/// Abstracted so the orchestrator's fallback chain is unit-testable without
/// the network.
public protocol RecordAnswering: Sendable {
    func answer(question: String, conversation: [(user: String, assistant: String)]) async throws -> RecordAnswer
}

/// Agentic Q&A over the local record: instead of one scoop of grounding, the
/// model HUNTS — full-text search, time-window pulls, and per-moment inspection,
/// multi-hop, until it can answer or honestly can't. The same pull pattern as
/// `use_skill` and the harness: tools resolve in-process against the local
/// SQLite, so each hop costs milliseconds plus one model turn.
///
/// Every moment shown to the model carries its `[#id]`; the model cites the ids
/// it used and the final answer returns them as structured citations.
public struct RecordSearchAnswerer: RecordAnswering, Sendable {
    private let store: CascadeStore
    private let keyStore: AnthropicKeyStore
    private let model: String
    private let maxHops: Int
    private static let logger = Logger(subsystem: "com.humain.cascade", category: "record-answerer")

    public init(
        store: CascadeStore,
        keyStore: AnthropicKeyStore = AnthropicKeyStore(),
        model: String = AnthropicModel.sonnet,
        maxHops: Int = 6
    ) {
        self.store = store
        self.keyStore = keyStore
        self.model = model
        self.maxHops = maxHops
    }

    // MARK: - Public entry

    /// Answers `question`, optionally with prior conversation turns for
    /// follow-ups ("and after that?"). Throws only on missing key / transport
    /// failure — the caller falls back to the single-shot answerer.
    public func answer(question: String, conversation: [(user: String, assistant: String)] = []) async throws -> RecordAnswer {
        guard let key = keyStore.readKey(), !key.isEmpty else {
            throw AnthropicError.missingKey
        }

        var messages: [[String: Any]] = []
        for turn in conversation.suffix(6) {
            messages.append(["role": "user", "content": turn.user])
            messages.append(["role": "assistant", "content": turn.assistant])
        }
        messages.append(["role": "user", "content": question])

        for hop in 0..<maxHops {
            let isLastHop = hop == maxHops - 1
            let reply = try await send(key: key, messages: messages, toolsAllowed: !isLastHop)
            guard let content = reply["content"] as? [[String: Any]] else {
                throw AnthropicError.emptyResponse
            }

            let toolUses = content.filter { ($0["type"] as? String) == "tool_use" }
            if toolUses.isEmpty {
                let text = content.compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }
                    .joined(separator: "\n")
                return Self.parseCitations(from: text)
            }

            messages.append(["role": "assistant", "content": content])
            var results: [[String: Any]] = []
            for use in toolUses {
                guard let id = use["id"] as? String, let name = use["name"] as? String else { continue }
                let input = use["input"] as? [String: Any] ?? [:]
                let output = await perform(tool: name, input: input)
                results.append(["type": "tool_result", "tool_use_id": id, "content": output])
            }
            messages.append(["role": "user", "content": results])
        }
        throw AnthropicError.transport("no final answer within \(maxHops) hops")
    }

    // MARK: - Tools (resolve in-process against the local store)

    private func perform(tool: String, input: [String: Any]) async -> String {
        switch tool {
        case "search_record":
            let query = (input["query"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return "search_record needs a query." }
            // AND-search first (precise), then any-token (recall) — the model
            // shouldn't have to know our FTS quirks.
            var hits = (try? await store.searchContexts(query: query, limit: 12)) ?? []
            if hits.isEmpty {
                hits = (try? await store.relevantContexts(to: query, limit: 12)) ?? []
            }
            let visible = hits.filter { !PrivacyRules.isSensitive($0) }
            guard !visible.isEmpty else { return "No recorded moments match “\(query)”. Try different words or a timeframe." }
            return visible.map { Self.line(for: $0, textCap: 240) }.joined(separator: "\n")

        case "get_timeframe":
            guard let start = Self.date(from: input["start_iso"]),
                  let end = Self.date(from: input["end_iso"]), end > start else {
                return "get_timeframe needs start_iso and end_iso (ISO-8601, end after start)."
            }
            let rows = ((try? await store.contexts(between: start, and: end, limit: 60)) ?? [])
                .filter { !PrivacyRules.isSensitive($0) }
            guard !rows.isEmpty else { return "Nothing recorded in that window." }
            return rows.map { Self.line(for: $0, textCap: 160) }.joined(separator: "\n")

        case "inspect_moment":
            guard let id = (input["id"] as? NSNumber)?.int64Value ?? (input["id"] as? Int).map(Int64.init) else {
                return "inspect_moment needs a numeric id."
            }
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

        default:
            return "Unknown tool \(tool)."
        }
    }

    // MARK: - Request plumbing

    private func send(key: String, messages: [[String: Any]], toolsAllowed: Bool) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        var body: [String: Any] = [
            "model": model,
            "max_tokens": 700,
            "system": Self.systemPrompt(),
            "messages": messages,
        ]
        if toolsAllowed {
            var tools = Self.toolDefinitions()
            // Cache the static prefix (system + tools) across hops.
            tools[tools.count - 1]["cache_control"] = ["type": "ephemeral"]
            body["tools"] = tools
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AnthropicError.transport("no HTTP response") }
        guard http.statusCode == 200 else {
            let detail = String(data: data, encoding: .utf8)?.prefix(300) ?? "?"
            Self.logger.error("Record answerer HTTP \(http.statusCode): \(detail, privacy: .public)")
            throw AnthropicError.http(http.statusCode, String(detail))
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AnthropicError.emptyResponse
        }
        return json
    }

    // A function, not a stored static — [[String: Any]] isn't Sendable, so a
    // global constant trips strict concurrency.
    private static func toolDefinitions() -> [[String: Any]] { [
        [
            "name": "search_record",
            "description": "Full-text search over everything the user has seen on screen (app names, window titles, on-screen text). Returns matching moments as [#id] time app — title | text. Search again with different words if the first try misses.",
            "input_schema": [
                "type": "object",
                "properties": ["query": ["type": "string", "description": "Keywords to search for"]],
                "required": ["query"],
            ],
        ],
        [
            "name": "get_timeframe",
            "description": "Everything recorded between two times, oldest first — for 'what was I doing around 2pm' style questions.",
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
            "description": "The full recorded text of one moment by its id, plus its immediate neighbors — use after a search hit to read the details.",
            "input_schema": [
                "type": "object",
                "properties": ["id": ["type": "integer", "description": "Moment id from a search result"]],
                "required": ["id"],
            ],
        ],
    ] }

    private static func systemPrompt() -> String {
        let formatter = ISO8601DateFormatter()
        return """
        You answer questions about what the user did and saw on their Mac, grounded ONLY \
        in their local screen record, which you search with the tools. Current time: \
        \(formatter.string(from: Date())) (timestamps in results are local HH:mm).

        Hunt before answering: search with the user's words, then with synonyms; pull a \
        timeframe when the question is about a stretch of time; inspect promising hits. \
        Two or three quick hops beat one lazy one. Never invent details that are not in \
        tool results, and never speculate about the future.

        Answer in one to four short sentences. After the answer, on its own final line, \
        write the moments you actually used: SOURCES: #id, #id (at most 4). If the record \
        genuinely doesn't contain the answer, say so in one line with no SOURCES line.
        """
    }

    // MARK: - Formatting

    /// "[#42] 14:03 Mail — Inbox | text…" — the id the model cites back.
    private static func line(for context: RecordedContext, textCap: Int) -> String {
        let title = context.windowTitle.map { " — \($0)" } ?? ""
        let text = (context.ocrText ?? "").replacingOccurrences(of: "\n", with: " · ")
        let trimmed = text.isEmpty ? "" : " | \(String(text.prefix(textCap)))"
        return "[#\(context.id)] \(time(context.capturedAt)) \(context.appName)\(title)\(trimmed)"
    }

    private static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private static func date(from value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string)
    }

    /// Splits "answer …\nSOURCES: #12, #87" into clean text + cited ids.
    /// Tolerates inline "[#12]" citations too. Public for tests.
    public static func parseCitations(from raw: String) -> RecordAnswer {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var ids: [Int64] = []

        if let range = text.range(of: #"(?im)^\s*SOURCES?\s*:\s*(.*)$"#, options: .regularExpression) {
            let line = String(text[range])
            ids.append(contentsOf: extractIDs(from: line))
            text.removeSubrange(range)
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Inline [#id] markers: collect, then strip from the display text.
        ids.append(contentsOf: extractIDs(from: text))
        text = text.replacingOccurrences(of: #"\s*\[#\d+\]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var unique: [Int64] = []
        for id in ids where !unique.contains(id) { unique.append(id) }
        return RecordAnswer(text: text, citedMomentIDs: Array(unique.prefix(4)))
    }

    private static func extractIDs(from text: String) -> [Int64] {
        guard let regex = try? NSRegularExpression(pattern: #"#(\d+)"#) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).flatMap { Int64(text[$0]) }
        }
    }
}
