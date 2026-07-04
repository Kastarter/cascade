import CoreGraphics
import Foundation
import ProviderKit

/// Offline d21-style ablation over recorded grounding candidates: AX-only vs vision-only vs
/// hybrid arms, scored by landing hit-test against each case's `expectedBoxOrPoint` (never
/// click counts). This is the SS6 offline pre-gate for any future grounding change.
///
/// Fully offline and pure: no network, no image decode. Candidates are RECORDED points --
/// the report validates the scoring/policy machinery, not the live AX-first quantitative
/// claim (the d14 live trio + real exported cases remain the evidence for any default flip).
public enum GroundingAblationArm: String, Codable, CaseIterable, Equatable, Sendable {
    case axOnly = "ax_only"
    case visionOnly = "vision_only"
    case hybrid

    /// Vision sources the vision-only arm may use. AX is the free+exact structural lane
    /// (LAW 2); vision is the audited exception.
    static let visionSources: Set<GroundingSource> = [.uiTars, .claude, .visualModel, .ocr]

    public func allows(_ source: GroundingSource) -> Bool {
        switch self {
        case .axOnly:
            return source == .accessibility
        case .visionOnly:
            return Self.visionSources.contains(source)
        case .hybrid:
            return source == .accessibility || Self.visionSources.contains(source)
        }
    }
}

/// One recorded grounding candidate attached to a benchmark case.
///
/// COORDINATE SPACE: `x`/`y` MUST be in the SAME space as the case's `expectedBoxOrPoint`
/// (fixture image pixels for fixtures; display-local points for exported cases) so
/// `GroundingBenchmarkExpected.contains(_:)` is a direct landing hit-test. A writer that
/// records candidates in the wrong space silently scores garbage -- same failure class as
/// the smartResize offset bug (34c2efa).
public struct GroundingAblationCandidate: Codable, Equatable, Sendable {
    public let source: GroundingSource
    public let x: Double
    public let y: Double
    public let confidence: Double

    public init(source: GroundingSource, x: Double, y: Double, confidence: Double) {
        self.source = source
        self.x = x
        self.y = y
        self.confidence = confidence
    }

    private enum CodingKeys: String, CodingKey {
        case source
        case x
        case y
        case confidence
    }

    public var point: CGPoint { CGPoint(x: x, y: y) }
}

public enum GroundingAblationObservationStatus: String, Codable, Equatable, Sendable {
    case hit
    case miss
    case abstain
    case skippedUnlabeled = "skipped_unlabeled"
    case skippedMissingTarget = "skipped_missing_target"
    case skippedNoCandidates = "skipped_no_candidates"
}

public struct GroundingAblationObservation: Codable, Equatable, Sendable {
    public let caseID: String
    public let arm: GroundingAblationArm
    public let status: GroundingAblationObservationStatus
    public let predictedX: Double?
    public let predictedY: Double?

    public init(
        caseID: String,
        arm: GroundingAblationArm,
        status: GroundingAblationObservationStatus,
        predictedX: Double? = nil,
        predictedY: Double? = nil
    ) {
        self.caseID = caseID
        self.arm = arm
        self.status = status
        self.predictedX = predictedX
        self.predictedY = predictedY
    }

    private enum CodingKeys: String, CodingKey {
        case caseID = "case_id"
        case arm
        case status
        case predictedX = "predicted_x"
        case predictedY = "predicted_y"
    }
}

/// Per-arm summary. `failureRate = (misses + abstains) / scored`: an arm with no usable
/// candidate ABSTAINS -- the abstain counts as a failure for the rate but is reported
/// separately (LAW 7: degrade to MISSED, never FALSE; the number stays honest).
public struct GroundingAblationArmSummary: Codable, Equatable, Sendable {
    public let arm: GroundingAblationArm
    public let scored: Int
    public let hits: Int
    public let misses: Int
    public let abstains: Int
    public let accuracy: Double
    public let failureRate: Double

    public init(arm: GroundingAblationArm, scored: Int, hits: Int, misses: Int, abstains: Int) {
        self.arm = arm
        self.scored = scored
        self.hits = hits
        self.misses = misses
        self.abstains = abstains
        self.accuracy = scored == 0 ? 0 : Double(hits) / Double(scored)
        self.failureRate = scored == 0 ? 0 : Double(misses + abstains) / Double(scored)
    }

    private enum CodingKeys: String, CodingKey {
        case arm
        case scored
        case hits
        case misses
        case abstains
        case accuracy
        case failureRate = "failure_rate"
    }
}

public struct GroundingAblationReport: Codable, Equatable, Sendable {
    public let totalCases: Int
    public let scoredCases: Int
    public let skippedUnlabeled: Int
    public let skippedMissingTarget: Int
    public let skippedNoCandidates: Int
    public let arms: [GroundingAblationArmSummary]
    /// THE SS6 gate summary field.
    public let hybridFailureRate: Double
    public let axOnlyFailureRate: Double
    public let visionOnlyFailureRate: Double
    public let observations: [GroundingAblationObservation]

    private enum CodingKeys: String, CodingKey {
        case totalCases = "total_cases"
        case scoredCases = "scored_cases"
        case skippedUnlabeled = "skipped_unlabeled"
        case skippedMissingTarget = "skipped_missing_target"
        case skippedNoCandidates = "skipped_no_candidates"
        case arms
        case hybridFailureRate = "hybrid_failure_rate"
        case axOnlyFailureRate = "ax_only_failure_rate"
        case visionOnlyFailureRate = "vision_only_failure_rate"
        case observations
    }

    public func jsonString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

public enum GroundingAblationRunnerError: Error, Equatable, CustomStringConvertible {
    /// Zero cases carry ablation candidates -- fail fast (LAW 8): a silently-empty report
    /// is the HP-9 shape.
    case noAblationCases

    public var description: String {
        switch self {
        case .noAblationCases:
            return "No benchmark cases carry ablation_candidates. Regenerate fixtures or export cases with recorded candidates before running the ablation."
        }
    }
}

public struct GroundingAblationRunner: Sendable {
    public init() {}

    public func run(jsonlURL: URL) throws -> GroundingAblationReport {
        try run(cases: GroundingBenchmarkJSONL.load(from: jsonlURL))
    }

    public func run(cases: [GroundingBenchmarkCase]) throws -> GroundingAblationReport {
        // Gate state up front: an ablation over zero candidate-bearing cases must throw,
        // never print a hollow all-zero report.
        guard cases.contains(where: { !($0.ablationCandidates ?? []).isEmpty }) else {
            throw GroundingAblationRunnerError.noAblationCases
        }

        var observations: [GroundingAblationObservation] = []
        var scoredCases = 0
        var skippedUnlabeled = 0
        var skippedMissingTarget = 0
        var skippedNoCandidates = 0
        var tallies: [GroundingAblationArm: (hits: Int, misses: Int, abstains: Int)] = [:]
        for arm in GroundingAblationArm.allCases {
            tallies[arm] = (0, 0, 0)
        }

        for benchmarkCase in cases {
            guard let target = benchmarkCase.targetText,
                  !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                skippedMissingTarget += 1
                observations.append(contentsOf: skipObservations(benchmarkCase, status: .skippedMissingTarget))
                continue
            }
            guard let expected = benchmarkCase.expectedBoxOrPoint else {
                skippedUnlabeled += 1
                observations.append(contentsOf: skipObservations(benchmarkCase, status: .skippedUnlabeled))
                continue
            }
            guard let candidates = benchmarkCase.ablationCandidates, !candidates.isEmpty else {
                skippedNoCandidates += 1
                observations.append(contentsOf: skipObservations(benchmarkCase, status: .skippedNoCandidates))
                continue
            }

            scoredCases += 1
            for arm in GroundingAblationArm.allCases {
                guard let candidate = Self.select(arm: arm, candidates: candidates) else {
                    tallies[arm]!.abstains += 1
                    observations.append(GroundingAblationObservation(
                        caseID: benchmarkCase.caseID,
                        arm: arm,
                        status: .abstain
                    ))
                    continue
                }
                let hit = expected.contains(candidate.point)
                if hit {
                    tallies[arm]!.hits += 1
                } else {
                    tallies[arm]!.misses += 1
                }
                observations.append(GroundingAblationObservation(
                    caseID: benchmarkCase.caseID,
                    arm: arm,
                    status: hit ? .hit : .miss,
                    predictedX: candidate.x,
                    predictedY: candidate.y
                ))
            }
        }

        let arms = GroundingAblationArm.allCases.map { arm -> GroundingAblationArmSummary in
            let tally = tallies[arm]!
            return GroundingAblationArmSummary(
                arm: arm,
                scored: tally.hits + tally.misses + tally.abstains,
                hits: tally.hits,
                misses: tally.misses,
                abstains: tally.abstains
            )
        }
        func failureRate(_ arm: GroundingAblationArm) -> Double {
            arms.first { $0.arm == arm }?.failureRate ?? 0
        }

        return GroundingAblationReport(
            totalCases: cases.count,
            scoredCases: scoredCases,
            skippedUnlabeled: skippedUnlabeled,
            skippedMissingTarget: skippedMissingTarget,
            skippedNoCandidates: skippedNoCandidates,
            arms: arms,
            hybridFailureRate: failureRate(.hybrid),
            axOnlyFailureRate: failureRate(.axOnly),
            visionOnlyFailureRate: failureRate(.visionOnly),
            observations: observations
        )
    }

    /// The one policy function, pure and pinned:
    /// - axOnly = highest-confidence `.accessibility` candidate
    /// - visionOnly = highest-confidence vision-source candidate
    /// - hybrid = the AX candidate if ANY exists, else the vision candidate -- mirroring
    ///   MixtureGrounder's AX-first routing structurally (LAW 2), NOT a confidence race.
    public static func select(
        arm: GroundingAblationArm,
        candidates: [GroundingAblationCandidate]
    ) -> GroundingAblationCandidate? {
        func best(_ pool: [GroundingAblationCandidate]) -> GroundingAblationCandidate? {
            pool.max { $0.confidence < $1.confidence }
        }
        let ax = candidates.filter { $0.source == .accessibility }
        let vision = candidates.filter { GroundingAblationArm.visionSources.contains($0.source) }
        switch arm {
        case .axOnly:
            return best(ax)
        case .visionOnly:
            return best(vision)
        case .hybrid:
            return best(ax) ?? best(vision)
        }
    }

    private func skipObservations(
        _ benchmarkCase: GroundingBenchmarkCase,
        status: GroundingAblationObservationStatus
    ) -> [GroundingAblationObservation] {
        GroundingAblationArm.allCases.map {
            GroundingAblationObservation(caseID: benchmarkCase.caseID, arm: $0, status: status)
        }
    }
}
