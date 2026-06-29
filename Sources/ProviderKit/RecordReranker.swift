import Foundation

public struct RecordChunkCandidate: Identifiable, Equatable, Sendable {
    public var id: Int64 { contextID }

    public let contextID: Int64
    public let text: String
    public let title: String?
    public let appName: String
    public let capturedAt: Date
    public let baseRank: Int
    public let baseScore: Double

    public init(
        contextID: Int64,
        text: String,
        title: String?,
        appName: String,
        capturedAt: Date,
        baseRank: Int = 0,
        baseScore: Double = 0
    ) {
        self.contextID = contextID
        self.text = text
        self.title = title
        self.appName = appName
        self.capturedAt = capturedAt
        self.baseRank = baseRank
        self.baseScore = baseScore
    }
}

public struct RecordRerankResult: Equatable, Sendable {
    public let candidate: RecordChunkCandidate
    public let score: Double

    public init(candidate: RecordChunkCandidate, score: Double) {
        self.candidate = candidate
        self.score = score
    }
}

public protocol RecordReranker: Sendable {
    func rerank(query: String, candidates: [RecordChunkCandidate], limit: Int) -> [RecordRerankResult]
}

public struct HeuristicRecordReranker: RecordReranker {
    public init() {}

    public func rerank(query: String, candidates: [RecordChunkCandidate], limit: Int) -> [RecordRerankResult] {
        guard limit > 0 else { return [] }
        let queryTerms = Self.terms(in: query)
        let normalizedQuery = Self.normalized(query)
        return candidates.map { candidate in
            RecordRerankResult(candidate: candidate, score: score(query: query, candidate: candidate, queryTerms: queryTerms, normalizedQuery: normalizedQuery))
        }
        .sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.candidate.capturedAt != rhs.candidate.capturedAt { return lhs.candidate.capturedAt > rhs.candidate.capturedAt }
            if lhs.candidate.baseRank != rhs.candidate.baseRank { return lhs.candidate.baseRank < rhs.candidate.baseRank }
            return lhs.candidate.contextID > rhs.candidate.contextID
        }
        .prefix(limit)
        .map { $0 }
    }

    public func score(query: String, candidate: RecordChunkCandidate) -> Double {
        score(
            query: query,
            candidate: candidate,
            queryTerms: Self.terms(in: query),
            normalizedQuery: Self.normalized(query)
        )
    }

    private func score(
        query: String,
        candidate: RecordChunkCandidate,
        queryTerms: Set<String>,
        normalizedQuery: String
    ) -> Double {
        guard !queryTerms.isEmpty else { return candidate.baseScore }
        let title = candidate.title ?? ""
        let searchable = Self.normalized([candidate.text, title, candidate.appName].joined(separator: " "))
        let textTerms = Self.terms(in: candidate.text)
        let titleTerms = Self.terms(in: title)
        let appTerms = Self.terms(in: candidate.appName)

        var score = candidate.baseScore
        if !normalizedQuery.isEmpty, searchable.contains(normalizedQuery) { score += 3.0 }
        if !normalizedQuery.isEmpty, Self.normalized(title).contains(normalizedQuery) { score += 1.2 }

        let covered = queryTerms.filter { searchable.contains($0) }.count
        score += 4.0 * (Double(covered) / Double(queryTerms.count))
        score += Double(queryTerms.intersection(titleTerms).count) * 0.8
        score += Double(queryTerms.intersection(appTerms).count) * 0.6
        score += Double(queryTerms.intersection(textTerms).count) * 0.25
        return score
    }

    private static func normalized(_ value: String) -> String {
        value.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func terms(in value: String) -> Set<String> {
        Set(value.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 && !stopwords.contains($0) })
    }

    private static let stopwords: Set<String> = [
        "the", "and", "was", "were", "what", "when", "where", "which", "who", "why",
        "how", "did", "does", "doing", "done", "have", "has", "had", "you", "your",
        "about", "with", "from", "that", "this", "these", "those", "for", "are",
        "show", "tell", "give", "find", "get", "see", "look", "today", "yesterday",
        "earlier", "morning", "afternoon", "evening", "tonight", "day", "week",
        "time", "thing", "things", "summary", "summarize", "recap"
    ]
}
