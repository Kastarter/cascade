import CascadeMemory
import Foundation
import Testing

private func makeMemoryStreamStore() throws -> CascadeStore {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("CascadeMemoryStreamTests-\(UUID().uuidString).sqlite")
        .path
    return try CascadeStore(path: path)
}

@Test
func memoryEventIsUpsertedFromInsertedContext() async throws {
    let store = try makeMemoryStreamStore()
    let moment = try await store.insert(RecordedContext(
        source: .screen,
        appName: "Safari",
        windowTitle: "Pricing",
        ocrText: "Review https://example.com/pricing for Project Alpha owner status"))

    let event = try #require(await store.memoryEvent(contextID: moment.id))
    #expect(event.contextID == moment.id)
    #expect(event.summary.contains("Project Alpha"))
    #expect(event.entitiesJSON.contains("url"))
    #expect(event.importance > 0)
}

@Test
func memoryEventCascadesWhenRecordedContextIsPruned() async throws {
    let store = try makeMemoryStreamStore()
    let old = try await store.insert(RecordedContext(
        capturedAt: Date(timeIntervalSince1970: 1_600_000_000),
        source: .screen,
        appName: "Notes",
        ocrText: "old project note"))
    #expect(try await store.memoryEvent(contextID: old.id) != nil)

    _ = try await store.prune(maxAge: 1, maxTotalBytes: 10_000_000)

    #expect(try await store.memoryEvent(contextID: old.id) == nil)
}

@Test
func memoryRankedIDsPreferRelevantRecentImportantEvents() async throws {
    let store = try makeMemoryStreamStore()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let old = try await store.insert(RecordedContext(
        capturedAt: now.addingTimeInterval(-30 * 24 * 60 * 60),
        source: .app,
        appName: "Notes",
        windowTitle: "Alpha",
        ocrText: "Alpha note"))
    let current = try await store.insert(RecordedContext(
        capturedAt: now.addingTimeInterval(-60),
        source: .screen,
        appName: "Linear",
        windowTitle: "Project Alpha",
        ocrText: "Project Alpha status owner deadline and invoice total"))

    let ids = try await store.memoryRankedIDs(matching: "project alpha status", limit: 5, now: now)

    #expect(ids.first == current.id)
    #expect(ids.contains(old.id))
}

@Test
func memoryAccessCountersIncrementOnlyWhenMarked() async throws {
    let store = try makeMemoryStreamStore()
    let moment = try await store.insert(RecordedContext(
        source: .screen,
        appName: "Notes",
        ocrText: "Project Beta decision"))

    #expect(try await store.memoryEvent(contextID: moment.id)?.accessCount == 0)
    try await store.markMemoryEventsAccessed([moment.id], at: moment.capturedAt.addingTimeInterval(10))
    let event = try #require(await store.memoryEvent(contextID: moment.id))

    #expect(event.accessCount == 1)
    #expect(event.lastAccessedAt != nil)
}
