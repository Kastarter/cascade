import CascadeMemory
import Foundation
import SQLite3
import Testing

private func makeActionCacheStore() throws -> (CascadeStore, String) {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("CascadeActionTrajectoryCache-\(UUID().uuidString).sqlite")
        .path
    return (try CascadeStore(path: path), path)
}

private func safeState(
    appName: String = "Mail",
    bundleIdentifier: String? = "com.apple.mail",
    windowTitle: String? = "Inbox",
    screenHash: UInt64 = 0xABCD,
    grid: [UInt64] = [0x1, 0x2, 0x3],
    ax: String? = "root-ax-send"
) -> ActionTrajectoryState {
    ActionTrajectoryState(
        appName: appName,
        bundleIdentifier: bundleIdentifier,
        windowTitle: windowTitle,
        screenHash: screenHash,
        screenGridHashes: grid,
        axFingerprint: ax
    )
}

private func clickAction(x: Double = 10, y: Double = 20, descriptor: String = "AXButton Send") -> ActionTrajectoryCacheAction {
    ActionTrajectoryCacheAction(
        kind: "click",
        json: #"{"x":\#(x),"y":\#(y),"target_descriptor":"\#(descriptor)"}"#
    )
}

@Test
func actionTrajectoryMigrationCreatesTableAndIndexesIdempotently() async throws {
    let (_, path) = try makeActionCacheStore()
    _ = try CascadeStore(path: path)

    #expect(rawInt(path, "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='action_trajectory_cache';") == 1)
    #expect(rawInt(path, "SELECT count(*) FROM sqlite_master WHERE type='index' AND name='idx_action_trajectory_cache_lookup';") == 1)
    #expect(!path.contains("Library/Application Support/Cascade"))
}

@Test
func actionTrajectoryKeysAreStableAndRowsExcludePrivateText() async throws {
    let (store, path) = try makeActionCacheStore()
    let state = safeState(windowTitle: "Inbox jane@example.com")
    let first = try await store.promoteActionTrajectoryCache(
        source: .assist,
        goal: "Email jane@example.com about payroll",
        state: state,
        targetDescriptor: "AXButton Send jane@example.com",
        targetText: "Send",
        action: clickAction(),
        now: Date(timeIntervalSince1970: 100)
    )
    let second = try await store.promoteActionTrajectoryCache(
        source: .assist,
        goal: "Email jane@example.com about payroll",
        state: state,
        targetDescriptor: "AXButton Send jane@example.com",
        targetText: "Send",
        action: clickAction(),
        now: Date(timeIntervalSince1970: 101)
    )
    let typed = try await store.promoteActionTrajectoryCache(
        source: .assist,
        goal: "send message",
        state: state,
        targetText: "Body",
        action: ActionTrajectoryCacheAction(kind: "type", json: #"{"text":"secret payroll 4111111111111111"}"#)
    )
    let businessPrivate = try await store.promoteActionTrajectoryCache(
        source: .assist,
        goal: "Review Aperture Delta term sheet",
        state: safeState(windowTitle: "Aperture Delta term sheet - Safari"),
        targetDescriptor: "AXButton Aperture Delta",
        targetText: "Aperture Delta term sheet",
        action: clickAction(descriptor: "AXButton Aperture Delta")
    )

    #expect(first?.actionKeyHash == second?.actionKeyHash)
    #expect(typed == nil)
    #expect(businessPrivate != nil)
    let storedText = rawJoinedText(path, table: "action_trajectory_cache")
    let actionJSON = rawText(path, "SELECT action_json FROM action_trajectory_cache LIMIT 1;")
    #expect(!storedText.localizedCaseInsensitiveContains("jane@example.com"))
    #expect(!storedText.localizedCaseInsensitiveContains("4111111111111111"))
    #expect(!storedText.localizedCaseInsensitiveContains("secret payroll"))
    #expect(!storedText.localizedCaseInsensitiveContains("Aperture"))
    #expect(!storedText.localizedCaseInsensitiveContains("Delta"))
    #expect(!storedText.localizedCaseInsensitiveContains("term sheet"))
    #expect(!actionJSON.localizedCaseInsensitiveContains("AXButton Send"))
    #expect(actionJSON.localizedCaseInsensitiveContains("textHash"))
    let audits = try await store.recentAudit(limit: 10).map(\.detail).joined(separator: "\n")
    #expect(!audits.localizedCaseInsensitiveContains("jane@example.com"))
    #expect(!audits.localizedCaseInsensitiveContains("secret payroll"))
}

@Test
func actionTrajectoryPromoteAndDemoteAdjustConfidenceAndExpiry() async throws {
    let (store, _) = try makeActionCacheStore()
    let row = try #require(try await store.promoteActionTrajectoryCache(
        source: .assist,
        goal: "click send",
        state: safeState(),
        targetDescriptor: "AXButton Send",
        targetText: "Send",
        action: clickAction(),
        now: Date(timeIntervalSince1970: 100)
    ))
    let promoted = try #require(try await store.promoteActionTrajectoryCache(
        source: .assist,
        goal: "click send",
        state: safeState(),
        targetDescriptor: "AXButton Send",
        targetText: "Send",
        action: clickAction(),
        now: Date(timeIntervalSince1970: 101)
    ))

    #expect(promoted.successCount == row.successCount + 1)
    #expect(promoted.confidence > row.confidence)

    let firstDemotion = try #require(try await store.demoteActionTrajectoryCache(id: promoted.id, reason: .wrongScreen))
    _ = try await store.demoteActionTrajectoryCache(id: promoted.id, reason: .wrongScreen)
    _ = try await store.demoteActionTrajectoryCache(id: promoted.id, reason: .wrongScreen)
    let lookup = try await store.lookupActionTrajectoryCache(
        goal: "click send",
        state: safeState(),
        targetDescriptor: "AXButton Send",
        targetText: "Send",
        actionKind: "click",
        audit: false
    )

    #expect(firstDemotion.failureCount == promoted.failureCount + 1)
    #expect(firstDemotion.confidence < promoted.confidence)
    #expect(lookup.executable == nil)
}

@Test
func actionTrajectoryStage2RejectsWrongAppWrongScreenAndModal() async throws {
    let (store, _) = try makeActionCacheStore()
    _ = try #require(try await store.promoteActionTrajectoryCache(
        source: .assist,
        goal: "click send",
        state: safeState(),
        targetDescriptor: "AXButton Send",
        targetText: "Send",
        action: clickAction()
    ))

    let wrongApp = try await store.lookupActionTrajectoryCache(
        goal: "click send",
        state: safeState(appName: "Notes", bundleIdentifier: "com.apple.Notes"),
        targetDescriptor: "AXButton Send",
        targetText: "Send",
        actionKind: "click",
        audit: false
    )
    let wrongScreen = try await store.lookupActionTrajectoryCache(
        goal: "click send",
        state: safeState(screenHash: 0xFFFF_FFFF, grid: [0xFFFF, 0xEEEE, 0xDDDD]),
        targetDescriptor: "AXButton Send",
        targetText: "Send",
        actionKind: "click",
        audit: false
    )
    let modal = try await store.lookupActionTrajectoryCache(
        goal: "click send",
        state: ActionTrajectoryState(
            appName: "Mail",
            bundleIdentifier: "com.apple.mail",
            windowTitle: "Inbox",
            screenHash: 0xABCD,
            screenGridHashes: [0x1, 0x2, 0x3],
            axFingerprint: "root-ax-send",
            modalPresent: true
        ),
        targetDescriptor: "AXButton Send",
        targetText: "Send",
        actionKind: "click",
        audit: false
    )

    #expect(wrongApp.isMiss)
    #expect(wrongScreen.isMiss)
    #expect(modal.isMiss)
}

@Test
func actionTrajectoryAllowlistOnlyExecutesVerifiedIdempotentActions() async throws {
    let (store, _) = try makeActionCacheStore()
    _ = try #require(try await store.promoteActionTrajectoryCache(
        source: .assist,
        goal: "open mail",
        state: safeState(),
        action: ActionTrajectoryCacheAction(kind: "open_app", json: #"{"app":"Mail"}"#)
    ))
    _ = try #require(try await store.promoteActionTrajectoryCache(
        source: .assist,
        goal: "click send",
        state: safeState(),
        targetText: "Send",
        action: ActionTrajectoryCacheAction(kind: "click", json: #"{"x":10,"y":20}"#)
    ))

    let openApp = try await store.lookupActionTrajectoryCache(
        goal: "open mail",
        state: safeState(screenHash: 0x9999, grid: [0x9999]),
        actionKind: "open_app",
        audit: false
    )
    let broadOpenApp = try await store.lookupActionTrajectoryCache(
        goal: "open mail and write a draft",
        state: safeState(screenHash: 0x9999, grid: [0x9999]),
        actionKind: "open_app",
        audit: false
    )
    let coordinateOnlyClick = try await store.lookupActionTrajectoryCache(
        goal: "click send",
        state: safeState(),
        targetText: "Send",
        actionKind: "click",
        audit: false
    )
    let typeRow = try await store.promoteActionTrajectoryCache(
        source: .assist,
        goal: "type value",
        state: safeState(),
        action: ActionTrajectoryCacheAction(kind: "type", json: #"{"text":"hello"}"#)
    )

    #expect(openApp.executable?.executable == true)
    #expect(broadOpenApp.executable == nil)
    #expect(coordinateOnlyClick.executable == nil)
    #expect(!coordinateOnlyClick.hints.isEmpty)
    #expect(typeRow == nil)
}

@Test
func actionTrajectoryCacheDoesNotPromoteURLReplayActions() async throws {
    let (store, _) = try makeActionCacheStore()
    let row = try await store.promoteActionTrajectoryCache(
        source: .assist,
        goal: "open customer report",
        state: safeState(appName: "Safari", bundleIdentifier: "com.apple.Safari"),
        action: ActionTrajectoryCacheAction(
            kind: "open_url",
            json: #"{"url":"https://intranet.example.com/customers/123/report?token=abc"}"#
        )
    )

    #expect(row == nil)
}

@Test
func actionTrajectoryTTLPrunesExpiredRowsAndKeepsFreshSuccesses() async throws {
    let (store, _) = try makeActionCacheStore()
    let now = Date(timeIntervalSince1970: 1_000)
    _ = try #require(try await store.promoteActionTrajectoryCache(
        source: .assist,
        goal: "short lived",
        state: safeState(appName: "Short", bundleIdentifier: "com.example.short"),
        action: ActionTrajectoryCacheAction(kind: "open_app", json: #"{"app":"Short"}"#),
        ttlPolicy: .short,
        now: now
    ))
    _ = try #require(try await store.promoteActionTrajectoryCache(
        source: .assist,
        goal: "long lived",
        state: safeState(appName: "Long", bundleIdentifier: "com.example.long"),
        action: ActionTrajectoryCacheAction(kind: "open_app", json: #"{"app":"Long"}"#),
        ttlPolicy: .long,
        now: now
    ))

    _ = try await store.pruneActionTrajectoryCache(now: now.addingTimeInterval(2 * 24 * 60 * 60))
    let rows = try await store.actionTrajectoryCacheRows()

    #expect(rows.count == 1)
    #expect(rows.first?.ttlPolicy == .long)
}

private func rawInt(_ path: String, _ sql: String) -> Int {
    var db: OpaquePointer?
    guard sqlite3_open(path, &db) == SQLITE_OK else { return 0 }
    defer { sqlite3_close(db) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return 0 }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
    return Int(sqlite3_column_int64(statement, 0))
}

private func rawJoinedText(_ path: String, table: String) -> String {
    var db: OpaquePointer?
    guard sqlite3_open(path, &db) == SQLITE_OK else { return "" }
    defer { sqlite3_close(db) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, "SELECT * FROM \(table);", -1, &statement, nil) == SQLITE_OK else { return "" }
    defer { sqlite3_finalize(statement) }
    var values: [String] = []
    while sqlite3_step(statement) == SQLITE_ROW {
        for index in 0..<sqlite3_column_count(statement) {
            if let cString = sqlite3_column_text(statement, index) {
                values.append(String(cString: cString))
            }
        }
    }
    return values.joined(separator: "\n")
}

private func rawText(_ path: String, _ sql: String) -> String {
    var db: OpaquePointer?
    guard sqlite3_open(path, &db) == SQLITE_OK else { return "" }
    defer { sqlite3_close(db) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return "" }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW,
          let cString = sqlite3_column_text(statement, 0) else {
        return ""
    }
    return String(cString: cString)
}
