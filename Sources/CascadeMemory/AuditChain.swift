import CryptoKit
import Foundation

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
/// next row. `CascadeStore.verifyAuditChain()` recomputes the chain and reports
/// the first row that no longer reconciles.
///
/// This is integrity (detect tampering), not confidentiality (hide content) — the
/// latter is the encryption-at-rest work tracked separately. The head hash can be
/// mirrored to the Keychain or an enterprise collector to defend against wholesale
/// truncation; that anchoring is a documented enterprise follow-up.
public enum AuditChain: Sendable {
    /// Hash that precedes the very first chained row.
    public static let genesis = String(repeating: "0", count: 64)

    /// Unit-separator-delimited serialization of the integrity-relevant fields.
    /// The order and separator are fixed so the hash is reproducible across
    /// processes and Cascade versions. `\u{1f}` (US) can't occur in normal
    /// audit text, so fields can't be confused for one another.
    public static func canonicalForm(createdAt: String, actor: String, action: String, detail: String) -> String {
        [createdAt, actor, action, detail].joined(separator: "\u{1f}")
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
    /// The chain no longer reconciles at this row id (content mutated, or a
    /// neighbouring row was inserted/deleted).
    case broken(atID: Int64)
    /// No chained rows exist yet.
    case empty
}
