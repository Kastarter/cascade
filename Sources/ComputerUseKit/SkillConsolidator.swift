import Foundation

/// Pure scoring helper for learned-skill review. It never reads or writes
/// SKILL.md files; callers decide how to present or persist the returned action.
public struct SkillConsolidator: Sendable {
    public struct Thresholds: Sendable {
        public let revise: Double
        public let archive: Double
        public let failureQuarantineCount: Int

        public init(
            revise: Double = 0.68,
            archive: Double = 0.84,
            failureQuarantineCount: Int = 2
        ) {
            self.revise = revise
            self.archive = archive
            self.failureQuarantineCount = failureQuarantineCount
        }
    }

    public struct LearnedSkillRecord: Sendable {
        public let id: String
        public let skill: AppSkill
        public let humanSteps: [String]
        public let approved: Bool
        public let successCount: Int
        public let failureCount: Int
        public let evidenceIDs: Set<String>
        public let quarantined: Bool
        public let archived: Bool

        public init(
            id: String,
            skill: AppSkill,
            humanSteps: [String] = [],
            approved: Bool = false,
            successCount: Int = 0,
            failureCount: Int = 0,
            evidenceIDs: Set<String> = [],
            quarantined: Bool = false,
            archived: Bool = false
        ) {
            self.id = id
            self.skill = skill
            self.humanSteps = humanSteps
            self.approved = approved
            self.successCount = max(0, successCount)
            self.failureCount = max(0, failureCount)
            self.evidenceIDs = evidenceIDs
            self.quarantined = quarantined
            self.archived = archived
        }
    }

    public enum Action: Sendable, Equatable {
        case newSkill
        case reviseExisting(existingID: String)
        case quarantine(reason: String)
        case archiveCandidate(existingID: String)
    }

    public struct OverlapScore: Sendable, Equatable {
        public let candidateID: String
        public let existingID: String
        public let total: Double
        public let appMatcher: Double
        public let useWhen: Double
        public let explicitAskOnly: Double
        public let humanSteps: Double
        public let approvedStatus: Double
        public let outcomeHistory: Double
        public let evidence: Double
    }

    public struct Result: Sendable, Equatable {
        public let action: Action
        public let bestMatch: OverlapScore?
        public let activeExistingIDs: [String]
    }

    private let thresholds: Thresholds

    public init(thresholds: Thresholds = Thresholds()) {
        self.thresholds = thresholds
    }

    public static func record(
        id: String,
        markdown: String,
        path: String,
        source: String,
        approved: Bool = false,
        successCount: Int = 0,
        failureCount: Int = 0,
        evidenceIDs: Set<String> = [],
        quarantined: Bool = false,
        archived: Bool = false
    ) -> LearnedSkillRecord? {
        guard let skill = AppSkillRegistry.parseSkill(markdown: markdown, path: path, source: source) else { return nil }
        return LearnedSkillRecord(
            id: id,
            skill: skill,
            humanSteps: inferredHumanSteps(from: skill.instructions),
            approved: approved,
            successCount: successCount,
            failureCount: failureCount,
            evidenceIDs: evidenceIDs,
            quarantined: quarantined,
            archived: archived
        )
    }

    public func learnedSkillRecords(from registry: AppSkillRegistry, source: String? = "user") -> [LearnedSkillRecord] {
        registry.skills
            .filter { skill in source.map { skill.source == $0 } ?? true }
            .map { skill in
                LearnedSkillRecord(
                    id: skill.name,
                    skill: skill,
                    humanSteps: Self.inferredHumanSteps(from: skill.instructions),
                    approved: skill.source == "user"
                )
            }
    }

    public func evaluate(_ candidate: LearnedSkillRecord, against existing: [LearnedSkillRecord]) -> Result {
        let active = activeSkills(from: existing)
        let activeIDs = active.map(\.id)

        if candidate.quarantined {
            return Result(
                action: .quarantine(reason: "candidate is already quarantined"),
                bestMatch: nil,
                activeExistingIDs: activeIDs
            )
        }
        if candidate.archived {
            return Result(
                action: .quarantine(reason: "candidate is already archived"),
                bestMatch: nil,
                activeExistingIDs: activeIDs
            )
        }
        if isFailureDominated(candidate) {
            return Result(
                action: .quarantine(reason: "candidate failure history dominates successes"),
                bestMatch: nil,
                activeExistingIDs: activeIDs
            )
        }

        guard let best = bestMatch(for: candidate, in: active) else {
            return Result(action: .newSkill, bestMatch: nil, activeExistingIDs: activeIDs)
        }
        guard best.score.total >= thresholds.revise else {
            return Result(action: .newSkill, bestMatch: best.score, activeExistingIDs: activeIDs)
        }

        if best.score.total >= thresholds.archive,
           !addsNovelSignal(candidate, beyond: best.record),
           qualityScore(candidate) < qualityScore(best.record) {
            return Result(
                action: .archiveCandidate(existingID: best.record.id),
                bestMatch: best.score,
                activeExistingIDs: activeIDs
            )
        }

        return Result(
            action: .reviseExisting(existingID: best.record.id),
            bestMatch: best.score,
            activeExistingIDs: activeIDs
        )
    }

    public func activeSkills(from records: [LearnedSkillRecord]) -> [LearnedSkillRecord] {
        records
            .filter { $0.approved && !$0.quarantined && !$0.archived && !isFailureDominated($0) }
            .sorted(by: stableOrder)
    }

    private func bestMatch(
        for candidate: LearnedSkillRecord,
        in existing: [LearnedSkillRecord]
    ) -> (record: LearnedSkillRecord, score: OverlapScore)? {
        let scored: [(record: LearnedSkillRecord, score: OverlapScore)] = existing
            .map { record in (record: record, score: score(candidate, against: record)) }
        return scored
            .sorted(by: { lhs, rhs in
                if lhs.score.total != rhs.score.total { return lhs.score.total > rhs.score.total }
                let lhsQuality = qualityScore(lhs.record)
                let rhsQuality = qualityScore(rhs.record)
                if lhsQuality != rhsQuality { return lhsQuality > rhsQuality }
                return stableOrder(lhs.record, rhs.record)
            })
            .first
    }

    private func score(_ candidate: LearnedSkillRecord, against existing: LearnedSkillRecord) -> OverlapScore {
        let appMatcher = appMatcherScore(candidate.skill, existing.skill)
        let useWhen = Self.jaccard(Self.tokens(in: candidate.skill.useWhen), Self.tokens(in: existing.skill.useWhen))
        let explicitAskOnly = candidate.skill.explicitAskOnly == existing.skill.explicitAskOnly ? 1.0 : 0.0
        let humanSteps = humanStepScore(candidate.humanSteps, existing.humanSteps)
        let approvedStatus = candidate.approved == existing.approved ? 1.0 : 0.65
        let outcomeHistory = outcomeScore(candidate, existing)
        let evidence = Self.jaccard(candidate.evidenceIDs, existing.evidenceIDs)
        let total =
            appMatcher * 0.30 +
            useWhen * 0.18 +
            explicitAskOnly * 0.08 +
            humanSteps * 0.22 +
            approvedStatus * 0.07 +
            outcomeHistory * 0.07 +
            evidence * 0.08
        return OverlapScore(
            candidateID: candidate.id,
            existingID: existing.id,
            total: total,
            appMatcher: appMatcher,
            useWhen: useWhen,
            explicitAskOnly: explicitAskOnly,
            humanSteps: humanSteps,
            approvedStatus: approvedStatus,
            outcomeHistory: outcomeHistory,
            evidence: evidence
        )
    }

    private func appMatcherScore(_ lhs: AppSkill, _ rhs: AppSkill) -> Double {
        guard let lhsMatchers = lhs.hints.appMatchers,
              let rhsMatchers = rhs.hints.appMatchers else { return 0.0 }

        let lhsBundles = Set(lhsMatchers.bundleIdentifiers.map(Self.normalizedPhrase).filter { !$0.isEmpty })
        let rhsBundles = Set(rhsMatchers.bundleIdentifiers.map(Self.normalizedPhrase).filter { !$0.isEmpty })
        if !lhsBundles.isDisjoint(with: rhsBundles) { return 1.0 }

        let lhsNames = lhsMatchers.names.map(Self.normalizedPhrase).filter { !$0.isEmpty }
        let rhsNames = rhsMatchers.names.map(Self.normalizedPhrase).filter { !$0.isEmpty }
        for lhsName in lhsNames {
            for rhsName in rhsNames where lhsName == rhsName || lhsName.contains(rhsName) || rhsName.contains(lhsName) {
                return 0.9
            }
        }
        return 0.0
    }

    private func humanStepScore(_ lhs: [String], _ rhs: [String]) -> Double {
        let lhsLines = Set(lhs.map(Self.normalizedStep).filter { !$0.isEmpty })
        let rhsLines = Set(rhs.map(Self.normalizedStep).filter { !$0.isEmpty })
        let lineScore = Self.jaccard(lhsLines, rhsLines)
        let tokenScore = Self.jaccard(Self.tokens(in: lhs.joined(separator: " ")), Self.tokens(in: rhs.joined(separator: " ")))
        return max(lineScore, tokenScore * 0.85)
    }

    private func outcomeScore(_ lhs: LearnedSkillRecord, _ rhs: LearnedSkillRecord) -> Double {
        max(0.0, 1.0 - abs(healthScore(lhs) - healthScore(rhs)))
    }

    private func healthScore(_ record: LearnedSkillRecord) -> Double {
        let successes = Double(record.successCount + 1)
        let attempts = Double(record.successCount + record.failureCount + 2)
        return successes / attempts
    }

    private func qualityScore(_ record: LearnedSkillRecord) -> Double {
        let approval = record.approved ? 2.0 : 0.0
        let evidence = Double(min(record.evidenceIDs.count, 6)) * 0.15
        return approval + Double(record.successCount) * 0.8 + evidence - Double(record.failureCount) * 1.1
    }

    private func isFailureDominated(_ record: LearnedSkillRecord) -> Bool {
        guard record.failureCount >= thresholds.failureQuarantineCount else { return false }
        if record.successCount == 0 { return true }
        return record.failureCount >= (record.successCount * 2 + 1)
    }

    private func addsNovelSignal(_ candidate: LearnedSkillRecord, beyond existing: LearnedSkillRecord) -> Bool {
        let candidateSteps = Set(candidate.humanSteps.map(Self.normalizedStep).filter { !$0.isEmpty })
        let existingSteps = Set(existing.humanSteps.map(Self.normalizedStep).filter { !$0.isEmpty })
        if !candidateSteps.subtracting(existingSteps).isEmpty { return true }
        if !candidate.evidenceIDs.subtracting(existing.evidenceIDs).isEmpty { return true }
        let candidateUseWhen = Self.tokens(in: candidate.skill.useWhen)
        let existingUseWhen = Self.tokens(in: existing.skill.useWhen)
        return !candidateUseWhen.subtracting(existingUseWhen).isEmpty
    }

    private func stableOrder(_ lhs: LearnedSkillRecord, _ rhs: LearnedSkillRecord) -> Bool {
        let lhsKey = "\(Self.normalizedPhrase(lhs.skill.name))\u{0}\(lhs.id)"
        let rhsKey = "\(Self.normalizedPhrase(rhs.skill.name))\u{0}\(rhs.id)"
        return lhsKey < rhsKey
    }

    private static func normalizedStep(_ step: String) -> String {
        tokens(in: step).sorted().joined(separator: " ")
    }

    private static func inferredHumanSteps(from instructions: String) -> [String] {
        instructions
            .split(separator: "\n")
            .compactMap { rawLine in
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                if line.hasPrefix("- ") {
                    return String(line.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if let marker = line.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
                    return String(line[marker.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                return nil
            }
            .filter { !$0.isEmpty }
    }

    private static func normalizedPhrase(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func tokens(in text: String) -> Set<String> {
        let stopwords: Set<String> = [
            "a", "an", "and", "are", "as", "at", "for", "from", "in", "into",
            "is", "it", "of", "on", "or", "the", "to", "use", "uses", "when",
            "with", "work", "works"
        ]
        var tokens: Set<String> = []
        var current = ""
        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else {
                if current.count > 1, !stopwords.contains(current) { tokens.insert(current) }
                current.removeAll(keepingCapacity: true)
            }
        }
        if current.count > 1, !stopwords.contains(current) { tokens.insert(current) }
        return tokens
    }

    private static func jaccard<T: Hashable>(_ lhs: Set<T>, _ rhs: Set<T>) -> Double {
        guard !lhs.isEmpty || !rhs.isEmpty else { return 0.0 }
        let intersection = lhs.intersection(rhs).count
        let union = lhs.union(rhs).count
        return union == 0 ? 0.0 : Double(intersection) / Double(union)
    }
}
