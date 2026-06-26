public struct VerificationCandidate: Sendable, Equatable {
    public let id: String
    public let confidence: Double

    public init(id: String, confidence: Double) {
        self.id = id
        self.confidence = VerifierCalibration.clampConfidence(confidence)
    }
}

public struct VerificationVoteRound: Sendable, Equatable {
    public let candidates: [VerificationCandidate]

    public init(candidates: [VerificationCandidate]) {
        self.candidates = candidates
    }
}

public enum VerificationTiePolicy: Sendable, Equatable {
    case abstain
}

public struct VerificationVoteResult: Sendable, Equatable {
    public let winnerID: String?
    public let voteCounts: [String: Int]
    public let abstentionCount: Int
    public let tiedCandidateIDs: [String]
    public let totalRounds: Int

    public init(
        winnerID: String?,
        voteCounts: [String: Int],
        abstentionCount: Int,
        tiedCandidateIDs: [String],
        totalRounds: Int
    ) {
        self.winnerID = winnerID
        self.voteCounts = voteCounts
        self.abstentionCount = abstentionCount
        self.tiedCandidateIDs = tiedCandidateIDs
        self.totalRounds = totalRounds
    }

    public var didAbstain: Bool { winnerID == nil }
}

public enum VerificationVote: Sendable {
    public static func aggregate(
        _ rounds: [VerificationVoteRound],
        tiePolicy: VerificationTiePolicy = .abstain
    ) -> VerificationVoteResult {
        var voteCounts: [String: Int] = [:]
        var abstentions = 0

        for round in rounds {
            guard let roundWinner = winner(in: round.candidates, tiePolicy: tiePolicy) else {
                abstentions += 1
                continue
            }
            voteCounts[roundWinner, default: 0] += 1
        }

        let aggregateWinner = aggregateWinner(in: voteCounts, tiePolicy: tiePolicy)
        return VerificationVoteResult(
            winnerID: aggregateWinner.winnerID,
            voteCounts: voteCounts,
            abstentionCount: abstentions,
            tiedCandidateIDs: aggregateWinner.tiedCandidateIDs,
            totalRounds: rounds.count
        )
    }

    private static func winner(
        in candidates: [VerificationCandidate],
        tiePolicy: VerificationTiePolicy
    ) -> String? {
        var bestConfidenceByID: [String: Double] = [:]
        for candidate in candidates where !candidate.id.isEmpty {
            bestConfidenceByID[candidate.id] = max(
                bestConfidenceByID[candidate.id] ?? 0,
                candidate.confidence
            )
        }

        guard let topConfidence = bestConfidenceByID.values.max() else { return nil }
        let topIDs = bestConfidenceByID
            .filter { $0.value == topConfidence }
            .map(\.key)
            .sorted()
        guard topIDs.count == 1 else {
            switch tiePolicy {
            case .abstain:
                return nil
            }
        }
        return topIDs[0]
    }

    private static func aggregateWinner(
        in voteCounts: [String: Int],
        tiePolicy: VerificationTiePolicy
    ) -> (winnerID: String?, tiedCandidateIDs: [String]) {
        guard let topCount = voteCounts.values.max(), topCount > 0 else {
            return (nil, [])
        }
        let topIDs = voteCounts
            .filter { $0.value == topCount }
            .map(\.key)
            .sorted()
        guard topIDs.count == 1 else {
            switch tiePolicy {
            case .abstain:
                return (nil, topIDs)
            }
        }
        return (topIDs[0], [])
    }
}

public enum VerifierCalibrationOutcome: String, Sendable, Equatable, Hashable, Codable {
    case acceptedCorrect
    case falseAccept
    case regrounded
    case paused
    case abstained

    public var isCorrectAccept: Bool {
        self == .acceptedCorrect
    }

    public var isFalseAccept: Bool {
        self == .falseAccept
    }

    public var isAbstention: Bool {
        self == .abstained
    }
}

public struct VerifierCalibrationSample: Sendable, Equatable {
    public let confidence: Double
    public let outcome: VerifierCalibrationOutcome

    public init(confidence: Double, outcome: VerifierCalibrationOutcome) {
        self.confidence = VerifierCalibration.clampConfidence(confidence)
        self.outcome = outcome
    }
}

public struct VerifierCalibrationBucket: Sendable, Equatable {
    public let index: Int
    public let lowerBound: Double
    public let upperBound: Double
    public let sampleCount: Int
    public let averageConfidence: Double
    public let accuracy: Double
    public let outcomeCounts: [VerifierCalibrationOutcome: Int]
    public let falseAcceptCount: Int
    public let abstentionCount: Int
    public let expectedCalibrationErrorContribution: Double

    public init(
        index: Int,
        lowerBound: Double,
        upperBound: Double,
        sampleCount: Int,
        averageConfidence: Double,
        accuracy: Double,
        outcomeCounts: [VerifierCalibrationOutcome: Int],
        falseAcceptCount: Int,
        abstentionCount: Int,
        expectedCalibrationErrorContribution: Double
    ) {
        self.index = index
        self.lowerBound = lowerBound
        self.upperBound = upperBound
        self.sampleCount = sampleCount
        self.averageConfidence = averageConfidence
        self.accuracy = accuracy
        self.outcomeCounts = outcomeCounts
        self.falseAcceptCount = falseAcceptCount
        self.abstentionCount = abstentionCount
        self.expectedCalibrationErrorContribution = expectedCalibrationErrorContribution
    }
}

public struct VerifierCalibrationReport: Sendable, Equatable {
    public let buckets: [VerifierCalibrationBucket]
    public let sampleCount: Int
    public let falseAcceptCount: Int
    public let abstentionCount: Int
    public let expectedCalibrationError: Double

    public init(
        buckets: [VerifierCalibrationBucket],
        sampleCount: Int,
        falseAcceptCount: Int,
        abstentionCount: Int,
        expectedCalibrationError: Double
    ) {
        self.buckets = buckets
        self.sampleCount = sampleCount
        self.falseAcceptCount = falseAcceptCount
        self.abstentionCount = abstentionCount
        self.expectedCalibrationError = expectedCalibrationError
    }

    public var falseAcceptRate: Double {
        guard sampleCount > 0 else { return 0 }
        return Double(falseAcceptCount) / Double(sampleCount)
    }

    public var abstentionRate: Double {
        guard sampleCount > 0 else { return 0 }
        return Double(abstentionCount) / Double(sampleCount)
    }
}

public enum VerifierCalibration: Sendable {
    public static func report(
        samples: [VerifierCalibrationSample],
        bucketCount: Int = 10
    ) -> VerifierCalibrationReport {
        let bucketCount = max(1, bucketCount)
        var samplesByBucket = Array(repeating: [VerifierCalibrationSample](), count: bucketCount)

        for sample in samples {
            samplesByBucket[bucketIndex(for: sample.confidence, bucketCount: bucketCount)].append(sample)
        }

        let total = samples.count
        let buckets = samplesByBucket.enumerated().map { index, bucketSamples in
            makeBucket(index: index, bucketCount: bucketCount, samples: bucketSamples, totalSamples: total)
        }
        return VerifierCalibrationReport(
            buckets: buckets,
            sampleCount: total,
            falseAcceptCount: samples.filter { $0.outcome.isFalseAccept }.count,
            abstentionCount: samples.filter { $0.outcome.isAbstention }.count,
            expectedCalibrationError: buckets.reduce(0) { $0 + $1.expectedCalibrationErrorContribution }
        )
    }

    public static func bucketIndex(for confidence: Double, bucketCount: Int) -> Int {
        let bucketCount = max(1, bucketCount)
        let clamped = clampConfidence(confidence)
        guard clamped < 1 else {
            return bucketCount - 1
        }
        return min(Int(clamped * Double(bucketCount)), bucketCount - 1)
    }

    public static func clampConfidence(_ confidence: Double) -> Double {
        min(1, max(0, confidence))
    }

    private static func makeBucket(
        index: Int,
        bucketCount: Int,
        samples: [VerifierCalibrationSample],
        totalSamples: Int
    ) -> VerifierCalibrationBucket {
        let lowerBound = Double(index) / Double(bucketCount)
        let upperBound = Double(index + 1) / Double(bucketCount)
        let count = samples.count
        var outcomeCounts: [VerifierCalibrationOutcome: Int] = [:]
        for sample in samples {
            outcomeCounts[sample.outcome, default: 0] += 1
        }

        let averageConfidence = count == 0 ? 0 : samples.reduce(0) { $0 + $1.confidence } / Double(count)
        let correctAccepts = outcomeCounts[.acceptedCorrect, default: 0]
        let accuracy = count == 0 ? 0 : Double(correctAccepts) / Double(count)
        let contribution = totalSamples == 0
            ? 0
            : (Double(count) / Double(totalSamples)) * abs(averageConfidence - accuracy)

        return VerifierCalibrationBucket(
            index: index,
            lowerBound: lowerBound,
            upperBound: upperBound,
            sampleCount: count,
            averageConfidence: averageConfidence,
            accuracy: accuracy,
            outcomeCounts: outcomeCounts,
            falseAcceptCount: outcomeCounts[.falseAccept, default: 0],
            abstentionCount: outcomeCounts[.abstained, default: 0],
            expectedCalibrationErrorContribution: contribution
        )
    }
}

public enum VerifierHighRiskRoute: String, Sendable, Equatable {
    case accept
    case reground
    case pause
}

public struct VerifierHighRiskThresholds: Sendable, Equatable {
    public let acceptAtOrAbove: Double
    public let regroundAtOrAbove: Double

    public init(acceptAtOrAbove: Double = 0.9, regroundAtOrAbove: Double = 0.7) {
        let accept = VerifierCalibration.clampConfidence(acceptAtOrAbove)
        let reground = VerifierCalibration.clampConfidence(regroundAtOrAbove)
        self.acceptAtOrAbove = max(accept, reground)
        self.regroundAtOrAbove = min(accept, reground)
    }
}

public enum VerifierHighRiskRouting: Sendable {
    public static func route(
        confidence: Double,
        thresholds: VerifierHighRiskThresholds = VerifierHighRiskThresholds()
    ) -> VerifierHighRiskRoute {
        let confidence = VerifierCalibration.clampConfidence(confidence)
        if confidence >= thresholds.acceptAtOrAbove {
            return .accept
        }
        if confidence >= thresholds.regroundAtOrAbove {
            return .reground
        }
        return .pause
    }
}
