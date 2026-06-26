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
    case verifierRejected = "verifier_rejected"
    case timeout
    case toolError = "tool_error"
    case targetNotFound = "target_not_found"
    case permissionDenied = "permission_denied"
    case loginRequired = "login_required"
    case modalBlocked = "modal_blocked"
    case unsafeAction = "unsafe_action"
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
            guard failureKind == nil else { throw AgentExperienceValidationError.failureKindOnNonFailure }
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
            case .permissionDenied, .unsafeAction:
                severity = 0.18
            case .verifierRejected, .targetNotFound, .toolError:
                severity = 0.12
            case .timeout, .loginRequired, .modalBlocked, .unknown:
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
    public var failureKind: AgentFailureKind?
    public var outcome: AgentExperienceOutcome?

    public init(
        appName: String? = nil,
        goalPattern: String? = nil,
        failureKind: AgentFailureKind? = nil,
        outcome: AgentExperienceOutcome? = nil
    ) {
        self.appName = appName
        self.goalPattern = goalPattern
        self.failureKind = failureKind
        self.outcome = outcome
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

    private static var agentExperienceColumns: String {
        """
        SELECT id, created_at, app_name, goal_pattern, recipe_signature, skill_slug, outcome, verification_signal, failure_kind, evidence_ids_json, action_count, retained_score, user_feedback
        """
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

private func ledgerText(_ statement: OpaquePointer, _ index: Int32) -> String? {
    guard let cString = sqlite3_column_text(statement, index) else { return nil }
    return String(cString: cString)
}
