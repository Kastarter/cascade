import Foundation
import SQLite3

public enum AgentExperienceOutcome: String, Codable, Sendable {
    case success
    case failure
    case refusal
    case userStop = "user_stop"
}

public enum AgentExperienceVerificationSignal: String, Codable, Sendable {
    case verified
    case completed
}

public enum AgentFailureKind: String, Codable, Sendable {
    case wrongStartState = "wrong_start_state"
    case verifierRejected = "verifier_rejected"
    case timeout
    case toolError = "tool_error"
    case targetNotFound = "target_not_found"
    case groundingMiss = "grounding_miss"
    case permissionDenied = "permission_denied"
    case secureInput = "secure_input"
    case loginRequired = "login_required"
    case modalBlocked = "modal_blocked"
    case noEffect = "no_effect"
    case staleFrameBatch = "stale_frame_batch"
    case verificationUnavailable = "verification_unavailable"
    case unsafeAction = "unsafe_action"
    case parameterNeedsLiveValue = "parameter_needs_live_value"
    case stepLimit = "step_limit"
    case userStop = "user_stop"
    case artifactWrongLane = "artifact_wrong_lane"
    case unknown
}

public enum AgentExperienceValidationError: Error, Equatable, LocalizedError, Sendable {
    case missingVerifiedCompletionSignal
    case missingFailureKind
    case failureKindOnNonFailure
    case negativeActionCount
    case blankApp
    case blankGoalPattern
    case blankRecipeSignature

    public var errorDescription: String? {
        switch self {
        case .missingVerifiedCompletionSignal:
            "Successful agent experience requires a verified or completed signal."
        case .missingFailureKind:
            "Failed agent experience requires a failure kind."
        case .failureKindOnNonFailure:
            "Only failed agent experiences may carry a failure kind."
        case .negativeActionCount:
            "Agent experience action count cannot be negative."
        case .blankApp:
            "Agent experience app cannot be blank."
        case .blankGoalPattern:
            "Agent experience goal pattern cannot be blank."
        case .blankRecipeSignature:
            "Agent experience recipe signature cannot be blank."
        }
    }
}

public struct AgentExperienceCase: Identifiable, Codable, Equatable, Sendable {
    public let id: Int64
    public let createdAt: Date
    public let appName: String
    public let goalPattern: String
    public let recipeSignature: String
    public let skillSlug: String?
    public let outcome: AgentExperienceOutcome
    public let verificationSignal: AgentExperienceVerificationSignal?
    public let failureKind: AgentFailureKind?
    public let evidenceIDs: [Int64]
    public let actionCount: Int
    public let retainedScore: Double
    public let userFeedback: String?

    public init(
        id: Int64 = 0,
        createdAt: Date = Date(),
        appName: String,
        goalPattern: String,
        recipeSignature: String,
        skillSlug: String? = nil,
        outcome: AgentExperienceOutcome,
        verificationSignal: AgentExperienceVerificationSignal? = nil,
        failureKind: AgentFailureKind? = nil,
        evidenceIDs: [Int64] = [],
        actionCount: Int,
        retainedScore: Double? = nil,
        userFeedback: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.appName = appName
        self.goalPattern = goalPattern
        self.recipeSignature = recipeSignature
        self.skillSlug = skillSlug
        self.outcome = outcome
        self.verificationSignal = verificationSignal
        self.failureKind = failureKind
        self.evidenceIDs = evidenceIDs
        self.actionCount = actionCount
        self.userFeedback = userFeedback
        self.retainedScore = retainedScore ?? AgentExperienceRetainedScorer.score(
            outcome: outcome,
            verificationSignal: verificationSignal,
            failureKind: failureKind,
            evidenceIDs: evidenceIDs,
            actionCount: actionCount,
            userFeedback: userFeedback
        )
    }

    public var createsAvoidRule: Bool {
        switch outcome {
        case .failure:
            return failureKind != nil && retainedScore < 0
        case .userStop:
            return hasUserFeedback && retainedScore < 0
        case .success, .refusal:
            return false
        }
    }

    public var hasUserFeedback: Bool {
        guard let userFeedback else { return false }
        return !userFeedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func validatedForStorage() throws -> AgentExperienceCase {
        guard actionCount >= 0 else { throw AgentExperienceValidationError.negativeActionCount }
        guard !appName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentExperienceValidationError.blankApp
        }
        guard !goalPattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentExperienceValidationError.blankGoalPattern
        }
        guard !recipeSignature.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentExperienceValidationError.blankRecipeSignature
        }
        switch outcome {
        case .success:
            guard verificationSignal != nil else {
                throw AgentExperienceValidationError.missingVerifiedCompletionSignal
            }
            guard failureKind == nil else { throw AgentExperienceValidationError.failureKindOnNonFailure }
        case .failure:
            guard failureKind != nil else { throw AgentExperienceValidationError.missingFailureKind }
        case .refusal, .userStop:
            break
        }
        return AgentExperienceCase(
            id: id,
            createdAt: createdAt,
            appName: appName.trimmingCharacters(in: .whitespacesAndNewlines),
            goalPattern: goalPattern.trimmingCharacters(in: .whitespacesAndNewlines),
            recipeSignature: recipeSignature.trimmingCharacters(in: .whitespacesAndNewlines),
            skillSlug: Self.normalizedOptional(skillSlug),
            outcome: outcome,
            verificationSignal: verificationSignal,
            failureKind: failureKind,
            evidenceIDs: evidenceIDs,
            actionCount: actionCount,
            userFeedback: Self.normalizedOptional(userFeedback)
        )
    }

    private static func normalizedOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public enum AgentExperienceRetainedScorer {
    public static func score(
        outcome: AgentExperienceOutcome,
        verificationSignal: AgentExperienceVerificationSignal?,
        failureKind: AgentFailureKind?,
        evidenceIDs: [Int64],
        actionCount: Int,
        userFeedback: String?
    ) -> Double {
        let evidenceBonus = min(0.12, Double(evidenceIDs.count) * 0.03)
        let actionBonus = min(0.10, Double(max(0, actionCount)) * 0.01)
        switch outcome {
        case .success:
            guard verificationSignal != nil else { return 0 }
            return min(1.0, 0.72 + evidenceBonus + actionBonus)
        case .failure:
            guard let failureKind else { return 0 }
            let severity: Double
            switch failureKind {
            case .permissionDenied, .unsafeAction, .secureInput:
                severity = 0.18
            case .verifierRejected, .targetNotFound, .toolError, .groundingMiss, .noEffect:
                severity = 0.12
            case .wrongStartState, .timeout, .loginRequired, .modalBlocked, .staleFrameBatch,
                 .verificationUnavailable, .parameterNeedsLiveValue, .stepLimit, .userStop,
                 .artifactWrongLane, .unknown:
                severity = 0.08
            }
            return max(-1.0, -(0.58 + evidenceBonus + severity))
        case .refusal:
            return 0.18 + min(0.07, evidenceBonus)
        case .userStop:
            let hasFeedback = !(userFeedback ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            guard hasFeedback else { return 0 }
            return max(-0.6, -(0.28 + evidenceBonus))
        }
    }
}

public struct AgentExperienceQuery: Sendable {
    public var appName: String?
    public var goalPattern: String?
    public var recipeSignature: String?
    public var failureKind: AgentFailureKind?
    public var outcome: AgentExperienceOutcome?

    public init(
        appName: String? = nil,
        goalPattern: String? = nil,
        recipeSignature: String? = nil,
        failureKind: AgentFailureKind? = nil,
        outcome: AgentExperienceOutcome? = nil
    ) {
        self.appName = appName
        self.goalPattern = goalPattern
        self.recipeSignature = recipeSignature
        self.failureKind = failureKind
        self.outcome = outcome
    }
}

public enum AgentFailureMemoryValidationError: Error, Equatable, LocalizedError, Sendable {
    case blankApp
    case blankGoalTokens
    case blankRepairHint

    public var errorDescription: String? {
        switch self {
        case .blankApp:
            "Agent failure memory app cannot be blank."
        case .blankGoalTokens:
            "Agent failure memory requires at least one normalized goal token."
        case .blankRepairHint:
            "Agent failure memory requires a repair hint."
        }
    }
}

public struct AgentFailureMemory: Identifiable, Codable, Equatable, Sendable {
    public let id: Int64
    public let createdAt: Date
    public let appName: String
    public let normalizedGoalTokens: [String]
    public let failureKind: AgentFailureKind
    public let firstBadAction: String?
    public let screenSignatureHash: String?
    public let targetHash: String?
    public let stateSummary: String?
    public let repairHint: String
    public let recoveryEvidenceHash: String?
    public let retainedScore: Double
    public let expiresAfterSuccesses: Int
    public let remainingCounterexamples: Int
    public let lastUsedAt: Date?
    public let expiredAt: Date?

    private enum CodingKeys: String, CodingKey {
        case id
        case createdAt
        case appName
        case normalizedGoalTokens
        case failureKind
        case firstBadAction
        case screenSignatureHash
        case targetHash
        case stateSummary
        case repairHint
        case recoveryEvidenceHash
        case retainedScore
        case expiresAfterSuccesses
        case remainingCounterexamples
        case lastUsedAt
        case expiredAt
    }

    public init(
        id: Int64 = 0,
        createdAt: Date = Date(),
        appName: String,
        normalizedGoalTokens: [String],
        failureKind: AgentFailureKind,
        firstBadAction: String? = nil,
        screenSignatureHash: String? = nil,
        targetHash: String? = nil,
        stateSummary: String? = nil,
        repairHint: String,
        recoveryEvidenceHash: String? = nil,
        retainedScore: Double? = nil,
        expiresAfterSuccesses: Int = 2,
        remainingCounterexamples: Int? = nil,
        lastUsedAt: Date? = nil,
        expiredAt: Date? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.appName = appName
        self.normalizedGoalTokens = normalizedGoalTokens
        self.failureKind = failureKind
        self.firstBadAction = firstBadAction
        self.screenSignatureHash = screenSignatureHash
        self.targetHash = targetHash
        self.stateSummary = stateSummary
        self.repairHint = repairHint
        self.recoveryEvidenceHash = recoveryEvidenceHash
        self.retainedScore = retainedScore ?? Self.defaultRetainedScore(for: failureKind)
        let ttl = max(0, expiresAfterSuccesses)
        self.expiresAfterSuccesses = ttl
        self.remainingCounterexamples = max(0, remainingCounterexamples ?? ttl)
        self.lastUsedAt = lastUsedAt
        self.expiredAt = expiredAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decodeIfPresent(Int64.self, forKey: .id) ?? 0,
            createdAt: try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(),
            appName: try container.decode(String.self, forKey: .appName),
            normalizedGoalTokens: try container.decode([String].self, forKey: .normalizedGoalTokens),
            failureKind: try container.decode(AgentFailureKind.self, forKey: .failureKind),
            firstBadAction: try container.decodeIfPresent(String.self, forKey: .firstBadAction),
            screenSignatureHash: try container.decodeIfPresent(String.self, forKey: .screenSignatureHash),
            targetHash: try container.decodeIfPresent(String.self, forKey: .targetHash),
            stateSummary: try container.decodeIfPresent(String.self, forKey: .stateSummary),
            repairHint: try container.decode(String.self, forKey: .repairHint),
            recoveryEvidenceHash: try container.decodeIfPresent(String.self, forKey: .recoveryEvidenceHash),
            retainedScore: try container.decodeIfPresent(Double.self, forKey: .retainedScore),
            expiresAfterSuccesses: try container.decodeIfPresent(Int.self, forKey: .expiresAfterSuccesses) ?? 2,
            remainingCounterexamples: try container.decodeIfPresent(Int.self, forKey: .remainingCounterexamples),
            lastUsedAt: try container.decodeIfPresent(Date.self, forKey: .lastUsedAt),
            expiredAt: try container.decodeIfPresent(Date.self, forKey: .expiredAt)
        )
    }

    public var isActive: Bool {
        expiredAt == nil && remainingCounterexamples > 0
    }

    public func validatedForStorage() throws -> AgentFailureMemory {
        let app = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !app.isEmpty else { throw AgentFailureMemoryValidationError.blankApp }
        let tokens = normalizedGoalTokens
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && !PrivacyRules.isSensitiveText($0) }
        guard !tokens.isEmpty else { throw AgentFailureMemoryValidationError.blankGoalTokens }
        let hint = repairHint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hint.isEmpty else { throw AgentFailureMemoryValidationError.blankRepairHint }
        return AgentFailureMemory(
            id: id,
            createdAt: createdAt,
            appName: app,
            normalizedGoalTokens: Array(Set(tokens)).sorted(),
            failureKind: failureKind,
            firstBadAction: Self.safeOptional(firstBadAction),
            screenSignatureHash: Self.safeOptional(screenSignatureHash),
            targetHash: Self.safeOptional(targetHash),
            stateSummary: Self.safeStateSummary(stateSummary),
            repairHint: String(hint.prefix(180)),
            recoveryEvidenceHash: Self.safeOptional(recoveryEvidenceHash),
            retainedScore: retainedScore,
            expiresAfterSuccesses: expiresAfterSuccesses,
            remainingCounterexamples: remainingCounterexamples,
            lastUsedAt: lastUsedAt,
            expiredAt: expiredAt
        )
    }

    private static func defaultRetainedScore(for failureKind: AgentFailureKind) -> Double {
        AgentExperienceRetainedScorer.score(
            outcome: .failure,
            verificationSignal: nil,
            failureKind: failureKind,
            evidenceIDs: [],
            actionCount: 1,
            userFeedback: nil
        )
    }

    private static func safeOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(160))
    }

    private static func safeStateSummary(_ value: String?) -> String? {
        guard let value else { return nil }
        let redacted = PIIDetector.redact(value).redacted
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !redacted.isEmpty, !PrivacyRules.isSensitiveText(redacted) else { return nil }
        return String(redacted.prefix(240))
    }
}

public struct AgentFailureMemoryQuery: Sendable {
    public var appName: String?
    public var failureKind: AgentFailureKind?
    public var activeOnly: Bool

    public init(appName: String? = nil, failureKind: AgentFailureKind? = nil, activeOnly: Bool = true) {
        self.appName = appName
        self.failureKind = failureKind
        self.activeOnly = activeOnly
    }
}

public extension CascadeStore {
    @discardableResult
    func recordAgentExperience(_ experience: AgentExperienceCase) throws -> AgentExperienceCase {
        let valid = try experience.validatedForStorage()
        let evidenceJSON = Self.encodeEvidenceIDs(valid.evidenceIDs)
        try withStatement("""
        INSERT INTO agent_experience_case
            (created_at, app_name, goal_pattern, recipe_signature, skill_slug, outcome, verification_signal, failure_kind, evidence_ids_json, action_count, retained_score, user_feedback)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """) { statement in
            ledgerBind(AgentExperienceDateCodec.string(from: valid.createdAt), at: 1, in: statement)
            ledgerBind(valid.appName, at: 2, in: statement)
            ledgerBind(valid.goalPattern, at: 3, in: statement)
            ledgerBind(valid.recipeSignature, at: 4, in: statement)
            ledgerBind(valid.skillSlug, at: 5, in: statement)
            ledgerBind(valid.outcome.rawValue, at: 6, in: statement)
            ledgerBind(valid.verificationSignal?.rawValue, at: 7, in: statement)
            ledgerBind(valid.failureKind?.rawValue, at: 8, in: statement)
            ledgerBind(evidenceJSON, at: 9, in: statement)
            sqlite3_bind_int64(statement, 10, Int64(valid.actionCount))
            sqlite3_bind_double(statement, 11, valid.retainedScore)
            ledgerBind(valid.userFeedback, at: 12, in: statement)
            try stepDone(statement)
        }
        let id = try withStatement("SELECT last_insert_rowid();") { statement in
            sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int64(statement, 0) : Int64(0)
        }
        return AgentExperienceCase(
            id: id,
            createdAt: valid.createdAt,
            appName: valid.appName,
            goalPattern: valid.goalPattern,
            recipeSignature: valid.recipeSignature,
            skillSlug: valid.skillSlug,
            outcome: valid.outcome,
            verificationSignal: valid.verificationSignal,
            failureKind: valid.failureKind,
            evidenceIDs: valid.evidenceIDs,
            actionCount: valid.actionCount,
            retainedScore: valid.retainedScore,
            userFeedback: valid.userFeedback
        )
    }

    func agentExperienceCases(matching query: AgentExperienceQuery = AgentExperienceQuery(), limit: Int = 100) throws -> [AgentExperienceCase] {
        var conditions: [String] = []
        var values: [String] = []
        if let appName = normalizedQueryValue(query.appName) {
            conditions.append("app_name = ?")
            values.append(appName)
        }
        if let goalPattern = normalizedQueryValue(query.goalPattern) {
            conditions.append("goal_pattern = ?")
            values.append(goalPattern)
        }
        if let recipeSignature = normalizedQueryValue(query.recipeSignature) {
            conditions.append("recipe_signature = ?")
            values.append(recipeSignature)
        }
        if let failureKind = query.failureKind {
            conditions.append("failure_kind = ?")
            values.append(failureKind.rawValue)
        }
        if let outcome = query.outcome {
            conditions.append("outcome = ?")
            values.append(outcome.rawValue)
        }
        let whereClause = conditions.isEmpty ? "" : "WHERE \(conditions.joined(separator: " AND "))"
        return try withStatement("""
        \(Self.agentExperienceColumns)
        FROM agent_experience_case
        \(whereClause)
        ORDER BY created_at DESC, id DESC
        LIMIT ?;
        """) { statement in
            for (index, value) in values.enumerated() {
                ledgerBind(value, at: Int32(index + 1), in: statement)
            }
            sqlite3_bind_int(statement, Int32(values.count + 1), Int32(max(0, limit)))
            var rows: [AgentExperienceCase] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(Self.decodeAgentExperience(statement))
            }
            return rows
        }
    }

    func agentExperienceAvoidRules(matching query: AgentExperienceQuery = AgentExperienceQuery(), limit: Int = 100) throws -> [AgentExperienceCase] {
        var conditions: [String] = [
            """
            ((outcome = ? AND failure_kind IS NOT NULL AND retained_score < 0)
                OR (outcome = ? AND user_feedback IS NOT NULL AND length(trim(user_feedback)) > 0 AND retained_score < 0))
            """
        ]
        var values: [String] = [AgentExperienceOutcome.failure.rawValue, AgentExperienceOutcome.userStop.rawValue]
        if let appName = normalizedQueryValue(query.appName) {
            conditions.append("app_name = ?")
            values.append(appName)
        }
        if let goalPattern = normalizedQueryValue(query.goalPattern) {
            conditions.append("goal_pattern = ?")
            values.append(goalPattern)
        }
        if let recipeSignature = normalizedQueryValue(query.recipeSignature) {
            conditions.append("recipe_signature = ?")
            values.append(recipeSignature)
        }
        if let failureKind = query.failureKind {
            conditions.append("failure_kind = ?")
            values.append(failureKind.rawValue)
        }
        if let outcome = query.outcome {
            conditions.append("outcome = ?")
            values.append(outcome.rawValue)
        }
        let whereClause = "WHERE \(conditions.joined(separator: " AND "))"
        return try withStatement("""
        \(Self.agentExperienceColumns)
        FROM agent_experience_case
        \(whereClause)
        ORDER BY created_at DESC, id DESC
        LIMIT ?;
        """) { statement in
            for (index, value) in values.enumerated() {
                ledgerBind(value, at: Int32(index + 1), in: statement)
            }
            sqlite3_bind_int(statement, Int32(values.count + 1), Int32(max(0, limit)))
            var rows: [AgentExperienceCase] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(Self.decodeAgentExperience(statement))
            }
            return rows
        }
    }

    func verifiedAgentExperienceCases(
        appName: String? = nil,
        goalPattern: String? = nil,
        recipeSignature: String? = nil,
        limit: Int = 50
    ) throws -> [AgentExperienceCase] {
        var conditions = ["outcome = ?", "verification_signal IS NOT NULL"]
        var values = [AgentExperienceOutcome.success.rawValue]
        if let appName = normalizedQueryValue(appName) {
            conditions.append("app_name = ?")
            values.append(appName)
        }
        if let goalPattern = normalizedQueryValue(goalPattern) {
            conditions.append("goal_pattern = ?")
            values.append(goalPattern)
        }
        if let recipeSignature = normalizedQueryValue(recipeSignature) {
            conditions.append("recipe_signature = ?")
            values.append(recipeSignature)
        }
        let whereClause = "WHERE \(conditions.joined(separator: " AND "))"
        return try withStatement("""
        \(Self.agentExperienceColumns)
        FROM agent_experience_case
        \(whereClause)
        ORDER BY created_at DESC, id DESC
        LIMIT ?;
        """) { statement in
            for (index, value) in values.enumerated() {
                ledgerBind(value, at: Int32(index + 1), in: statement)
            }
            sqlite3_bind_int(statement, Int32(values.count + 1), Int32(max(0, limit)))
            var rows: [AgentExperienceCase] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(Self.decodeAgentExperience(statement))
            }
            return rows
        }
    }

    @discardableResult
    func recordAgentFailureMemory(_ memory: AgentFailureMemory) throws -> AgentFailureMemory {
        let valid = try memory.validatedForStorage()
        let tokensJSON = Self.encodeGoalTokens(valid.normalizedGoalTokens)
        try withStatement("""
        INSERT INTO agent_failure_memory
            (created_at, app_name, goal_tokens_json, failure_kind, first_bad_action, screen_signature_hash, target_hash, state_summary, repair_hint, recovery_evidence_hash, retained_score, expires_after_successes, remaining_counterexamples, last_used_at, expired_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """) { statement in
            ledgerBind(AgentExperienceDateCodec.string(from: valid.createdAt), at: 1, in: statement)
            ledgerBind(valid.appName, at: 2, in: statement)
            ledgerBind(tokensJSON, at: 3, in: statement)
            ledgerBind(valid.failureKind.rawValue, at: 4, in: statement)
            ledgerBind(valid.firstBadAction, at: 5, in: statement)
            ledgerBind(valid.screenSignatureHash, at: 6, in: statement)
            ledgerBind(valid.targetHash, at: 7, in: statement)
            ledgerBind(valid.stateSummary, at: 8, in: statement)
            ledgerBind(valid.repairHint, at: 9, in: statement)
            ledgerBind(valid.recoveryEvidenceHash, at: 10, in: statement)
            sqlite3_bind_double(statement, 11, valid.retainedScore)
            sqlite3_bind_int(statement, 12, Int32(valid.expiresAfterSuccesses))
            sqlite3_bind_int(statement, 13, Int32(valid.remainingCounterexamples))
            ledgerBind(valid.lastUsedAt.map(AgentExperienceDateCodec.string(from:)), at: 14, in: statement)
            ledgerBind(valid.expiredAt.map(AgentExperienceDateCodec.string(from:)), at: 15, in: statement)
            try stepDone(statement)
        }
        let id = try withStatement("SELECT last_insert_rowid();") { statement in
            sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int64(statement, 0) : Int64(0)
        }
        return AgentFailureMemory(
            id: id,
            createdAt: valid.createdAt,
            appName: valid.appName,
            normalizedGoalTokens: valid.normalizedGoalTokens,
            failureKind: valid.failureKind,
            firstBadAction: valid.firstBadAction,
            screenSignatureHash: valid.screenSignatureHash,
            targetHash: valid.targetHash,
            stateSummary: valid.stateSummary,
            repairHint: valid.repairHint,
            recoveryEvidenceHash: valid.recoveryEvidenceHash,
            retainedScore: valid.retainedScore,
            expiresAfterSuccesses: valid.expiresAfterSuccesses,
            remainingCounterexamples: valid.remainingCounterexamples,
            lastUsedAt: valid.lastUsedAt,
            expiredAt: valid.expiredAt
        )
    }

    func agentFailureMemories(matching query: AgentFailureMemoryQuery = AgentFailureMemoryQuery(), limit: Int = 100) throws -> [AgentFailureMemory] {
        var conditions: [String] = []
        var values: [String] = []
        if let appName = normalizedQueryValue(query.appName) {
            conditions.append("app_name = ?")
            values.append(appName)
        }
        if let failureKind = query.failureKind {
            conditions.append("failure_kind = ?")
            values.append(failureKind.rawValue)
        }
        if query.activeOnly {
            conditions.append("expired_at IS NULL")
            conditions.append("remaining_counterexamples > 0")
        }
        let whereClause = conditions.isEmpty ? "" : "WHERE \(conditions.joined(separator: " AND "))"
        return try withStatement("""
        \(Self.agentFailureMemoryColumns)
        FROM agent_failure_memory
        \(whereClause)
        ORDER BY created_at DESC, id DESC
        LIMIT ?;
        """) { statement in
            for (index, value) in values.enumerated() {
                ledgerBind(value, at: Int32(index + 1), in: statement)
            }
            sqlite3_bind_int(statement, Int32(values.count + 1), Int32(max(0, limit)))
            var rows: [AgentFailureMemory] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(Self.decodeAgentFailureMemory(statement))
            }
            return rows
        }
    }

    @discardableResult
    func markAgentFailureMemoriesUsed(ids: [Int64], at date: Date = Date()) throws -> [AgentFailureMemory] {
        let uniqueIDs = Array(Set(ids.filter { $0 > 0 })).sorted()
        guard !uniqueIDs.isEmpty else { return [] }
        let usedAt = AgentExperienceDateCodec.string(from: date)
        for id in uniqueIDs {
            try withStatement("UPDATE agent_failure_memory SET last_used_at = ? WHERE id = ?;") { statement in
                ledgerBind(usedAt, at: 1, in: statement)
                sqlite3_bind_int64(statement, 2, id)
                try stepDone(statement)
            }
        }
        return try agentFailureMemories(ids: uniqueIDs, activeOnly: false)
    }

    @discardableResult
    func recordAgentFailureCounterexample(
        appName: String,
        goalPattern: String,
        failureKind: AgentFailureKind? = nil,
        at date: Date = Date()
    ) throws -> [AgentFailureMemory] {
        let app = normalizedQueryValue(appName) ?? appName
        let queryTokens = Set(TrajectoryGoalTokenizer.normalizedGoalTokens(from: goalPattern))
        guard !app.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !queryTokens.isEmpty else { return [] }
        let candidates = try agentFailureMemories(
            matching: AgentFailureMemoryQuery(appName: app, failureKind: failureKind, activeOnly: true),
            limit: 200
        )
        let matched = candidates.filter { memory in
            !Set(memory.normalizedGoalTokens).isDisjoint(with: queryTokens)
        }
        guard !matched.isEmpty else { return [] }
        let now = AgentExperienceDateCodec.string(from: date)
        for memory in matched {
            let remaining = max(0, memory.remainingCounterexamples - 1)
            try withStatement("""
            UPDATE agent_failure_memory
            SET remaining_counterexamples = ?, last_used_at = ?, expired_at = ?
            WHERE id = ?;
            """) { statement in
                sqlite3_bind_int(statement, 1, Int32(remaining))
                ledgerBind(now, at: 2, in: statement)
                ledgerBind(remaining == 0 ? now : nil, at: 3, in: statement)
                sqlite3_bind_int64(statement, 4, memory.id)
                try stepDone(statement)
            }
        }
        return try agentFailureMemories(ids: matched.map(\.id), activeOnly: false)
    }

    private static var agentExperienceColumns: String {
        """
        SELECT id, created_at, app_name, goal_pattern, recipe_signature, skill_slug, outcome, verification_signal, failure_kind, evidence_ids_json, action_count, retained_score, user_feedback
        """
    }

    private static var agentFailureMemoryColumns: String {
        """
        SELECT id, created_at, app_name, goal_tokens_json, failure_kind, first_bad_action, screen_signature_hash, target_hash, state_summary, repair_hint, recovery_evidence_hash, retained_score, expires_after_successes, remaining_counterexamples, last_used_at, expired_at
        """
    }

    private func agentFailureMemories(ids: [Int64], activeOnly: Bool) throws -> [AgentFailureMemory] {
        let uniqueIDs = Array(Set(ids.filter { $0 > 0 })).sorted()
        guard !uniqueIDs.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: uniqueIDs.count).joined(separator: ",")
        let activeClause = activeOnly ? "AND expired_at IS NULL AND remaining_counterexamples > 0" : ""
        return try withStatement("""
        \(Self.agentFailureMemoryColumns)
        FROM agent_failure_memory
        WHERE id IN (\(placeholders)) \(activeClause)
        ORDER BY created_at DESC, id DESC;
        """) { statement in
            for (index, id) in uniqueIDs.enumerated() {
                sqlite3_bind_int64(statement, Int32(index + 1), id)
            }
            var rows: [AgentFailureMemory] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(Self.decodeAgentFailureMemory(statement))
            }
            return rows
        }
    }

    private static func decodeAgentExperience(_ statement: OpaquePointer) -> AgentExperienceCase {
        let outcome = AgentExperienceOutcome(rawValue: ledgerText(statement, 6) ?? "") ?? .failure
        return AgentExperienceCase(
            id: sqlite3_column_int64(statement, 0),
            createdAt: AgentExperienceDateCodec.date(from: ledgerText(statement, 1)) ?? Date(),
            appName: ledgerText(statement, 2) ?? "Unknown",
            goalPattern: ledgerText(statement, 3) ?? "",
            recipeSignature: ledgerText(statement, 4) ?? "",
            skillSlug: ledgerText(statement, 5),
            outcome: outcome,
            verificationSignal: ledgerText(statement, 7).flatMap(AgentExperienceVerificationSignal.init(rawValue:)),
            failureKind: ledgerText(statement, 8).flatMap(AgentFailureKind.init(rawValue:)),
            evidenceIDs: decodeEvidenceIDs(ledgerText(statement, 9)),
            actionCount: Int(sqlite3_column_int64(statement, 10)),
            retainedScore: sqlite3_column_double(statement, 11),
            userFeedback: ledgerText(statement, 12)
        )
    }

    private static func decodeAgentFailureMemory(_ statement: OpaquePointer) -> AgentFailureMemory {
        AgentFailureMemory(
            id: sqlite3_column_int64(statement, 0),
            createdAt: AgentExperienceDateCodec.date(from: ledgerText(statement, 1)) ?? Date(),
            appName: ledgerText(statement, 2) ?? "Unknown",
            normalizedGoalTokens: decodeGoalTokens(ledgerText(statement, 3)),
            failureKind: ledgerText(statement, 4).flatMap(AgentFailureKind.init(rawValue:)) ?? .unknown,
            firstBadAction: ledgerText(statement, 5),
            screenSignatureHash: ledgerText(statement, 6),
            targetHash: ledgerText(statement, 7),
            stateSummary: ledgerText(statement, 8),
            repairHint: ledgerText(statement, 9) ?? "",
            recoveryEvidenceHash: ledgerText(statement, 10),
            retainedScore: sqlite3_column_double(statement, 11),
            expiresAfterSuccesses: Int(sqlite3_column_int(statement, 12)),
            remainingCounterexamples: Int(sqlite3_column_int(statement, 13)),
            lastUsedAt: AgentExperienceDateCodec.date(from: ledgerText(statement, 14)),
            expiredAt: AgentExperienceDateCodec.date(from: ledgerText(statement, 15))
        )
    }

    private static func encodeEvidenceIDs(_ ids: [Int64]) -> String {
        guard let data = try? JSONEncoder().encode(ids),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }

    private static func decodeEvidenceIDs(_ json: String?) -> [Int64] {
        guard let json, let data = json.data(using: .utf8),
              let ids = try? JSONDecoder().decode([Int64].self, from: data) else {
            return []
        }
        return ids
    }

    private static func encodeGoalTokens(_ tokens: [String]) -> String {
        guard let data = try? JSONEncoder().encode(tokens),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }

    private static func decodeGoalTokens(_ json: String?) -> [String] {
        guard let json, let data = json.data(using: .utf8),
              let tokens = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return tokens
    }

    private func normalizedQueryValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private enum AgentExperienceDateCodec {
    private static func formatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    static func string(from date: Date) -> String {
        formatter().string(from: date)
    }

    static func date(from string: String?) -> Date? {
        guard let string else { return nil }
        return formatter().date(from: string)
    }
}

private func ledgerBind(_ value: String?, at index: Int32, in statement: OpaquePointer) {
    guard let value else {
        sqlite3_bind_null(statement, index)
        return
    }
    sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
}

private enum TrajectoryGoalTokenizer {
    static func normalizedGoalTokens(from goal: String) -> [String] {
        let stopwords: Set<String> = [
            "a", "an", "and", "are", "as", "at", "be", "by", "for", "from", "in",
            "into", "is", "it", "latest", "of", "on", "or", "out", "the", "then",
            "this", "to", "with"
        ]
        let parts = goal
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count > 1 && !stopwords.contains($0) && !PrivacyRules.isSensitiveText($0) }

        var seen = Set<String>()
        var ordered: [String] = []
        for part in parts where seen.insert(part).inserted {
            ordered.append(part)
        }
        return ordered
    }
}

private func ledgerText(_ statement: OpaquePointer, _ index: Int32) -> String? {
    guard let cString = sqlite3_column_text(statement, index) else { return nil }
    return String(cString: cString)
}
