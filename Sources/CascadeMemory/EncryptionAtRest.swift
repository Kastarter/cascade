import CryptoKit
import Foundation
import SQLite3
#if canImport(Security)
import Security
#endif

// MARK: - Encryption at rest (§7, open wound #5)
//
// This file is the ENCRYPTION SEAM for `CascadeStore` plus the REAL key
// lifecycle (`KeyCustodian`). It is deliberately an *honest skeleton* (LAW 7):
// nothing here encrypts a single byte today, and nothing here is capable of
// pretending otherwise — `EncryptionAtRestStatus` can only report `.encrypted`
// from a real cipher envelope, and the only cipher envelope in the tree
// (`SQLCipherEnvelope`) throws `cipherUnavailable` because Package.swift has no
// SQLCipher dependency. The store remains PLAINTEXT in all configurations; the
// `cascade.encryptAtRest` flag (read only in AppShell) changes nothing except
// that a Keychain key exists and an audit row + status say so out loud.
//
// ## One-time plaintext → SQLCipher migration (documentation only — UNIMPLEMENTED)
//
// SQLCipher cannot open a plaintext database with `PRAGMA key`; an existing
// store must be exported ONCE via `sqlcipher_export`:
//
//   1. Checkpoint and close the plaintext store cleanly:
//      `PRAGMA wal_checkpoint(TRUNCATE);` then close every connection, so no
//      `-wal`/`-shm` sidecar survives with plaintext pages.
//   2. Open the plaintext DB with a SQLCipher-linked build (no key), then:
//      `ATTACH DATABASE '<path>.enc' AS encrypted KEY "x'<hex>'";`
//      `SELECT sqlcipher_export('encrypted');`
//      `DETACH DATABASE encrypted;`
//      where `<hex>` is `KeyCustodian.loadOrCreateKey()` rendered by
//      `keyHexForPragma` (raw-key form, so no KDF ambiguity across versions).
//   3. Verify-open `<path>.enc` with the same key as the FIRST statement on the
//      connection (`PRAGMA key = "x'<hex>'";`), then
//      `PRAGMA integrity_check;` and `SELECT count(*) FROM sqlite_master;`
//      must succeed before the plaintext original is touched.
//   4. Atomically rename `<path>.enc` over `<path>` and secure-delete the
//      plaintext original (and any leftover `-wal`/`-shm`).
//
// SCOPE NOTE: this seam covers the SQLite DB connection ONLY. Frame JPEGs, the
// WAL sidecars of a *running* store, and FTS shadow tables inside the DB file
// are inside the DB envelope, but on-disk image files are NOT — plan §7's "no
// plaintext sidecar survives" is a separate, future envelope around the frame
// store. Do not claim encryption-at-rest until both are done.
//
// ## Key-loss recovery (BY DESIGN)
//
// See `KeyCustodian` — losing the key makes an encrypted store unrecoverable on
// purpose. Recovery is `destroyKey()` + delete the DB + re-record. There is
// NEVER a silent plaintext fallback for a store that was encrypted.
//
// TODO(cipher-swap): add the SQLCipher package to Package.swift, flip
// `SQLCipherEnvelope.isSQLCipherLinked` to true (a test pins it false so the
// flip is a conscious act), and implement `PRAGMA key` + a
// `SELECT count(*) FROM sqlite_master` verify inside
// `SQLCipherEnvelope.prepareConnection`.

/// Visible encryption state of a `CascadeStore` (LAW 7: degrade to "not yet
/// encrypted", never to fake-encrypted). Nothing in this codebase can report
/// `.encrypted` until a real cipher actually runs on the connection.
public enum EncryptionAtRestStatus: Sendable, Equatable {
    /// The store is plaintext and says so. Today's shipped state.
    case notEncrypted
    /// A real cipher prepared this connection. Unreachable today — no envelope
    /// in the tree is allowed to return it (SQLCipher is not linked).
    case encrypted
    /// Encryption was requested but cannot be provided; the reason is shown,
    /// not hidden. The store behind this status is PLAINTEXT.
    case unavailable(reason: String)
}

public enum EncryptionAtRestError: Error, LocalizedError {
    /// The configured cipher is not linked into this build. Fail fast (LAW 8) —
    /// never open-and-pretend.
    case cipherUnavailable(String)
    case keyGenerationFailed(OSStatus)
    case keychainFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .cipherUnavailable(let reason): "Encryption at rest unavailable: \(reason)"
        case .keyGenerationFailed(let status): "Key generation failed: OSStatus \(status)"
        case .keychainFailed(let status): "Keychain operation failed: OSStatus \(status)"
        }
    }
}

// MARK: - The seam

/// THE ENCRYPTION SEAM around `CascadeStore`'s SQLite connection.
///
/// `prepareConnection` is invoked on the raw sqlite handle immediately after
/// `sqlite3_open_v2` and BEFORE `CascadeStore.migrate` runs any SQL — exactly
/// where SQLCipher's `PRAGMA key` must be the first statement on the
/// connection. A throwing envelope aborts store construction (the handle is
/// closed); it can never leave a half-keyed store running.
public protocol StoreEncryptionEnvelope: Sendable {
    /// Called with a live, freshly opened sqlite handle before any other SQL.
    func prepareConnection(_ db: OpaquePointer, path: String) throws
    /// What this envelope honestly provides, for UI/audit surfacing.
    var status: EncryptionAtRestStatus { get }
}

/// The default envelope: does NOTHING — issues zero SQL statements, zero
/// PRAGMAs — so today's plaintext store is byte-identical to before the seam
/// existed. Status says `.notEncrypted` out loud.
public struct NullStoreEncryptionEnvelope: StoreEncryptionEnvelope {
    public init() {}
    public func prepareConnection(_ db: OpaquePointer, path: String) throws {}
    public var status: EncryptionAtRestStatus { .notEncrypted }
}

/// The requested-but-unavailable envelope: byte-identical to the Null envelope
/// on the connection (zero SQL, zero PRAGMAs — the store IS plaintext) but its
/// `status` is `.unavailable(reason:)`, so a live store constructed under a
/// flag-ON/no-cipher boot STRUCTURALLY carries the LAW 7 degradation signal.
/// Without this, "encryption requested but not provided" existed only as a
/// fire-and-forget audit row whose failure could be silently swallowed;
/// `CascadeStore.encryptionStatus` would read `.notEncrypted` and the
/// documented `.unavailable` state was unreachable from any live store.
public struct UnavailableStoreEncryptionEnvelope: StoreEncryptionEnvelope {
    public let reason: String
    public init(reason: String) { self.reason = reason }
    public func prepareConnection(_ db: OpaquePointer, path: String) throws {}
    public var status: EncryptionAtRestStatus { .unavailable(reason: reason) }
}

// MARK: - Key lifecycle

/// Out-of-band store for the database encryption key. Injected so production
/// uses the Keychain while tests use an in-memory double — mirrors the
/// `AuditAnchorStore` pattern (the Keychain prompts or fails in unsigned test
/// binaries).
public protocol EncryptionKeyStore: Sendable {
    func load() throws -> Data?
    func save(_ key: Data) throws
    func destroy() throws
}

/// REAL Keychain-backed key store: a device-only generic-password item under
/// service `com.humain.cascade`, account keyed by SHA-256 of the database path
/// (same stable-account convention as `KeychainAuditAnchor`).
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` so a background recorder
/// can reopen the store after one unlock, but the key never leaves the device.
///
/// `requireUserPresence` is the LocalAuthentication hook: when true the item is
/// created with `SecAccessControlCreateWithFlags(..., .userPresence)`, so any
/// read triggers Touch ID / password. Real code, default `false`, and never
/// exercised in tests (biometric prompts cannot run headless).
public struct KeychainEncryptionKeyStore: EncryptionKeyStore {
    private let service = "com.humain.cascade"
    private let databasePath: String
    private let requireUserPresence: Bool

    public init(databasePath: String, requireUserPresence: Bool = false) {
        self.databasePath = databasePath
        self.requireUserPresence = requireUserPresence
    }

    public func load() throws -> Data? {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            return item as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw EncryptionAtRestError.keychainFailed(status)
        }
        #else
        return nil
        #endif
    }

    public func save(_ key: Data) throws {
        #if canImport(Security)
        var add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(),
            kSecValueData as String: key,
        ]
        if requireUserPresence {
            var accessControlError: Unmanaged<CFError>?
            guard let accessControl = SecAccessControlCreateWithFlags(
                kCFAllocatorDefault,
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                .userPresence,
                &accessControlError
            ) else {
                throw EncryptionAtRestError.keychainFailed(errSecParam)
            }
            add[kSecAttrAccessControl as String] = accessControl
        } else {
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account(),
            ]
            let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: key] as CFDictionary)
            guard update == errSecSuccess else {
                throw EncryptionAtRestError.keychainFailed(update)
            }
        } else if status != errSecSuccess {
            throw EncryptionAtRestError.keychainFailed(status)
        }
        #endif
    }

    public func destroy() throws {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(),
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw EncryptionAtRestError.keychainFailed(status)
        }
        #endif
    }

    /// Stable per-database account key (SHA-256 of the path — `String.hashValue`
    /// is per-process randomized and would not survive a relaunch).
    private func account() -> String {
        SHA256.hash(data: Data(databasePath.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

/// In-memory key store for tests (the Keychain prompts/fails in unsigned test
/// binaries — same reason `InMemoryAuditAnchor` exists).
public final class InMemoryEncryptionKeyStore: EncryptionKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: Data?
    public init() {}
    public func load() throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return key
    }
    public func save(_ key: Data) throws {
        lock.lock(); defer { lock.unlock() }
        self.key = key
    }
    public func destroy() throws {
        lock.lock(); defer { lock.unlock() }
        key = nil
    }
}

/// REAL key lifecycle for the (future) at-rest cipher. This part is not a stub:
/// `loadOrCreateKey` mints and persists a 256-bit key today, so the day the
/// cipher lands the key already has a managed lifecycle.
///
/// ## Key-loss contract (BY DESIGN)
///
/// If the key is lost (Keychain wiped, device migration without Keychain,
/// `destroyKey()` called), an *encrypted* store is UNRECOVERABLE. That is the
/// point of encryption at rest — there is deliberately no escrow and no
/// backdoor. Recovery is: `destroyKey()` → delete the database file (and
/// sidecars) → re-record from scratch. A store that was encrypted must NEVER
/// silently fall back to plaintext; if the key cannot be loaded the open must
/// fail loudly (LAW 7: MISSED, never FALSE).
public struct KeyCustodian: Sendable {
    public static let keyLength = 32 // 256-bit raw key

    private let keyStore: any EncryptionKeyStore

    public init(keyStore: any EncryptionKeyStore) {
        self.keyStore = keyStore
    }

    /// Production convenience: Keychain-backed, keyed to the database path.
    public init(databasePath: String, requireUserPresence: Bool = false) {
        self.init(keyStore: KeychainEncryptionKeyStore(
            databasePath: databasePath,
            requireUserPresence: requireUserPresence
        ))
    }

    /// Returns the existing key, or mints + persists a fresh 32-byte key.
    /// Idempotent: repeated calls return the SAME key until `destroyKey()`.
    public func loadOrCreateKey() throws -> Data {
        if let existing = try keyStore.load(), existing.count == Self.keyLength {
            return existing
        }
        let fresh = try Self.generateKey()
        try keyStore.save(fresh)
        return fresh
    }

    /// The key-loss recovery primitive: irreversibly discards the key. Any
    /// store encrypted under it becomes permanently unreadable (see the
    /// key-loss contract above); the next `loadOrCreateKey()` mints a new key
    /// for a NEW store.
    public func destroyKey() throws {
        try keyStore.destroy()
    }

    /// Renders a raw key for SQLCipher's raw-key PRAGMA form:
    /// `PRAGMA key = "x'<64 hex chars>'";` — raw form skips the KDF so the key
    /// is exactly the Keychain bytes (no salt/derivation version drift).
    public func keyHexForPragma(_ key: Data) -> String {
        "x'" + key.map { String(format: "%02x", $0) }.joined() + "'"
    }

    private static func generateKey() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: keyLength)
        #if canImport(Security)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw EncryptionAtRestError.keyGenerationFailed(status)
        }
        #else
        var generator = SystemRandomNumberGenerator()
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: .min ... .max, using: &generator)
        }
        #endif
        return Data(bytes)
    }
}

// MARK: - SQLCipher envelope (HONEST STUB)

/// The SQLCipher envelope — an HONEST STUB. Package.swift has NO SQLCipher
/// dependency, so this envelope cannot key a connection; it throws
/// `cipherUnavailable` from `prepareConnection` (fail fast, LAW 8 — it can
/// never fake-encrypt) and reports `.unavailable`. The `KeyCustodian` it
/// carries is real: the key lifecycle works today even though the cipher does
/// not exist yet.
///
/// The one-time plaintext → encrypted migration procedure and the cipher-swap
/// TODO live in the file-level doc block at the top of this file.
public struct SQLCipherEnvelope: StoreEncryptionEnvelope {
    /// Compile-time gate: SQLCipher is NOT linked into this build. A test pins
    /// this false — whoever adds the SQLCipher package and flips it must
    /// consciously break that test and implement `PRAGMA key` + the
    /// `SELECT count(*) FROM sqlite_master` verify below.
    public static let isSQLCipherLinked = false

    public let custodian: KeyCustodian

    public init(custodian: KeyCustodian) {
        self.custodian = custodian
    }

    public func prepareConnection(_ db: OpaquePointer, path: String) throws {
        // TODO(cipher-swap): when SQLCipher is linked —
        //   1. let key = try custodian.loadOrCreateKey()
        //   2. execute `PRAGMA key = "\(custodian.keyHexForPragma(key))";` as
        //      the FIRST statement on this connection
        //   3. verify with `SELECT count(*) FROM sqlite_master;` (a wrong key
        //      surfaces as SQLITE_NOTADB here, not at PRAGMA time)
        //   4. return .encrypted from `status`
        // Until then: fail fast. Never open-and-pretend.
        throw EncryptionAtRestError.cipherUnavailable(
            "SQLCipher is not linked into this build (Package.swift has no SQLCipher dependency); refusing to open the store as if it were encrypted"
        )
    }

    public var status: EncryptionAtRestStatus {
        .unavailable(reason: "SQLCipher not linked; store is PLAINTEXT")
    }
}
