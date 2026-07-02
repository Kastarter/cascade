import CascadeMemory
import Foundation

public enum AgentContextFreshness: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case live
    case current
    case recent
    case historical
    case staticContext = "static"
    case unknown
}

public struct AgentContextBudget: Sendable, Equatable, Codable {
    public static let standard = AgentContextBudget(
        totalCharacters: 6_000,
        perSectionCharacters: 1_200
    )

    public let totalCharacters: Int
    public let perSectionCharacters: Int

    public init(totalCharacters: Int, perSectionCharacters: Int) {
        self.totalCharacters = max(0, totalCharacters)
        self.perSectionCharacters = max(0, perSectionCharacters)
    }
}

public struct AgentContextSection: Sendable, Equatable, Hashable, Codable {
    public static let defaultOrder = 100
    public static let affordanceOrder = 20

    public let name: String
    public let body: String
    public let freshness: AgentContextFreshness
    public let order: Int
    public let maxCharacters: Int?

    public init(
        name: String,
        body: String,
        freshness: AgentContextFreshness = .unknown,
        order: Int = Self.defaultOrder,
        maxCharacters: Int? = nil
    ) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = trimmedName.isEmpty ? "context" : trimmedName
        self.body = body
        self.freshness = freshness
        self.order = order
        self.maxCharacters = maxCharacters.map { max(0, $0) }
    }
}

public struct AgentAffordanceMark: Sendable, Equatable, Hashable, Codable {
    public let mark: String
    public let role: String
    public let label: String
    public let actionHint: String?
    public let order: Int
    public let freshness: AgentContextFreshness

    public init(
        mark: String,
        role: String,
        label: String,
        actionHint: String? = nil,
        order: Int = AgentContextSection.affordanceOrder,
        freshness: AgentContextFreshness = .live
    ) {
        self.mark = Self.inline(mark)
        self.role = Self.inline(role)
        self.label = Self.inline(label)
        let action = actionHint.map(Self.inline)?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.actionHint = action?.isEmpty == true ? nil : action
        self.order = order
        self.freshness = freshness
    }

    public var renderedLine: String {
        let markToken = AuditIdentity.safeToken(mark)
        let roleToken = AuditIdentity.safeToken(role.lowercased())
        let labelText = Self.inline(label)
        var line = "\(markToken) [\(roleToken)]"
        if !labelText.isEmpty {
            line += " \(labelText)"
        }
        if let actionHint, !actionHint.isEmpty {
            line += " -> \(actionHint)"
        }
        return line
    }

    public static func renderedLines(_ marks: [AgentAffordanceMark]) -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        for mark in marks.sorted(by: sort) {
            let line = mark.renderedLine
            let hash = AuditIdentity.hash(line)
            guard seen.insert(hash).inserted else { continue }
            output.append(line)
        }
        return output
    }

    private static func sort(_ lhs: AgentAffordanceMark, _ rhs: AgentAffordanceMark) -> Bool {
        if lhs.order != rhs.order { return lhs.order < rhs.order }
        let lhsMark = AuditIdentity.safeToken(lhs.mark)
        let rhsMark = AuditIdentity.safeToken(rhs.mark)
        if lhsMark != rhsMark { return lhsMark < rhsMark }
        let lhsRole = AuditIdentity.safeToken(lhs.role)
        let rhsRole = AuditIdentity.safeToken(rhs.role)
        if lhsRole != rhsRole { return lhsRole < rhsRole }
        return AuditIdentity.hash(lhs.renderedLine) < AuditIdentity.hash(rhs.renderedLine)
    }

    private static func inline(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct RenderedAgentContextSection: Sendable, Equatable, Codable {
    public let name: String
    public let freshness: AgentContextFreshness
    public let sourceHash: String
    public let renderedHash: String
    public let sourceCharacters: Int
    public let renderedCharacters: Int
    public let textCharacters: Int
    public let truncated: Bool

    public init(
        name: String,
        freshness: AgentContextFreshness,
        sourceHash: String,
        renderedHash: String,
        sourceCharacters: Int,
        renderedCharacters: Int,
        textCharacters: Int,
        truncated: Bool
    ) {
        self.name = name
        self.freshness = freshness
        self.sourceHash = sourceHash
        self.renderedHash = renderedHash
        self.sourceCharacters = max(0, sourceCharacters)
        self.renderedCharacters = max(0, renderedCharacters)
        self.textCharacters = max(0, textCharacters)
        self.truncated = truncated
    }

    public var auditDescriptor: String {
        [
            "name=\(AuditIdentity.safeToken(name))",
            "freshness=\(freshness.rawValue)",
            "sourceHash=\(sourceHash)",
            "sourceChars=\(sourceCharacters)",
            "renderedHash=\(renderedHash)",
            "renderedChars=\(renderedCharacters)",
            "textChars=\(textCharacters)",
            "truncated=\(truncated ? 1 : 0)"
        ].joined(separator: " ")
    }
}

public struct RenderedAgentContextPack: Sendable, Equatable, Codable {
    public let text: String
    public let sections: [RenderedAgentContextSection]
    public let inputSectionCount: Int
    public let dedupedSectionCount: Int
    public let droppedSectionCount: Int

    public init(
        text: String,
        sections: [RenderedAgentContextSection],
        inputSectionCount: Int,
        dedupedSectionCount: Int,
        droppedSectionCount: Int
    ) {
        self.text = text
        self.sections = sections
        self.inputSectionCount = max(0, inputSectionCount)
        self.dedupedSectionCount = max(0, dedupedSectionCount)
        self.droppedSectionCount = max(0, droppedSectionCount)
    }

    public var totalCharacters: Int { text.count }

    public var auditDescriptor: String {
        var parts = [
            "inputSections=\(inputSectionCount)",
            "renderedSections=\(sections.count)",
            "dedupedSections=\(dedupedSectionCount)",
            "droppedSections=\(droppedSectionCount)",
            "totalChars=\(totalCharacters)",
            "textHash=\(AuditIdentity.hash(text))"
        ]
        parts.append(contentsOf: sections.map { "section{\($0.auditDescriptor)}" })
        return parts.joined(separator: " ")
    }
}

public struct AgentContextPack: Sendable, Equatable, Codable {
    public let sections: [AgentContextSection]
    public let affordanceMarks: [AgentAffordanceMark]
    public let budget: AgentContextBudget

    public init(
        sections: [AgentContextSection] = [],
        affordanceMarks: [AgentAffordanceMark] = [],
        budget: AgentContextBudget = .standard
    ) {
        self.sections = sections
        self.affordanceMarks = affordanceMarks
        self.budget = budget
    }

    public func render() -> RenderedAgentContextPack {
        Self.render(
            sections: sections,
            affordanceMarks: affordanceMarks,
            budget: budget
        )
    }

    public func renderText() -> String {
        render().text
    }

    public static func render(
        sections: [AgentContextSection],
        affordanceMarks: [AgentAffordanceMark] = [],
        budget: AgentContextBudget = .standard
    ) -> RenderedAgentContextPack {
        let inputSections = sections + affordanceSections(from: affordanceMarks)
        let sorted = inputSections
            .map(normalized)
            .filter { !$0.body.isEmpty }
            .sorted(by: sort)

        var seen = Set<String>()
        var unique: [AgentContextSection] = []
        var dedupedCount = 0
        for section in sorted {
            let hash = AuditIdentity.hash(section.body)
            if seen.insert(hash).inserted {
                unique.append(section)
            } else {
                dedupedCount += 1
            }
        }

        var renderedText = ""
        var renderedSections: [RenderedAgentContextSection] = []
        var budgetDroppedCount = 0
        for section in unique {
            let separator = renderedText.isEmpty ? "" : "\n\n"
            let prefix = sectionPrefix(for: section)
            let remainingTotal = budget.totalCharacters - renderedText.count - separator.count
            guard remainingTotal > prefix.count else {
                budgetDroppedCount += 1
                continue
            }

            let bodyLimit = min(
                section.maxCharacters ?? budget.perSectionCharacters,
                budget.perSectionCharacters,
                remainingTotal - prefix.count
            )
            guard bodyLimit > 0 else {
                budgetDroppedCount += 1
                continue
            }

            let clipped = clipped(section.body, limit: bodyLimit)
            guard !clipped.text.isEmpty else {
                budgetDroppedCount += 1
                continue
            }

            let block = prefix + clipped.text
            renderedText += separator + block
            renderedSections.append(RenderedAgentContextSection(
                name: section.name,
                freshness: section.freshness,
                sourceHash: AuditIdentity.hash(section.body),
                renderedHash: AuditIdentity.hash(clipped.text),
                sourceCharacters: section.body.count,
                renderedCharacters: clipped.text.count,
                textCharacters: block.count,
                truncated: clipped.truncated
            ))
        }

        let emptyDroppedCount = max(0, inputSections.count - sorted.count)
        return RenderedAgentContextPack(
            text: renderedText,
            sections: renderedSections,
            inputSectionCount: inputSections.count,
            dedupedSectionCount: dedupedCount,
            droppedSectionCount: emptyDroppedCount + budgetDroppedCount
        )
    }

    private static func affordanceSections(from marks: [AgentAffordanceMark]) -> [AgentContextSection] {
        let lines = AgentAffordanceMark.renderedLines(marks)
        guard !lines.isEmpty else { return [] }
        return [
            AgentContextSection(
                name: "affordances",
                body: lines.joined(separator: "\n"),
                freshness: .live,
                order: AgentContextSection.affordanceOrder
            )
        ]
    }

    private static func normalized(_ section: AgentContextSection) -> AgentContextSection {
        AgentContextSection(
            name: normalizedName(section.name),
            body: normalizedBody(section.body),
            freshness: section.freshness,
            order: section.order,
            maxCharacters: section.maxCharacters
        )
    }

    private static func sort(_ lhs: AgentContextSection, _ rhs: AgentContextSection) -> Bool {
        if lhs.order != rhs.order { return lhs.order < rhs.order }
        let lhsName = normalizedName(lhs.name)
        let rhsName = normalizedName(rhs.name)
        if lhsName != rhsName { return lhsName < rhsName }
        if lhs.freshness != rhs.freshness { return lhs.freshness.rawValue < rhs.freshness.rawValue }
        return AuditIdentity.hash(lhs.body) < AuditIdentity.hash(rhs.body)
    }

    private static func normalizedName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "context" : trimmed
    }

    private static func normalizedBody(_ body: String) -> String {
        body
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sectionPrefix(for section: AgentContextSection) -> String {
        "## \(section.name)\nfreshness: \(section.freshness.rawValue)\n"
    }

    private static func clipped(_ text: String, limit: Int) -> (text: String, truncated: Bool) {
        guard limit > 0 else { return ("", text.isEmpty == false) }
        guard text.count > limit else { return (text, false) }
        let marker = "\n[truncated]"
        guard limit > marker.count else {
            return (String(text.prefix(limit)), true)
        }
        let prefixCount = max(0, limit - marker.count)
        let prefix = String(text.prefix(prefixCount))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (prefix + marker, true)
    }
}
