@testable import CascadeMemory
import Foundation
import Testing

private func makeMaintenanceStore() throws -> CascadeStore {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("CascadeMaintenanceTests-\(UUID().uuidString).sqlite")
        .path
    return try CascadeStore(path: path)
}

@Test
func storeAppliesPerformancePragmasOnOpen() async throws {
    let store = try makeMaintenanceStore()

    #expect(try await store.pragmaIntValue("foreign_keys") == 1)
    #expect(try await store.pragmaIntValue("synchronous") == 1)
    #expect(try await store.pragmaIntValue("busy_timeout") == 2500)
    #expect(try await store.pragmaIntValue("temp_store") == 2)
    #expect(try await store.pragmaIntValue("wal_autocheckpoint") == 512)
}

@Test
func passiveMaintenancePreservesSearch() async throws {
    let store = try makeMaintenanceStore()
    _ = try await store.insert(RecordedContext(source: .screen, appName: "Safari", ocrText: "maintenance searchable token"))

    try await store.performMaintenance(reason: .idle)

    let hits = try await store.searchContexts(query: "searchable")
    #expect(hits.count == 1)
    #expect(hits.first?.appName == "Safari")
}

@Test
func pruneThenMaintenanceKeepsDeletedRowsOutOfFTS() async throws {
    let store = try makeMaintenanceStore()
    _ = try await store.insert(RecordedContext(
        capturedAt: Date(timeIntervalSinceNow: -100 * 24 * 3600),
        source: .screen,
        appName: "OldApp",
        ocrText: "expired maintenance token"
    ))
    _ = try await store.insert(RecordedContext(
        source: .screen,
        appName: "FreshApp",
        ocrText: "fresh maintenance token"
    ))

    _ = try await store.prune(maxAge: 7 * 24 * 3600)
    try await store.performMaintenance(reason: .idle)

    #expect(try await store.searchContexts(query: "expired").isEmpty)
    #expect(try await store.searchContexts(query: "fresh").count == 1)
}
