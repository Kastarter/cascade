import CascadeMemory
import Testing

/// Pure unit tests for Reciprocal Rank Fusion — the math that lets `hybridContexts`
/// merge the keyword and semantic lanes instead of falling back lane-to-lane.

@Test
func rrfRanksMomentsInBothLanesAboveThoseInOnlyOne() {
    // id 1 and id 3 each appear in BOTH lanes; id 2 and id 4 in only one.
    let lanes: [[Int64]] = [[1, 2, 3], [3, 4, 1]]
    let fused = RankFusion.reciprocalRankFusion(lanes, limit: 10)
    // The two-lane moments come first; ties (1 vs 3, 2 vs 4) break toward the
    // higher id (newer moment). 1 = 1/61+1/63, 3 = 1/63+1/61 → tie → 3 before 1.
    #expect(fused == [3, 1, 4, 2])
}

@Test
func rrfTwoLaneAgreementBeatsSingleLaneTopHit() {
    // id 10 is #1 in lane A and #2 in lane B; id 20 is only #1 in lane B.
    // Appearing in both lanes must beat being the top of just one.
    let fused = RankFusion.reciprocalRankFusion([[10], [20, 10]], limit: 10)
    #expect(fused == [10, 20])
}

@Test
func rrfWithOneEmptyLaneDegradesToTheOtherLanesOrder() {
    // This is the "only keyword matched" / "only meaning matched" case: fusion
    // must not crash or reorder — it just yields the non-empty lane's ranking.
    #expect(RankFusion.reciprocalRankFusion([[5, 6, 7], []], limit: 10) == [5, 6, 7])
    #expect(RankFusion.reciprocalRankFusion([[], [8, 9]], limit: 10) == [8, 9])
}

@Test
func rrfHonorsLimitAndEmptyInputs() {
    #expect(RankFusion.reciprocalRankFusion([[1, 2, 3, 4, 5]], limit: 2) == [1, 2])
    #expect(RankFusion.reciprocalRankFusion([[1, 2, 3]], limit: 0) == [])
    #expect(RankFusion.reciprocalRankFusion([[], []], limit: 10) == [])
    #expect(RankFusion.reciprocalRankFusion([[Int64]](), limit: 10) == [])
}

@Test
func rrfDedupesAcrossLanesIntoOneEntry() {
    // A moment in both lanes must appear exactly once in the fused result.
    let fused = RankFusion.reciprocalRankFusion([[1, 2], [2, 1]], limit: 10)
    #expect(fused.count == 2)
    #expect(Set(fused) == [1, 2])
}

@Test
func rrfCandidateProvenancePreservesOrderingAndLaneRanks() {
    let fused = RankFusion.reciprocalRankFusion([
        .init(.lexical, ids: [1, 2, 3]),
        .init(.vector, ids: [3, 4, 1]),
    ], limit: 10)

    #expect(fused.map(\.id) == RankFusion.reciprocalRankFusion([[1, 2, 3], [3, 4, 1]], limit: 10))
    let top = fused[0]
    #expect(top.id == 3)
    #expect(top.lexicalRank == 2)
    #expect(top.vectorRank == 0)
    #expect(top.memoryRank == nil)
    let expected = (1.0 / 63.0) + (1.0 / 61.0)
    #expect(abs(top.finalScore - expected) < 0.000_000_001)
    #expect(top.contributions.contains { $0.lane == .lexical && $0.rank == 2 })
    #expect(top.contributions.contains { $0.lane == .vector && $0.rank == 0 })
}
