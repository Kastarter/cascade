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
        guard limit > 0 else { return [] }
        var scores: [Int64: Double] = [:]
        for lane in lanes {
            for (rank, id) in lane.enumerated() {
                scores[id, default: 0] += 1.0 / Double(k + rank + 1)
            }
        }
        return scores
            .sorted { lhs, rhs in
                lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value > rhs.value
            }
            .prefix(limit)
            .map(\.key)
    }
}
