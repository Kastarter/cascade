import CascadeMemory
import Foundation
import Testing

private func makePrivacyStore() throws -> CascadeStore {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("CascadePrivacy-\(UUID().uuidString).sqlite")
        .path
    return try CascadeStore(path: path)
}

@Test
func directContextInsertRedactsPIIFromStoredTextAndSearch() async throws {
    let store = try makePrivacyStore()
    let inserted = try await store.insert(RecordedContext(
        source: .screen,
        appName: "Mail",
        windowTitle: "jane@example.com",
        ocrText: "Email jane@example.com with card 4242 4242 4242 4242"
    ))

    #expect(inserted.ocrText?.contains("jane@example.com") == false)
    #expect(inserted.ocrText?.contains("<EMAIL>") == true)
    #expect(try await store.searchContexts(query: "jane@example.com").isEmpty)
    #expect(try await store.searchContexts(query: "EMAIL").count == 1)
}

@Test
func directInputInsertCannotPersistRawTypedSecrets() async throws {
    let store = try makePrivacyStore()
    try await store.insertInputEvent(InputEvent(
        kind: .type,
        text: "hunter2@example.com",
        appName: "Mail"
    ))
    try await store.insertInputEvent(InputEvent(
        kind: .click,
        text: "Send to jane@example.com",
        appName: "Mail"
    ))

    let events = try await store.recentInputEvents(limit: 10)
    #expect(events.contains { $0.kind == .type && $0.text == "typed 19 chars" })
    #expect(events.contains { $0.kind == .click && $0.text == "Send to <EMAIL>" })
    #expect(events.allSatisfy { !($0.text ?? "").contains("hunter2@example.com") })
    #expect(events.allSatisfy { !($0.text ?? "").contains("jane@example.com") })
}
