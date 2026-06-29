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

@Test
func privacySummaryAndManifestAreMetadataOnly() async throws {
    let store = try makePrivacyStore()
    let frameURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("CascadePrivacyFrame-\(UUID().uuidString).jpg")
    try Data([1, 2, 3, 4, 5]).write(to: frameURL)

    _ = try await store.insert(RecordedContext(
        capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
        source: .screen,
        appName: "Mail",
        bundleIdentifier: "com.apple.mail",
        windowTitle: "Confidential",
        ocrText: "Email jane@example.com",
        imagePath: frameURL.path
    ))

    let manifest = try await store.privacyExportManifest(policy: CapturePrivacyPolicy(
        retentionByDataClass: ["frames": CaptureRetentionPolicy(maxAgeDays: 3, maxBytes: 10)]
    ))

    #expect(manifest.summary.totalContexts == 1)
    #expect(manifest.summary.estimatedFrameBytes == 5)
    #expect(manifest.summary.buckets.first?.appName == "Mail")
    #expect(manifest.summary.retentionByDataClass["frames"] == CaptureRetentionPolicy(maxAgeDays: 3, maxBytes: 10))
    #expect(manifest.omittedFields.contains("ocr_text"))
    #expect(manifest.omittedFields.contains("image_path"))
}

@Test
func scopedPrivacyDeletionReturnsBackingFilesAndHonorsSource() async throws {
    let store = try makePrivacyStore()
    let frameURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("CascadePrivacyDelete-\(UUID().uuidString).jpg")
    try Data([9, 8, 7]).write(to: frameURL)
    _ = try await store.insert(RecordedContext(
        source: .screen,
        appName: "Safari",
        bundleIdentifier: "com.apple.Safari",
        imagePath: frameURL.path
    ))
    try await store.insertInputEvent(InputEvent(kind: .click, text: "Open", appName: "Safari", bundleIdentifier: "com.apple.Safari"))

    let result = try await store.deletePrivacyData(scope: PrivacyDataScope(source: .screen, appName: "Safari"))

    #expect(result.deletedContextCount == 1)
    #expect(result.deletedInputEventCount == 0)
    #expect(result.backingImagePaths == [frameURL.path])
    #expect(try await store.recentContexts(limit: 10).isEmpty)
    #expect(try await store.recentInputEvents(limit: 10).count == 1)
}
