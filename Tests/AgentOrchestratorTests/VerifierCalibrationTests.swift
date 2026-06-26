import AgentOrchestrator
import Testing

@Test
func candidateOrderRandomizationDoesNotChangeAggregateWinner() {
    let first = VerificationVote.aggregate([
        VerificationVoteRound(candidates: [
            VerificationCandidate(id: "invoice-copy", confidence: 0.91),
            VerificationCandidate(id: "calendar-cleanup", confidence: 0.42),
            VerificationCandidate(id: "crm-update", confidence: 0.38),
        ]),
        VerificationVoteRound(candidates: [
            VerificationCandidate(id: "calendar-cleanup", confidence: 0.45),
            VerificationCandidate(id: "invoice-copy", confidence: 0.87),
            VerificationCandidate(id: "crm-update", confidence: 0.50),
        ]),
        VerificationVoteRound(candidates: [
            VerificationCandidate(id: "invoice-copy", confidence: 0.74),
            VerificationCandidate(id: "crm-update", confidence: 0.68),
            VerificationCandidate(id: "calendar-cleanup", confidence: 0.66),
        ]),
    ])
    let randomized = VerificationVote.aggregate([
        VerificationVoteRound(candidates: [
            VerificationCandidate(id: "crm-update", confidence: 0.38),
            VerificationCandidate(id: "invoice-copy", confidence: 0.91),
            VerificationCandidate(id: "calendar-cleanup", confidence: 0.42),
        ]),
        VerificationVoteRound(candidates: [
            VerificationCandidate(id: "invoice-copy", confidence: 0.87),
            VerificationCandidate(id: "crm-update", confidence: 0.50),
            VerificationCandidate(id: "calendar-cleanup", confidence: 0.45),
        ]),
        VerificationVoteRound(candidates: [
            VerificationCandidate(id: "calendar-cleanup", confidence: 0.66),
            VerificationCandidate(id: "invoice-copy", confidence: 0.74),
            VerificationCandidate(id: "crm-update", confidence: 0.68),
        ]),
    ])

    #expect(first.winnerID == "invoice-copy")
    #expect(randomized.winnerID == first.winnerID)
    #expect(randomized.voteCounts == first.voteCounts)
    #expect(randomized.abstentionCount == 0)
}

@Test
func aggregateTiesAbstainByPolicy() {
    let result = VerificationVote.aggregate([
        VerificationVoteRound(candidates: [
            VerificationCandidate(id: "a", confidence: 0.8),
            VerificationCandidate(id: "b", confidence: 0.7),
        ]),
        VerificationVoteRound(candidates: [
            VerificationCandidate(id: "b", confidence: 0.9),
            VerificationCandidate(id: "a", confidence: 0.4),
        ]),
        VerificationVoteRound(candidates: [
            VerificationCandidate(id: "c", confidence: 0.6),
            VerificationCandidate(id: "d", confidence: 0.6),
        ]),
    ])

    #expect(result.winnerID == nil)
    #expect(result.didAbstain)
    #expect(result.voteCounts == ["a": 1, "b": 1])
    #expect(result.abstentionCount == 1)
    #expect(result.tiedCandidateIDs == ["a", "b"])
}

@Test
func bucketMathIsStableAtBoundaries() {
    let report = VerifierCalibration.report(samples: [
        VerifierCalibrationSample(confidence: 0.0, outcome: .acceptedCorrect),
        VerifierCalibrationSample(confidence: 0.2, outcome: .falseAccept),
        VerifierCalibrationSample(confidence: 0.4, outcome: .abstained),
        VerifierCalibrationSample(confidence: 0.6, outcome: .regrounded),
        VerifierCalibrationSample(confidence: 1.0, outcome: .acceptedCorrect),
    ], bucketCount: 5)

    #expect(report.buckets.map(\.sampleCount) == [1, 1, 1, 1, 1])
    #expect(report.buckets[0].lowerBound == 0.0)
    #expect(report.buckets[0].upperBound == 0.2)
    #expect(report.buckets[4].lowerBound == 0.8)
    #expect(report.buckets[4].upperBound == 1.0)
    #expect(VerifierCalibration.bucketIndex(for: 1.0, bucketCount: 5) == 4)
    #expect(VerifierCalibration.bucketIndex(for: 1.0, bucketCount: Int.max) == Int.max - 1)
    #expect(report.buckets[1].falseAcceptCount == 1)
    #expect(report.buckets[2].abstentionCount == 1)
    #expect(report.falseAcceptCount == 1)
    #expect(report.abstentionCount == 1)
}

@Test
func expectedCalibrationErrorUsesWeightedBucketGaps() {
    let report = VerifierCalibration.report(samples: [
        VerifierCalibrationSample(confidence: 0.1, outcome: .falseAccept),
        VerifierCalibrationSample(confidence: 0.3, outcome: .acceptedCorrect),
        VerifierCalibrationSample(confidence: 0.7, outcome: .acceptedCorrect),
        VerifierCalibrationSample(confidence: 0.9, outcome: .acceptedCorrect),
    ], bucketCount: 2)

    #expect(report.buckets[0].averageConfidence.isApproximately(0.2))
    #expect(report.buckets[0].accuracy.isApproximately(0.5))
    #expect(report.buckets[1].averageConfidence.isApproximately(0.8))
    #expect(report.buckets[1].accuracy.isApproximately(1.0))
    #expect(report.expectedCalibrationError.isApproximately(0.25))
    #expect(report.falseAcceptRate.isApproximately(0.25))
    #expect(report.abstentionRate == 0)
}

@Test
func highRiskThresholdsRouteToAcceptRegroundAndPauseBands() {
    let thresholds = VerifierHighRiskThresholds(acceptAtOrAbove: 0.9, regroundAtOrAbove: 0.7)

    #expect(VerifierHighRiskRouting.route(confidence: 0.9, thresholds: thresholds) == .accept)
    #expect(VerifierHighRiskRouting.route(confidence: 0.89, thresholds: thresholds) == .reground)
    #expect(VerifierHighRiskRouting.route(confidence: 0.7, thresholds: thresholds) == .reground)
    #expect(VerifierHighRiskRouting.route(confidence: 0.69, thresholds: thresholds) == .pause)
}

private extension Double {
    func isApproximately(_ other: Double, tolerance: Double = 0.000_001) -> Bool {
        abs(self - other) <= tolerance
    }
}
