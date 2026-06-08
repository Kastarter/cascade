import Foundation
import SQLite3

public enum ContextSource: String, Codable, Sendable {
    case screen
    case app
    case accessibility
    case input
    case system
}

public struct RecordedContext: Identifiable, Codable, Equatable, Sendable {
    public let id: Int64
    public let capturedAt: Date
    public let source: ContextSource
    public let appName: String
    public let bundleIdentifier: String?
    public let windowTitle: String?
    public let ocrText: String?
    public let metadataJSON: String?

    public init(
        id: Int64 = 0,
        capturedAt: Date = Date(),
        source: ContextSource,
        appName: String,
        bundleIdentifier: String? = nil,
        windowTitle: String? = nil,
        ocrText: String? = nil,
        metadataJSON: String? = nil
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.source = source
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.windowTitle = windowTitle
        self.ocrText = ocrText
        self.metadataJSON = metadataJSON
    }
}

public struct AuditEvent: Identifiable, Codable, Equatable, Sendable {
    public let id: Int64
    public let createdAt: Date
    public let actor: String
    public let action: String
    public let detail: String

    public init(id: Int64 = 0, createdAt: Date = Date(), actor: String, action: String, detail: String) {
        self.id = id
        self.createdAt = createdAt
        self.actor = actor
        self.action = action
        self.detail = detail
    }
}

public enum CascadeStoreError: Error, LocalizedError {
    case openFailed(String)
    case sqlite(String)
    case prepareFailed(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let message): "Open database: \(message)"
        case .sqlite(let message): "SQLite error: \(message)"
        case .prepareFailed(let message): "Prepare statement: \(message)"
        }
    }
}

public actor CascadeStore {
    private let connection: SQLiteConnection
    private let path: String

    public init(path: String? = nil) throws {
        self.path = path ?? Self.defaultDatabasePath()
        try Self.ensureParentDirectory(for: self.path)

        var handle: OpaquePointer?
        guard sqlite3_open_v2(self.path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = handle.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "unknown"
            if let handle {
                sqlite3_close(handle)
            }
            throw CascadeStoreError.openFailed(message)
        }

        connection = SQLiteConnection(handle)
        try Self.migrate(handle)
    }

    public static func defaultDatabasePath() -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("Cascade", isDirectory: true)
            .appendingPathComponent("Cascade.sqlite", isDirectory: false)
            .path
    }

    public func insert(_ context: RecordedContext) throws -> RecordedContext {
        let sql = """
        INSERT INTO recorded_context
            (captured_at, source, app_name, bundle_identifier, window_title, ocr_text, metadata_json)
        VALUES (?, ?, ?, ?, ?, ?, ?);
        """
        try withStatement(sql) { statement in
            bind(DateCodec.string(from: context.capturedAt), at: 1, in: statement)
            bind(context.source.rawValue, at: 2, in: statement)
            bind(context.appName, at: 3, in: statement)
            bind(context.bundleIdentifier, at: 4, in: statement)
            bind(context.windowTitle, at: 5, in: statement)
            bind(context.ocrText, at: 6, in: statement)
            bind(context.metadataJSON, at: 7, in: statement)
            try stepDone(statement)
        }
        return RecordedContext(
            id: sqlite3_last_insert_rowid(connection.db),
            capturedAt: context.capturedAt,
            source: context.source,
            appName: context.appName,
            bundleIdentifier: context.bundleIdentifier,
            windowTitle: context.windowTitle,
            ocrText: context.ocrText,
            metadataJSON: context.metadataJSON
        )
    }

    public func recentContexts(limit: Int = 40) throws -> [RecordedContext] {
        let sql = """
        SELECT id, captured_at, source, app_name, bundle_identifier, window_title, ocr_text, metadata_json
        FROM recorded_context
        ORDER BY captured_at DESC, id DESC
        LIMIT ?;
        """
        return try withStatement(sql) { statement in
            sqlite3_bind_int(statement, 1, Int32(limit))
            var rows: [RecordedContext] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(RecordedContext(
                    id: sqlite3_column_int64(statement, 0),
                    capturedAt: DateCodec.date(from: text(statement, 1)) ?? Date(),
                    source: ContextSource(rawValue: text(statement, 2) ?? "") ?? .system,
                    appName: text(statement, 3) ?? "Unknown",
                    bundleIdentifier: text(statement, 4),
                    windowTitle: text(statement, 5),
                    ocrText: text(statement, 6),
                    metadataJSON: text(statement, 7)
                ))
            }
            return rows
        }
    }

    public func appendAudit(_ event: AuditEvent) throws -> AuditEvent {
        let sql = "INSERT INTO audit_event (created_at, actor, action, detail) VALUES (?, ?, ?, ?);"
        try withStatement(sql) { statement in
            bind(DateCodec.string(from: event.createdAt), at: 1, in: statement)
            bind(event.actor, at: 2, in: statement)
            bind(event.action, at: 3, in: statement)
            bind(event.detail, at: 4, in: statement)
            try stepDone(statement)
        }
        return AuditEvent(
            id: sqlite3_last_insert_rowid(connection.db),
            createdAt: event.createdAt,
            actor: event.actor,
            action: event.action,
            detail: event.detail
        )
    }

    public func recentAudit(limit: Int = 80) throws -> [AuditEvent] {
        let sql = """
        SELECT id, created_at, actor, action, detail
        FROM audit_event
        ORDER BY created_at DESC, id DESC
        LIMIT ?;
        """
        return try withStatement(sql) { statement in
            sqlite3_bind_int(statement, 1, Int32(limit))
            var rows: [AuditEvent] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(AuditEvent(
                    id: sqlite3_column_int64(statement, 0),
                    createdAt: DateCodec.date(from: text(statement, 1)) ?? Date(),
                    actor: text(statement, 2) ?? "system",
                    action: text(statement, 3) ?? "unknown",
                    detail: text(statement, 4) ?? ""
                ))
            }
            return rows
        }
    }

    private static func migrate(_ db: OpaquePointer?) throws {
        try execute("""
        PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS recorded_context (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            captured_at TEXT NOT NULL,
            source TEXT NOT NULL,
            app_name TEXT NOT NULL,
            bundle_identifier TEXT,
            window_title TEXT,
            ocr_text TEXT,
            metadata_json TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_recorded_context_captured_at
            ON recorded_context(captured_at DESC);

        CREATE TABLE IF NOT EXISTS audit_event (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at TEXT NOT NULL,
            actor TEXT NOT NULL,
            action TEXT NOT NULL,
            detail TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_audit_event_created_at
            ON audit_event(created_at DESC);
        """, db: db)
    }

    private func execute(_ sql: String) throws {
        try Self.execute(sql, db: connection.db)
    }

    private static func execute(_ sql: String, db: OpaquePointer?) throws {
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) }
                ?? db.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) }
                ?? "unknown"
            sqlite3_free(error)
            throw CascadeStoreError.sqlite(message)
        }
    }

    private func withStatement<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection.db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw CascadeStoreError.prepareFailed(lastError())
        }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw CascadeStoreError.sqlite(lastError())
        }
    }

    private func lastError() -> String {
        connection.db.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "unknown"
    }

    private func bind(_ value: String?, at index: Int32, in statement: OpaquePointer) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    private func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: cString)
    }

    private static func ensureParentDirectory(for path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }
}

private final class SQLiteConnection: @unchecked Sendable {
    let db: OpaquePointer?

    init(_ db: OpaquePointer?) {
        self.db = db
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }
}

private enum DateCodec {
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
