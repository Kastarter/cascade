import Foundation
import SQLite3

// §4d perception-anchor collection — the WRITE side only.
//
// A perception anchor is a verified (bundle_id, semantic-text-hash) →
// AXTargetDescriptor ensemble: "in this app, the control whose semantic phrase
// hashes to H looked like THIS the last time a click on it was real". Rows come
// from two evidence sources:
//   • "human"          — a recorded human click that carried its AX descriptor
//                        (InputRecorder drain hook).
//   • "agent_verified" — an agent click whose effect the PostActionVerifier
//                        ladder confirmed (CascadeAppModel verify hook).
//
// Deliberately NO read/recall path exists anywhere in the runtime: the only
// reader is the TEST/INSPECTION accessor below, never GroundingRouter/replay.
// An anchor that is missing, unwritable, or sanitized away degrades to a
// MISSED recall, never a FALSE one (LAW 7). Everything is gated behind
// `cascade.anchorWrite`, default OFF (LAW 3/6).
//
// Known accepted collision: UNIQUE(bundle_id, target_text_hash) collapses two
// distinct controls with identical semantic phrases into one anchor whose
// descriptor_json (and source) is last-writer-wins. Acceptable for pure
// write-side collection — a future flagged read path (cascade.anchorRecall)
// owns precision.

/// UserDefaults gate for perception-anchor writes. Default OFF: an unset key
/// reads `false`, so the shipped path never decodes, hits AX, or touches the
/// table. Mirrors `GroundingBenchFlags` / `PerceptionSnapshotFlag`.
public enum PerceptionAnchorWriteFlag {
    public static let key = "cascade.anchorWrite"

    public static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key)
    }
}

/// One stored anchor row — a read model for tests/inspection only.
public struct PerceptionAnchor: Equatable, Sendable {
    public let bundleID: String
    public let targetTextHash: String
    public let descriptorJSON: String
    public let source: String
    public let verifiedCount: Int
    public let updatedAt: Date

    public init(
        bundleID: String,
        targetTextHash: String,
        descriptorJSON: String,
        source: String,
        verifiedCount: Int,
        updatedAt: Date
    ) {
        self.bundleID = bundleID
        self.targetTextHash = targetTextHash
        self.descriptorJSON = descriptorJSON
        self.source = source
        self.verifiedCount = verifiedCount
        self.updatedAt = updatedAt
    }
}

/// Pure candidate extraction from recorded input events — the entire logic of
/// the InputRecorder drain hook, factored out so it is headless-testable
/// without CGEvent taps or live AX.
public enum PerceptionAnchorWriter {
    /// Anchor candidates from a drained batch of input events: clicks that
    /// carry both a bundle identifier and a decodable AX target descriptor
    /// with a semantic text hash. Candidates without a hash are SKIPPED —
    /// missed, never false (LAW 7).
    public static func anchorCandidates(
        from events: [InputEvent]
    ) -> [(bundleID: String, textHash: String, descriptorJSON: String)] {
        events.compactMap { event in
            switch event.kind {
            case .click, .doubleClick, .rightClick:
                break
            case .type, .key, .scroll:
                return nil
            }
            guard let bundleID = event.bundleIdentifier, !bundleID.isEmpty,
                  let json = event.targetDescriptor, !json.isEmpty,
                  let descriptor = AXTargetDescriptorV2.decode(json),
                  let hash = descriptor.semanticTextHash ?? descriptor.semanticHash
            else { return nil }
            return (bundleID: bundleID, textHash: hash, descriptorJSON: json)
        }
    }
}

extension CascadeStore {
    /// Upserts one perception anchor. First sighting inserts with
    /// `verified_count = 1`; every re-verification of the same
    /// (bundle_id, target_text_hash) increments the count and refreshes the
    /// descriptor/source/updated_at to the latest evidence.
    ///
    /// Belt-and-braces privacy gate: the descriptor JSON is re-run through
    /// `InputEventSanitizer.sanitize(descriptor:)` here (the agent-verified
    /// path bypasses the recorder's gate). If sanitization rejects it the
    /// write is SKIPPED (returns false) — missed, never false (LAW 7).
    @discardableResult
    public func upsertPerceptionAnchor(
        bundleID: String,
        targetTextHash: String,
        descriptorJSON: String,
        source: String,
        at date: Date = Date()
    ) throws -> Bool {
        let trimmedBundle = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedHash = targetTextHash.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBundle.isEmpty, !trimmedHash.isEmpty,
              let safeDescriptor = InputEventSanitizer.sanitize(descriptor: descriptorJSON)
        else { return false }
        let sql = """
        INSERT INTO perception_anchor
            (bundle_id, target_text_hash, descriptor_json, source, verified_count, updated_at)
        VALUES (?, ?, ?, ?, 1, ?)
        ON CONFLICT(bundle_id, target_text_hash) DO UPDATE SET
            verified_count = perception_anchor.verified_count + 1,
            descriptor_json = excluded.descriptor_json,
            source = excluded.source,
            updated_at = excluded.updated_at;
        """
        try withStatement(sql) { statement in
            Self.anchorBind(trimmedBundle, at: 1, in: statement)
            Self.anchorBind(trimmedHash, at: 2, in: statement)
            Self.anchorBind(safeDescriptor, at: 3, in: statement)
            Self.anchorBind(source, at: 4, in: statement)
            Self.anchorBind(Self.anchorDateString(date), at: 5, in: statement)
            try stepDone(statement)
        }
        return true
    }

    /// TEST/INSPECTION ONLY — NOT a grounding read source. The runtime read
    /// path deliberately stays absent (LAW 7: degrade to missed recall, never
    /// a false anchor); the only callers are the focused store test and manual
    /// sqlite3 spot-checks. Do not wire into GroundingRouter/replay — a future
    /// read path arrives behind its own flag (cascade.anchorRecall).
    public func perceptionAnchors(bundleID: String? = nil, limit: Int = 100) throws -> [PerceptionAnchor] {
        let sql = """
        SELECT bundle_id, target_text_hash, descriptor_json, source, verified_count, updated_at
        FROM perception_anchor
        WHERE ? IS NULL OR bundle_id = ?
        ORDER BY verified_count DESC, updated_at DESC, id DESC
        LIMIT ?;
        """
        return try withStatement(sql) { statement in
            Self.anchorBind(bundleID, at: 1, in: statement)
            Self.anchorBind(bundleID, at: 2, in: statement)
            sqlite3_bind_int(statement, 3, Int32(max(0, limit)))
            var rows: [PerceptionAnchor] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(PerceptionAnchor(
                    bundleID: Self.anchorText(statement, 0) ?? "",
                    targetTextHash: Self.anchorText(statement, 1) ?? "",
                    descriptorJSON: Self.anchorText(statement, 2) ?? "",
                    source: Self.anchorText(statement, 3) ?? "",
                    verifiedCount: Int(sqlite3_column_int(statement, 4)),
                    updatedAt: Self.anchorDate(from: Self.anchorText(statement, 5)) ?? Date(timeIntervalSince1970: 0)
                ))
            }
            return rows
        }
    }

    // MARK: - Private helpers (file-local mirror of the module's bind pattern)

    private static func anchorBind(_ value: String?, at index: Int32, in statement: OpaquePointer) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    private static func anchorDateString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func anchorDate(from value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func anchorText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: cString)
    }
}
