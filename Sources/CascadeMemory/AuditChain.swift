import CryptoKit
import Foundation
#if canImport(Security)
import Security
#endif

/// Tamper-evident hash chaining for the audit log.
///
/// For an audit-first product, a mutable plaintext audit table is a liability: a
/// local process (or a compromised agent) could rewrite or delete history with no
/// trace. We make tampering *evident* by linking every row to its predecessor:
///
///     event_hash = SHA256( prev_hash ⏎ canonical_event )
///
/// where `prev_hash` is the previous row's `event_hash` (or the genesis constant
/// for the first chained row). Mutating any field of a row changes its
/// `event_hash`; deleting or inserting a row breaks the `prev_hash` link of the
/// next row. The internal chain alone can't catch a *tail truncation* or a
/// *wholesale rewrite* (the shortened/rewritten chain still looks internally
/// consistent), so the chain head `{count, hash}` is also mirrored to an
/// out-of-band `AuditAnchorStore` (the Keychain in production) — an attacker who
/// can edit the DB can't edit that anchor.
///
/// This is integrity (detect tampering), not confidentiality (hide content) — the
/// latter is the encryption-at-rest work tracked separately.
public enum AuditChain: Sendable {
    /// Hash that precedes the very first chained row.
    public static let genesis = String(repeating: "0", count: 64)

    /// Canonical serialization of the integrity-relevant fields. Each field is
    /// length-prefixed (`<utf8-byte-count>:<field>`) and unit-separated, so two
    /// different field splits can NEVER produce the same string — e.g.
    /// `(action:"a", detail:"b\u{1f}c")` and `(action:"a\u{1f}b", detail:"c")`
    /// encode differently. Order is fixed for cross-process/version reproducibility.
    public static func canonicalForm(createdAt: String, actor: String, action: String, detail: String) -> String {
        [createdAt, actor, action, detail]
            .map { "\($0.utf8.count):\($0)" }
            .joined(separator: "\u{1f}")
    }

    /// `event_hash = SHA256(prev_hash || US || canonical_event)` as lowercase hex.
    public static func hash(prev: String, canonical: String) -> String {
        let digest = SHA256.hash(data: Data((prev + "\u{1f}" + canonical).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Result of verifying the audit hash chain.
public enum AuditChainStatus: Equatable, Sendable {
    /// Every chained row reconciles; `verified` is how many were checked.
    case intact(verified: Int)
    /// The chain no longer reconciles at this row id (content mutated, a
    /// neighbouring row was inserted/deleted, or an unchained row appeared after
    /// the chain began).
    case broken(atID: Int64)
    /// The internal chain is consistent but disagrees with the out-of-band anchor —
    /// rows were truncated or appended/rewritten outside the trusted append path.
    case truncated(expectedCount: Int, foundCount: Int)
    /// No chained rows exist yet.
    case empty
}

// MARK: - External anchor

/// The trusted head of the audit chain: how many chained rows there are and the
/// last row's hash. Persisted OUTSIDE the SQLite file so truncation and wholesale
/// rewrite are detectable — an attacker who can edit the DB can't edit this.
public struct AuditHead: Sendable, Equatable, Codable {
    public let count: Int
    public let hash: String
    public init(count: Int, hash: String) {
        self.count = count
        self.hash = hash
    }
}

/// Out-of-band store for the audit chain head. Injected so production uses the
/// Keychain while tests use an in-memory double.
public protocol AuditAnchorStore: Sendable {
    func load(database id: String) -> AuditHead?
    func save(_ head: AuditHead, database id: String)
}

/// Default: no external anchor (internal chain integrity only). The app injects
/// `KeychainAuditAnchor`; headless/test contexts get this no-op so they never
/// touch the Keychain (which can prompt or fail in unsigned binaries).
public struct NullAuditAnchor: AuditAnchorStore {
    public init() {}
    public func load(database id: String) -> AuditHead? { nil }
    public func save(_ head: AuditHead, database id: String) {}
}

/// In-memory anchor for tests — persists across `CascadeStore` reopens when the
/// same instance is shared, so truncation/rewrite detection can be exercised
/// deterministically without the Keychain.
public final class InMemoryAuditAnchor: AuditAnchorStore, @unchecked Sendable {
    private let lock = NSLock()
    private var heads: [String: AuditHead] = [:]
    public init() {}
    public func load(database id: String) -> AuditHead? {
        lock.lock(); defer { lock.unlock() }
        return heads[id]
    }
    public func save(_ head: AuditHead, database id: String) {
        lock.lock(); defer { lock.unlock() }
        heads[id] = head
    }
}

/// Keychain-backed anchor. Stores the head as a device-only generic-password item
/// keyed by a stable hash of the database path. Best-effort: if the Keychain is
/// unavailable (e.g. an unsigned headless context) `load` returns nil and `save`
/// is a no-op, degrading to internal-chain-only integrity rather than failing.
public struct KeychainAuditAnchor: AuditAnchorStore {
    private let service = "com.humain.cascade.audit-anchor"
    public init() {}

    public func load(database id: String) -> AuditHead? {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(id),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let head = try? JSONDecoder().decode(AuditHead.self, from: data) else { return nil }
        return head
        #else
        return nil
        #endif
    }

    public func save(_ head: AuditHead, database id: String) {
        #if canImport(Security)
        guard let data = try? JSONEncoder().encode(head) else { return }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(id),
        ]
        if SecItemCopyMatching(base as CFDictionary, nil) == errSecSuccess {
            SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        } else {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
        #endif
    }

    /// Stable per-database account key (SHA-256 of the path — String.hashValue is
    /// per-process randomized and would not survive a relaunch).
    private func account(_ id: String) -> String {
        SHA256.hash(data: Data(id.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
