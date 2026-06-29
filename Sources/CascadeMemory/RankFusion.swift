import Foundation

/// Reciprocal Rank Fusion — merges several independently-ranked candidate lists
/// into one combined ranking. This is how the serious hybrid-retrieval systems
/// (Zep/Graphiti among them) combine a keyword (BM25) lane and a dense (vector)
/// lane: run BOTH in parallel, then fuse, instead of falling back lane-to-lane.
///
/// The fix it buys us over a fallback chain: a moment that the keyword lane
/// missed but the meaning lane ranked highly now surfaces even when keyword
/// search ALSO returned something — the old `if hits.isEmpty { … }` cascade only
/// consulted the semantic lane when keyword search came up empty, so a strong
/// semantic match was invisible whenever a weak keyword match existed.
public enum RankFusion {
    /// Canonical RRF constant (Cormack, Clarke & Büttcher, 2009). Large enough
    /// that no single lane's #1 hit dominates the fusion, small enough that rank
    /// position still carries weight.
    public static let defaultK = 60

    public enum Lane: String, Codable, Sendable {
        case lexical
        case vector
        case memory
        case rerank
    }

    public struct RankedLane: Equatable, Sendable {
        public let lane: Lane
        public let ids: [Int64]

        public init(_ lane: Lane, ids: [Int64]) {
            self.lane = lane
            self.ids = ids
        }
    }

    public struct LaneContribution: Equatable, Sendable {
        public let lane: Lane
        public let rank: Int
        public let score: Double

        public init(lane: Lane, rank: Int, score: Double) {
            self.lane = lane
            self.rank = rank
            self.score = score
        }
    }

    public struct FusedCandidate: Identifiable, Equatable, Sendable {
        public let id: Int64
        public let finalScore: Double
        public let lexicalRank: Int?
        public let vectorRank: Int?
        public let memoryRank: Int?
        public let rerankScore: Double?
        public let contributions: [LaneContribution]

        public init(
            id: Int64,
            finalScore: Double,
            lexicalRank: Int? = nil,
            vectorRank: Int? = nil,
            memoryRank: Int? = nil,
            rerankScore: Double? = nil,
            contributions: [LaneContribution] = []
        ) {
            self.id = id
            self.finalScore = finalScore
            self.lexicalRank = lexicalRank
            self.vectorRank = vectorRank
            self.memoryRank = memoryRank
            self.rerankScore = rerankScore
            self.contributions = contributions
        }
    }

    /// Fuse ranked ID lists into one ranking, best-first, capped at `limit`.
    ///
    /// Each lane is an ordered list of moment ids (rank 0 = best in that lane). A
    /// moment's fused score is `Σ 1 / (k + rank + 1)` over every lane it appears
    /// in — so appearing high in TWO lanes (keyword *and* meaning) beats appearing
    /// high in only one, which is exactly the signal we want. Pure and
    /// deterministic: ties break toward the newer moment (higher id), matching the
    /// product's recency preference and keeping the result stable for tests.
    public static func reciprocalRankFusion(
        _ lanes: [[Int64]],
        k: Int = defaultK,
        limit: Int
    ) -> [Int64] {
        let knownLanes: [Lane] = [.lexical, .vector, .memory]
        let ranked = lanes.enumerated().map { index, ids in
            RankedLane(index < knownLanes.count ? knownLanes[index] : .rerank, ids: ids)
        }
        return reciprocalRankFusion(ranked, k: k, limit: limit).map(\.id)
    }

    /// Fuse ranked ID lanes while preserving provenance for evaluation and debugging.
    ///
    /// `rank` is zero-based to match the existing bare-ID API's implementation. The
    /// RRF contribution for a lane is still `1 / (k + rank + 1)`.
    public static func reciprocalRankFusion(
        _ lanes: [RankedLane],
        k: Int = defaultK,
        limit: Int
    ) -> [FusedCandidate] {
        guard limit > 0 else { return [] }
        var contributionsByID: [Int64: [LaneContribution]] = [:]

        for lane in lanes {
            for (rank, id) in lane.ids.enumerated() {
                let contribution = LaneContribution(
                    lane: lane.lane,
                    rank: rank,
                    score: 1.0 / Double(k + rank + 1)
                )
                contributionsByID[id, default: []].append(contribution)
            }
        }

        return contributionsByID.map { id, contributions in
            let finalScore = contributions.reduce(0) { $0 + $1.score }
            return FusedCandidate(
                id: id,
                finalScore: finalScore,
                lexicalRank: contributions.first { $0.lane == .lexical }?.rank,
                vectorRank: contributions.first { $0.lane == .vector }?.rank,
                memoryRank: contributions.first { $0.lane == .memory }?.rank,
                rerankScore: contributions.first { $0.lane == .rerank }?.score,
                contributions: contributions.sorted { lhs, rhs in
                    lhs.lane.rawValue == rhs.lane.rawValue ? lhs.rank < rhs.rank : lhs.lane.rawValue < rhs.lane.rawValue
                }
            )
        }
        .sorted { lhs, rhs in
            lhs.finalScore == rhs.finalScore ? lhs.id > rhs.id : lhs.finalScore > rhs.finalScore
        }
        .prefix(limit)
        .map { $0 }
    }
}
