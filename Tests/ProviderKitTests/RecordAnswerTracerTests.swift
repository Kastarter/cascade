import CascadeMemory
import Foundation
import ProviderKit
import Testing

private func makeTracerStore() throws -> CascadeStore {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("RecordAnswerTracerTests-\(UUID().uuidString).sqlite")
        .path
    return try CascadeStore(path: path)
}

private func makeSuite() -> UserDefaults {
    UserDefaults(suiteName: "RecordAnswerTracerTests-\(UUID().uuidString)")!
}

@Test
func ifEnabledIsNilWhenFlagAbsentOrFalse() throws {
    let store = try makeTracerStore()
    let absent = makeSuite()
    #expect(RecordAnswerTracer.ifEnabled(store: store, defaults: absent) == nil)

    let off = makeSuite()
    off.set(false, forKey: RecordAnswerTracer.flagKey)
    #expect(RecordAnswerTracer.ifEnabled(store: store, defaults: off) == nil)
}

@Test
func ifEnabledReturnsTracerWhenFlagTrue() throws {
    let store = try makeTracerStore()
    let on = makeSuite()
    on.set(true, forKey: RecordAnswerTracer.flagKey)
    let tracer = RecordAnswerTracer.ifEnabled(store: store, defaults: on)
    #expect(tracer != nil)
    // 6-hex correlation id.
    #expect(tracer?.askID.range(of: #"^[0-9a-f]{6}$"#, options: .regularExpression) != nil)
}

@Test
func emitPersistsOneAuditRowWithExpectedShape() async throws {
    let store = try makeTracerStore()
    let on = makeSuite()
    on.set(true, forKey: RecordAnswerTracer.flagKey)
    let tracer = try #require(RecordAnswerTracer.ifEnabled(store: store, defaults: on))

    await tracer.emit("test.stage", [("k", "v")])

    let rows = try await store.recentAudit(limit: 20).filter { $0.action == RecordAnswerTracer.auditAction }
    #expect(rows.count == 1)
    let row = try #require(rows.first)
    #expect(row.actor == "agent")
    #expect(row.detail.contains("ask=\(tracer.askID)"))
    #expect(row.detail.contains(" t="))
    #expect(row.detail.contains("stage=test.stage"))
    #expect(row.detail.contains("k=v"))
}

@Test
func elapsedMsIsMonotonicAndNonNegative() throws {
    let store = try makeTracerStore()
    let on = makeSuite()
    on.set(true, forKey: RecordAnswerTracer.flagKey)
    let tracer = try #require(RecordAnswerTracer.ifEnabled(store: store, defaults: on))

    let first = tracer.elapsedMs()
    let second = tracer.elapsedMs()
    #expect(first >= 0)
    #expect(second >= first)
}
