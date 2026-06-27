import CascadeMemory
import CryptoKit
import Foundation
import ProviderKit
import Testing

private func makeStore() throws -> CascadeStore {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("CascadeRecallTests-\(UUID().uuidString).sqlite")
        .path
    return try CascadeStore(path: path)
}

private func sha256Prefix(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
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

// MARK: - list_sessions

@Test
func recallListSessionsGroupsMomentsIntoSessions() async throws {
    let store = try makeStore()
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    // A Keynote session, then a switch to Mail → two sessions, not five frames.
    let k1 = try await store.insert(RecordedContext(
        capturedAt: base, source: .screen, appName: "Keynote", windowTitle: "Q1 Deck", ocrText: "title slide"))
    _ = try await store.insert(RecordedContext(
        capturedAt: base.addingTimeInterval(30), source: .screen, appName: "Keynote", windowTitle: "Q1 Deck", ocrText: "agenda"))
    let mail = try await store.insert(RecordedContext(
        capturedAt: base.addingTimeInterval(120), source: .screen, appName: "Mail", windowTitle: "Inbox", ocrText: "reply"))

    let iso = ISO8601DateFormatter()
    let out = await RecordRecall(store: store).perform(.sessions(
        startISO: iso.string(from: base.addingTimeInterval(-60)),
        endISO: iso.string(from: base.addingTimeInterval(600))))

    // Two session lines, anchored on each session's first moment id.
    #expect(out.contains("[#\(k1.id)]"))
    #expect(out.contains("Keynote — Q1 Deck"))
    #expect(out.contains("[#\(mail.id)]"))
    #expect(out.contains("Mail — Inbox"))
    #expect(out.contains("moments"))
    #expect(out.components(separatedBy: "\n").count == 2)
}

@Test
func recallListSessionsRejectsBadRange() async throws {
    let store = try makeStore()
    let out = await RecordRecall(store: store).perform(.sessions(startISO: "x", endISO: nil))
    #expect(out.contains("list_sessions needs"))
}

@Test
func recallListSessionsEmptyWindowSaysSo() async throws {
    let store = try makeStore()
    let iso = ISO8601DateFormatter()
    let now = Date(timeIntervalSince1970: 1_600_000_000)
    let out = await RecordRecall(store: store).perform(.sessions(
        startISO: iso.string(from: now), endISO: iso.string(from: now.addingTimeInterval(60))))
    #expect(out.contains("No sessions recorded"))
}

@Test
func recallListSessionsExcludesSensitiveMoments() async throws {
    let store = try makeStore()
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    // A "1Password" window is sensitive → it must not anchor or appear as a session.
    _ = try await store.insert(RecordedContext(
        capturedAt: base, source: .screen, appName: "Safari", windowTitle: "1Password", ocrText: "vault"))
    let visible = try await store.insert(RecordedContext(
        capturedAt: base.addingTimeInterval(30), source: .screen, appName: "Notes", windowTitle: "Roadmap", ocrText: "plan"))

    let iso = ISO8601DateFormatter()
    let out = await RecordRecall(store: store).perform(.sessions(
        startISO: iso.string(from: base.addingTimeInterval(-60)),
        endISO: iso.string(from: base.addingTimeInterval(600))))

    #expect(out.contains("[#\(visible.id)]"))
    #expect(out.contains("Notes — Roadmap"))
    #expect(!out.contains("1Password"))
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
    #expect(RecordRecall.Call(name: "list_sessions", input: ["start_iso": "a", "end_iso": "b"])
        == .sessions(startISO: "a", endISO: "b"))
    #expect(RecordRecall.Call(name: "bogus", input: [:]) == .unknown("bogus"))
}

@Test
func recallCallAuditDetailUsesSafeDescriptors() {
    let phrase = "Aperture-Delta Jane Example confidential runway.pdf"
    let detail = RecordRecall.Call.search(query: phrase).auditDetail
    #expect(detail.contains("tool=search_record"))
    #expect(detail.contains("queryLength=\(phrase.count)"))
    #expect(detail.contains("queryHash=\(sha256Prefix(phrase))"))
    #expect(!detail.contains(phrase))
    #expect(detail == RecordRecall.Call.search(query: phrase).auditDetail)

    let timeframe = RecordRecall.Call.timeframe(
        startISO: "2026-06-26T12:34:56-04:00",
        endISO: "private appointment with Jane"
    ).auditDetail
    #expect(timeframe.contains("tool=get_timeframe"))
    #expect(timeframe.contains("start=2026-06-26T16:34:56.000Z"))
    #expect(timeframe.contains("end=invalid"))
    #expect(!timeframe.contains("private appointment with Jane"))

    #expect(RecordRecall.Call.inspect(id: 12).auditDetail == "tool=inspect_moment id=12")
    #expect(RecordRecall.Call.sessions(startISO: nil, endISO: "not a timestamp").auditDetail
        == "tool=list_sessions start=missing end=invalid")
}

@Test
func recallToolNamesAreStableAndDistinctFromOtherTools() {
    #expect(RecordRecall.isRecallTool("search_record"))
    #expect(RecordRecall.isRecallTool("get_timeframe"))
    #expect(RecordRecall.isRecallTool("inspect_moment"))
    #expect(RecordRecall.isRecallTool("list_sessions"))
    #expect(!RecordRecall.isRecallTool("inspect_structure"))
    #expect(!RecordRecall.isRecallTool("computer"))
    #expect(!RecordRecall.isRecallTool("use_skill"))
    // Recall names must not collide with the Mac harness tools, or the in-process
    // router in ComputerUseAgent would send a call to the wrong provider lane.
    for harness in AgentHarness.readOnlyTools + AgentHarness.powerTools {
        #expect(!RecordRecall.isRecallTool(harness))
    }
}

@Test
func recallToolDefinitionsExposeEveryTool() {
    let names = RecordRecall.toolDefinitions().compactMap { $0["name"] as? String }
    #expect(Set(names) == RecordRecall.toolNames())
}
