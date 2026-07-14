import CascadeMemory
import Foundation
@testable import MacContextKit
import Testing

private final class MaintenanceNow: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date) {
        self.date = date
    }

    func get() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return date
    }

    func set(_ date: Date) {
        lock.lock()
        self.date = date
        lock.unlock()
    }
}

@MainActor
private func maintenanceEventually(
    attempts: Int = 100,
    _ condition: () async -> Bool
) async -> Bool {
    for _ in 0..<attempts {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return false
}

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
    #expect(!(try await store.knowledgeGraphChunks(forDay: expiredDay)).isEmpty)
    #expect(try await store.searchKnowledgeGraphs(matching: "historicindigo").map(\.graph.day).contains(expiredDay))
    #expect(!FileManager.default.fileExists(atPath: expiredPath))

    // The aged (25h) moment is outside the 24-hour watchable window: its frame
    // is compacted into the knowledge graph, and the source ROW is deleted too —
    // the chunk is the only remaining representation, and it still answers.
    #expect(try await store.context(id: inserted[1].id) == nil)
    #expect(!FileManager.default.fileExists(atPath: agedPath))
    #expect(!(try await store.searchKnowledgeGraphs(matching: "APER-202")).isEmpty)

    let recent = try #require(try await store.context(id: inserted[2].id))
    #expect(recent.imagePath == recentPath)
    #expect(FileManager.default.fileExists(atPath: recentPath))
}

@MainActor @Test
func testRecorderStartsMaintenanceWithoutCaptureAndKeepsItThroughPause() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("RecorderMaintenancePaused-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let store = try CascadeStore(path: directory.appendingPathComponent("cascade.sqlite").path)
    let frame = directory.appendingPathComponent("crosses-cutoff.heic")
    try Data("real paused frame".utf8).write(to: frame, options: .atomic)
    let initialNow = Date()
    let context = try await store.insert(RecordedContext(
        capturedAt: initialNow.addingTimeInterval(-23 * 3600),
        source: .screen,
        appName: "Notes",
        bundleIdentifier: "com.apple.Notes",
        windowTitle: "Paused retention",
        ocrText: "pausedretentionmarker must compact after crossing",
        imagePath: frame.path
    ))
    let clock = MaintenanceNow(initialNow)
    let scheduler = RecorderMaintenanceScheduler(
        store: store,
        maintenanceInterval: .milliseconds(20),
        maintenanceTolerance: .zero,
        now: { clock.get() }
    )
    let recorder = ContextRecorder(store: store, maintenanceScheduler: scheduler)

    #expect(await maintenanceEventually { await scheduler.isRunning() })
    try? await Task.sleep(for: .milliseconds(80))
    #expect(FileManager.default.fileExists(atPath: frame.path))
    #expect(try await store.context(id: context.id)?.imagePath == frame.path)

    recorder.pause()
    #expect(await scheduler.isRunning())
    clock.set(initialNow.addingTimeInterval(2 * 3600))

    let deletedWhilePaused = await maintenanceEventually {
        let stored = try? await store.context(id: context.id)
        return stored?.imagePath == nil && !FileManager.default.fileExists(atPath: frame.path)
    }
    let stillRunning = await scheduler.isRunning()
    await scheduler.stop()

    #expect(deletedWhilePaused)
    #expect(stillRunning)
    #expect(try await store.searchKnowledgeGraphs(matching: "pausedretentionmarker").isEmpty == false)
}
