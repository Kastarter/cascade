import CascadeMemory
import Foundation
import SQLite3
import Testing

private func makeLayoutStorePath(_ prefix: String) -> String {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString).sqlite")
        .path
}

private func withRawDatabase<T>(_ path: String, _ body: (OpaquePointer?) throws -> T) throws -> T {
    var db: OpaquePointer?
    guard sqlite3_open(path, &db) == SQLITE_OK else {
        throw CascadeStoreError.openFailed("raw sqlite open failed")
    }
    defer { sqlite3_close(db) }
    sqlite3_exec(db, "PRAGMA busy_timeout=1000;", nil, nil, nil)
    return try body(db)
}

private func rawExec(_ path: String, _ sql: String) throws {
    try withRawDatabase(path) { db in
        var error: UnsafeMutablePointer<CChar>?
        defer { sqlite3_free(error) }
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown sqlite error"
            throw CascadeStoreError.sqlite(message)
        }
    }
}

private func rawStrings(_ path: String, _ sql: String) throws -> [String] {
    try withRawDatabase(path) { db in
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw CascadeStoreError.prepareFailed("raw prepare failed")
        }
        defer { sqlite3_finalize(statement) }

        var rows: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let cString = sqlite3_column_text(statement, 0) {
                rows.append(String(cString: cString))
            }
        }
        return rows
    }
}

private func rawInt64s(_ path: String, _ sql: String) throws -> [Int64] {
    try withRawDatabase(path) { db in
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw CascadeStoreError.prepareFailed("raw prepare failed")
        }
        defer { sqlite3_finalize(statement) }

        var rows: [Int64] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(sqlite3_column_int64(statement, 0))
        }
        return rows
    }
}

private func createLegacyEventStore(at path: String) throws {
    try rawExec(path, """
    CREATE TABLE recorded_context (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        captured_at TEXT NOT NULL,
        source TEXT NOT NULL,
        app_name TEXT NOT NULL,
        bundle_identifier TEXT,
        window_title TEXT,
        ocr_text TEXT,
        image_path TEXT,
        metadata_json TEXT
    );
    CREATE INDEX idx_recorded_context_captured_at
        ON recorded_context(captured_at DESC);

    CREATE TABLE input_event (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        captured_at TEXT NOT NULL,
        kind TEXT NOT NULL,
        x REAL,
        y REAL,
        text TEXT,
        key TEXT,
        modifiers TEXT,
        app_name TEXT NOT NULL,
        bundle_identifier TEXT,
        window_title TEXT
    );
    CREATE INDEX idx_input_event_captured_at
        ON input_event(captured_at DESC);
    """)
}

@Test
func migrationAddsCapturedMillisecondsColumnsAndIndexes() async throws {
    let path = makeLayoutStorePath("CascadeLayoutMigration")
    try createLegacyEventStore(at: path)

    _ = try CascadeStore(path: path)

    let contextColumns = try rawStrings(path, "SELECT name FROM pragma_table_info('recorded_context');")
    let inputColumns = try rawStrings(path, "SELECT name FROM pragma_table_info('input_event');")
    let contextIndexes = try rawStrings(path, "SELECT name FROM pragma_index_list('recorded_context');")
    let inputIndexes = try rawStrings(path, "SELECT name FROM pragma_index_list('input_event');")

    #expect(contextColumns.contains("captured_ms"))
    #expect(inputColumns.contains("captured_ms"))
    #expect(contextIndexes.contains("idx_recorded_context_captured_ms"))
    #expect(inputIndexes.contains("idx_input_event_captured_ms"))
}

@Test
func capturedMillisecondsWritesAndHelpersMirrorDateRanges() async throws {
    let path = makeLayoutStorePath("CascadeLayoutRange")
    let store = try CascadeStore(path: path)
    let base = Date(timeIntervalSince1970: 1_900_000_000.125)
    let contexts = (0..<5).map { index in
        RecordedContext(
            capturedAt: base.addingTimeInterval(Double(index)),
            source: .screen,
            appName: "Context\(index)",
            ocrText: "integer range context \(index)"
        )
    }
    let inputEvents = (0..<5).map { index in
        InputEvent(
            capturedAt: base.addingTimeInterval(Double(index)),
            kind: .click,
            x: Double(index),
            y: Double(index),
            appName: "Input\(index)"
        )
    }

    _ = try await store.insertContexts(contexts)
    try await store.insertInputEvents(inputEvents)

    let start = base.addingTimeInterval(1)
    let end = base.addingTimeInterval(3)
    let millisecondRange = EventStoreLayout.capturedMilliseconds(for: start)...EventStoreLayout.capturedMilliseconds(for: end)
    let dateContexts = try await store.contexts(between: start, and: end, limit: 10)
    let millisecondContexts = try await store.contexts(capturedMilliseconds: millisecondRange, limit: 10)
    let dateInputEvents = try await store.inputEvents(between: start, and: end, limit: 10)
    let millisecondInputEvents = try await store.inputEvents(capturedMilliseconds: millisecondRange, limit: 10)

    #expect(millisecondContexts == dateContexts)
    #expect(millisecondInputEvents == dateInputEvents)
    #expect(dateContexts.map(\.appName) == ["Context1", "Context2", "Context3"])
    #expect(dateInputEvents.map(\.appName) == ["Input1", "Input2", "Input3"])
    #expect(try await store.recentContexts(limit: 10).count == contexts.count)
    #expect(try await store.recentInputEvents(limit: 10).count == inputEvents.count)

    let storedContextMilliseconds = try rawInt64s(path, "SELECT captured_ms FROM recorded_context ORDER BY captured_ms ASC, id ASC;")
    let storedInputMilliseconds = try rawInt64s(path, "SELECT captured_ms FROM input_event ORDER BY captured_ms ASC, id ASC;")
    #expect(storedContextMilliseconds == contexts.map { EventStoreLayout.capturedMilliseconds(for: $0.capturedAt) })
    #expect(storedInputMilliseconds == inputEvents.map { EventStoreLayout.capturedMilliseconds(for: $0.capturedAt) })
}
