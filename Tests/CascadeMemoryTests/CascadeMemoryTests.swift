import CascadeMemory
import Foundation
import Testing

@Test
func storePersistsContextAndAudit() async throws {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("CascadeMemoryTests-\(UUID().uuidString).sqlite")
        .path
    let store = try CascadeStore(path: path)

    let inserted = try await store.insert(RecordedContext(
        source: .app,
        appName: "Notes",
        bundleIdentifier: "com.apple.Notes",
        windowTitle: "Daily recap"
    ))
    let audit = try await store.appendAudit(AuditEvent(actor: "system", action: "test", detail: "stored"))

    let contexts = try await store.recentContexts(limit: 4)
    let events = try await store.recentAudit(limit: 4)

    #expect(inserted.id > 0)
    #expect(audit.id > 0)
    #expect(contexts.first?.appName == "Notes")
    #expect(events.first?.action == "test")
}
