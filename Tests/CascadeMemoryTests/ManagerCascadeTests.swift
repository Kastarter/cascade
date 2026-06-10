import CascadeMemory
import Foundation
import Testing

private func makeStore() throws -> CascadeStore {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("CascadeManagerCascadeTests-\(UUID().uuidString).sqlite")
        .path
    return try CascadeStore(path: path)
}

@Test
func cascadesPersistAcrossStoreReopens() async throws {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("CascadeManagerCascadeTests-\(UUID().uuidString).sqlite")
        .path
    let store = try CascadeStore(path: path)
    _ = try await store.insertManagerCascade(title: "File the weekly report", summary: "Cascaded by your manager.")

    // The inbox is durable — a fresh store over the same file sees the cascade.
    let reopened = try CascadeStore(path: path)
    let rows = try await reopened.managerCascades()
    #expect(rows.count == 1)
    #expect(rows[0].title == "File the weekly report")
    #expect(rows[0].status == .pending)
}

@Test
func statusTransitionsPersist() async throws {
    let store = try makeStore()
    let deployed = try await store.insertManagerCascade(title: "A", summary: "s")
    let declined = try await store.insertManagerCascade(title: "B", summary: "s")
    try await store.setManagerCascadeStatus(id: deployed.id, status: .deployed)
    try await store.setManagerCascadeStatus(id: declined.id, status: .declined)

    let rows = try await store.managerCascades()
    #expect(rows.first { $0.id == deployed.id }?.status == .deployed)
    #expect(rows.first { $0.id == declined.id }?.status == .declined)
    #expect(rows.allSatisfy { $0.status != .pending })
}

@Test
func newestCascadeListsFirst() async throws {
    let store = try makeStore()
    _ = try await store.insertManagerCascade(title: "older", summary: "s", at: Date(timeIntervalSinceNow: -60))
    _ = try await store.insertManagerCascade(title: "newer", summary: "s")
    let rows = try await store.managerCascades()
    #expect(rows.map(\.title) == ["newer", "older"])
}
