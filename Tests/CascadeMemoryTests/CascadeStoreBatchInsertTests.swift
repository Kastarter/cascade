@testable import CascadeMemory
import Foundation
import Testing

private func makeBatchStore() throws -> CascadeStore {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("CascadeStoreBatchInsertTests-\(UUID().uuidString).sqlite")
        .path
    return try CascadeStore(path: path)
}

private func expectContext(_ actual: RecordedContext?, matches expected: RecordedContext) {
    #expect(actual != nil)
    guard let actual else { return }
    #expect(actual.capturedAt == expected.capturedAt)
    #expect(actual.source == expected.source)
    #expect(actual.appName == expected.appName)
    #expect(actual.bundleIdentifier == expected.bundleIdentifier)
    #expect(actual.windowTitle == expected.windowTitle)
    #expect(actual.ocrText == expected.ocrText)
    #expect(actual.imagePath == expected.imagePath)
    #expect(actual.metadataJSON == expected.metadataJSON)
    #expect(actual.frameHash == expected.frameHash)
}

private func expectEvent(_ actual: InputEvent?, matches expected: InputEvent) {
    #expect(actual != nil)
    guard let actual else { return }
    #expect(actual.capturedAt == expected.capturedAt)
    #expect(actual.kind == expected.kind)
    #expect(actual.x == expected.x)
    #expect(actual.y == expected.y)
    #expect(actual.text == expected.text)
    #expect(actual.key == expected.key)
    #expect(actual.modifiers == expected.modifiers)
    #expect(actual.appName == expected.appName)
    #expect(actual.bundleIdentifier == expected.bundleIdentifier)
    #expect(actual.windowTitle == expected.windowTitle)
    #expect(actual.targetDescriptor == expected.targetDescriptor)
}

@Test
func batchAndSingleContextInsertsProduceSameRowsAndSearchEntries() async throws {
    let store = try makeBatchStore()
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    let single = RecordedContext(
        capturedAt: base,
        source: .screen,
        appName: "Safari",
        bundleIdentifier: "com.apple.Safari",
        windowTitle: "Single",
        ocrText: "shared batch marker",
        imagePath: "/tmp/single.jpg",
        metadataJSON: "{\"source\":\"single\"}",
        frameHash: 101
    )
    let batched = RecordedContext(
        capturedAt: base.addingTimeInterval(1),
        source: .screen,
        appName: "Safari",
        bundleIdentifier: "com.apple.Safari",
        windowTitle: "Batched",
        ocrText: "shared batch marker",
        imagePath: "/tmp/batched.jpg",
        metadataJSON: "{\"source\":\"batch\"}",
        frameHash: 202
    )

    let insertedSingle = try await store.insert(single)
    let insertedBatch = try await store.insertContexts([batched])

    #expect(insertedBatch.count == 1)
    let insertedBatchID = insertedBatch[0].id
    let rows = try await store.recentContexts(limit: 10)
    expectContext(rows.first { $0.id == insertedSingle.id }, matches: single)
    expectContext(rows.first { $0.id == insertedBatchID }, matches: batched)
    #expect(try await store.searchContexts(query: "marker").count == 2)
}

@Test
func batchAndSingleInputEventInsertsProduceSameRows() async throws {
    let store = try makeBatchStore()
    let base = Date(timeIntervalSince1970: 1_800_000_100)
    let single = InputEvent(
        capturedAt: base,
        kind: .click,
        x: 10,
        y: 20,
        text: "Save",
        modifiers: ["command"],
        appName: "Notes",
        bundleIdentifier: "com.apple.Notes",
        windowTitle: "Daily",
        targetDescriptor: AXTargetDescriptor.encode(role: "AXButton", identifier: "save")
    )
    let batched = InputEvent(
        capturedAt: base.addingTimeInterval(1),
        kind: .key,
        key: "return",
        modifiers: ["shift"],
        appName: "Notes",
        bundleIdentifier: "com.apple.Notes",
        windowTitle: "Daily",
        targetDescriptor: AXTargetDescriptor.encode(role: "AXTextArea", identifier: "body")
    )

    try await store.insertInputEvent(single)
    try await store.insertInputEvents([batched])

    let rows = try await store.recentInputEvents(limit: 10)
    expectEvent(rows.first { $0.text == "Save" }, matches: single)
    expectEvent(rows.first { $0.key == "return" }, matches: batched)
}

@Test
func emptyBatchInsertsAreNoOps() async throws {
    let store = try makeBatchStore()

    #expect(try await store.insertContexts([]).isEmpty)
    try await store.insertInputEvents([])

    #expect(try await store.recentContexts(limit: 10).isEmpty)
    #expect(try await store.recentInputEvents(limit: 10).isEmpty)
}

@Test
func injectedBatchBindFailureRollsBackPartialRowsAndSearchIndex() async throws {
    let store = try makeBatchStore()
    let base = Date(timeIntervalSince1970: 1_800_000_200)
    await store.setBatchBindFailureInjector { table, rowIndex in
        if case .recordedContext = table, rowIndex == 1 {
            throw CascadeStoreError.sqlite("injected bind failure")
        }
    }

    do {
        _ = try await store.insertContexts([
            RecordedContext(capturedAt: base, source: .screen, appName: "Mail", ocrText: "rollback sentinel"),
            RecordedContext(capturedAt: base.addingTimeInterval(1), source: .screen, appName: "Mail", ocrText: "should not persist")
        ])
        #expect(Bool(false), "Expected injected context bind failure")
    } catch {
        #expect(error is CascadeStoreError)
    }

    #expect(try await store.recentContexts(limit: 10).isEmpty)
    #expect(try await store.searchContexts(query: "sentinel").isEmpty)

    await store.setBatchBindFailureInjector { table, rowIndex in
        if case .inputEvent = table, rowIndex == 2 {
            throw CascadeStoreError.sqlite("injected bind failure")
        }
    }

    do {
        try await store.insertInputEvents((0..<3).map { index in
            InputEvent(
                capturedAt: base.addingTimeInterval(Double(index)),
                kind: .key,
                key: "K\(index)",
                appName: "Terminal"
            )
        })
        #expect(Bool(false), "Expected injected input-event bind failure")
    } catch {
        #expect(error is CascadeStoreError)
    }

    #expect(try await store.recentInputEvents(limit: 10).isEmpty)
}

@Test
func batchInputInsertReusesStatementForMoreThanOneHundredEvents() async throws {
    let store = try makeBatchStore()
    let base = Date(timeIntervalSince1970: 1_800_000_300)
    let events = (0..<125).map { index in
        InputEvent(
            capturedAt: base.addingTimeInterval(Double(index)),
            kind: .key,
            text: "payload-\(index)",
            key: "K\(index)",
            modifiers: index.isMultiple(of: 2) ? ["command"] : [],
            appName: "Editor",
            bundleIdentifier: "com.example.Editor",
            windowTitle: "Batch \(index)",
            targetDescriptor: AXTargetDescriptor.encode(role: "AXTextField", identifier: "field-\(index)")
        )
    }

    try await store.insertInputEvents(events)

    let rows = try await store.inputEvents(between: base, and: base.addingTimeInterval(200), limit: 200)
    #expect(rows.count == events.count)
    expectEvent(rows.first, matches: events[0])
    expectEvent(rows[safe: 87], matches: events[87])
    expectEvent(rows.last, matches: events[124])
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
