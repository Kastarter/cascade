import Foundation

public enum AnchorDriftScorer {
    public enum AnchorSource: String, Sendable, Equatable {
        case accessibility
        case vision
        case recordedPoint
        case semantic
        case unknown
    }

    public enum Outcome: Sendable, Equatable {
        case stable
        case drifted
        case ambiguous
        case demote
        case retryNextCandidate
    }

    public enum Reason: Sendable, Hashable {
        case noCandidates
        case scoreDrop
        case sourceChanged
        case hashChanged
        case closeTopCandidates
        case verificationFailure
        case repeatedFailures
        case staleVerification
        case withinRetryMargin
    }

    public struct VerifiedAnchor: Sendable, Equatable {
        public let score: Double
        public let source: AnchorSource
        public let hash: String?
        public let verifiedAt: Date

        public init(score: Double, source: AnchorSource, hash: String?, verifiedAt: Date) {
            self.score = score
            self.source = source
            self.hash = hash
            self.verifiedAt = verifiedAt
        }
    }

    public struct Candidate: Sendable, Equatable {
        public let id: String
        public let score: Double
        public let source: AnchorSource
        public let hash: String?
        public let failureCount: Int

        public init(
            id: String,
            score: Double,
            source: AnchorSource,
            hash: String?,
            failureCount: Int = 0
        ) {
            self.id = id
            self.score = score
            self.source = source
            self.hash = hash
            self.failureCount = failureCount
        }
    }

    public struct Configuration: Sendable, Equatable {
        public let maximumStableScoreDrop: Double
        public let sourceChangeScoreDrop: Double
        public let ambiguousTopMargin: Double
        public let retryNextCandidateMargin: Double
        public let minimumRetryScore: Double
        public let demoteFailureCount: Int
        public let recentVerificationWindow: TimeInterval
        public let staleVerificationScoreSlack: Double

        public init(
            maximumStableScoreDrop: Double = 0.15,
            sourceChangeScoreDrop: Double = 0.06,
            ambiguousTopMargin: Double = 0.035,
            retryNextCandidateMargin: Double = 0.05,
            minimumRetryScore: Double = 0.60,
            demoteFailureCount: Int = 3,
            recentVerificationWindow: TimeInterval = 10 * 60,
            staleVerificationScoreSlack: Double = 0.08
        ) {
            self.maximumStableScoreDrop = maximumStableScoreDrop
            self.sourceChangeScoreDrop = sourceChangeScoreDrop
            self.ambiguousTopMargin = ambiguousTopMargin
            self.retryNextCandidateMargin = retryNextCandidateMargin
            self.minimumRetryScore = minimumRetryScore
            self.demoteFailureCount = demoteFailureCount
            self.recentVerificationWindow = recentVerificationWindow
            self.staleVerificationScoreSlack = staleVerificationScoreSlack
        }

        public static let `default` = Configuration()
    }

    public struct Result: Sendable, Equatable {
        public let outcome: Outcome
        public let selected: Candidate?
        public let alternate: Candidate?
        public let reasons: Set<Reason>

        public init(
            outcome: Outcome,
            selected: Candidate?,
            alternate: Candidate?,
            reasons: Set<Reason>
        ) {
            self.outcome = outcome
            self.selected = selected
            self.alternate = alternate
            self.reasons = reasons
        }
    }

    public static func evaluate(
        previous: VerifiedAnchor,
        rankedCandidates: [Candidate],
        now: Date = Date(),
        configuration: Configuration = .default
    ) -> Result {
        guard let best = rankedCandidates.first else {
            return Result(outcome: .drifted, selected: nil, alternate: nil, reasons: [.noCandidates])
        }

        let second = rankedCandidates.dropFirst().first
        let verificationAge = max(0, now.timeIntervalSince(previous.verifiedAt))
        let isRecent = verificationAge <= configuration.recentVerificationWindow
        let scoreDrop = previous.score - best.score
        let allowedScoreDrop = configuration.maximumStableScoreDrop
            + (isRecent ? 0 : configuration.staleVerificationScoreSlack)
        let topTwoMargin = second.map { best.score - $0.score }

        var reasons = Set<Reason>()
        if !isRecent {
            reasons.insert(.staleVerification)
        }
        if scoreDrop > allowedScoreDrop {
            reasons.insert(.scoreDrop)
        }
        if previous.source != best.source {
            reasons.insert(.sourceChanged)
        }
        if let previousHash = previous.hash, let currentHash = best.hash, previousHash != currentHash {
            reasons.insert(.hashChanged)
        }
        if best.failureCount > 0 {
            reasons.insert(.verificationFailure)
        }

        if best.failureCount >= configuration.demoteFailureCount {
            reasons.insert(.repeatedFailures)
            return Result(outcome: .demote, selected: best, alternate: second, reasons: reasons)
        }

        if best.failureCount > 0,
           let second,
           let topTwoMargin,
           topTwoMargin >= 0,
           topTwoMargin <= configuration.retryNextCandidateMargin,
           second.score >= configuration.minimumRetryScore {
            reasons.insert(.withinRetryMargin)
            return Result(outcome: .retryNextCandidate, selected: second, alternate: best, reasons: reasons)
        }

        if let second, let topTwoMargin, topTwoMargin >= 0, topTwoMargin <= configuration.ambiguousTopMargin {
            reasons.insert(.closeTopCandidates)
            return Result(outcome: .ambiguous, selected: best, alternate: second, reasons: reasons)
        }

        let identityChanged = reasons.contains(.sourceChanged) || reasons.contains(.hashChanged)
        let sourceSensitiveDrop = scoreDrop > configuration.sourceChangeScoreDrop
        let failedWithoutRetry = best.failureCount > 0
        if reasons.contains(.scoreDrop) || (isRecent && identityChanged && sourceSensitiveDrop) || failedWithoutRetry {
            return Result(outcome: .drifted, selected: best, alternate: second, reasons: reasons)
        }

        return Result(outcome: .stable, selected: best, alternate: second, reasons: reasons)
    }
}
