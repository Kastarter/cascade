import CascadeMemory
import CoreGraphics
import Foundation
import SQLite3

public enum GroundingAuditExporterError: Error, Equatable, CustomStringConvertible {
    case liveDatabaseRejected(String)
    case openFailed(String)
    case queryFailed(String)

    public var description: String {
        switch self {
        case .liveDatabaseRejected(let path):
            return "Refusing to open live Cascade database at \(path). Pass a closed/checkpointed copy instead."
        case .openFailed(let message):
            return "SQLite open failed: \(message)"
        case .queryFailed(let message):
            return "SQLite query failed: \(message)"
        }
    }
}

public struct GroundingAuditExporter: Sendable {
    public struct Options: Equatable, Sendable {
        public let nearestContextWindow: TimeInterval
        public let clickLabelWindow: TimeInterval
        public let verifierWindow: TimeInterval
        public let frameRoot: URL?
        public let targetTextByHash: [String: String]

        public init(
            nearestContextWindow: TimeInterval = 3,
            clickLabelWindow: TimeInterval = 8,
            verifierWindow: TimeInterval = 8,
            frameRoot: URL? = nil,
            targetTextByHash: [String: String] = [:]
        ) {
            self.nearestContextWindow = nearestContextWindow
            self.clickLabelWindow = clickLabelWindow
            self.verifierWindow = verifierWindow
            self.frameRoot = frameRoot
            self.targetTextByHash = targetTextByHash
        }
    }

    public init() {}

    public func export(databasePath: URL, outputURL: URL, options: Options = Options()) throws -> [GroundingBenchmarkCase] {
        let rows = try cases(databasePath: databasePath, options: options)
        try GroundingBenchmarkJSONL.write(rows, to: outputURL)
        return rows
    }

    public func cases(databasePath: URL, options: Options = Options()) throws -> [GroundingBenchmarkCase] {
        try Self.rejectLiveDatabase(databasePath)
        let db = try ReadOnlyDatabase(url: databasePath)
        let audits = try db.auditRows()
        let contexts = try db.safeFrameContexts()
        let clicks = try db.clickRows()
        let positiveVerifierRows = audits.filter { $0.action == "grounding.verifier" && $0.auditValue("verdict") == "accept" }

        return audits.compactMap { audit in
            guard audit.action == "agent.ground.miss" || audit.action == "grounding.verifier",
                  let targetHash = Self.targetHash(from: audit),
                  let context = Self.nearestContext(
                      to: audit.capturedMilliseconds,
                      in: contexts,
                      window: options.nearestContextWindow
                  ),
                  !PrivacyRules.isSensitive(appName: context.appName, bundleIdentifier: context.bundleIdentifier, windowTitle: nil),
                  let framePath = Self.resolvedFramePath(context.imagePath, frameRoot: options.frameRoot),
                  FileManager.default.fileExists(atPath: framePath) else {
                return nil
            }

            let expected = Self.verifiedClickPoint(
                after: audit,
                targetHash: targetHash,
                context: context,
                clicks: clicks,
                positiveVerifierRows: positiveVerifierRows,
                clickLabelWindow: options.clickLabelWindow,
                verifierWindow: options.verifierWindow
            )
            return GroundingBenchmarkCase(
                caseID: "audit-\(audit.id)",
                framePath: framePath,
                targetText: options.targetTextByHash[targetHash],
                targetHash: targetHash,
                expectedBoxOrPoint: expected,
                appBundle: context.bundleIdentifier,
                appName: context.appName,
                outcome: Self.outcome(for: audit, expected: expected),
                sourceAuditEventID: audit.id,
                contextID: context.id
            )
        }
    }

    public static func loadTargetSidecar(from url: URL?) throws -> [String: String] {
        guard let url else { return [:] }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([String: String].self, from: data)
    }

    public static func rejectLiveDatabase(_ url: URL) throws {
        let live = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cascade/Cascade.sqlite")
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        let supplied = url
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        guard supplied != live else { throw GroundingAuditExporterError.liveDatabaseRejected(supplied) }
    }

    private static func targetHash(from audit: AuditRow) -> String? {
        let keys: [String]
        if audit.action == "agent.ground.miss" {
            keys = ["missedTargetHash", "targetHash", "selectedCandidateHash", "candidateHash"]
        } else {
            keys = ["targetHash", "missedTargetHash", "selectedCandidateHash", "candidateHash"]
        }
        return keys.lazy.compactMap { audit.auditValue($0) }.first
    }

    private static func outcome(for audit: AuditRow, expected: GroundingBenchmarkExpected?) -> GroundingBenchmarkOutcome {
        if expected != nil { return .accept }
        if audit.action == "agent.ground.miss" { return .unlabeled }
        switch audit.auditValue("verdict") {
        case "reject", "abstain":
            return .reject
        case "accept":
            return .unlabeled
        default:
            return .unlabeled
        }
    }

    private static func nearestContext(
        to capturedMilliseconds: Int64,
        in contexts: [ContextRow],
        window: TimeInterval
    ) -> ContextRow? {
        let allowed = Int64((window * 1000).rounded())
        return contexts
            .filter { abs($0.capturedMilliseconds - capturedMilliseconds) <= allowed }
            .min {
                let left = abs($0.capturedMilliseconds - capturedMilliseconds)
                let right = abs($1.capturedMilliseconds - capturedMilliseconds)
                if left != right { return left < right }
                return $0.id < $1.id
            }
    }

    private static func resolvedFramePath(_ rawPath: String, frameRoot: URL?) -> String? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("/") { return trimmed }
        return (frameRoot ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            .appendingPathComponent(trimmed)
            .standardizedFileURL
            .path
    }

    private static func verifiedClickPoint(
        after audit: AuditRow,
        targetHash: String,
        context: ContextRow,
        clicks: [ClickRow],
        positiveVerifierRows: [AuditRow],
        clickLabelWindow: TimeInterval,
        verifierWindow: TimeInterval
    ) -> GroundingBenchmarkExpected? {
        let clickMax = audit.capturedMilliseconds + Int64((clickLabelWindow * 1000).rounded())
        guard let click = clicks.first(where: { click in
            click.capturedMilliseconds >= audit.capturedMilliseconds
                && click.capturedMilliseconds <= clickMax
                && click.matches(context: context)
        }) else { return nil }

	        let verifierMax = click.capturedMilliseconds + Int64((verifierWindow * 1000).rounded())
	        let hasPositiveVerifier = positiveVerifierRows.contains { row in
	            guard let verifierTargetHash = Self.targetHash(from: row) else { return false }
	            return row.capturedMilliseconds >= click.capturedMilliseconds
	                && row.capturedMilliseconds <= verifierMax
	                && targetHash == verifierTargetHash
	        }
        guard hasPositiveVerifier else { return nil }
        return .point(CGPoint(x: click.x, y: click.y), radius: 24)
    }
}

private struct AuditRow: Equatable {
    let id: Int64
    let createdAt: String
    let capturedMilliseconds: Int64
    let action: String
    let detail: String

    func auditValue(_ key: String) -> String? {
        for token in detail.split(separator: " ") {
            let pieces = token.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pieces.count == 2, pieces[0] == key else { continue }
            let value = String(pieces[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        return nil
    }
}

private struct ContextRow: Equatable {
    let id: Int64
    let capturedMilliseconds: Int64
    let appName: String
    let bundleIdentifier: String?
    let imagePath: String
}

private struct ClickRow: Equatable {
    let capturedMilliseconds: Int64
    let x: Double
    let y: Double
    let appName: String
    let bundleIdentifier: String?

    func matches(context: ContextRow) -> Bool {
        if let bundleIdentifier, let contextBundle = context.bundleIdentifier {
            return bundleIdentifier == contextBundle
        }
        return appName == context.appName
    }
}

private final class ReadOnlyDatabase {
    private let db: OpaquePointer?

    init(url: URL) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        let status = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard status == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let handle { sqlite3_close(handle) }
            throw GroundingAuditExporterError.openFailed(message)
        }
        self.db = handle
        try exec("PRAGMA query_only = ON;")
    }

    deinit {
        sqlite3_close(db)
    }

    func auditRows() throws -> [AuditRow] {
        try query("""
        SELECT id, created_at, action, detail
        FROM audit_event
        WHERE action IN ('agent.ground.miss', 'grounding.verifier')
        ORDER BY created_at ASC, id ASC;
        """) { statement in
            let createdAt = text(statement, 1) ?? ""
            return AuditRow(
                id: sqlite3_column_int64(statement, 0),
                createdAt: createdAt,
                capturedMilliseconds: Self.capturedMilliseconds(from: createdAt),
                action: text(statement, 2) ?? "",
                detail: text(statement, 3) ?? ""
            )
        }
    }

    func safeFrameContexts() throws -> [ContextRow] {
        try query("""
        SELECT id, captured_at, captured_ms, app_name, bundle_identifier, image_path
        FROM recorded_context
        WHERE image_path IS NOT NULL
          AND image_path <> ''
          AND COALESCE(safe_to_show, 1) = 1
        ORDER BY captured_ms ASC, id ASC;
        """) { statement in
            let capturedAt = text(statement, 1) ?? ""
            return ContextRow(
                id: sqlite3_column_int64(statement, 0),
                capturedMilliseconds: int64(statement, 2) ?? Self.capturedMilliseconds(from: capturedAt),
                appName: text(statement, 3) ?? "Unknown",
                bundleIdentifier: text(statement, 4),
                imagePath: text(statement, 5) ?? ""
            )
        }
    }

    func clickRows() throws -> [ClickRow] {
        try query("""
        SELECT captured_at, captured_ms, x, y, app_name, bundle_identifier
        FROM input_event
        WHERE kind IN ('click', 'doubleClick', 'rightClick')
          AND x IS NOT NULL
          AND y IS NOT NULL
        ORDER BY captured_ms ASC, id ASC;
        """) { statement in
            let capturedAt = text(statement, 0) ?? ""
            return ClickRow(
                capturedMilliseconds: int64(statement, 1) ?? Self.capturedMilliseconds(from: capturedAt),
                x: sqlite3_column_double(statement, 2),
                y: sqlite3_column_double(statement, 3),
                appName: text(statement, 4) ?? "Unknown",
                bundleIdentifier: text(statement, 5)
            )
        }
    }

    private func exec(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(db, sql, nil, nil, &error)
        guard status == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? sqliteMessage
            sqlite3_free(error)
            throw GroundingAuditExporterError.queryFailed(message)
        }
    }

    private func query<T>(_ sql: String, decode: (OpaquePointer) throws -> T) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw GroundingAuditExporterError.queryFailed(sqliteMessage)
        }
        defer { sqlite3_finalize(statement) }

        var rows: [T] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_ROW {
                rows.append(try decode(statement!))
            } else if status == SQLITE_DONE {
                return rows
            } else {
                throw GroundingAuditExporterError.queryFailed(sqliteMessage)
            }
        }
    }

    private var sqliteMessage: String {
        guard let message = sqlite3_errmsg(db) else { return "unknown" }
        return String(cString: message)
    }

    private static func capturedMilliseconds(from string: String) -> Int64 {
        let date = DateParsers.date(from: string) ?? Date(timeIntervalSince1970: 0)
        return Int64((date.timeIntervalSince1970 * 1000).rounded())
    }
}

private enum DateParsers {
    static func date(from string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        return ISO8601DateFormatter().date(from: string)
    }
}

private func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
    guard let raw = sqlite3_column_text(statement, index) else { return nil }
    return String(cString: raw)
}

private func int64(_ statement: OpaquePointer, _ index: Int32) -> Int64? {
    sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, index)
}
