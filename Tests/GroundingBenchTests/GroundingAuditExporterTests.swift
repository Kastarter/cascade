import Foundation
import GroundingBench
import SQLite3
import Testing

@Suite(.serialized)
struct GroundingAuditExporterTests {
    @Test
    func exporterEmitsStableSchemaWithoutRawAuditDetail() throws {
        let fixture = try ExportFixture()
        try fixture.insertContext(id: 7, milliseconds: 1_800_000_000_000, imagePath: fixture.framePath)
        try fixture.insertAudit(
            id: 11,
            milliseconds: 1_800_000_000_100,
            action: "grounding.verifier",
            detail: "verdict=reject outcome=rejected failure=offscreen confidence=0.21 candidates=2 selectedCandidateHash=privateCandidate targetChars=6 targetHash=targetabc"
        )

        let cases = try GroundingAuditExporter().export(
            databasePath: fixture.dbURL,
            outputURL: fixture.outputURL,
            options: .init(targetTextByHash: ["targetabc": "Submit"])
        )
        let line = try String(contentsOf: fixture.outputURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        )

        #expect(cases.count == 1)
        #expect(object.keys.sorted() == [
            "app_bundle",
            "app_name",
            "case_id",
            "context_id",
            "expected_box_or_point",
            "frame_path",
            "outcome",
            "schema_version",
            "source_audit_event_id",
            "target_hash",
            "target_text",
        ])
        #expect(object["target_hash"] as? String == "targetabc")
        #expect(object["target_text"] as? String == "Submit")
        #expect(object["expected_box_or_point"] is NSNull)
        #expect(object["outcome"] as? String == "reject")
        #expect(!line.contains("privateCandidate"))
        #expect(!line.contains("targetChars"))
    }

    @Test
    func exporterRefusesLiveDatabasePathBeforeOpeningSQLite() throws {
        let live = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cascade/Cascade.sqlite")
        do {
            _ = try GroundingAuditExporter().cases(databasePath: live)
            Issue.record("Expected live DB path to be rejected")
        } catch let error as GroundingAuditExporterError {
            #expect(error.description.contains("Refusing to open live Cascade database"))
        }
    }

    @Test
    func exporterLeavesAuditOnlyTargetsHashedUntilSidecarSuppliesText() throws {
        let fixture = try ExportFixture()
        try fixture.insertContext(id: 8, milliseconds: 1_800_000_010_000, imagePath: fixture.framePath)
        try fixture.insertAudit(
            id: 12,
            milliseconds: 1_800_000_010_050,
            action: "agent.ground.miss",
            detail: "turn=3 missedTargetHash=privatehash controlCount=4 labelsHash=labels"
        )

        let auditOnly = try GroundingAuditExporter().cases(databasePath: fixture.dbURL)
        let withSidecar = try GroundingAuditExporter().cases(
            databasePath: fixture.dbURL,
            options: .init(targetTextByHash: ["privatehash": "Visible Button"])
        )

        #expect(auditOnly.first?.targetHash == "privatehash")
        #expect(auditOnly.first?.targetText == nil)
        #expect(auditOnly.first?.expectedBoxOrPoint == nil)
        #expect(auditOnly.first?.outcome == .unlabeled)
        #expect(withSidecar.first?.targetText == "Visible Button")
    }

    @Test
    func exporterLabelsOnlyWhenLaterClickHasSubsequentAcceptVerifier() throws {
        let fixture = try ExportFixture()
        try fixture.insertContext(id: 9, milliseconds: 1_800_000_020_000, imagePath: fixture.framePath)
        try fixture.insertAudit(
            id: 13,
            milliseconds: 1_800_000_020_000,
            action: "agent.ground.miss",
            detail: "turn=4 missedTargetHash=labeledtarget controlCount=1 labelsHash=abc"
        )
        try fixture.insertClick(milliseconds: 1_800_000_021_000, x: 74, y: 91)
        try fixture.insertAudit(
            id: 14,
            milliseconds: 1_800_000_022_000,
            action: "grounding.verifier",
            detail: "verdict=accept outcome=accepted failure=none confidence=0.94 targetChars=6 targetHash=labeledtarget"
        )

        let cases = try GroundingAuditExporter().cases(
            databasePath: fixture.dbURL,
            options: .init(targetTextByHash: ["labeledtarget": "Continue"])
        )
        let source = try #require(cases.first { $0.sourceAuditEventID == 13 })
        let expected = try #require(source.expectedBoxOrPoint)

        #expect(expected.kind == .point)
        #expect(expected.contains(CGPoint(x: 74, y: 91)))
        #expect(source.outcome == .accept)
    }
}

private final class ExportFixture {
    let directory: URL
    let dbURL: URL
    let outputURL: URL
    let framePath: String
    private let db: OpaquePointer?

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GroundingAuditExporter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        dbURL = directory.appendingPathComponent("Cascade.sqlite")
        outputURL = directory.appendingPathComponent("cases.jsonl")
        let frames = try GroundingBenchFixtures.generate(into: directory.appendingPathComponent("frames"))
        framePath = try #require(frames.first?.framePath)
        var handle: OpaquePointer?
        guard sqlite3_open(dbURL.path, &handle) == SQLITE_OK else {
            throw GroundingAuditExporterError.openFailed("test db")
        }
        db = handle
        try exec("""
        CREATE TABLE audit_event (
            id INTEGER PRIMARY KEY,
            created_at TEXT NOT NULL,
            actor TEXT NOT NULL,
            action TEXT NOT NULL,
            detail TEXT NOT NULL
        );
        CREATE TABLE recorded_context (
            id INTEGER PRIMARY KEY,
            captured_at TEXT NOT NULL,
            captured_ms INTEGER NOT NULL,
            app_name TEXT NOT NULL,
            bundle_identifier TEXT,
            image_path TEXT,
            safe_to_show INTEGER NOT NULL DEFAULT 1
        );
        CREATE TABLE input_event (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            captured_at TEXT NOT NULL,
            captured_ms INTEGER NOT NULL,
            kind TEXT NOT NULL,
            x REAL,
            y REAL,
            app_name TEXT NOT NULL,
            bundle_identifier TEXT
        );
        """)
    }

    deinit {
        sqlite3_close(db)
    }

    func insertContext(id: Int64, milliseconds: Int64, imagePath: String) throws {
        try exec("""
        INSERT INTO recorded_context (id, captured_at, captured_ms, app_name, bundle_identifier, image_path, safe_to_show)
        VALUES (\(id), '\(Self.iso(milliseconds))', \(milliseconds), 'FixtureApp', 'com.cascade.fixture', '\(imagePath)', 1);
        """)
    }

    func insertAudit(id: Int64, milliseconds: Int64, action: String, detail: String) throws {
        try exec("""
        INSERT INTO audit_event (id, created_at, actor, action, detail)
        VALUES (\(id), '\(Self.iso(milliseconds))', 'agent', '\(action)', '\(detail)');
        """)
    }

    func insertClick(milliseconds: Int64, x: Double, y: Double) throws {
        try exec("""
        INSERT INTO input_event (captured_at, captured_ms, kind, x, y, app_name, bundle_identifier)
        VALUES ('\(Self.iso(milliseconds))', \(milliseconds), 'click', \(x), \(y), 'FixtureApp', 'com.cascade.fixture');
        """)
    }

    private func exec(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw GroundingAuditExporterError.queryFailed(message)
        }
    }

    private static func iso(_ milliseconds: Int64) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1000))
    }
}
