import CascadeMemory
import Foundation

public enum SuggestionKind: String, Codable, Sendable {
    case dailyRecap
    case repeatedWorkflow
    case reviewQueue
}

public struct AgentSuggestion: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let summary: String
    public let kind: SuggestionKind
    public let confidence: Double
    public let evidence: [String]
    public let doable: Bool
    /// The observed context the suggestion came from — what a concrete deploy
    /// action needs (the display title alone is not an executable goal).
    public let appName: String?
    public let windowTitle: String?

    public init(
        id: UUID = UUID(),
        title: String,
        summary: String,
        kind: SuggestionKind,
        confidence: Double,
        evidence: [String],
        doable: Bool,
        appName: String? = nil,
        windowTitle: String? = nil
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.kind = kind
        self.confidence = confidence
        self.evidence = evidence
        self.doable = doable
        self.appName = appName
        self.windowTitle = windowTitle
    }
}

public struct SuggestionEngine: Sendable {
    public init() {}

    /// Deliverable-shaped quick actions over the record. Repeated-WORKFLOW
    /// detection lives in WasteDetector (real recorded actions, real recipes) —
    /// this engine must never emit a watered-down copy of those cards, so
    /// "you keep coming back to X" grouping is gone.
    public func suggest(from contexts: [RecordedContext]) -> [AgentSuggestion] {
        let nonSensitive = contexts.filter { !PrivacyRules.isSensitive($0) }
        guard nonSensitive.count >= 2 else { return [] }

        return [AgentSuggestion(
            title: "Draft today’s recap from the record",
            summary: "Cascade writes a short recap of what you actually worked on today — grounded only in the local record, shown in the Reel chat.",
            kind: .dailyRecap,
            confidence: 0.72,
            evidence: [
                "\(nonSensitive.count) local context samples",
                "\(Set(nonSensitive.map(\.appName)).count) apps observed"
            ],
            doable: true
        )]
    }
}
