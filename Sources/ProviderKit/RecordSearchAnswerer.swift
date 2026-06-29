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
    private let recall: RecordRecall
    private let keyStore: AnthropicKeyStore
    private let model: String
    private let maxHops: Int
    private let includeStructuredContent: Bool
    private static let logger = Logger(subsystem: "com.humain.cascade", category: "record-answerer")

    public init(
        store: CascadeStore,
        keyStore: AnthropicKeyStore = AnthropicKeyStore(),
        model: String = AnthropicModel.sonnet,
        maxHops: Int = 6,
        includeStructuredContent: Bool = false
    ) {
        self.store = store
        self.recall = RecordRecall(store: store, reranker: HeuristicRecordReranker())
        self.keyStore = keyStore
        self.model = model
        self.maxHops = maxHops
        self.includeStructuredContent = includeStructuredContent
    }

    public func configuredToolDefinitions() -> [[String: Any]] {
        RecordRecall.toolDefinitions(includeStructuredContent: includeStructuredContent)
    }

    public var usesRerankedRecall: Bool { recall.hasReranker }

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

    /// Delegates to the shared `RecordRecall` so the Ask panel and the on-screen
    /// cursor agent run byte-identical retrieval against the record.
    private func perform(tool: String, input: [String: Any]) async -> String {
        guard RecordRecall.isRecallTool(tool, includeStructuredContent: includeStructuredContent) else {
            return "Unknown recall tool \(tool)."
        }
        return await recall.perform(tool: tool, input: input)
    }

    // MARK: - Request plumbing

    private func send(key: String, messages: [[String: Any]], toolsAllowed: Bool) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        // System is split into a STABLE, cacheable prefix and a VOLATILE time
        // block placed after the cache breakpoint. The tool loop rebuilds this
        // request on every hop; if the wall-clock time lived in the cached prefix
        // (as it used to), the prefix would differ by milliseconds each hop and
        // the cache would never hit. Static-first, volatile-last is Anthropic's
        // documented caching pattern.
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 700,
            "system": [
                ["type": "text", "text": Self.stableSystemPrompt(), "cache_control": ["type": "ephemeral"]],
                ["type": "text", "text": Self.timeContext()],
            ],
            "messages": messages,
        ]
        if toolsAllowed {
            var tools = RecordRecall.toolDefinitions(includeStructuredContent: includeStructuredContent)
            // Also cache the (static) tools block.
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

    /// The stable, cacheable system prefix — byte-identical across hops and
    /// answers, so the prompt cache actually hits. Carries NO wall-clock time
    /// (that lives in `timeContext()`, after the cache breakpoint). Public for tests.
    public static func stableSystemPrompt() -> String {
        """
        You answer questions about what the user did and saw on their Mac, grounded ONLY \
        in their local screen record, which you search with the tools. Timestamps in \
        results are local HH:mm; the current time is given separately below.

        Hunt before answering: search with the user's words, then with synonyms; pull a \
        timeframe when the question is about a stretch of time; inspect promising hits. \
        Two or three quick hops beat one lazy one. Never invent details that are not in \
        tool results, and never speculate about the future.

        Answer in one to four short sentences. After the answer, on its own final line, \
        write the moments you actually used: SOURCES: #id, #id (at most 4). If the record \
        genuinely doesn't contain the answer, say so in one line with no SOURCES line.
        """
    }

    /// The volatile per-request note (current time). Placed AFTER the cache
    /// breakpoint so it can change every call without invalidating the cache.
    public static func timeContext() -> String {
        "Current time: \(ISO8601DateFormatter().string(from: Date()))."
    }

    // MARK: - Citation parsing

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
