import CryptoKit
import Foundation
import SQLite3

public enum ActionTrajectoryCacheSource: String, Codable, CaseIterable, Sendable {
    case assist
    case recipe
    case sandbox
    case grounding
}

public enum ActionTrajectoryTTLPolicy: String, Codable, CaseIterable, Sendable {
    case short
    case standard
    case long

    var duration: TimeInterval {
        switch self {
        case .short: 24 * 60 * 60
        case .standard: 30 * 24 * 60 * 60
        case .long: 90 * 24 * 60 * 60
        }
    }
}

public enum ActionTrajectoryCacheDecisionReason: String, Codable, Sendable {
    case exact
    case semanticHint
    case miss
    case wrongApp
    case wrongWindow
    case wrongURLScope
    case wrongScreen
    case missingAnchor
    case modalPresent
    case disallowedAction
    case lowConfidence
    case expired
    case sensitive
}

public struct ActionTrajectoryState: Equatable, Sendable {
    public let appName: String
    public let bundleIdentifier: String?
    public let windowTitle: String?
    public let webAppID: String?
    public let urlScope: String?
    public let screenHash: UInt64?
    public let screenGridHashes: [UInt64]
    public let ocrSimhash: UInt64?
    public let axFingerprint: String?
    public let modalPresent: Bool

    public init(
        appName: String,
        bundleIdentifier: String? = nil,
        windowTitle: String? = nil,
        webAppID: String? = nil,
        urlScope: String? = nil,
        screenHash: UInt64? = nil,
        screenGridHashes: [UInt64] = [],
        ocrSimhash: UInt64? = nil,
        axFingerprint: String? = nil,
        modalPresent: Bool = false
    ) {
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.windowTitle = windowTitle
        self.webAppID = webAppID
        self.urlScope = Self.urlScope(from: urlScope)
        self.screenHash = screenHash
        self.screenGridHashes = screenGridHashes
        self.ocrSimhash = ocrSimhash
        self.axFingerprint = axFingerprint?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.modalPresent = modalPresent
    }

    public static func urlScope(from rawValue: String?) -> String? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines), !rawValue.isEmpty else {
            return nil
        }
        guard let url = URL(string: rawValue),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = url.host?.lowercased() else {
            return SemanticEmbeddingText.normalized(rawValue).nilIfEmpty
        }
        let path = url.path
            .split(separator: "/")
            .prefix(2)
            .map { component in
                component.allSatisfy(\.isNumber) ? ":id" : String(component).lowercased()
            }
            .joined(separator: "/")
        return path.isEmpty ? "\(scheme)://\(host)" : "\(scheme)://\(host)/\(path)"
    }
}

public struct ActionTrajectoryCacheAction: Equatable, Sendable {
    public let kind: String
    public let json: String
    public let preconditionJSON: String?
    public let postconditionJSON: String?

    public init(
        kind: String,
        json: String,
        preconditionJSON: String? = nil,
        postconditionJSON: String? = nil
    ) {
        self.kind = Self.normalizedKind(kind)
        self.json = json
        self.preconditionJSON = preconditionJSON
        self.postconditionJSON = postconditionJSON
    }

    public static func normalizedKind(_ kind: String) -> String {
        kind.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "_")
            .lowercased()
    }
}

public struct ActionTrajectoryCacheRow: Equatable, Sendable, Identifiable {
    public let id: Int64
    public let createdAt: Date
    public let updatedAt: Date
    public let lastUsedAt: Date
    public let source: ActionTrajectoryCacheSource
    public let actionKeyHash: String
    public let goalNorm: String
    public let appName: String
    public let bundleIdentifier: String?
    public let windowTitleNorm: String?
    public let webAppID: String?
    public let urlScope: String?
    public let screenHash: UInt64?
    public let screenGridHashes: [UInt64]
    public let ocrSimhash: UInt64?
    public let axFingerprint: String?
    public let targetDescriptor: String?
    public let targetTextNorm: String?
    public let actionKind: String
    public let actionJSON: String
    public let preconditionJSON: String?
    public let postconditionJSON: String?
    public let successCount: Int
    public let failureCount: Int
    public let confidence: Double
    public let embedding: [Float]?
    public let ttlPolicy: ActionTrajectoryTTLPolicy
    public let expiresAt: Date?

    public var isExpired: Bool {
        expiresAt.map { $0 <= Date() } ?? false
    }
}

public struct ActionTrajectoryCacheLookupResult: Equatable, Sendable {
    public let row: ActionTrajectoryCacheRow
    public let executable: Bool
    public let reason: ActionTrajectoryCacheDecisionReason
    public let score: Double
    public let hint: String?
}

public struct ActionTrajectoryCacheLookup: Equatable, Sendable {
    public let executable: ActionTrajectoryCacheLookupResult?
    public let hints: [String]
    public let candidateCount: Int
    public let bypassReason: ActionTrajectoryCacheDecisionReason?

    public var isMiss: Bool {
        executable == nil && hints.isEmpty
    }

    public static let empty = ActionTrajectoryCacheLookup(
        executable: nil,
        hints: [],
        candidateCount: 0,
        bypassReason: .miss
    )
}

public extension CascadeStore {
    func ensureActionTrajectoryCacheSchema() throws {
        try withStatement("""
        CREATE TABLE IF NOT EXISTS action_trajectory_cache (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            last_used_at TEXT NOT NULL,
            source TEXT NOT NULL,
            action_key_hash TEXT NOT NULL UNIQUE,
            goal_norm TEXT NOT NULL,
            app_name TEXT NOT NULL,
            bundle_identifier TEXT,
            window_title_norm TEXT,
            web_app_id TEXT,
            url_scope TEXT,
            screen_hash INTEGER,
            screen_grid_hashes TEXT NOT NULL DEFAULT '[]',
            ocr_simhash INTEGER,
            ax_fingerprint TEXT,
            target_descriptor TEXT,
            target_text_norm TEXT,
            action_kind TEXT NOT NULL,
            action_json TEXT NOT NULL,
            precondition_json TEXT,
            postcondition_json TEXT,
            success_count INTEGER NOT NULL DEFAULT 0,
            failure_count INTEGER NOT NULL DEFAULT 0,
            confidence REAL NOT NULL DEFAULT 0,
            embedding BLOB,
            ttl_policy TEXT NOT NULL DEFAULT 'standard',
            expires_at TEXT
        );
        """) { statement in
            try stepDone(statement)
        }
        try withStatement("""
        CREATE INDEX IF NOT EXISTS idx_action_trajectory_cache_lookup
            ON action_trajectory_cache(action_kind, bundle_identifier, web_app_id, url_scope, confidence DESC, last_used_at DESC);
        """) { statement in
            try stepDone(statement)
        }
        try withStatement("""
        CREATE INDEX IF NOT EXISTS idx_action_trajectory_cache_expiry
            ON action_trajectory_cache(expires_at);
        """) { statement in
            try stepDone(statement)
        }
        try withStatement("""
        CREATE INDEX IF NOT EXISTS idx_action_trajectory_cache_goal
            ON action_trajectory_cache(goal_norm, target_text_norm);
        """) { statement in
            try stepDone(statement)
        }
    }

    @discardableResult
    func promoteActionTrajectoryCache(
        source: ActionTrajectoryCacheSource,
        goal: String,
        state: ActionTrajectoryState,
        targetDescriptor: String? = nil,
        targetText: String? = nil,
        action: ActionTrajectoryCacheAction,
        ttlPolicy: ActionTrajectoryTTLPolicy = .standard,
        verified: Bool = true,
        now: Date = Date(),
        audit: Bool = true
    ) throws -> ActionTrajectoryCacheRow? {
        let prepared = ActionTrajectoryPreparedInput(
            source: source,
            goal: goal,
            state: state,
            targetDescriptor: targetDescriptor,
            targetText: targetText,
            action: action,
            ttlPolicy: ttlPolicy,
            now: now
        )
        guard let prepared else {
            if audit {
                _ = try? appendAudit(AuditEvent(
                    actor: "agent",
                    action: "action_cache.skipped_sensitive",
                    detail: ActionTrajectoryAudit.detail(status: "skipped", reason: .sensitive, goal: goal, state: state, actionKind: action.kind)
                ))
            }
            return nil
        }
        let existing = try actionTrajectoryRow(actionKeyHash: prepared.actionKeyHash)
        let nextSuccess = (existing?.successCount ?? 0) + (verified ? 1 : 0)
        let nextFailure = verified ? max(0, (existing?.failureCount ?? 0) - 1) : (existing?.failureCount ?? 0)
        let baseConfidence = max(existing?.confidence ?? 0.55, verified ? 0.55 : 0.30)
        let nextConfidence = verified ? min(0.98, baseConfidence + 0.12) : baseConfidence
        let createdAt = existing?.createdAt ?? now
        let expiresAt = now.addingTimeInterval(ttlPolicy.duration)

        let sql = """
        INSERT INTO action_trajectory_cache
            (created_at, updated_at, last_used_at, source, action_key_hash, goal_norm,
             app_name, bundle_identifier, window_title_norm, web_app_id, url_scope,
             screen_hash, screen_grid_hashes, ocr_simhash, ax_fingerprint, target_descriptor,
             target_text_norm, action_kind, action_json, precondition_json, postcondition_json,
             success_count, failure_count, confidence, embedding, ttl_policy, expires_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(action_key_hash) DO UPDATE SET
            updated_at = excluded.updated_at,
            last_used_at = excluded.last_used_at,
            source = excluded.source,
            goal_norm = excluded.goal_norm,
            app_name = excluded.app_name,
            bundle_identifier = excluded.bundle_identifier,
            window_title_norm = excluded.window_title_norm,
            web_app_id = excluded.web_app_id,
            url_scope = excluded.url_scope,
            screen_hash = excluded.screen_hash,
            screen_grid_hashes = excluded.screen_grid_hashes,
            ocr_simhash = excluded.ocr_simhash,
            ax_fingerprint = excluded.ax_fingerprint,
            target_descriptor = excluded.target_descriptor,
            target_text_norm = excluded.target_text_norm,
            action_kind = excluded.action_kind,
            action_json = excluded.action_json,
            precondition_json = excluded.precondition_json,
            postcondition_json = excluded.postcondition_json,
            success_count = excluded.success_count,
            failure_count = excluded.failure_count,
            confidence = excluded.confidence,
            embedding = excluded.embedding,
            ttl_policy = excluded.ttl_policy,
            expires_at = excluded.expires_at;
        """
        try withStatement(sql) { statement in
            bindActionCache(ActionTrajectoryDateCodec.string(from: createdAt), at: 1, in: statement)
            bindActionCache(ActionTrajectoryDateCodec.string(from: now), at: 2, in: statement)
            bindActionCache(ActionTrajectoryDateCodec.string(from: now), at: 3, in: statement)
            bindActionCache(source.rawValue, at: 4, in: statement)
            bindActionCache(prepared.actionKeyHash, at: 5, in: statement)
            bindActionCache(prepared.goalNorm, at: 6, in: statement)
            bindActionCache(prepared.appNameNorm, at: 7, in: statement)
            bindActionCache(prepared.bundleIdentifier, at: 8, in: statement)
            bindActionCache(prepared.windowTitleNorm, at: 9, in: statement)
            bindActionCache(prepared.webAppID, at: 10, in: statement)
            bindActionCache(prepared.urlScope, at: 11, in: statement)
            bindActionCache(prepared.screenHash.map { Int64(bitPattern: $0) }, at: 12, in: statement)
            bindActionCache(Self.gridJSON(prepared.screenGridHashes), at: 13, in: statement)
            bindActionCache(prepared.ocrSimhash.map { Int64(bitPattern: $0) }, at: 14, in: statement)
            bindActionCache(prepared.axFingerprint, at: 15, in: statement)
            bindActionCache(prepared.targetDescriptorNorm, at: 16, in: statement)
            bindActionCache(prepared.targetTextNorm, at: 17, in: statement)
            bindActionCache(prepared.action.kind, at: 18, in: statement)
            bindActionCache(prepared.sanitizedActionJSON, at: 19, in: statement)
            bindActionCache(prepared.sanitizedPreconditionJSON, at: 20, in: statement)
            bindActionCache(prepared.sanitizedPostconditionJSON, at: 21, in: statement)
            bindActionCache(Int64(nextSuccess), at: 22, in: statement)
            bindActionCache(Int64(nextFailure), at: 23, in: statement)
            bindActionCache(nextConfidence, at: 24, in: statement)
            bindActionCache(prepared.embedding.map(LocalSemanticVector.blob), at: 25, in: statement)
            bindActionCache(ttlPolicy.rawValue, at: 26, in: statement)
            bindActionCache(ActionTrajectoryDateCodec.string(from: expiresAt), at: 27, in: statement)
            try stepDone(statement)
        }
        guard let row = try actionTrajectoryRow(actionKeyHash: prepared.actionKeyHash) else { return nil }
        if audit {
            _ = try? appendAudit(AuditEvent(
                actor: "agent",
                action: "action_cache.promote",
                detail: ActionTrajectoryAudit.detail(row: row, status: "promoted", reason: .exact)
            ))
        }
        return row
    }

    @discardableResult
    func demoteActionTrajectoryCache(
        id: Int64,
        reason: ActionTrajectoryCacheDecisionReason,
        now: Date = Date(),
        audit: Bool = true
    ) throws -> ActionTrajectoryCacheRow? {
        guard let existing = try actionTrajectoryRow(id: id) else { return nil }
        let nextFailure = existing.failureCount + 1
        let nextConfidence = max(0, existing.confidence - 0.35)
        let expiresAt = (nextConfidence < 0.20 || nextFailure >= 3) ? now : existing.expiresAt
        let sql = """
        UPDATE action_trajectory_cache
        SET updated_at = ?, last_used_at = ?, failure_count = ?, confidence = ?, expires_at = ?
        WHERE id = ?;
        """
        try withStatement(sql) { statement in
            bindActionCache(ActionTrajectoryDateCodec.string(from: now), at: 1, in: statement)
            bindActionCache(ActionTrajectoryDateCodec.string(from: now), at: 2, in: statement)
            bindActionCache(Int64(nextFailure), at: 3, in: statement)
            bindActionCache(nextConfidence, at: 4, in: statement)
            bindActionCache(expiresAt.map(ActionTrajectoryDateCodec.string), at: 5, in: statement)
            bindActionCache(id, at: 6, in: statement)
            try stepDone(statement)
        }
        let row = try actionTrajectoryRow(id: id)
        if audit {
            _ = try? appendAudit(AuditEvent(
                actor: "agent",
                action: "action_cache.demote",
                detail: ActionTrajectoryAudit.detail(row: row ?? existing, status: "demoted", reason: reason)
            ))
        }
        return row
    }

    func lookupActionTrajectoryCache(
        goal: String,
        state: ActionTrajectoryState,
        targetDescriptor: String? = nil,
        targetText: String? = nil,
        actionKind: String? = nil,
        topK: Int = 3,
        now: Date = Date(),
        audit: Bool = true
    ) throws -> ActionTrajectoryCacheLookup {
        guard let query = ActionTrajectoryPreparedQuery(
            goal: goal,
            state: state,
            targetDescriptor: targetDescriptor,
            targetText: targetText,
            actionKind: actionKind
        ) else {
            if audit {
                _ = try? appendAudit(AuditEvent(
                    actor: "agent",
                    action: "action_cache.skipped_sensitive",
                    detail: ActionTrajectoryAudit.detail(status: "skipped", reason: .sensitive, goal: goal, state: state, actionKind: actionKind)
                ))
            }
            return .empty
        }
        try pruneActionTrajectoryCache(now: now)
        let candidates = try actionTrajectoryCandidates(now: now, limit: 200)
            .filter { row in
                guard row.confidence >= 0.20 else { return false }
                if let requested = query.actionKind, row.actionKind != requested { return false }
                return true
            }
        guard !candidates.isEmpty else {
            if audit {
                _ = try? appendAudit(AuditEvent(
                    actor: "agent",
                    action: "action_cache.miss",
                    detail: ActionTrajectoryAudit.detail(status: "miss", reason: .miss, goal: goal, state: state, actionKind: actionKind)
                ))
            }
            return .empty
        }

        let ranked = Self.rankActionTrajectoryCandidates(query: query, rows: candidates, limit: max(topK, 1))
        var hints: [String] = []
        var exactMismatchReason: ActionTrajectoryCacheDecisionReason?
        for scored in ranked {
            let gate = Self.stage2Gate(row: scored.row, query: query)
            switch gate {
            case .exactExecutable:
                let result = ActionTrajectoryCacheLookupResult(
                    row: scored.row,
                    executable: true,
                    reason: .exact,
                    score: scored.score,
                    hint: nil
                )
                try markActionTrajectoryUsed(id: scored.row.id, now: now)
                if audit {
                    _ = try? appendAudit(AuditEvent(
                        actor: "agent",
                        action: "action_cache.hit",
                        detail: ActionTrajectoryAudit.detail(row: scored.row, status: "hit", reason: .exact)
                    ))
                }
                return ActionTrajectoryCacheLookup(
                    executable: result,
                    hints: hints,
                    candidateCount: ranked.count,
                    bypassReason: nil
                )
            case .compatibleHint:
                if let hint = ActionTrajectoryAudit.hint(row: scored.row, score: scored.score) {
                    hints.append(hint)
                }
            case .incompatible(let reason):
                exactMismatchReason = exactMismatchReason ?? reason
            }
        }

        if !hints.isEmpty {
            if audit {
                _ = try? appendAudit(AuditEvent(
                    actor: "agent",
                    action: "action_cache.hit",
                    detail: ActionTrajectoryAudit.detail(status: "semantic", reason: .semanticHint, goal: goal, state: state, actionKind: actionKind, candidateCount: ranked.count)
                ))
            }
            return ActionTrajectoryCacheLookup(
                executable: nil,
                hints: Array(hints.prefix(topK)),
                candidateCount: ranked.count,
                bypassReason: .semanticHint
            )
        }

        if audit {
            _ = try? appendAudit(AuditEvent(
                actor: "agent",
                action: "action_cache.miss",
                detail: ActionTrajectoryAudit.detail(status: "miss", reason: exactMismatchReason ?? .miss, goal: goal, state: state, actionKind: actionKind, candidateCount: ranked.count)
            ))
        }
        return ActionTrajectoryCacheLookup(
            executable: nil,
            hints: [],
            candidateCount: ranked.count,
            bypassReason: exactMismatchReason ?? .miss
        )
    }

    @discardableResult
    func pruneActionTrajectoryCache(now: Date = Date(), maxRows: Int = 5_000) throws -> Int {
        let nowString = ActionTrajectoryDateCodec.string(from: now)
        var deleted = 0
        try withStatement("""
        DELETE FROM action_trajectory_cache
        WHERE (expires_at IS NOT NULL AND expires_at <= ?)
           OR confidence < 0.20
           OR failure_count >= 3;
        """) { statement in
            bindActionCache(nowString, at: 1, in: statement)
            try stepDone(statement)
            deleted += Int(sqlite3_changes(sqlite3_db_handle(statement)))
        }
        try withStatement("""
        DELETE FROM action_trajectory_cache
        WHERE id IN (
            SELECT id FROM action_trajectory_cache
            ORDER BY (success_count * 3 - failure_count * 5) ASC, last_used_at ASC
            LIMIT max((SELECT count(*) FROM action_trajectory_cache) - ?, 0)
        );
        """) { statement in
            bindActionCache(Int64(maxRows), at: 1, in: statement)
            try stepDone(statement)
            deleted += Int(sqlite3_changes(sqlite3_db_handle(statement)))
        }
        return deleted
    }

    func actionTrajectoryCacheRows(limit: Int = 100) throws -> [ActionTrajectoryCacheRow] {
        try actionTrajectoryCandidates(now: Date.distantPast, limit: limit, includeExpired: true)
    }
}

private enum ActionTrajectoryStage2Gate {
    case exactExecutable
    case compatibleHint
    case incompatible(ActionTrajectoryCacheDecisionReason)
}

private struct ActionTrajectoryScoredRow {
    let row: ActionTrajectoryCacheRow
    let score: Double
}

private struct ActionTrajectoryPreparedQuery {
    let goalNorm: String
    let appNameNorm: String
    let bundleIdentifier: String?
    let windowTitleNorm: String?
    let webAppID: String?
    let urlScope: String?
    let screenHash: UInt64?
    let screenGridHashes: [UInt64]
    let ocrSimhash: UInt64?
    let axFingerprint: String?
    let modalPresent: Bool
    let targetDescriptorNorm: String?
    let targetTextNorm: String?
    let actionKind: String?
    let embedding: [Float]?

    init?(
        goal: String,
        state: ActionTrajectoryState,
        targetDescriptor: String?,
        targetText: String?,
        actionKind: String?
    ) {
        guard !PrivacyRules.isSensitive(appName: state.appName, bundleIdentifier: state.bundleIdentifier, windowTitle: state.windowTitle) else {
            return nil
        }
        guard let goalNorm = ActionTrajectoryPrivacy.normalizedStorageText(goal), !goalNorm.isEmpty else { return nil }
        let targetDescriptorNorm = ActionTrajectoryPrivacy.normalizedStorageText(targetDescriptor)
        let targetTextNorm = ActionTrajectoryPrivacy.normalizedStorageText(targetText)
        let targetIdentity = [targetDescriptor, targetText].compactMap { $0 }.joined(separator: " ")
        if !targetIdentity.isEmpty, PrivacyRules.isSensitiveText(targetIdentity) {
            return nil
        }
        self.goalNorm = goalNorm
        self.appNameNorm = ActionTrajectoryPrivacy.normalizedStorageText(state.appName) ?? "unknown"
        self.bundleIdentifier = ActionTrajectoryPrivacy.safeIdentifier(state.bundleIdentifier)
        self.windowTitleNorm = ActionTrajectoryPrivacy.normalizedStorageText(state.windowTitle)
        self.webAppID = ActionTrajectoryPrivacy.safeIdentifier(state.webAppID)
        self.urlScope = ActionTrajectoryPrivacy.safeURLScope(state.urlScope)
        self.screenHash = state.screenHash
        self.screenGridHashes = state.screenGridHashes
        self.ocrSimhash = state.ocrSimhash
        self.axFingerprint = state.axFingerprint
        self.modalPresent = state.modalPresent
        self.targetDescriptorNorm = targetDescriptorNorm
        self.targetTextNorm = targetTextNorm
        self.actionKind = actionKind.map(ActionTrajectoryCacheAction.normalizedKind)
        self.embedding = LocalSemanticVector.vector(for: [goalNorm, targetDescriptorNorm, targetTextNorm, self.actionKind].compactMap { $0 }.joined(separator: " "))
    }
}

private struct ActionTrajectoryPreparedInput {
    let source: ActionTrajectoryCacheSource
    let goalNorm: String
    let appNameNorm: String
    let bundleIdentifier: String?
    let windowTitleNorm: String?
    let webAppID: String?
    let urlScope: String?
    let screenHash: UInt64?
    let screenGridHashes: [UInt64]
    let ocrSimhash: UInt64?
    let axFingerprint: String?
    let targetDescriptorNorm: String?
    let targetTextNorm: String?
    let action: ActionTrajectoryCacheAction
    let sanitizedActionJSON: String
    let sanitizedPreconditionJSON: String?
    let sanitizedPostconditionJSON: String?
    let embedding: [Float]?
    let ttlPolicy: ActionTrajectoryTTLPolicy
    let actionKeyHash: String

    init?(
        source: ActionTrajectoryCacheSource,
        goal: String,
        state: ActionTrajectoryState,
        targetDescriptor: String?,
        targetText: String?,
        action: ActionTrajectoryCacheAction,
        ttlPolicy: ActionTrajectoryTTLPolicy,
        now _: Date
    ) {
        guard !PrivacyRules.isSensitive(appName: state.appName, bundleIdentifier: state.bundleIdentifier, windowTitle: state.windowTitle) else {
            return nil
        }
        guard action.kind != "type", action.kind != "key", action.kind != "drag", action.kind != "open_url" else {
            return nil
        }
        guard let goalNorm = ActionTrajectoryPrivacy.normalizedStorageText(goal), !goalNorm.isEmpty else { return nil }
        let targetDescriptorNorm = ActionTrajectoryPrivacy.normalizedStorageText(targetDescriptor)
        let targetTextNorm = ActionTrajectoryPrivacy.normalizedStorageText(targetText)
        let targetIdentity = [targetDescriptor, targetText].compactMap { $0 }.joined(separator: " ")
        if !targetIdentity.isEmpty, PrivacyRules.isSensitiveText(targetIdentity) {
            return nil
        }
        guard let sanitizedActionJSON = ActionTrajectoryPrivacy.sanitizedJSON(action.json, actionKind: action.kind) else {
            return nil
        }
        self.source = source
        self.goalNorm = goalNorm
        self.appNameNorm = ActionTrajectoryPrivacy.normalizedStorageText(state.appName) ?? "unknown"
        self.bundleIdentifier = ActionTrajectoryPrivacy.safeIdentifier(state.bundleIdentifier)
        self.windowTitleNorm = ActionTrajectoryPrivacy.normalizedStorageText(state.windowTitle)
        self.webAppID = ActionTrajectoryPrivacy.safeIdentifier(state.webAppID)
        self.urlScope = ActionTrajectoryPrivacy.safeURLScope(state.urlScope)
        self.screenHash = state.screenHash
        self.screenGridHashes = state.screenGridHashes
        self.ocrSimhash = state.ocrSimhash
        self.axFingerprint = state.axFingerprint
        self.targetDescriptorNorm = targetDescriptorNorm
        self.targetTextNorm = targetTextNorm
        self.action = action
        self.sanitizedActionJSON = sanitizedActionJSON
        self.sanitizedPreconditionJSON = action.preconditionJSON.flatMap { ActionTrajectoryPrivacy.sanitizedJSON($0, actionKind: action.kind) }
        self.sanitizedPostconditionJSON = action.postconditionJSON.flatMap { ActionTrajectoryPrivacy.sanitizedJSON($0, actionKind: action.kind) }
        self.embedding = LocalSemanticVector.vector(for: [goalNorm, targetDescriptorNorm, targetTextNorm, action.kind].compactMap { $0 }.joined(separator: " "))
        self.ttlPolicy = ttlPolicy
        // Pre-computed into locals + explicit [String] so the type-checker resolves each
        // element in constant time. Inline, this 16-element heterogeneous literal (with
        // radix-16 transforms) blew the type-check time budget on the CI runner (compiled
        // fine locally on a fast M1). Same components/order/separator/hash → identical keys.
        let hexScreenHash = screenHash.map { String($0, radix: 16) } ?? ""
        let hexGridHashes = screenGridHashes.map { String($0, radix: 16) }.joined(separator: ",")
        let hexOcrSimhash = ocrSimhash.map { String($0, radix: 16) } ?? ""
        let keyComponents: [String] = [
            "v2",
            source.rawValue,
            goalNorm,
            appNameNorm,
            bundleIdentifier ?? "",
            windowTitleNorm ?? "",
            webAppID ?? "",
            urlScope ?? "",
            hexScreenHash,
            hexGridHashes,
            hexOcrSimhash,
            axFingerprint ?? "",
            targetDescriptorNorm ?? "",
            targetTextNorm ?? "",
            action.kind,
            sanitizedActionJSON,
        ]
        self.actionKeyHash = ActionTrajectoryPrivacy.sha256Hex(keyComponents.joined(separator: "\u{1f}"))
    }
}

private enum ActionTrajectoryPrivacy {
    static func normalizedStorageText(_ text: String?) -> String? {
        guard let normalized = normalizedPlainText(text) else { return nil }
        return privateDescriptor(field: "text", normalized: normalized)
    }

    static func safeIdentifier(_ text: String?) -> String? {
        guard let normalized = normalizedPlainText(text) else { return nil }
        return "id_\(AuditIdentity.hash(normalized))_chars_\(normalized.count)"
    }

    static func safeURLScope(_ text: String?) -> String? {
        guard let scope = ActionTrajectoryState.urlScope(from: text),
              let normalized = normalizedPlainText(scope) else {
            return nil
        }
        return "url_\(AuditIdentity.hash(normalized))_chars_\(normalized.count)"
    }

    private static func normalizedPlainText(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        guard !PrivacyRules.isSensitiveText(text) else { return nil }
        let redacted = PIIDetector.redact(text, includeNames: false, highConfidenceOnly: false).redacted
        let keywordRedacted = PrivacyRules.redactingSensitiveKeywords(in: redacted)
        return SemanticEmbeddingText.normalized(keywordRedacted).nilIfEmpty
    }

    private static func privateDescriptor(field: String, normalized: String) -> String {
        "\(field)Hash=\(AuditIdentity.hash(normalized)) \(field)Chars=\(normalized.count)"
    }

    static func sanitizedJSON(_ json: String, actionKind: String) -> String? {
        guard actionKind != "type" else { return nil }
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return normalizedPlainText(json).map { #"{"valueHash":"\#(AuditIdentity.hash($0))","valueChars":\#($0.count)}"# }
        }
        let scrubbed = scrub(object, path: [])
        guard JSONSerialization.isValidJSONObject(scrubbed),
              let encoded = try? JSONSerialization.data(withJSONObject: scrubbed, options: [.sortedKeys]),
              let rendered = String(data: encoded, encoding: .utf8) else {
            return nil
        }
        return rendered
    }

    static func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func scrub(_ value: Any, path: [String]) -> Any {
        if let dict = value as? [String: Any] {
            return dict.reduce(into: [String: Any]()) { result, item in
                let key = item.key
                let normalizedKey = key.lowercased()
                if ActionTrajectoryPrivateFields.contains(normalizedKey) {
                    result[key] = ["privateText": "excluded"]
                } else if ActionTrajectoryHashedTextFields.contains(normalizedKey),
                          let string = item.value as? String {
                    result[key] = ["textHash": AuditIdentity.hash(string), "textChars": string.count]
                } else if normalizedKey == "url" || normalizedKey == "url_string" || normalizedKey == "href" {
                    if let scope = ActionTrajectoryState.urlScope(from: item.value as? String) {
                        result[key] = ["urlScopeHash": AuditIdentity.hash(scope), "urlScopeChars": scope.count]
                    } else {
                        result[key] = ["urlScopeHash": "none", "urlScopeChars": 0]
                    }
                } else {
                    result[key] = scrub(item.value, path: path + [key])
                }
            }
        }
        if let array = value as? [Any] {
            return array.map { scrub($0, path: path) }
        }
        if let string = value as? String {
            if let scope = ActionTrajectoryState.urlScope(from: string), string.contains("://") {
                return ["urlScopeHash": AuditIdentity.hash(scope), "urlScopeChars": scope.count]
            }
            if PrivacyRules.isSensitiveText(string) || PIIDetector.containsHighConfidencePII(string) {
                return ["textHash": AuditIdentity.hash(string), "textChars": string.count]
            }
            return string
        }
        return value
    }
}

private let ActionTrajectoryPrivateFields: Set<String> = [
    "text",
    "typedtext",
    "typed_text",
    "texttotype",
    "text_to_type",
    "privatetext",
    "private_text",
    "password",
    "value"
]

private let ActionTrajectoryHashedTextFields: Set<String> = [
    "target",
    "target_text",
    "targettext",
    "target_descriptor",
    "targetdescriptor",
    "label",
    "anchor",
    "ocr_anchor",
    "ocranchor"
]

private enum ActionTrajectoryAudit {
    static func detail(
        row: ActionTrajectoryCacheRow,
        status: String,
        reason: ActionTrajectoryCacheDecisionReason,
        candidateCount: Int? = nil
    ) -> String {
        var parts = [
            "status=\(AuditIdentity.safeToken(status))",
            "reason=\(reason.rawValue)",
            "rowHash=\(AuditIdentity.hash(row.actionKeyHash))",
            "goalHash=\(AuditIdentity.hash(row.goalNorm))",
            "goalChars=\(row.goalNorm.count)",
            "appHash=\(AuditIdentity.hash(row.appName))",
            "bundleHash=\(AuditIdentity.hash(row.bundleIdentifier))",
            "windowHash=\(AuditIdentity.hash(row.windowTitleNorm))",
            "targetHash=\(AuditIdentity.hash(row.targetTextNorm ?? row.targetDescriptor))",
            "kind=\(AuditIdentity.safeToken(row.actionKind))",
            "successes=\(row.successCount)",
            "failures=\(row.failureCount)",
            String(format: "confidence=%.2f", row.confidence),
        ]
        if let candidateCount { parts.append("candidates=\(candidateCount)") }
        return parts.joined(separator: " ")
    }

    static func detail(
        status: String,
        reason: ActionTrajectoryCacheDecisionReason,
        goal: String,
        state: ActionTrajectoryState,
        actionKind: String?,
        candidateCount: Int? = nil
    ) -> String {
        var parts = [
            "status=\(AuditIdentity.safeToken(status))",
            "reason=\(reason.rawValue)",
            AuditIdentity.descriptor("goal", goal),
            "appHash=\(AuditIdentity.hash(state.appName))",
            "bundleHash=\(AuditIdentity.hash(state.bundleIdentifier))",
            "windowHash=\(AuditIdentity.hash(state.windowTitle))",
            "kind=\(AuditIdentity.safeToken(actionKind ?? "unknown"))",
        ]
        if let candidateCount { parts.append("candidates=\(candidateCount)") }
        return parts.joined(separator: " ")
    }

    static func hint(row: ActionTrajectoryCacheRow, score: Double) -> String? {
        guard row.successCount > 0 else { return nil }
        return [
            "Prior verified \(AuditIdentity.safeToken(row.actionKind)) action may apply.",
            "rowHash=\(AuditIdentity.hash(row.actionKeyHash))",
            "targetHash=\(AuditIdentity.hash(row.targetTextNorm ?? row.targetDescriptor))",
            String(format: "confidence=%.2f", row.confidence),
            String(format: "score=%.2f", score),
        ].joined(separator: " ")
    }
}

private extension CascadeStore {
    static func rankActionTrajectoryCandidates(
        query: ActionTrajectoryPreparedQuery,
        rows: [ActionTrajectoryCacheRow],
        limit: Int
    ) -> [ActionTrajectoryScoredRow] {
        let lexical = rows.sorted { lhs, rhs in
            lexicalScore(query: query, row: lhs) == lexicalScore(query: query, row: rhs)
                ? lhs.id > rhs.id
                : lexicalScore(query: query, row: lhs) > lexicalScore(query: query, row: rhs)
        }.map(\.id)
        let vector = rows.sorted { lhs, rhs in
            vectorScore(query: query, row: lhs) == vectorScore(query: query, row: rhs)
                ? lhs.id > rhs.id
                : vectorScore(query: query, row: lhs) > vectorScore(query: query, row: rhs)
        }.map(\.id)
        let structured = rows.sorted { lhs, rhs in
            structuredScore(query: query, row: lhs) == structuredScore(query: query, row: rhs)
                ? lhs.id > rhs.id
                : structuredScore(query: query, row: lhs) > structuredScore(query: query, row: rhs)
        }.map(\.id)
        let fused = RankFusion.reciprocalRankFusion([
            .init(.lexical, ids: lexical),
            .init(.vector, ids: vector),
            .init(.structured, ids: structured),
        ], limit: limit)
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        return fused.compactMap { fusedCandidate in
            guard let row = byID[fusedCandidate.id] else { return nil }
            let score = fusedCandidate.finalScore
                + lexicalScore(query: query, row: row)
                + vectorScore(query: query, row: row)
                + structuredScore(query: query, row: row)
                + min(row.confidence, 1.0)
            return ActionTrajectoryScoredRow(row: row, score: score)
        }
    }

    static func stage2Gate(row: ActionTrajectoryCacheRow, query: ActionTrajectoryPreparedQuery) -> ActionTrajectoryStage2Gate {
        if query.modalPresent { return .incompatible(.modalPresent) }
        guard identityCompatible(row: row, query: query) else { return .incompatible(.wrongApp) }
        if let rowURL = row.urlScope, let queryURL = query.urlScope, rowURL != queryURL {
            return .incompatible(.wrongURLScope)
        }
        if row.urlScope == nil, query.urlScope == nil,
           let rowWindow = row.windowTitleNorm, let queryWindow = query.windowTitleNorm,
           !rowWindow.isEmpty, !queryWindow.isEmpty, rowWindow != queryWindow {
            return .incompatible(.wrongWindow)
        }
        let screenCompatible = screenCompatible(row: row, query: query)
        let anchorCompatible = anchorCompatible(row: row, query: query)
        if !screenCompatible { return .incompatible(.wrongScreen) }
        if requiresAnchor(row.actionKind), !anchorCompatible { return .incompatible(.missingAnchor) }
        guard row.successCount > 0, row.confidence >= 0.65 else { return .compatibleHint }
        guard autoExecutable(row: row, query: query, anchorCompatible: anchorCompatible) else {
            return .compatibleHint
        }
        return .exactExecutable
    }

    static func lexicalScore(query: ActionTrajectoryPreparedQuery, row: ActionTrajectoryCacheRow) -> Double {
        let lhs = tokenSet([query.goalNorm, query.targetDescriptorNorm, query.targetTextNorm, query.actionKind].compactMap { $0 }.joined(separator: " "))
        let rhs = tokenSet([row.goalNorm, row.targetDescriptor, row.targetTextNorm, row.actionKind].compactMap { $0 }.joined(separator: " "))
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        let intersection = lhs.intersection(rhs).count
        let union = lhs.union(rhs).count
        return union == 0 ? 0 : Double(intersection) / Double(union)
    }

    static func vectorScore(query: ActionTrajectoryPreparedQuery, row: ActionTrajectoryCacheRow) -> Double {
        guard let queryEmbedding = query.embedding, let rowEmbedding = row.embedding else { return 0 }
        return max(0, Double(LocalSemanticVector.cosine(queryEmbedding, rowEmbedding)))
    }

    static func structuredScore(query: ActionTrajectoryPreparedQuery, row: ActionTrajectoryCacheRow) -> Double {
        var score = 0.0
        if identityCompatible(row: row, query: query) { score += 0.35 }
        if query.actionKind == nil || query.actionKind == row.actionKind { score += 0.25 }
        if row.targetDescriptor != nil && row.targetDescriptor == query.targetDescriptorNorm { score += 0.20 }
        if row.targetTextNorm != nil && row.targetTextNorm == query.targetTextNorm { score += 0.15 }
        if screenCompatible(row: row, query: query) { score += 0.15 }
        return score
    }

    static func identityCompatible(row: ActionTrajectoryCacheRow, query: ActionTrajectoryPreparedQuery) -> Bool {
        if let rowWeb = row.webAppID, let queryWeb = query.webAppID {
            return rowWeb == queryWeb
        }
        if let rowURL = row.urlScope, let queryURL = query.urlScope {
            return rowURL == queryURL
        }
        if let rowBundle = row.bundleIdentifier, let queryBundle = query.bundleIdentifier {
            return rowBundle == queryBundle
        }
        return row.appName == query.appNameNorm
    }

    static func screenCompatible(row: ActionTrajectoryCacheRow, query: ActionTrajectoryPreparedQuery) -> Bool {
        if row.actionKind == "open_app" || row.actionKind == "open_url" { return true }
        if let rowHash = row.screenHash, let queryHash = query.screenHash {
            return hammingDistance(rowHash, queryHash) <= 8
        }
        if !row.screenGridHashes.isEmpty, !query.screenGridHashes.isEmpty {
            return duplicateGrid(row.screenGridHashes, query.screenGridHashes, threshold: 10)
        }
        return row.axFingerprint != nil && row.axFingerprint == query.axFingerprint
    }

    static func anchorCompatible(row: ActionTrajectoryCacheRow, query: ActionTrajectoryPreparedQuery) -> Bool {
        if let rowAX = row.axFingerprint, let queryAX = query.axFingerprint, rowAX == queryAX { return true }
        if let rowTarget = row.targetDescriptor, let queryTarget = query.targetDescriptorNorm, rowTarget == queryTarget { return true }
        if let rowText = row.targetTextNorm, let queryText = query.targetTextNorm, rowText == queryText { return true }
        if let rowOCR = row.ocrSimhash, let queryOCR = query.ocrSimhash {
            return hammingDistance(rowOCR, queryOCR) <= 6
        }
        return false
    }

    static func autoExecutable(row: ActionTrajectoryCacheRow, query: ActionTrajectoryPreparedQuery, anchorCompatible: Bool) -> Bool {
        switch row.actionKind {
        case "open_app", "scroll":
            return row.goalNorm == query.goalNorm
        case "click":
            return anchorCompatible && row.targetDescriptor != nil && query.targetDescriptorNorm != nil
        default:
            return false
        }
    }

    static func requiresAnchor(_ actionKind: String) -> Bool {
        actionKind == "click"
    }

    static func tokenSet(_ text: String) -> Set<String> {
        Set(SemanticEmbeddingText.normalized(text).split(separator: " ").map(String.init))
    }

    static func hammingDistance(_ lhs: UInt64, _ rhs: UInt64) -> Int {
        (lhs ^ rhs).nonzeroBitCount
    }

    static func duplicateGrid(_ lhs: [UInt64], _ rhs: [UInt64], threshold: Int) -> Bool {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return false }
        let total = zip(lhs, rhs).reduce(0) { partial, pair in
            partial + hammingDistance(pair.0, pair.1)
        }
        return total <= threshold * lhs.count
    }

    func actionTrajectoryCandidates(now: Date, limit: Int, includeExpired: Bool = false) throws -> [ActionTrajectoryCacheRow] {
        let sql = """
        SELECT id, created_at, updated_at, last_used_at, source, action_key_hash,
               goal_norm, app_name, bundle_identifier, window_title_norm, web_app_id,
               url_scope, screen_hash, screen_grid_hashes, ocr_simhash, ax_fingerprint,
               target_descriptor, target_text_norm, action_kind, action_json,
               precondition_json, postcondition_json, success_count, failure_count,
               confidence, embedding, ttl_policy, expires_at
        FROM action_trajectory_cache
        WHERE (? = 1 OR expires_at IS NULL OR expires_at > ?)
        ORDER BY confidence DESC, last_used_at DESC
        LIMIT ?;
        """
        return try withStatement(sql) { statement in
            bindActionCache(includeExpired ? Int64(1) : Int64(0), at: 1, in: statement)
            bindActionCache(ActionTrajectoryDateCodec.string(from: now), at: 2, in: statement)
            bindActionCache(Int64(limit), at: 3, in: statement)
            var rows: [ActionTrajectoryCacheRow] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(Self.decodeActionTrajectoryRow(statement))
            }
            return rows
        }
    }

    func actionTrajectoryRow(id: Int64) throws -> ActionTrajectoryCacheRow? {
        try withStatement(Self.actionTrajectorySelectSQL(whereClause: "id = ?")) { statement in
            bindActionCache(id, at: 1, in: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return Self.decodeActionTrajectoryRow(statement)
        }
    }

    func actionTrajectoryRow(actionKeyHash: String) throws -> ActionTrajectoryCacheRow? {
        try withStatement(Self.actionTrajectorySelectSQL(whereClause: "action_key_hash = ?")) { statement in
            bindActionCache(actionKeyHash, at: 1, in: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return Self.decodeActionTrajectoryRow(statement)
        }
    }

    func markActionTrajectoryUsed(id: Int64, now: Date) throws {
        try withStatement("UPDATE action_trajectory_cache SET last_used_at = ? WHERE id = ?;") { statement in
            bindActionCache(ActionTrajectoryDateCodec.string(from: now), at: 1, in: statement)
            bindActionCache(id, at: 2, in: statement)
            try stepDone(statement)
        }
    }

    static func actionTrajectorySelectSQL(whereClause: String) -> String {
        """
        SELECT id, created_at, updated_at, last_used_at, source, action_key_hash,
               goal_norm, app_name, bundle_identifier, window_title_norm, web_app_id,
               url_scope, screen_hash, screen_grid_hashes, ocr_simhash, ax_fingerprint,
               target_descriptor, target_text_norm, action_kind, action_json,
               precondition_json, postcondition_json, success_count, failure_count,
               confidence, embedding, ttl_policy, expires_at
        FROM action_trajectory_cache
        WHERE \(whereClause)
        LIMIT 1;
        """
    }

    static func decodeActionTrajectoryRow(_ statement: OpaquePointer) -> ActionTrajectoryCacheRow {
        ActionTrajectoryCacheRow(
            id: sqlite3_column_int64(statement, 0),
            createdAt: ActionTrajectoryDateCodec.date(from: text(statement, 1)) ?? Date(),
            updatedAt: ActionTrajectoryDateCodec.date(from: text(statement, 2)) ?? Date(),
            lastUsedAt: ActionTrajectoryDateCodec.date(from: text(statement, 3)) ?? Date(),
            source: ActionTrajectoryCacheSource(rawValue: text(statement, 4) ?? "") ?? .assist,
            actionKeyHash: text(statement, 5) ?? "",
            goalNorm: text(statement, 6) ?? "",
            appName: text(statement, 7) ?? "",
            bundleIdentifier: text(statement, 8),
            windowTitleNorm: text(statement, 9),
            webAppID: text(statement, 10),
            urlScope: text(statement, 11),
            screenHash: int64(statement, 12).map { UInt64(bitPattern: $0) },
            screenGridHashes: gridValues(from: text(statement, 13)),
            ocrSimhash: int64(statement, 14).map { UInt64(bitPattern: $0) },
            axFingerprint: text(statement, 15),
            targetDescriptor: text(statement, 16),
            targetTextNorm: text(statement, 17),
            actionKind: text(statement, 18) ?? "",
            actionJSON: text(statement, 19) ?? "{}",
            preconditionJSON: text(statement, 20),
            postconditionJSON: text(statement, 21),
            successCount: Int(sqlite3_column_int64(statement, 22)),
            failureCount: Int(sqlite3_column_int64(statement, 23)),
            confidence: sqlite3_column_double(statement, 24),
            embedding: blob(statement, 25).map(LocalSemanticVector.vector),
            ttlPolicy: ActionTrajectoryTTLPolicy(rawValue: text(statement, 26) ?? "") ?? .standard,
            expiresAt: ActionTrajectoryDateCodec.date(from: text(statement, 27))
        )
    }

    static func gridJSON(_ values: [UInt64]) -> String {
        let encoded = values.map { String($0) }
        guard let data = try? JSONSerialization.data(withJSONObject: encoded, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return string
    }

    static func gridValues(from json: String?) -> [UInt64] {
        guard let json, let data = json.data(using: .utf8),
              let values = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            return []
        }
        return values.compactMap(UInt64.init)
    }

    func bindActionCache(_ value: String?, at index: Int32, in statement: OpaquePointer) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    func bindActionCache(_ value: Int64?, at index: Int32, in statement: OpaquePointer) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_int64(statement, index, value)
    }

    func bindActionCache(_ value: Double?, at index: Int32, in statement: OpaquePointer) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_double(statement, index, value)
    }

    func bindActionCache(_ value: Data?, at index: Int32, in statement: OpaquePointer) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        _ = value.withUnsafeBytes { buffer in
            sqlite3_bind_blob(
                statement,
                index,
                buffer.baseAddress,
                Int32(value.count),
                unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            )
        }
    }

    static func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: cString)
    }

    static func int64(_ statement: OpaquePointer, _ index: Int32) -> Int64? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(statement, index)
    }

    static func blob(_ statement: OpaquePointer, _ index: Int32) -> Data? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let bytes = sqlite3_column_blob(statement, index) else {
            return nil
        }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
    }
}

private enum ActionTrajectoryDateCodec {
    static func string(from date: Date) -> String {
        formatter().string(from: date)
    }

    static func date(from string: String?) -> Date? {
        guard let string else { return nil }
        return formatter().date(from: string)
    }

    private static func formatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
