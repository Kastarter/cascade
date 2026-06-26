import CascadeMemory
import Foundation

/// Claude-backed grounded Q&A over local context. Read-only and retrospective —
/// the system prompt forbids speculation and forward-looking plans, matching
/// Cascade's Reel-Q&A privacy stance. Callers pass already privacy-filtered
/// contexts; this type does no sensitivity filtering of its own.
public struct ClaudeGroundedAnswerer: ContextQuestionAnswering {
    private let client: any MessageCompleting
    private let model: String
    static let promptVersion = "claude-grounded-answerer.prompt.v1"
    static let schemaVersion = "claude-grounded-answerer.schema.v1"

    public init(client: any MessageCompleting = AnthropicClient(), model: String = AnthropicModel.opus) {
        self.client = client
        self.model = model
    }

    public func answer(question: String, grounding: ChatGrounding) async throws -> String {
        var sections = ["Question: \(question)"]

        let timelineRows = grounding.timeline.isEmpty ? grounding.allMoments : grounding.timeline
        let timeline = ActivityTimeline.digest(from: timelineRows)
        if !timeline.isEmpty {
            sections.append("Activity timeline (whole recorded window, oldest first, collapsed into app sessions):\n\(timeline)")
        }
        if !grounding.samples.isEmpty {
            let samples = grounding.samples.sorted { $0.capturedAt < $1.capturedAt }
            sections.append("On-screen content sampled across the window (oldest first):\n\(Self.block(samples))")
        }
        if !grounding.relevant.isEmpty {
            sections.append("Moments matching the question (best match first):\n\(Self.block(grounding.relevant))")
        }
        let recent = Array(grounding.recent.sorted { $0.capturedAt > $1.capturedAt }.prefix(12))
        sections.append(
            "Most recent moments in detail (most recent first):\n"
                + (recent.isEmpty ? "(no recorded local context)" : Self.block(recent))
        )

        return try await client.complete(
            system: Self.systemPrompt,
            user: sections.joined(separator: "\n\n"),
            model: model,
            maxTokens: 300,
            options: .deterministic(
                promptVersion: Self.promptVersion,
                schemaVersion: Self.schemaVersion,
                callsite: "ClaudeGroundedAnswerer.answer"
            )
        )
    }

    /// One moment per line, timestamped so the model can anchor answers in time.
    private static func block(_ contexts: [RecordedContext], timeZone: TimeZone = .current) -> String {
        let time = DateFormatter()
        time.locale = Locale(identifier: "en_US_POSIX")
        time.timeZone = timeZone
        time.dateFormat = "HH:mm"
        return contexts.map { context in
            let title = context.windowTitle.map { " — \($0)" } ?? ""
            let ocr = context.ocrText.map { " | on-screen: \($0.prefix(300))" } ?? ""
            return "• \(time.string(from: context.capturedAt)) \(context.appName)\(title)\(ocr)"
        }.joined(separator: "\n")
    }

    static let systemPrompt = """
    You answer questions about what the employee did locally, grounded ONLY in the \
    provided context samples. You are read-only and retrospective: never speculate, \
    never plan or suggest future actions, and never invent details that are not in \
    the context.

    Use the activity timeline for questions about a longer stretch (a day, an \
    evening) — cover the whole timeline, not just the latest entries. Use the \
    sampled content and question-matching moments for specifics seen earlier (names, \
    numbers, deadlines, messages). Use the detailed moments for what just happened.

    Answer in one to three short sentences. No preamble, no restating the question, \
    no boilerplate disclaimers. If the context doesn't contain the answer, say so in \
    one short line.
    """
}
