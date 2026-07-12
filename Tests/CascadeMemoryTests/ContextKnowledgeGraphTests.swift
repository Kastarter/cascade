@testable import CascadeMemory
import Foundation
import SQLite3
import Testing

private struct KnowledgeGraphFixture {
    let directory: URL
    let databasePath: String
    let store: CascadeStore

    init(_ name: String) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        databasePath = directory.appendingPathComponent("cascade.sqlite").path
        store = try CascadeStore(path: databasePath)
    }

    func frame(_ name: String) throws -> String {
        let url = directory.appendingPathComponent(name)
        try Data("real-frame-\(name)".utf8).write(to: url, options: .atomic)
        return url.path
    }
}

private enum TestDeleteError: Error { case forced }
private enum TestInterruptionError: Error { case simulatedCrash }

private func fixedUTCDate(_ value: String) throws -> Date {
    let formatter = ISO8601DateFormatter()
    return try #require(formatter.date(from: value))
}

private func kgRawStrings(_ path: String, _ sql: String) throws -> [String] {
    var database: OpaquePointer?
    guard sqlite3_open(path, &database) == SQLITE_OK else {
        throw CascadeStoreError.openFailed("raw sqlite open failed")
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
        throw CascadeStoreError.prepareFailed("raw sqlite prepare failed")
    }
    defer { sqlite3_finalize(statement) }
    var result: [String] = []
    while sqlite3_step(statement) == SQLITE_ROW {
        result.append(sqlite3_column_text(statement, 0).map(String.init(cString:)) ?? "")
    }
    return result
}

private func kgRawInt(_ path: String, _ sql: String) throws -> Int64 {
    var database: OpaquePointer?
    guard sqlite3_open(path, &database) == SQLITE_OK else {
        throw CascadeStoreError.openFailed("raw sqlite open failed")
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
        throw CascadeStoreError.prepareFailed("raw sqlite prepare failed")
    }
    defer { sqlite3_finalize(statement) }
    return sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int64(statement, 0) : 0
}

private func kgRawExec(_ path: String, _ sql: String) throws {
    var database: OpaquePointer?
    guard sqlite3_open(path, &database) == SQLITE_OK else {
        throw CascadeStoreError.openFailed("raw sqlite open failed")
    }
    defer { sqlite3_close(database) }
    var error: UnsafeMutablePointer<CChar>?
    defer { sqlite3_free(error) }
    guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
        throw CascadeStoreError.sqlite(error.map { String(cString: $0) } ?? "raw sqlite error")
    }
}

private func legacyEscaped(_ value: String) -> String {
    value.replacingOccurrences(of: "'", with: "''")
}

private func auditField(_ name: String, in detail: String) -> String? {
    detail.split(separator: " ").first { $0.hasPrefix("\(name)=") }?
        .dropFirst(name.count + 1)
        .description
}

private func makeGraphContexts(
    firstDate: Date,
    secondDate: Date,
    firstFrame: String,
    secondFrame: String
) -> [RecordedContext] {
    [
        RecordedContext(
            capturedAt: firstDate,
            source: .screen,
            appName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            windowTitle: "Acme Q2 Budget",
            ocrText: "Review https://example.com/q2-budget APER-42 TODO: reconcile runway by 2030-01-15 #finance",
            imagePath: firstFrame
        ),
        RecordedContext(
            capturedAt: secondDate,
            source: .screen,
            appName: "Xcode",
            bundleIdentifier: "com.apple.dt.Xcode",
            windowTitle: "Cascade — ContextKnowledgeGraph.swift",
            ocrText: "Implement APER-42 in /Users/shared/Cascade/ContextKnowledgeGraph.swift for the Acme budget",
            imagePath: secondFrame
        ),
    ]
}

@Test
func testLegacyKnowledgeGraphEdgesDecodeConservativeEndpointObservations() throws {
    let json = """
    {
      "from": "window:legacy",
      "to": "session:legacy",
      "kind": "session_membership",
      "weight": 3,
      "first_seen_ms": 1000,
      "last_seen_ms": 3000
    }
    """

    let edge = try JSONDecoder().decode(ContextKnowledgeGraphEdge.self, from: Data(json.utf8))

    #expect(edge.observedAtMs == [1000, 3000])
}

@Test
func testCompactionDeletesOnlyFramesOlderThan24HoursAndPersistsGraph() async throws {
    let fixture = try KnowledgeGraphFixture("ContextKGDelete")
    let now = try fixedUTCDate("2030-01-02T12:00:00Z")
    let cutoff = now.addingTimeInterval(-24 * 3600)
    let oldOne = try fixture.frame("old-safari.heic")
    let oldTwo = try fixture.frame("old-xcode.heic")
    let exactCutoffPath = try fixture.frame("exact-cutoff.heic")
    let recentPath = try fixture.frame("recent.heic")
    let inserted = try await fixture.store.insertContexts(
        makeGraphContexts(
            firstDate: now.addingTimeInterval(-26 * 3600),
            secondDate: now.addingTimeInterval(-25.5 * 3600),
            firstFrame: oldOne,
            secondFrame: oldTwo
        ) + [
            RecordedContext(
                capturedAt: cutoff,
                source: .screen,
                appName: "Calendar",
                windowTitle: "Exactly 24 hours",
                ocrText: "Equality is not yet eligible",
                imagePath: exactCutoffPath
            ),
            RecordedContext(
                capturedAt: now.addingTimeInterval(-23 * 3600),
                source: .screen,
                appName: "Notes",
                windowTitle: "Still recent",
                ocrText: "This frame must remain",
                imagePath: recentPath
            ),
        ]
    )

    let result = try await fixture.store.compactAgedContextsIntoKnowledgeGraph(olderThan: cutoff)

    #expect(result.graphsWritten == 1)
    #expect(result.contextsCovered == 2)
    #expect(result.frameReferencesCleared == 2)
    #expect(result.filesDeleted == 2)
    #expect(result.deletionFailures == 0)
    #expect(result.isCaughtUp)
    #expect(!FileManager.default.fileExists(atPath: oldOne))
    #expect(!FileManager.default.fileExists(atPath: oldTwo))
    #expect(FileManager.default.fileExists(atPath: exactCutoffPath))
    #expect(FileManager.default.fileExists(atPath: recentPath))
    #expect(try await fixture.store.context(id: inserted[0].id)?.imagePath == nil)
    #expect(try await fixture.store.context(id: inserted[1].id)?.imagePath == nil)
    #expect(try await fixture.store.context(id: inserted[2].id)?.imagePath == exactCutoffPath)
    #expect(try await fixture.store.context(id: inserted[3].id)?.imagePath == recentPath)

    let day = EventStoreLayout.utcDayKey(for: inserted[0].capturedAt)
    let graph = try #require(try await fixture.store.knowledgeGraph(forDay: day))
    let encoded = try ContextKnowledgeGraphBuilder.canonicalData(for: graph)
    let decoded = try JSONDecoder().decode(ContextKnowledgeGraph.self, from: encoded)
    #expect(decoded == graph)
    #expect(graph.schemaVersion == 2)
    #expect(graph.partitionKey == "utc-day:\(day)")
    #expect(graph.source.contextCount == 2)
    #expect(graph.range.endMs < EventStoreLayout.capturedMilliseconds(for: cutoff))
    #expect(Set(graph.nodes.map(\.type)) == Set(ContextKnowledgeGraphNode.NodeType.allCases))
    #expect(Set(graph.edges.map(\.kind)) == Set(ContextKnowledgeGraphEdge.Kind.allCases))
    #expect(graph.edges.allSatisfy { !$0.observedAtMs.isEmpty })

    let manifest = try #require(try await fixture.store.dayPartitionManifest(dayKey: day))
    #expect(manifest.frameCount == 2) // the equality and 23-hour rows share this UTC day

    let audit = try #require(try await fixture.store.recentAudit(limit: 10)
        .first { $0.action == "retention.frame_compaction" })
    #expect(audit.detail.contains("references=2"))
    #expect(audit.detail.contains("files=2"))
    #expect(!audit.detail.contains("reconcile runway"))
    #expect(!audit.detail.contains(fixture.directory.path))
    let batchAudits = try await fixture.store.recentAudit(limit: 10)
    let intent = try #require(batchAudits.first { $0.action == "retention.frame_delete_intent" })
    let committed = try #require(batchAudits.first { $0.action == "retention.frame_delete_committed" })
    #expect(auditField("batch", in: intent.detail) == auditField("batch", in: committed.detail))
    #expect(intent.detail.contains(AuditIdentity.hash("frame-path:\(oldOne)")))
    #expect(intent.detail.contains(AuditIdentity.hash("frame-path:\(oldTwo)")))
    #expect(!intent.detail.contains(oldOne))
    #expect(!intent.detail.contains(oldTwo))
    #expect(committed.detail.contains("references=2"))
    #expect(committed.detail.contains("files=2"))
    #expect(committed.detail.contains("alreadyMissing=0"))
    #expect(CapturePrivacyPolicy.default.retentionByDataClass["frames"]?.maxAgeDays == 1)
}

@Test
func testCrashAfterUnlinkKeepsIntentAndRecoveryAuditsMissingFile() async throws {
    let fixture = try KnowledgeGraphFixture("ContextKGCrashAfterUnlink")
    let now = try fixedUTCDate("2030-01-03T12:00:00Z")
    let cutoff = now.addingTimeInterval(-24 * 3600)
    let frame = try fixture.frame("crash-after-unlink.heic")
    let context = try await fixture.store.insert(RecordedContext(
        capturedAt: now.addingTimeInterval(-25 * 3600),
        source: .screen,
        appName: "Safari",
        windowTitle: "Durable deletion intent",
        ocrText: "frame must reconcile after a simulated crash",
        imagePath: frame
    ))

    do {
        _ = try await fixture.store.compactAgedContextsIntoKnowledgeGraph(
            olderThan: cutoff,
            deletingFrameWith: { try FileManager.default.removeItem(atPath: $0) },
            onBatchPhase: { phase, _ in
                if phase == .afterFileDeletion { throw TestInterruptionError.simulatedCrash }
            }
        )
        Issue.record("Expected simulated interruption after unlink")
    } catch TestInterruptionError.simulatedCrash {
        // Expected: this models termination before the image_path transaction.
    }

    #expect(!FileManager.default.fileExists(atPath: frame))
    #expect(try await fixture.store.context(id: context.id)?.imagePath == frame)
    let interruptedAudits = try await fixture.store.recentAudit(limit: 20)
    let intent = try #require(interruptedAudits.first { $0.action == "retention.frame_delete_intent" })
    #expect(intent.detail.contains(AuditIdentity.hash("frame-path:\(frame)")))
    #expect(!intent.detail.contains(frame))
    #expect(!interruptedAudits.contains { $0.action == "retention.frame_delete_committed" })

    let recovered = try await fixture.store.compactAgedContextsIntoKnowledgeGraph(olderThan: cutoff)
    #expect(recovered.filesDeleted == 0)
    #expect(recovered.frameReferencesCleared == 1)
    #expect(recovered.isCaughtUp)
    #expect(try await fixture.store.context(id: context.id)?.imagePath == nil)
    let recoveredAudits = try await fixture.store.recentAudit(limit: 30)
    let outcome = try #require(recoveredAudits.first { $0.action == "retention.frame_delete_committed" })
    #expect(outcome.detail.contains("references=1"))
    #expect(outcome.detail.contains("files=0"))
    #expect(outcome.detail.contains("alreadyMissing=1"))
}

@Test
func testCrashAfterReferenceCommitLeavesCorrelatedDurableIntent() async throws {
    let fixture = try KnowledgeGraphFixture("ContextKGCrashAfterReferenceCommit")
    let now = try fixedUTCDate("2030-01-04T12:00:00Z")
    let cutoff = now.addingTimeInterval(-24 * 3600)
    let frame = try fixture.frame("crash-after-commit.heic")
    let context = try await fixture.store.insert(RecordedContext(
        capturedAt: now.addingTimeInterval(-25 * 3600),
        source: .screen,
        appName: "Notes",
        windowTitle: "Committed reference clear",
        ocrText: "intent survives the post-commit crash window",
        imagePath: frame
    ))

    do {
        _ = try await fixture.store.compactAgedContextsIntoKnowledgeGraph(
            olderThan: cutoff,
            deletingFrameWith: { try FileManager.default.removeItem(atPath: $0) },
            onBatchPhase: { phase, _ in
                if phase == .afterReferenceCommit { throw TestInterruptionError.simulatedCrash }
            }
        )
        Issue.record("Expected simulated interruption after reference commit")
    } catch TestInterruptionError.simulatedCrash {
        // Expected: the SQL commit landed but the outcome audit did not.
    }

    #expect(!FileManager.default.fileExists(atPath: frame))
    #expect(try await fixture.store.context(id: context.id)?.imagePath == nil)
    let audits = try await fixture.store.recentAudit(limit: 20)
    let intent = try #require(audits.first { $0.action == "retention.frame_delete_intent" })
    #expect(intent.detail.contains(AuditIdentity.hash("frame-path:\(frame)")))
    #expect(!audits.contains { $0.action == "retention.frame_delete_committed" })

    let retry = try await fixture.store.compactAgedContextsIntoKnowledgeGraph(olderThan: cutoff)
    #expect(retry.frameReferencesCleared == 0)
    #expect(retry.filesDeleted == 0)
    #expect(retry.isCaughtUp)
    let retryAudits = try await fixture.store.recentAudit(limit: 30)
    #expect(retryAudits.contains { $0.id == intent.id })
}

@Test
func testCompactionIsIdempotent() async throws {
    let fixture = try KnowledgeGraphFixture("ContextKGIdempotent")
    let now = try fixedUTCDate("2030-02-02T12:00:00Z")
    let frame = try fixture.frame("idempotent.heic")
    let context = try await fixture.store.insert(RecordedContext(
        capturedAt: now.addingTimeInterval(-25 * 3600),
        source: .screen,
        appName: "Safari",
        windowTitle: "Roadmap",
        ocrText: "Idempotent APER-55 roadmap",
        imagePath: frame
    ))
    let cutoff = now.addingTimeInterval(-24 * 3600)

    let first = try await fixture.store.compactAgedContextsIntoKnowledgeGraph(olderThan: cutoff)
    let metadataBefore = try kgRawStrings(
        fixture.databasePath,
        "SELECT graph_sha256 || '|' || updated_at FROM context_kg;"
    )
    let auditBefore = try await fixture.store.recentAudit(limit: 20)
        .filter { $0.action == "retention.frame_compaction" }.count
    let second = try await fixture.store.compactAgedContextsIntoKnowledgeGraph(olderThan: cutoff)
    let metadataAfter = try kgRawStrings(
        fixture.databasePath,
        "SELECT graph_sha256 || '|' || updated_at FROM context_kg;"
    )
    let auditAfter = try await fixture.store.recentAudit(limit: 20)
        .filter { $0.action == "retention.frame_compaction" }.count

    #expect(first.graphsWritten == 1)
    #expect(try await fixture.store.context(id: context.id)?.imagePath == nil)
    #expect(second.graphsWritten == 0)
    #expect(second.contextsCovered == 0)
    #expect(second.frameReferencesCleared == 0)
    #expect(second.filesDeleted == 0)
    #expect(second.deletionFailures == 0)
    #expect(second.isCaughtUp)
    #expect(metadataAfter == metadataBefore)
    #expect(auditAfter == auditBefore)
}

@Test
func testCompactionAdvancesAPartialUTCDay() async throws {
    let fixture = try KnowledgeGraphFixture("ContextKGPartial")
    let dayStart = try fixedUTCDate("2030-03-04T00:00:00Z")
    let earlyPath = try fixture.frame("early.heic")
    let laterPath = try fixture.frame("later.heic")
    let inserted = try await fixture.store.insertContexts([
        RecordedContext(
            capturedAt: dayStart.addingTimeInterval(10 * 3600),
            source: .screen,
            appName: "Safari",
            windowTitle: "Morning plan",
            ocrText: "Morning APER-71",
            imagePath: earlyPath
        ),
        RecordedContext(
            capturedAt: dayStart.addingTimeInterval(14 * 3600),
            source: .screen,
            appName: "Xcode",
            windowTitle: "Afternoon implementation",
            ocrText: "Afternoon APER-72",
            imagePath: laterPath
        ),
    ])

    let first = try await fixture.store.compactAgedContextsIntoKnowledgeGraph(
        olderThan: dayStart.addingTimeInterval(12 * 3600)
    )
    let firstGraph = try #require(try await fixture.store.knowledgeGraph(forDay: EventStoreLayout.utcDayKey(for: dayStart)))
    #expect(first.graphsWritten == 1)
    #expect(firstGraph.source.contextCount == 1)
    #expect(!FileManager.default.fileExists(atPath: earlyPath))
    #expect(FileManager.default.fileExists(atPath: laterPath))
    #expect(try await fixture.store.context(id: inserted[1].id)?.imagePath == laterPath)

    let second = try await fixture.store.compactAgedContextsIntoKnowledgeGraph(
        olderThan: dayStart.addingTimeInterval(15 * 3600)
    )
    let secondGraph = try #require(try await fixture.store.knowledgeGraph(forDay: EventStoreLayout.utcDayKey(for: dayStart)))
    #expect(second.graphsWritten == 1)
    #expect(second.contextsCovered == 1)
    #expect(secondGraph.source.contextCount == 2)
    #expect(secondGraph.source.maxContextID == inserted[1].id)
    #expect(try kgRawInt(fixture.databasePath, "SELECT COUNT(*) FROM context_kg;") == 1)
    #expect(!FileManager.default.fileExists(atPath: laterPath))
    #expect(try await fixture.store.context(id: inserted[1].id)?.imagePath == nil)
}

@Test
func testSharedPathReferencedByRecentContextIsNotDeleted() async throws {
    let fixture = try KnowledgeGraphFixture("ContextKGShared")
    let now = try fixedUTCDate("2030-04-02T12:00:00Z")
    let shared = try fixture.frame("shared.heic")
    let inserted = try await fixture.store.insertContexts([
        RecordedContext(
            capturedAt: now.addingTimeInterval(-25 * 3600),
            source: .screen,
            appName: "Safari",
            ocrText: "old shared frame",
            imagePath: shared
        ),
        RecordedContext(
            capturedAt: now.addingTimeInterval(-23 * 3600),
            source: .screen,
            appName: "Safari",
            ocrText: "recent shared frame",
            imagePath: shared
        ),
    ])

    let result = try await fixture.store.compactAgedContextsIntoKnowledgeGraph(
        olderThan: now.addingTimeInterval(-24 * 3600)
    )

    #expect(result.frameReferencesCleared == 1)
    #expect(result.filesDeleted == 0)
    #expect(FileManager.default.fileExists(atPath: shared))
    #expect(try await fixture.store.context(id: inserted[0].id)?.imagePath == nil)
    #expect(try await fixture.store.context(id: inserted[1].id)?.imagePath == shared)
}

@Test
func testDeletionFailureLeavesReferenceForRetry() async throws {
    let fixture = try KnowledgeGraphFixture("ContextKGFailure")
    let now = try fixedUTCDate("2030-05-02T12:00:00Z")
    let frame = try fixture.frame("retry.heic")
    let context = try await fixture.store.insert(RecordedContext(
        capturedAt: now.addingTimeInterval(-25 * 3600),
        source: .screen,
        appName: "Xcode",
        windowTitle: "Retry deletion",
        ocrText: "Retryable APER-88",
        imagePath: frame
    ))
    let cutoff = now.addingTimeInterval(-24 * 3600)

    let failed = try await fixture.store.compactAgedContextsIntoKnowledgeGraph(
        olderThan: cutoff,
        deletingFrameWith: { _ in throw TestDeleteError.forced }
    )
    let metadataBefore = try kgRawStrings(
        fixture.databasePath,
        "SELECT graph_sha256 || '|' || updated_at FROM context_kg;"
    )
    #expect(failed.graphsWritten == 1)
    #expect(failed.deletionFailures == 1)
    #expect(!failed.isCaughtUp)
    #expect(FileManager.default.fileExists(atPath: frame))
    #expect(try await fixture.store.context(id: context.id)?.imagePath == frame)
    #expect(try await fixture.store.knowledgeGraph(forDay: EventStoreLayout.utcDayKey(for: context.capturedAt)) != nil)

    let retried = try await fixture.store.compactAgedContextsIntoKnowledgeGraph(olderThan: cutoff)
    let metadataAfter = try kgRawStrings(
        fixture.databasePath,
        "SELECT graph_sha256 || '|' || updated_at FROM context_kg;"
    )
    #expect(retried.graphsWritten == 0)
    #expect(retried.filesDeleted == 1)
    #expect(retried.frameReferencesCleared == 1)
    #expect(retried.isCaughtUp)
    #expect(metadataAfter == metadataBefore)
    #expect(!FileManager.default.fileExists(atPath: frame))
    #expect(try await fixture.store.context(id: context.id)?.imagePath == nil)
}

@Test
func testFrameCompactionPreservesOCRAndRecordedContextFTS() async throws {
    let fixture = try KnowledgeGraphFixture("ContextKGFTS")
    let now = try fixedUTCDate("2030-06-02T12:00:00Z")
    let frame = try fixture.frame("fts.heic")
    let context = try await fixture.store.insert(RecordedContext(
        capturedAt: now.addingTimeInterval(-25 * 3600),
        source: .screen,
        appName: "Numbers",
        windowTitle: "Forecast",
        ocrText: "heliotropeforecast unique searchable phrase",
        imagePath: frame
    ))

    _ = try await fixture.store.compactAgedContextsIntoKnowledgeGraph(
        olderThan: now.addingTimeInterval(-24 * 3600)
    )

    let retained = try #require(try await fixture.store.context(id: context.id))
    #expect(retained.imagePath == nil)
    #expect(retained.ocrText?.contains("heliotropeforecast") == true)
    #expect(try await fixture.store.searchContexts(query: "heliotropeforecast").map(\.id).contains(context.id))
    #expect(try await fixture.store.hybridContexts(matching: "heliotropeforecast").map(\.id).contains(context.id))
}

@Test
func testPruneAfterCompactionPreservesKGAndKGFTS() async throws {
    let fixture = try KnowledgeGraphFixture("ContextKGPrune")
    let now = Date()
    let frame = try fixture.frame("pruned.heic")
    let context = try await fixture.store.insert(RecordedContext(
        capturedAt: now.addingTimeInterval(-8 * 24 * 3600),
        source: .screen,
        appName: "Safari",
        windowTitle: "Historic Acme plan",
        ocrText: "elderberryarchive historic Acme APER-99 https://example.com/archive",
        imagePath: frame
    ))
    let day = EventStoreLayout.utcDayKey(for: context.capturedAt)

    _ = try await fixture.store.compactAgedContextsIntoKnowledgeGraph(
        olderThan: now.addingTimeInterval(-24 * 3600)
    )
    _ = try await fixture.store.prune(maxAge: 7 * 24 * 3600, maxTotalBytes: .max)

    #expect(try await fixture.store.context(id: context.id) == nil)
    #expect(try await fixture.store.searchContexts(query: "elderberryarchive").isEmpty)
    #expect(try await fixture.store.knowledgeGraph(forDay: day) != nil)
    let graphHits = try await fixture.store.searchKnowledgeGraphs(matching: "elderberryarchive")
    #expect(graphHits.map(\.graph.day).contains(day))
    #expect(try kgRawInt(fixture.databasePath, "SELECT COUNT(*) FROM context_kg_fts;") == 1)
}

@Test
func testLateBackfillMergesWithoutReplacingPrunedDayGraph() async throws {
    let fixture = try KnowledgeGraphFixture("ContextKGLateBackfill")
    let now = Date()
    let firstDate = now.addingTimeInterval(-8 * 24 * 3600)
    let firstPath = try fixture.frame("original.heic")
    let original = try await fixture.store.insert(RecordedContext(
        capturedAt: firstDate,
        source: .screen,
        appName: "Safari",
        windowTitle: "Original history",
        ocrText: "originalcobalt APER-110",
        imagePath: firstPath
    ))
    let cutoff = now.addingTimeInterval(-24 * 3600)
    _ = try await fixture.store.compactAgedContextsIntoKnowledgeGraph(olderThan: cutoff)
    _ = try await fixture.store.prune(maxAge: 7 * 24 * 3600, maxTotalBytes: .max)
    #expect(try await fixture.store.context(id: original.id) == nil)

    let backfillPath = try fixture.frame("backfill.heic")
    let backfill = try await fixture.store.insert(RecordedContext(
        capturedAt: firstDate.addingTimeInterval(3600),
        source: .screen,
        appName: "Xcode",
        windowTitle: "Late history",
        ocrText: "latevermilion APER-111",
        imagePath: backfillPath
    ))
    let result = try await fixture.store.compactAgedContextsIntoKnowledgeGraph(olderThan: cutoff)
    let day = EventStoreLayout.utcDayKey(for: firstDate)
    let graph = try #require(try await fixture.store.knowledgeGraph(forDay: day))

    #expect(result.graphsWritten == 1)
    #expect(result.contextsCovered == 1)
    #expect(graph.source.contextCount == 2)
    #expect(graph.source.maxContextID == backfill.id)
    #expect(graph.summary.contains("2 contexts"))
    #expect(try await fixture.store.searchKnowledgeGraphs(matching: "originalcobalt").map(\.graph.day).contains(day))
    #expect(try await fixture.store.searchKnowledgeGraphs(matching: "latevermilion").map(\.graph.day).contains(day))
    #expect(!FileManager.default.fileExists(atPath: backfillPath))
    #expect(try await fixture.store.context(id: backfill.id)?.imagePath == nil)
}

@Test
func testSizePruneProtectsContextsUntilTheir24HourCutoff() async throws {
    let fixture = try KnowledgeGraphFixture("ContextKGProtectedPrune")
    let now = Date()
    let oldPath = try fixture.frame("old-budget.heic")
    let recentPath = try fixture.frame("protected-recent.heic")
    let inserted = try await fixture.store.insertContexts([
        RecordedContext(
            capturedAt: now.addingTimeInterval(-25 * 3600),
            source: .screen,
            appName: "Safari",
            ocrText: "old compacted source",
            imagePath: oldPath
        ),
        RecordedContext(
            capturedAt: now.addingTimeInterval(-60 * 60),
            source: .screen,
            appName: "Notes",
            ocrText: "recent source must survive pressure",
            imagePath: recentPath
        ),
    ])
    let cutoff = now.addingTimeInterval(-24 * 3600)
    _ = try await fixture.store.compactAgedContextsIntoKnowledgeGraph(olderThan: cutoff)

    _ = try await fixture.store.prune(
        maxAge: 365 * 24 * 3600,
        maxTotalBytes: 0,
        protectingContextsCapturedOnOrAfter: cutoff
    )

    #expect(try await fixture.store.context(id: inserted[0].id) == nil)
    #expect(try await fixture.store.knowledgeGraph(forDay: EventStoreLayout.utcDayKey(for: inserted[0].capturedAt)) != nil)
    let recent = try #require(try await fixture.store.context(id: inserted[1].id))
    #expect(recent.imagePath == recentPath)
    #expect(recent.ocrText?.contains("must survive") == true)
    #expect(FileManager.default.fileExists(atPath: recentPath))
}

@Test
func testLegacyDatabaseMigrationCreatesAndUsesContextKG() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ContextKGLegacy-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let path = directory.appendingPathComponent("legacy.sqlite").path
    let frame = directory.appendingPathComponent("legacy.heic").path
    try Data("legacy-real-frame".utf8).write(to: URL(fileURLWithPath: frame))
    let capturedAt = Date().addingTimeInterval(-48 * 3600)
    let legacyDateFormatter = ISO8601DateFormatter()
    legacyDateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let dateString = legacyDateFormatter.string(from: capturedAt)
    try kgRawExec(path, """
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
    INSERT INTO recorded_context
        (captured_at, source, app_name, bundle_identifier, window_title, ocr_text, image_path)
    VALUES (
        '\(legacyEscaped(dateString))', 'screen', 'Safari', 'com.apple.Safari',
        'Legacy roadmap', 'legacyquartz APER-101 https://example.com/legacy',
        '\(legacyEscaped(frame))'
    );
    """)

    let store = try CascadeStore(path: path)
    let result = try await store.compactAgedContextsIntoKnowledgeGraph(
        olderThan: Date().addingTimeInterval(-24 * 3600)
    )
    let day = EventStoreLayout.utcDayKey(for: capturedAt)

    #expect(result.graphsWritten == 1)
    #expect(result.filesDeleted == 1)
    #expect(!FileManager.default.fileExists(atPath: frame))
    #expect(try await store.knowledgeGraph(forDay: day) != nil)
    #expect(try await store.searchKnowledgeGraphs(matching: "legacyquartz").map(\.graph.day).contains(day))
    #expect(try kgRawStrings(path, "SELECT name FROM sqlite_master WHERE type='table';").contains("context_kg"))
    let triggerNames = try kgRawStrings(
        path,
        "SELECT name FROM sqlite_master WHERE type='trigger' AND name LIKE 'context_kg_%' ORDER BY name;"
    )
    #expect(Set(triggerNames) == ["context_kg_ad", "context_kg_ai", "context_kg_au"])
    let storedJSON = try #require(try kgRawStrings(path, "SELECT graph_json FROM context_kg;").first)
    #expect(try JSONDecoder().decode(ContextKnowledgeGraph.self, from: Data(storedJSON.utf8)).day == day)
}
