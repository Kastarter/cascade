import Foundation
import Testing

@testable import ComputerUseKit

struct AnchorDriftScorerTests {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000)

    @Test func movedControlWithStrongScoreStaysStable() {
        let result = AnchorDriftScorer.evaluate(
            previous: previous(score: 0.94),
            rankedCandidates: [
                candidate("save-moved", score: 0.91),
                candidate("save-toolbar", score: 0.72),
            ],
            now: now)

        #expect(result.outcome == .stable)
        #expect(result.selected?.id == "save-moved")
    }

    @Test func scoreDropOverThresholdFlagsDrift() {
        let result = AnchorDriftScorer.evaluate(
            previous: previous(score: 0.94),
            rankedCandidates: [candidate("save", score: 0.76)],
            now: now)

        #expect(result.outcome == .drifted)
        #expect(result.reasons.contains(.scoreDrop))
    }

    @Test func closeTopCandidatesBecomeAmbiguous() {
        let result = AnchorDriftScorer.evaluate(
            previous: previous(score: 0.94),
            rankedCandidates: [
                candidate("save-footer", score: 0.91),
                candidate("save-toolbar", score: 0.89),
            ],
            now: now)

        #expect(result.outcome == .ambiguous)
        #expect(result.selected?.id == "save-footer")
        #expect(result.alternate?.id == "save-toolbar")
        #expect(result.reasons.contains(.closeTopCandidates))
    }

    @Test func documentedAmbiguityMarginFlagsCloseTopCandidates() {
        let result = AnchorDriftScorer.evaluate(
            previous: previous(score: 0.94),
            rankedCandidates: [
                candidate("continue-billing", score: 0.91),
                candidate("continue-help", score: 0.865),
            ],
            now: now)

        #expect(result.outcome == .ambiguous)
        #expect(result.reasons.contains(.closeTopCandidates))
    }

    @Test func repeatedFailedAnchorsDemote() {
        let result = AnchorDriftScorer.evaluate(
            previous: previous(score: 0.94),
            rankedCandidates: [candidate("save", score: 0.93, failureCount: 3)],
            now: now)

        #expect(result.outcome == .demote)
        #expect(result.reasons.contains(.repeatedFailures))
    }

    @Test func failedAnchorRetriesNextCandidateOnlyInsideConfiguredMargin() {
        let config = AnchorDriftScorer.Configuration(retryNextCandidateMargin: 0.04)
        let inside = AnchorDriftScorer.evaluate(
            previous: previous(score: 0.94),
            rankedCandidates: [
                candidate("save-failed", score: 0.91, failureCount: 1),
                candidate("save-next", score: 0.88),
            ],
            now: now,
            configuration: config)

        #expect(inside.outcome == .retryNextCandidate)
        #expect(inside.selected?.id == "save-next")
        #expect(inside.reasons.contains(.withinRetryMargin))

        let outside = AnchorDriftScorer.evaluate(
            previous: previous(score: 0.94),
            rankedCandidates: [
                candidate("save-failed", score: 0.91, failureCount: 1),
                candidate("save-far", score: 0.82),
            ],
            now: now,
            configuration: config)

        #expect(outside.outcome == .drifted)
        #expect(outside.selected?.id == "save-failed")
        #expect(!outside.reasons.contains(.withinRetryMargin))
    }

    @Test func recentSourceAndHashChangeWithSmallDropFlagsDrift() {
        let result = AnchorDriftScorer.evaluate(
            previous: previous(score: 0.94, source: .accessibility, hash: "ax-save"),
            rankedCandidates: [candidate("save", score: 0.86, source: .vision, hash: "vision-save")],
            now: now)

        #expect(result.outcome == .drifted)
        #expect(result.reasons.contains(.sourceChanged))
        #expect(result.reasons.contains(.hashChanged))
    }

    @Test func sourceChangeWithoutScoreDropStillFlagsDrift() {
        let result = AnchorDriftScorer.evaluate(
            previous: previous(score: 0.94, source: .accessibility, hash: "save-v1"),
            rankedCandidates: [candidate("save", score: 0.94, source: .vision, hash: "save-v1")],
            now: now)

        #expect(result.outcome == .drifted)
        #expect(result.reasons.contains(.sourceChanged))
        #expect(!result.reasons.contains(.scoreDrop))
    }

    @Test func staleVerificationAllowsMoreScoreSlack() {
        let stalePrevious = previous(
            score: 0.94,
            verifiedAt: now.addingTimeInterval(-1_800))
        let result = AnchorDriftScorer.evaluate(
            previous: stalePrevious,
            rankedCandidates: [candidate("save", score: 0.73)],
            now: now)

        #expect(result.outcome == .stable)
        #expect(result.reasons.contains(.staleVerification))
    }

    private func previous(
        score: Double = 0.94,
        source: AnchorDriftScorer.AnchorSource = .accessibility,
        hash: String? = "save-v1",
        verifiedAt: Date? = nil
    ) -> AnchorDriftScorer.VerifiedAnchor {
        AnchorDriftScorer.VerifiedAnchor(
            score: score,
            source: source,
            hash: hash,
            verifiedAt: verifiedAt ?? now.addingTimeInterval(-30))
    }

    private func candidate(
        _ id: String,
        score: Double,
        source: AnchorDriftScorer.AnchorSource = .accessibility,
        hash: String? = "save-v1",
        failureCount: Int = 0
    ) -> AnchorDriftScorer.Candidate {
        AnchorDriftScorer.Candidate(
            id: id,
            score: score,
            source: source,
            hash: hash,
            failureCount: failureCount)
    }
}
