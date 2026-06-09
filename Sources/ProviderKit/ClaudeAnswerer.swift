import CascadeMemory
import Foundation

/// Claude-backed grounded Q&A over local context. Read-only and retrospective —
/// the system prompt forbids speculation and forward-looking plans, matching
/// Cascade's Reel-Q&A privacy stance. Callers pass already privacy-filtered
/// contexts; this type does no sensitivity filtering of its own.
public struct ClaudeGroundedAnswerer: ContextQuestionAnswering {
    private let client: any MessageCompleting
    private let model: String

    public init(client: any MessageCompleting = AnthropicClient(), model: String = AnthropicModel.opus) {
        self.client = client
        self.model = model
    }

    public func answer(question: String, contexts: [RecordedContext]) async throws -> String {
        let recent = contexts.sorted { $0.capturedAt > $1.capturedAt }.prefix(12)
        let block: String
        if recent.isEmpty {
            block = "(no recorded local context)"
        } else {
            block = recent.map { context in
                let title = context.windowTitle.map { " — \($0)" } ?? ""
                let ocr = context.ocrText.map { " | on-screen: \($0.prefix(300))" } ?? ""
                return "• \(context.appName)\(title)\(ocr)"
            }.joined(separator: "\n")
        }
        return try await client.complete(
            system: Self.systemPrompt,
            user: "Question: \(question)\n\nLocal context (most recent first):\n\(block)",
            model: model,
            maxTokens: 1024
        )
    }

    static let systemPrompt = """
    You answer questions about what the employee did locally, grounded ONLY in the \
    provided context samples. You are read-only and retrospective: never speculate, \
    never plan or suggest future actions, and never invent details that are not in \
    the context. If the context does not contain the answer, say so plainly. Be concise.
    """
}
