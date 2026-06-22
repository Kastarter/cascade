import CascadeMemory
import Foundation
import ProviderKit
import Testing

private func makeStore() throws -> CascadeStore {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("CascadeRecallTests-\(UUID().uuidString).sqlite")
        .path
    return try CascadeStore(path: path)
}

// MARK: - search_record

@Test
func recallSearchReturnsCitableIdLines() async throws {
    let store = try makeStore()
    let safari = try await store.insert(RecordedContext(
        source: .screen, appName: "Safari", windowTitle: "Inbox",
        ocrText: "quarterly revenue projections"))
    _ = try await store.insert(RecordedContext(
        source: .screen, appName: "Mail", ocrText: "lunch plans tomorrow"))

    let out = await RecordRecall(store: store).perform(.search(query: "revenue"))
    #expect(out.contains("[#\(safari.id)]"))     // the id the model can inspect/cite
    #expect(out.contains("Safari"))
    #expect(out.contains("revenue projections"))
    #expect(!out.contains("lunch plans"))         // the other moment didn't match
}

@Test
func recallSearchEmptyQueryAsksForOne() async throws {
    let store = try makeStore()
    // The production path always parses via Call.init, which trims — a
    // whitespace-only query becomes empty and trips the guard.
    let call = RecordRecall.Call(name: "search_record", input: ["query": "   "])
    let out = await RecordRecall(store: store).perform(call)
    #expect(out == "search_record needs a query.")
}

@Test
func recallSearchNoMatchSaysSo() async throws {
    let store = try makeStore()
    _ = try await store.insert(RecordedContext(source: .screen, appName: "Mail", ocrText: "hello"))
    let out = await RecordRecall(store: store).perform(.search(query: "zzzzneverrecorded"))
    #expect(out.contains("No recorded moments match"))
}

@Test
func recallSearchFiltersSensitiveMoments() async throws {
    let store = try makeStore()
    // "password" marks the moment sensitive → it must never surface in recall,
    // even on a direct content hit.
    _ = try await store.insert(RecordedContext(
        source: .screen, appName: "Safari", windowTitle: "1Password",
        ocrText: "unicorn vault entry"))

    let out = await RecordRecall(store: store).perform(.search(query: "unicorn"))
    #expect(out.contains("No recorded moments match"))
    #expect(!out.contains("unicorn vault"))
}

// MARK: - get_timeframe

@Test
func recallTimeframeWindowsByTime() async throws {
    let store = try makeStore()
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    let inWindow = try await store.insert(RecordedContext(
        capturedAt: base, source: .screen, appName: "Keynote", ocrText: "title slide"))
    let outOfWindow = try await store.insert(RecordedContext(
        capturedAt: base.addingTimeInterval(7_200), source: .screen, appName: "Mail", ocrText: "later"))

    let iso = ISO8601DateFormatter()
    let out = await RecordRecall(store: store).perform(.timeframe(
        startISO: iso.string(from: base.addingTimeInterval(-60)),
        endISO: iso.string(from: base.addingTimeInterval(60))))

    #expect(out.contains("[#\(inWindow.id)]"))
    #expect(!out.contains("[#\(outOfWindow.id)]"))
}

@Test
func recallTimeframeRejectsBadRange() async throws {
    let store = try makeStore()
    let out = await RecordRecall(store: store).perform(.timeframe(startISO: nil, endISO: "not-a-date"))
    #expect(out.contains("get_timeframe needs"))
}

// MARK: - inspect_moment

@Test
func recallInspectIncludesNeighbors() async throws {
    let store = try makeStore()
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    let target = try await store.insert(RecordedContext(
        capturedAt: base, source: .screen, appName: "Keynote", ocrText: "the deck I started"))
    let neighbor = try await store.insert(RecordedContext(
        capturedAt: base.addingTimeInterval(30), source: .screen, appName: "Keynote", ocrText: "next slide"))

    let out = await RecordRecall(store: store).perform(.inspect(id: target.id))
    #expect(out.contains("the deck I started"))   // full text of the target
    #expect(out.contains("Nearby:"))
    #expect(out.contains("[#\(neighbor.id)]"))     // the surrounding story, one hop
}

@Test
func recallInspectNeedsNumericId() async throws {
    let store = try makeStore()
    let out = await RecordRecall(store: store).perform(.inspect(id: nil))
    #expect(out == "inspect_moment needs a numeric id.")
}

@Test
func recallInspectUnknownIdSaysSo() async throws {
    let store = try makeStore()
    let out = await RecordRecall(store: store).perform(.inspect(id: 9_999))
    #expect(out.contains("No accessible moment #9999"))
}

// MARK: - Call parsing + routing

@Test
func recallCallParsesEachToolFromRawInput() {
    #expect(RecordRecall.Call(name: "search_record", input: ["query": "  hi  "]) == .search(query: "hi"))
    #expect(RecordRecall.Call(name: "get_timeframe", input: ["start_iso": "a", "end_iso": "b"])
        == .timeframe(startISO: "a", endISO: "b"))
    #expect(RecordRecall.Call(name: "inspect_moment", input: ["id": 42]) == .inspect(id: 42))
    #expect(RecordRecall.Call(name: "inspect_moment", input: ["id": NSNumber(value: 7)]) == .inspect(id: 7))
    #expect(RecordRecall.Call(name: "bogus", input: [:]) == .unknown("bogus"))
}

@Test
func recallCallAuditDetailIsVerbatim() {
    #expect(RecordRecall.Call.search(query: "the email").auditDetail == "search_record: the email")
    #expect(RecordRecall.Call.timeframe(startISO: "T1", endISO: "T2").auditDetail == "get_timeframe: T1 → T2")
    #expect(RecordRecall.Call.inspect(id: 12).auditDetail == "inspect_moment: #12")
}

@Test
func recallToolNamesAreStableAndDistinctFromOtherTools() {
    #expect(RecordRecall.isRecallTool("search_record"))
    #expect(RecordRecall.isRecallTool("get_timeframe"))
    #expect(RecordRecall.isRecallTool("inspect_moment"))
    #expect(!RecordRecall.isRecallTool("computer"))
    #expect(!RecordRecall.isRecallTool("use_skill"))
    // Recall names must not collide with the Mac harness tools, or the in-process
    // router in ComputerUseAgent would send a call to the wrong provider lane.
    for harness in AgentHarness.readOnlyTools + AgentHarness.powerTools {
        #expect(!RecordRecall.isRecallTool(harness))
    }
}

@Test
func recallToolDefinitionsExposeTheThreeTools() {
    let names = RecordRecall.toolDefinitions().compactMap { $0["name"] as? String }
    #expect(Set(names) == RecordRecall.toolNames)
}
