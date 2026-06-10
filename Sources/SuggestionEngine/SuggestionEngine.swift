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

    public func suggest(from contexts: [RecordedContext]) -> [AgentSuggestion] {
        let nonSensitive = contexts.filter { !PrivacyRules.isSensitive($0) }
        guard !nonSensitive.isEmpty else { return [] }

        var suggestions: [AgentSuggestion] = []
        let grouped = Dictionary(grouping: nonSensitive) { context in
            [context.bundleIdentifier ?? context.appName, context.windowTitle ?? ""].joined(separator: "::")
        }
        for (_, items) in grouped where items.count >= 3 {
            let latest = items.sorted { $0.capturedAt > $1.capturedAt }.first!
            suggestions.append(AgentSuggestion(
                title: "You keep coming back to \(latest.appName)" + (latest.windowTitle.map { " — “\(String($0.prefix(40)))”" } ?? ""),
                summary: "Seen \(items.count) times in the record. Run this to get a breakdown of what you keep doing there and what an agent could take over.",
                kind: .repeatedWorkflow,
                confidence: min(0.95, 0.55 + Double(items.count) * 0.08),
                evidence: [
                    "\(items.count) matching moments",
                    latest.windowTitle.map { "Latest window: \($0)" } ?? "Latest app: \(latest.appName)"
                ],
                doable: true,
                appName: latest.appName,
                windowTitle: latest.windowTitle
            ))
        }

        if nonSensitive.count >= 2 {
            suggestions.append(AgentSuggestion(
                title: "Draft today’s recap from the record",
                summary: "Cascade writes a short recap of what you actually worked on today — grounded only in the local record, shown in the Reel chat.",
                kind: .dailyRecap,
                confidence: 0.72,
                evidence: [
                    "\(nonSensitive.count) local context samples",
                    "\(Set(nonSensitive.map(\.appName)).count) apps observed"
                ],
                doable: true
            ))
        }

        return suggestions.sorted { lhs, rhs in
            if lhs.confidence == rhs.confidence { return lhs.title < rhs.title }
            return lhs.confidence > rhs.confidence
        }
    }
}
