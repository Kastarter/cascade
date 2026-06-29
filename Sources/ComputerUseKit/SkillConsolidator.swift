import Foundation

/// Pure scoring helper for learned-skill review. It never reads or writes
/// SKILL.md files; callers decide how to present or persist the returned action.
public struct SkillConsolidator: Sendable {
    public enum SkillRisk: String, Sendable, Equatable {
        case low
        case medium
        case high
        case safety
    }

    public struct SkillConsolidationCandidate: Sendable, Equatable {
        public let targetSlug: String
        public let appName: String
        public let sourceCaseIDs: [String]
        public let proposedMarkdown: String
        public let mergeReason: String
        public let predictedRisk: SkillRisk
        public let requiredEvidence: [String]

        public init(
            targetSlug: String,
            appName: String,
            sourceCaseIDs: [String],
            proposedMarkdown: String,
            mergeReason: String,
            predictedRisk: SkillRisk,
            requiredEvidence: [String]
        ) {
            self.targetSlug = targetSlug
            self.appName = appName
            self.sourceCaseIDs = sourceCaseIDs
            self.proposedMarkdown = proposedMarkdown
            self.mergeReason = mergeReason
            self.predictedRisk = predictedRisk
            self.requiredEvidence = requiredEvidence
        }
    }

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
        public let sourceCaseIDs: Set<String>
        public let risk: SkillRisk
        public let status: AppSkillStatus
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
            sourceCaseIDs: Set<String> = [],
            risk: SkillRisk = .low,
            status: AppSkillStatus = .active,
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
            self.sourceCaseIDs = sourceCaseIDs
            self.risk = risk
            self.status = status
            self.quarantined = quarantined || status == .quarantined
            self.archived = archived || status == .archived
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
        public let sourceCaseIDs: [String]
        public let successCount: Int
        public let failureCount: Int
        public let predictedRisk: SkillRisk
        public let requiredEvidence: [String]
        public let mergeReason: String
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
        sourceCaseIDs: Set<String> = [],
        risk: SkillRisk = .low,
        status: AppSkillStatus? = nil,
        quarantined: Bool = false,
        archived: Bool = false
    ) -> LearnedSkillRecord? {
        guard let skill = AppSkillRegistry.parseSkill(markdown: markdown, path: path, source: source) else { return nil }
        let effectiveSourceCases = sourceCaseIDs.isEmpty ? Set(skill.sourceCaseIDs) : sourceCaseIDs
        return LearnedSkillRecord(
            id: id,
            skill: skill,
            humanSteps: inferredHumanSteps(from: skill.instructions),
            approved: approved,
            successCount: max(successCount, skill.successCount),
            failureCount: max(failureCount, skill.failureCount),
            evidenceIDs: evidenceIDs.isEmpty ? Set(skill.sourceCaseIDs) : evidenceIDs,
            sourceCaseIDs: effectiveSourceCases,
            risk: riskFrom(metadata: skill.riskClass) ?? risk,
            status: status ?? skill.status,
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
                        && skill.status == .active,
                    successCount: skill.successCount,
                    failureCount: skill.failureCount,
                    evidenceIDs: Set(skill.sourceCaseIDs),
                    sourceCaseIDs: Set(skill.sourceCaseIDs),
                    risk: Self.riskFrom(metadata: skill.riskClass) ?? .low,
                    status: skill.status
                )
            }
    }

    public func evaluate(_ candidate: LearnedSkillRecord, against existing: [LearnedSkillRecord]) -> Result {
        let active = activeSkills(from: existing)
        let activeIDs = active.map(\.id)

        if candidate.quarantined {
            return result(
                for: candidate,
                action: .quarantine(reason: "candidate is already quarantined"),
                bestMatch: nil,
                activeExistingIDs: activeIDs,
                mergeReason: "candidate status is quarantined"
            )
        }
        if candidate.archived {
            return result(
                for: candidate,
                action: .quarantine(reason: "candidate is already archived"),
                bestMatch: nil,
                activeExistingIDs: activeIDs,
                mergeReason: "candidate status is archived"
            )
        }
        if hasUnresolvedSafetyEvidence(candidate) {
            return result(
                for: candidate,
                action: .quarantine(reason: "candidate includes unresolved safety or permission evidence"),
                bestMatch: nil,
                activeExistingIDs: activeIDs,
                mergeReason: "safety/permission evidence requires human review",
                requiredEvidence: ["verified safe completion", "explicit permission boundary"]
            )
        }
        if isFailureDominated(candidate) {
            return result(
                for: candidate,
                action: .quarantine(reason: "candidate failure history dominates successes"),
                bestMatch: nil,
                activeExistingIDs: activeIDs,
                mergeReason: "failure history dominates successes",
                requiredEvidence: ["at least one verified success case after the failure"]
            )
        }
        if candidate.successCount == 0 || candidate.sourceCaseIDs.isEmpty {
            return result(
                for: candidate,
                action: .quarantine(reason: "verified source case required before consolidation"),
                bestMatch: nil,
                activeExistingIDs: activeIDs,
                mergeReason: "missing verified success source case",
                requiredEvidence: ["verified_success_case", "source_case_id"]
            )
        }

        guard let best = bestMatch(for: candidate, in: active) else {
            return result(
                for: candidate,
                action: .newSkill,
                bestMatch: nil,
                activeExistingIDs: activeIDs,
                mergeReason: "no active similar skill matched"
            )
        }
        guard best.score.total >= thresholds.revise else {
            return result(
                for: candidate,
                action: .newSkill,
                bestMatch: best.score,
                activeExistingIDs: activeIDs,
                mergeReason: "overlap below revision threshold"
            )
        }

        if best.score.total >= thresholds.archive,
           !addsNovelSignal(candidate, beyond: best.record),
           qualityScore(candidate) < qualityScore(best.record) {
            return result(
                for: candidate,
                action: .archiveCandidate(existingID: best.record.id),
                bestMatch: best.score,
                activeExistingIDs: activeIDs,
                mergeReason: "active skill already covers this draft with stronger verified signal"
            )
        }

        return result(
            for: candidate,
            action: .reviseExisting(existingID: best.record.id),
            bestMatch: best.score,
            activeExistingIDs: activeIDs,
            mergeReason: "verified draft overlaps an active skill and adds reusable signal"
        )
    }

    public func activeSkills(from records: [LearnedSkillRecord]) -> [LearnedSkillRecord] {
        records
            .filter { $0.approved && $0.status == .active && !$0.quarantined && !$0.archived && !isFailureDominated($0) }
            .sorted(by: stableOrder)
    }

    private func result(
        for candidate: LearnedSkillRecord,
        action: Action,
        bestMatch: OverlapScore?,
        activeExistingIDs: [String],
        mergeReason: String,
        requiredEvidence: [String] = []
    ) -> Result {
        Result(
            action: action,
            bestMatch: bestMatch,
            activeExistingIDs: activeExistingIDs,
            sourceCaseIDs: Array(candidate.sourceCaseIDs).sorted(),
            successCount: candidate.successCount,
            failureCount: candidate.failureCount,
            predictedRisk: predictedRisk(for: candidate),
            requiredEvidence: requiredEvidence,
            mergeReason: mergeReason
        )
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

    private func hasUnresolvedSafetyEvidence(_ record: LearnedSkillRecord) -> Bool {
        let text = "\(record.skill.markdown)\n\(record.skill.description)\n\(record.skill.useWhen)".lowercased()
        let markers = [
            "unsafe_action", "secure_input", "permission_denied", "safety refusal",
            "bypass permission", "disable security", "keychain", "password"
        ]
        return markers.contains { text.contains($0) }
    }

    private func predictedRisk(for record: LearnedSkillRecord) -> SkillRisk {
        if record.risk == .safety || hasUnresolvedSafetyEvidence(record) { return .safety }
        if record.failureCount >= thresholds.failureQuarantineCount { return .high }
        if record.failureCount > 0 { return .medium }
        return record.risk
    }

    private func addsNovelSignal(_ candidate: LearnedSkillRecord, beyond existing: LearnedSkillRecord) -> Bool {
	        let candidateSteps = Set(candidate.humanSteps.map(Self.normalizedStep).filter { !$0.isEmpty })
	        let existingSteps = Set(existing.humanSteps.map(Self.normalizedStep).filter { !$0.isEmpty })
	        if !candidateSteps.subtracting(existingSteps).isEmpty { return true }
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

    private static func riskFrom(metadata: String?) -> SkillRisk? {
        guard let metadata else { return nil }
        return SkillRisk(rawValue: metadata.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    private static func jaccard<T: Hashable>(_ lhs: Set<T>, _ rhs: Set<T>) -> Double {
        guard !lhs.isEmpty || !rhs.isEmpty else { return 0.0 }
        let intersection = lhs.intersection(rhs).count
        let union = lhs.union(rhs).count
        return union == 0 ? 0.0 : Double(intersection) / Double(union)
    }
}
