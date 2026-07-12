import CascadeMemory
import Foundation
@testable import MacContextKit
import Testing

@Test
func testRunOnceCompactsBeforePruneAtFixedNow() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("RecorderMaintenanceKG-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let databasePath = directory.appendingPathComponent("cascade.sqlite").path
    let store = try CascadeStore(path: databasePath)
    let now = Date()

    func frame(_ name: String) throws -> String {
        let url = directory.appendingPathComponent(name)
        try Data("real-frame-\(name)".utf8).write(to: url, options: .atomic)
        return url.path
    }

    let expiredPath = try frame("expired.heic")
    let agedPath = try frame("aged.heic")
    let recentPath = try frame("recent.heic")
    let inserted = try await store.insertContexts([
        RecordedContext(
            capturedAt: now.addingTimeInterval(-8 * 24 * 3600),
            source: .screen,
            appName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            windowTitle: "Historic Acme plan",
            ocrText: "historicindigo APER-201 https://example.com/history",
            imagePath: expiredPath
        ),
        RecordedContext(
            capturedAt: now.addingTimeInterval(-25 * 3600),
            source: .screen,
            appName: "Xcode",
            bundleIdentifier: "com.apple.dt.Xcode",
            windowTitle: "Aged implementation",
            ocrText: "twenty five hour implementation APER-202",
            imagePath: agedPath
        ),
        RecordedContext(
            capturedAt: now.addingTimeInterval(-23 * 3600),
            source: .screen,
            appName: "Notes",
            bundleIdentifier: "com.apple.Notes",
            windowTitle: "Recent plan",
            ocrText: "twenty three hour plan",
            imagePath: recentPath
        ),
    ])

    let scheduler = RecorderMaintenanceScheduler(store: store)
    await scheduler.updateBudget(RecorderCadenceBudget(allowsSemanticIndexing: false))
    await scheduler.runOnce(reason: .idle, now: now)

    let expiredDay = EventStoreLayout.utcDayKey(for: inserted[0].capturedAt)
    #expect(try await store.context(id: inserted[0].id) == nil)
    #expect(try await store.knowledgeGraph(forDay: expiredDay) != nil)
    #expect(try await store.searchKnowledgeGraphs(matching: "historicindigo").map(\.graph.day).contains(expiredDay))
    #expect(!FileManager.default.fileExists(atPath: expiredPath))

    let aged = try #require(try await store.context(id: inserted[1].id))
    #expect(aged.imagePath == nil)
    #expect(aged.ocrText?.contains("APER-202") == true)
    #expect(!FileManager.default.fileExists(atPath: agedPath))

    let recent = try #require(try await store.context(id: inserted[2].id))
    #expect(recent.imagePath == recentPath)
    #expect(FileManager.default.fileExists(atPath: recentPath))
}
