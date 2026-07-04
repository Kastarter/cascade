@testable import CascadeMemory
import Foundation
import SQLite3
import Testing

// §7 encryption-at-rest seam + key lifecycle tests. These exercise the ON-path
// (a real envelope really intercepts a real sqlite connection) without a no-op
// fake-cache-shape flag (LAW 6), and pin the honest-stub properties (LAW 7):
// SQLCipherEnvelope must throw, isSQLCipherLinked must be false, and the
// default (Null) envelope must leave the shipped plaintext path untouched.
// Keychain-backed KeychainEncryptionKeyStore is deliberately NOT exercised —
// the Keychain prompts/fails in unsigned test binaries (same reason
// InMemoryAuditAnchor exists); tests use InMemoryEncryptionKeyStore.

private func temporaryDatabasePath(_ label: String) -> String {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("EncryptionAtRestTests-\(label)-\(UUID().uuidString).sqlite")
        .path
}

/// Opens a bare sqlite handle on a temp file (no CascadeStore involved).
private func openRawSQLiteHandle(path: String) throws -> OpaquePointer {
    var handle: OpaquePointer?
    let rc = sqlite3_open_v2(path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
    guard rc == SQLITE_OK, let handle else {
        if let handle { sqlite3_close(handle) }
        throw EncryptionAtRestError.cipherUnavailable("test: sqlite3_open_v2 rc=\(rc)")
    }
    return handle
}

// MARK: - (a) KeyCustodian lifecycle over the in-memory double

@Test
func keyCustodianCreatesLoadsAndDestroysKeys() throws {
    let custodian = KeyCustodian(keyStore: InMemoryEncryptionKeyStore())

    let first = try custodian.loadOrCreateKey()
    #expect(first.count == 32)

    // Idempotent: second call returns the SAME key.
    let second = try custodian.loadOrCreateKey()
    #expect(second == first)

    // Key-loss recovery primitive: destroy then load mints a DIFFERENT key —
    // the old store is unrecoverable BY DESIGN, the new key serves a NEW store.
    try custodian.destroyKey()
    let third = try custodian.loadOrCreateKey()
    #expect(third.count == 32)
    #expect(third != first)
}

@Test
func keyHexForPragmaRendersRawKeyForm() throws {
    let custodian = KeyCustodian(keyStore: InMemoryEncryptionKeyStore())
    let hex = custodian.keyHexForPragma(Data([0x00, 0xab, 0xff]))
    #expect(hex == "x'00abff'")
}

// MARK: - (b) SQLCipherEnvelope is an honest stub

@Test
func sqlCipherEnvelopeIsHonestlyUnlinkedAndThrows() throws {
    // Whoever adds the SQLCipher package and flips this gate must consciously
    // break this pin — and implement PRAGMA key + the sqlite_master verify.
    #expect(SQLCipherEnvelope.isSQLCipherLinked == false)

    let envelope = SQLCipherEnvelope(custodian: KeyCustodian(keyStore: InMemoryEncryptionKeyStore()))
    if case .unavailable = envelope.status {} else {
        Issue.record("SQLCipherEnvelope.status must be .unavailable while SQLCipher is not linked, got \(envelope.status)")
    }

    let path = temporaryDatabasePath("cipher-stub")
    let handle = try openRawSQLiteHandle(path: path)
    defer { sqlite3_close(handle) }
    #expect(throws: EncryptionAtRestError.self) {
        try envelope.prepareConnection(handle, path: path)
    }
}

// MARK: - (c) Seam ordering: prepareConnection fires BEFORE migrate

/// Records what the seam saw: that it fired, that the handle was live
/// (`PRAGMA user_version` succeeds), and how many rows `sqlite_master` had —
/// which must be ZERO because the hook runs before `CascadeStore.migrate`
/// creates any table. That ordering is the load-bearing property for a future
/// `PRAGMA key` (it must be the first statement on the connection).
private final class SpyEnvelope: StoreEncryptionEnvelope, @unchecked Sendable {
    private let lock = NSLock()
    private var _prepareCalls = 0
    private var _handleWasLive = false
    private var _schemaObjectCount: Int32 = -1

    var prepareCalls: Int {
        lock.lock(); defer { lock.unlock() }
        return _prepareCalls
    }
    var handleWasLive: Bool {
        lock.lock(); defer { lock.unlock() }
        return _handleWasLive
    }
    var schemaObjectCount: Int32 {
        lock.lock(); defer { lock.unlock() }
        return _schemaObjectCount
    }

    func prepareConnection(_ db: OpaquePointer, path: String) throws {
        let live = sqlite3_exec(db, "PRAGMA user_version;", nil, nil, nil) == SQLITE_OK

        var count: Int32 = -1
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT count(*) FROM sqlite_master;", -1, &statement, nil) == SQLITE_OK,
           sqlite3_step(statement) == SQLITE_ROW {
            count = sqlite3_column_int(statement, 0)
        }
        sqlite3_finalize(statement)

        lock.lock()
        _prepareCalls += 1
        _handleWasLive = live
        _schemaObjectCount = count
        lock.unlock()
    }

    var status: EncryptionAtRestStatus { .notEncrypted }
}

@Test
func seamRunsOnLiveHandleBeforeMigrate() async throws {
    let spy = SpyEnvelope()
    let path = temporaryDatabasePath("seam-order")
    let store = try CascadeStore(path: path, encryptionEnvelope: spy)

    #expect(spy.prepareCalls == 1)
    #expect(spy.handleWasLive)
    // No cascade tables existed yet when the seam ran — migrate came after.
    #expect(spy.schemaObjectCount == 0)
    #expect(store.encryptionStatus == .notEncrypted)

    // ...and the store the seam intercepted is fully functional afterward.
    let inserted = try await store.insert(RecordedContext(
        capturedAt: Date(timeIntervalSince1970: 1_800_000_100),
        source: .screen,
        appName: "Safari",
        ocrText: "seam ordering sentinel"
    ))
    #expect(inserted.id > 0)
}

// MARK: - (d) Seam fail-fast: a throwing envelope aborts init and leaks no handle

private struct ThrowingEnvelope: StoreEncryptionEnvelope {
    func prepareConnection(_ db: OpaquePointer, path: String) throws {
        throw EncryptionAtRestError.cipherUnavailable("test: deliberate failure")
    }
    var status: EncryptionAtRestStatus { .unavailable(reason: "test") }
}

@Test
func throwingEnvelopeFailsStoreInitWithoutLeakingTheHandle() throws {
    let path = temporaryDatabasePath("fail-fast")

    #expect(throws: EncryptionAtRestError.self) {
        _ = try CascadeStore(path: path, encryptionEnvelope: ThrowingEnvelope())
    }

    // The failed init closed its handle: a fresh open on the SAME path with a
    // good envelope succeeds and can migrate/write normally.
    let recovered = try CascadeStore(path: path)
    #expect(recovered.encryptionStatus == .notEncrypted)
}

// MARK: - (e) Requested-but-unavailable envelope: structural LAW 7 status

@Test
func unavailableEnvelopeStoreIsPlaintextButSaysUnavailable() async throws {
    // The flag-ON/no-cipher boot path constructs the store with this envelope,
    // so a LIVE store carries `.unavailable` structurally — the documented
    // requested-but-unavailable state is no longer only a fire-and-forget
    // audit row.
    let store = try CascadeStore(
        path: temporaryDatabasePath("unavailable-envelope"),
        encryptionEnvelope: UnavailableStoreEncryptionEnvelope(reason: "test: no cipher linked")
    )
    #expect(store.encryptionStatus == .unavailable(reason: "test: no cipher linked"))

    // ...and on the connection it behaves exactly like the plaintext store it
    // honestly is (zero SQL from the envelope; normal migrate + round trip).
    let inserted = try await store.insert(RecordedContext(
        capturedAt: Date(timeIntervalSince1970: 1_800_000_200),
        source: .screen,
        appName: "Notes",
        ocrText: "unavailable status sentinel"
    ))
    #expect(inserted.id > 0)
}

// MARK: - (f) OFF-path guard: default envelope == today's plaintext store

@Test
func defaultEnvelopeStoreRoundTripsLikeToday() async throws {
    // No envelope argument at all — the exact shipped call shape.
    let store = try CascadeStore(path: temporaryDatabasePath("off-path"))
    #expect(store.encryptionStatus == .notEncrypted)

    let context = RecordedContext(
        capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
        source: .screen,
        appName: "Notes",
        bundleIdentifier: "com.apple.Notes",
        windowTitle: "Plaintext",
        ocrText: "off path round trip sentinel",
        imagePath: nil,
        metadataJSON: nil,
        frameHash: 7
    )
    let inserted = try await store.insert(context)
    let rows = try await store.recentContexts(limit: 5)
    let fetched = rows.first { $0.id == inserted.id }
    #expect(fetched != nil)
    #expect(fetched?.ocrText == context.ocrText)
    #expect(fetched?.appName == context.appName)
}
