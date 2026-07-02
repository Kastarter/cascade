import CascadeMemory
import Foundation
import NaturalLanguage

public enum TypedActionVerb: String, Codable, Equatable, Hashable, Sendable {
    case click
    case doubleClick
    case rightClick
    case type
    case copy
    case cut
    case paste
    case save
    case selectAll
    case submit
    case shortcut
    case key
    case scroll
}

public enum TypedActionSlotCategory: String, Codable, Equatable, Hashable, Sendable {
    case ticker
    case number
    case word
    case date
    case url
    case name
}

public struct TypedActionSlot: Codable, Equatable, Hashable, Sendable {
    public let category: TypedActionSlotCategory
    public let valueShape: String
    public let valueHash: String

    public init(category: TypedActionSlotCategory, valueShape: String, valueHash: String) {
        self.category = category
        self.valueShape = valueShape
        self.valueHash = valueHash
    }
}

public struct TypedAction: Codable, Equatable, Hashable, Sendable {
    public let verb: TypedActionVerb
    public let surface: String
    public let targetRole: String
    public let targetLabelClass: String
    public let dataSlot: TypedActionSlot?

    public init(
        verb: TypedActionVerb,
        surface: String,
        targetRole: String,
        targetLabelClass: String,
        dataSlot: TypedActionSlot? = nil
    ) {
        self.verb = verb
        self.surface = surface
        self.targetRole = targetRole
        self.targetLabelClass = targetLabelClass
        self.dataSlot = dataSlot
    }

    public var abstractToken: String {
        [
            "ta:v1",
            "verb=\(verb.rawValue)",
            "surface=\(surface)",
            "role=\(targetRole)",
            "label=\(targetLabelClass)",
            "slot=\(dataSlot?.category.rawValue ?? "none")"
        ].joined(separator: "|")
    }

    var semanticText: String {
        [
            verb.rawValue,
            surface,
            targetRole,
            targetLabelClass,
            dataSlot?.category.rawValue
        ].compactMap { $0 }.joined(separator: " ")
    }
}

public struct TypedActionEpisode: Equatable, Sendable {
    public let index: Int
    public let actions: [TypedAction]
    public let eventIDs: [Int64]
    public let startedAt: Date
    public let endedAt: Date

    public init(index: Int, actions: [TypedAction], eventIDs: [Int64], startedAt: Date, endedAt: Date) {
        self.index = index
        self.actions = actions
        self.eventIDs = eventIDs
        self.startedAt = startedAt
        self.endedAt = endedAt
    }

    public var abstractTokens: [String] {
        actions.map(\.abstractToken)
    }

    var semanticText: String {
        actions.map(\.semanticText).joined(separator: " ")
    }
}

public struct TypedActionEpisodeCluster: Equatable, Sendable {
    public let representativeIndex: Int
    public let episodeIndices: [Int]
    public let abstractTokens: [String]
}

public struct TypedActionAbstractor: Sendable {
    public init() {}

    public func abstract(_ event: InputEvent, surface: String? = nil) -> TypedAction {
        let resolvedSurface = Self.surfaceKey(surface ?? event.appName)
        let descriptor = AXTargetDescriptorV2.decode(event.targetDescriptor, fallbackLabel: event.text ?? "")
        let label = descriptor?.label.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayLabel = (label?.isEmpty == false ? label : event.text) ?? ""
        let slot = Self.slotObservation(in: event.text)
            ?? Self.slotObservation(in: label)
            ?? Self.slotObservation(in: descriptor?.windowTitle)
            ?? Self.slotObservation(in: event.windowTitle)

        return TypedAction(
            verb: Self.verb(for: event),
            surface: resolvedSurface,
            targetRole: Self.targetRole(for: event, descriptor: descriptor),
            targetLabelClass: Self.labelClass(for: displayLabel, slot: slot),
            dataSlot: slot
        )
    }

    public func abstract(_ events: [InputEvent], surface: (InputEvent) -> String) -> [TypedAction] {
        events.map { abstract($0, surface: surface($0)) }
    }

    public static func classifySlotValue(_ value: String) -> TypedActionSlotCategory {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .word }
        if isURL(trimmed) { return .url }
        if isDate(trimmed) { return .date }
        if isNumber(trimmed) { return .number }
        if isTicker(trimmed) { return .ticker }
        if isName(trimmed) { return .name }
        return .word
    }

    public static func slotObservation(in text: String?) -> TypedActionSlot? {
        guard let raw = text?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if isURL(raw), let token = firstMatch(in: raw, pattern: #"(?i)\b(?:https?://|www\.)\S+\b"#) {
            return slot(category: .url, value: token)
        }
        if let token = firstMatch(in: raw, pattern: #"(?i)\b(?:\d{4}-\d{1,2}-\d{1,2}|\d{1,2}/\d{1,2}/\d{2,4}|(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+\d{1,2}(?:,\s*\d{4})?)\b"#) {
            return slot(category: .date, value: token)
        }
        if let token = firstTicker(in: raw) {
            return slot(category: .ticker, value: token)
        }
        if let token = firstMatch(in: raw, pattern: #"(?i)(?:[$€£¥]\s*)?\b\d[\d,]*(?:\.\d+)?(?:\s*(?:usd|cad|eur|gbp|percent|%))?\b"#) {
            return slot(category: .number, value: token)
        }
        if isName(raw) {
            return slot(category: .name, value: raw)
        }
        if let token = firstMatch(in: raw, pattern: #"\b[\p{L}][\p{L}'-]{1,}\b"#) {
            return slot(category: .word, value: token)
        }
        return nil
    }
}

public struct TypedActionEpisodeClusterer: Sendable {
    public let threshold: Double

    public init(threshold: Double = 0.82) {
        self.threshold = threshold
    }

    public func cluster(_ episodes: [TypedActionEpisode]) -> [TypedActionEpisodeCluster] {
        let ordered = episodes.sorted(by: Self.episodeSort)
        let vectors = Dictionary(uniqueKeysWithValues: ordered.map { episode in
            (episode.index, LocalSemanticVector.vector(for: episode.semanticText))
        })
        var clusters: [[TypedActionEpisode]] = []

        for episode in ordered {
            if let index = clusters.firstIndex(where: { cluster in
                cluster.contains { member in
                    similarity(episode, member, vectors: vectors) >= threshold
                }
            }) {
                clusters[index].append(episode)
                clusters[index].sort(by: Self.episodeSort)
            } else {
                clusters.append([episode])
            }
        }

        return clusters
            .map { cluster in
                let representative = medoid(in: cluster, vectors: vectors)
                return TypedActionEpisodeCluster(
                    representativeIndex: representative.index,
                    episodeIndices: cluster.map(\.index).sorted(),
                    abstractTokens: representative.abstractTokens
                )
            }
            .sorted {
                let lhsFirst = $0.episodeIndices.first ?? Int.max
                let rhsFirst = $1.episodeIndices.first ?? Int.max
                if lhsFirst != rhsFirst { return lhsFirst < rhsFirst }
                return $0.abstractTokens.lexicographicallyPrecedes($1.abstractTokens)
            }
    }

    private func medoid(
        in cluster: [TypedActionEpisode],
        vectors: [Int: [Float]?]
    ) -> TypedActionEpisode {
        cluster.max { lhs, rhs in
            let lhsScore = cluster.reduce(0.0) { $0 + similarity(lhs, $1, vectors: vectors) }
            let rhsScore = cluster.reduce(0.0) { $0 + similarity(rhs, $1, vectors: vectors) }
            if lhsScore != rhsScore { return lhsScore < rhsScore }
            if lhs.actions.count != rhs.actions.count { return lhs.actions.count < rhs.actions.count }
            if lhs.startedAt != rhs.startedAt { return lhs.startedAt > rhs.startedAt }
            return lhs.abstractTokens.lexicographicallyPrecedes(rhs.abstractTokens)
        } ?? cluster[0]
    }

    private func similarity(
        _ lhs: TypedActionEpisode,
        _ rhs: TypedActionEpisode,
        vectors: [Int: [Float]?]
    ) -> Double {
        let structural = Self.sequenceSimilarity(lhs.abstractTokens, rhs.abstractTokens)
        if let lhsVector = vectors[lhs.index] ?? nil,
           let rhsVector = vectors[rhs.index] ?? nil,
           lhsVector.count == rhsVector.count {
            let semantic = Double(LocalSemanticVector.cosine(lhsVector, rhsVector))
            return max(structural, semantic)
        }
        return structural
    }

    private static func episodeSort(_ lhs: TypedActionEpisode, _ rhs: TypedActionEpisode) -> Bool {
        if lhs.startedAt != rhs.startedAt { return lhs.startedAt < rhs.startedAt }
        if lhs.eventIDs != rhs.eventIDs { return lhs.eventIDs.lexicographicallyPrecedes(rhs.eventIDs) }
        if lhs.index != rhs.index { return lhs.index < rhs.index }
        return lhs.abstractTokens.lexicographicallyPrecedes(rhs.abstractTokens)
    }

    private static func sequenceSimilarity(_ lhs: [String], _ rhs: [String]) -> Double {
        max(levenshteinSimilarity(lhs, rhs), jaccard(lhs, rhs))
    }

    private static func levenshteinSimilarity(_ lhs: [String], _ rhs: [String]) -> Double {
        if lhs.isEmpty && rhs.isEmpty { return 1 }
        let longest = max(lhs.count, rhs.count)
        guard longest > 0 else { return 1 }
        var previous = Array(0...rhs.count)
        var current = [Int](repeating: 0, count: rhs.count + 1)
        for i in 1...lhs.count {
            current[0] = i
            for j in 1...rhs.count {
                let cost = lhs[i - 1] == rhs[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return 1.0 - Double(previous[rhs.count]) / Double(longest)
    }

    private static func jaccard(_ lhs: [String], _ rhs: [String]) -> Double {
        let left = Set(lhs)
        let right = Set(rhs)
        let union = left.union(right)
        guard !union.isEmpty else { return 1 }
        return Double(left.intersection(right).count) / Double(union.count)
    }
}

private extension TypedActionAbstractor {
    static func verb(for event: InputEvent) -> TypedActionVerb {
        switch event.kind {
        case .click: return .click
        case .doubleClick: return .doubleClick
        case .rightClick: return .rightClick
        case .type: return .type
        case .scroll: return .scroll
        case .key:
            let key = event.key?.lowercased() ?? ""
            let modifiers = Set(event.modifiers.map { $0.lowercased() })
            let commandLike = modifiers.contains("command") || modifiers.contains("control")
            guard commandLike else { return .key }
            switch key {
            case "c": return .copy
            case "x": return .cut
            case "v": return .paste
            case "s": return .save
            case "a": return .selectAll
            case "return", "enter": return .submit
            default: return .shortcut
            }
        }
    }

    static func targetRole(for event: InputEvent, descriptor: AXTargetDescriptorV2?) -> String {
        if let role = descriptor?.role {
            let normalized = component(role)
            if normalized.contains("button") { return "button" }
            if normalized.contains("text") || normalized.contains("field") || normalized.contains("input") { return "field" }
            if normalized.contains("link") { return "link" }
            if normalized.contains("cell") || normalized.contains("row") { return "cell" }
            if normalized.contains("menu") { return "menu" }
            if !normalized.isEmpty { return "control" }
        }
        switch event.kind {
        case .type: return "field"
        case .key: return "keyboard"
        case .scroll: return "viewport"
        case .click, .doubleClick, .rightClick:
            return event.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? "control" : "point"
        }
    }

    static func labelClass(for label: String, slot: TypedActionSlot?) -> String {
        if let slot { return "data-\(slot.category.rawValue)" }
        let normalized = component(label)
        guard !normalized.isEmpty else { return "none" }
        if normalized.contains("search") || normalized.contains("find") { return "search-field" }
        if normalized.contains("save") || normalized.contains("send") || normalized.contains("submit") || normalized.contains("done") {
            return "command"
        }
        if normalized.contains("row") || normalized.contains("cell") || normalized.contains("column") {
            return "grid"
        }
        return classifySlotValue(label).rawValue
    }

    static func surfaceKey(_ value: String) -> String {
        let normalized = component(value)
        return normalized.isEmpty ? "unknown" : String(normalized.prefix(40))
    }

    static func slot(category: TypedActionSlotCategory, value: String) -> TypedActionSlot {
        TypedActionSlot(
            category: category,
            valueShape: valueShape(value, category: category),
            valueHash: AuditIdentity.hash(normalizedValue(value))
        )
    }

    static func firstTicker(in raw: String) -> String? {
        let tokens = raw.matches(of: /\$?[A-Z]{2,6}\b/).map { String($0.output).trimmingCharacters(in: CharacterSet(charactersIn: "$")) }
        return tokens.first(where: isTicker)
    }

    static func isTicker(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "$ "))
        guard matches(trimmed, #"^[A-Z]{2,6}$"#) else { return false }
        let commonWords: Set<String> = ["THE", "AND", "FOR", "WITH", "FROM", "PRICE", "USD", "CAD", "EUR", "GBP"]
        return !commonWords.contains(trimmed)
    }

    static func isNumber(_ value: String) -> Bool {
        matches(value, #"(?i)^\s*(?:[$€£¥]\s*)?\d[\d,]*(?:\.\d+)?(?:\s*(?:usd|cad|eur|gbp|percent|%))?\s*$"#)
    }

    static func isDate(_ value: String) -> Bool {
        matches(value, #"(?i)^\s*(?:\d{4}-\d{1,2}-\d{1,2}|\d{1,2}/\d{1,2}/\d{2,4}|(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+\d{1,2}(?:,\s*\d{4})?)\s*$"#)
    }

    static func isURL(_ value: String) -> Bool {
        matches(value, #"(?i)^\s*(?:https?://|www\.)\S+\s*$"#)
    }

    static func isName(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if matches(trimmed, #"^[A-Z][a-z]+(?:\s+[A-Z][a-z]+){1,3}$"#) {
            return true
        }
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = trimmed
        var foundName = false
        tagger.enumerateTags(
            in: trimmed.startIndex..<trimmed.endIndex,
            unit: .word,
            scheme: .nameType,
            options: [.joinNames, .omitWhitespace, .omitPunctuation]
        ) { tag, range in
            if tag == .personalName, trimmed[range].count >= 3 {
                foundName = true
                return false
            }
            return true
        }
        return foundName
    }

    static func firstMatch(in value: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, range: range),
              let swiftRange = Range(match.range, in: value) else { return nil }
        return String(value[swiftRange])
    }

    static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }

    static func component(_ value: String?) -> String {
        guard let value else { return "" }
        let folded = value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        return folded
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }

    static func normalizedValue(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func valueShape(_ value: String, category: TypedActionSlotCategory) -> String {
        let mapped = value.trimmingCharacters(in: .whitespacesAndNewlines).map { character -> Character in
            if character.isNumber { return "0" }
            if character.isLetter { return "A" }
            if character.isWhitespace { return " " }
            return character
        }
        return "\(category.rawValue):\(String(mapped).prefix(48))"
    }
}
