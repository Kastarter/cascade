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

private struct ReverseRecordReranker: RecordReranker {
    func rerank(query: String, candidates: [RecordChunkCandidate], limit: Int) -> [RecordRerankResult] {
        candidates
            .sorted { $0.contextID > $1.contextID }
            .prefix(limit)
            .map { RecordRerankResult(candidate: $0, score: Double($0.contextID)) }
    }
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
    let envelope = try observationEnvelope(from: out)
    #expect(envelope.trust == .untrustedRecord)
    #expect(envelope.acquiredByTool == "search_record")
}

@Test
func recallSearchEmptyQueryAsksForOne() async throws {
    let store = try makeStore()
    // The production path always parses via Call.init, which trims — a
    // whitespace-only query becomes empty and trips the guard.
    let call = RecordRecall.Call(name: "search_record", input: ["query": "   "])
    let out = await RecordRecall(store: store).perform(call)
    #expect(out == #"{"kind":"validation_error","message":"search_record needs a query.","status":"error","tool":"search_record"}"#)
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

@Test
func recallDefaultsToNoRerankerForAgentCallers() throws {
    let store = try makeStore()
    #expect(!RecordRecall(store: store).hasReranker)
}

@Test
func recallSearchRerankerPreservesRecordedContextCitationIDs() async throws {
    let store = try makeStore()
    let first = try await store.insert(RecordedContext(
        source: .screen,
        appName: "Notes",
        ocrText: "alpha handoff note"))
    let second = try await store.insert(RecordedContext(
        source: .screen,
        appName: "Notes",
        ocrText: "alpha handoff decision"))

    let out = await RecordRecall(store: store, reranker: ReverseRecordReranker()).perform(.search(query: "alpha handoff"))
    let lines = out.components(separatedBy: "\n")

    #expect(lines.first?.contains("[#\(second.id)]") == true)
    #expect(out.contains("[#\(first.id)]"))
    #expect(out.contains("[#\(second.id)]"))
}

@Test
func heuristicRecordRerankerScoresPhraseTitleAndCoverage() {
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    let weak = RecordChunkCandidate(
        contextID: 1,
        text: "alpha notes",
        title: "Inbox",
        appName: "Mail",
        capturedAt: base,
        baseRank: 0,
        baseScore: 0.02
    )
    let strong = RecordChunkCandidate(
        contextID: 2,
        text: "budget details for the project",
        title: "Project Alpha Budget",
        appName: "Numbers",
        capturedAt: base.addingTimeInterval(-60),
        baseRank: 1,
        baseScore: 0.01
    )

    let ranked = HeuristicRecordReranker().rerank(query: "project alpha budget", candidates: [weak, strong], limit: 2)

    #expect(ranked.first?.candidate.contextID == strong.contextID)
    #expect(ranked[0].score > ranked[1].score)
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
    let envelope = try observationEnvelope(from: out)
    #expect(envelope.payload.components(separatedBy: "\n").count == 2)
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
    #expect(out == #"{"kind":"validation_error","message":"inspect_moment needs a numeric id.","status":"error","tool":"inspect_moment"}"#)
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

// MARK: - knowledge-graph fallback after source retention

private func makePrunedKnowledgeGraphStore(
    token: String
) async throws -> (store: CascadeStore, capturedAt: Date, day: String, contextID: Int64) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("CascadeRecallKG-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let store = try CascadeStore(path: directory.appendingPathComponent("cascade.sqlite").path)
    let frame = directory.appendingPathComponent("historic.heic")
    try Data("real historic frame".utf8).write(to: frame, options: .atomic)
    let now = Date()
    let capturedAt = now.addingTimeInterval(-8 * 24 * 3600)
    let context = try await store.insert(RecordedContext(
        capturedAt: capturedAt,
        source: .screen,
        appName: "Safari",
        bundleIdentifier: "com.apple.Safari",
        windowTitle: "Acme Q2 Budget",
        ocrText: "\(token) APER-301 https://example.com/q2-budget TODO: reconcile Acme runway by 2026-08-01 #finance",
        imagePath: frame.path
    ))
    _ = try await store.compactAgedContextsIntoKnowledgeGraph(
        olderThan: now.addingTimeInterval(-24 * 3600)
    )
    _ = try await store.prune(maxAge: 7 * 24 * 3600, maxTotalBytes: .max)
    #expect(try await store.context(id: context.id) == nil)
    #expect(!FileManager.default.fileExists(atPath: frame.path))
    return (store, capturedAt, EventStoreLayout.utcDayKey(for: capturedAt), context.id)
}

private func recallKGDirectory(_ name: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func utcDate(_ value: String) throws -> Date {
    try #require(ISO8601DateFormatter().date(from: value))
}

private func writeRecallFrame(named name: String, in directory: URL) throws -> URL {
    let frame = directory.appendingPathComponent(name)
    try Data("real frame \(name)".utf8).write(to: frame, options: .atomic)
    return frame
}

private func pruneRecallRows(through cutoff: Date, store: CascadeStore) async throws {
    let maxAge = max(1, Date().timeIntervalSince(cutoff))
    _ = try await store.prune(maxAge: maxAge, maxTotalBytes: .max)
}

@Test
func testSearchRecordFallsBackToKGAfterSourcePrune() async throws {
    let fixture = try await makePrunedKnowledgeGraphStore(token: "violetarchive")
    let utc = try #require(TimeZone(secondsFromGMT: 0))

    let output = await RecordRecall(store: fixture.store, presentationTimeZone: utc)
        .perform(.search(query: "violetarchive"))

    #expect(output.contains("[KG \(fixture.day)]"))
    #expect(output.contains("Safari"))
    #expect(output.contains("example.com/q2-budget") || output.contains("Q2 Budget"))
    #expect(output.contains("violetarchive"))
    #expect(!output.contains("[#\(fixture.contextID)]"))
    #expect(!output.contains("[#"))
    let envelope = try observationEnvelope(from: output)
    #expect(envelope.acquiredByTool == "search_record")
}

@Test
func testSearchRecordReturnsLateUnclassifiedOCRFromDurableKG() async throws {
    let directory = try recallKGDirectory("CascadeRecallKGLateOCR")
    let store = try CascadeStore(path: directory.appendingPathComponent("cascade.sqlite").path)
    let now = Date()
    let sessionStart = now.addingTimeInterval(-8 * 24 * 3600)
    let token = "lateuniquerecallzebra"
    let frequentTerms = (0..<24).map { "frequentterm\($0)" }.joined(separator: " ")
    var contexts: [RecordedContext] = []

    for index in 0..<20 {
        let frame = try writeRecallFrame(named: "late-\(index).heic", in: directory)
        let lateFact = index == 13 ? " \(token) amount 4817 approved" : ""
        contexts.append(RecordedContext(
            capturedAt: sessionStart.addingTimeInterval(TimeInterval(index * 60)),
            source: .screen,
            appName: "Notes",
            bundleIdentifier: "com.apple.Notes",
            windowTitle: "Weekly status",
            ocrText: "context \(index) \(frequentTerms)\(lateFact)",
            imagePath: frame.path
        ))
    }

    _ = try await store.insertContexts(contexts)
    _ = try await store.compactAgedContextsIntoKnowledgeGraph(
        olderThan: now.addingTimeInterval(-24 * 3600)
    )
    _ = try await store.prune(maxAge: 7 * 24 * 3600, maxTotalBytes: .max)

    #expect(try await store.searchContexts(query: token).isEmpty)
    let utc = try #require(TimeZone(secondsFromGMT: 0))
    let output = await RecordRecall(store: store, presentationTimeZone: utc)
        .perform(.search(query: token))

    #expect(output.contains("[KG "))
    #expect(output.contains(token))
    #expect(output.contains("4817 approved"))
    #expect(!output.contains("[#"))
}

@Test
func testTimeframeAndSessionsFallBackToKGAfterSourcePrune() async throws {
    let fixture = try await makePrunedKnowledgeGraphStore(token: "amberarchive")
    let formatter = ISO8601DateFormatter()
    let start = formatter.string(from: fixture.capturedAt.addingTimeInterval(-60))
    let end = formatter.string(from: fixture.capturedAt.addingTimeInterval(600))
    let utc = try #require(TimeZone(secondsFromGMT: 0))
    let recall = RecordRecall(store: fixture.store, presentationTimeZone: utc)

    let timeframe = await recall.perform(.timeframe(startISO: start, endISO: end))
    let sessions = await recall.perform(.sessions(startISO: start, endISO: end))

    #expect(timeframe.contains("[KG \(fixture.day)]"))
    #expect(timeframe.contains("Safari"))
    #expect(timeframe.contains("amberarchive"))
    #expect(!timeframe.contains("[#"))
    #expect(sessions.contains("[KG \(fixture.day)]"))
    #expect(sessions.contains("Safari"))
    #expect(sessions.contains("contexts"))
    #expect(!sessions.contains("[#"))
}

@Test
func recallMergesRawAndKGHistoryWithinTheSameUTCDay() async throws {
    let directory = try recallKGDirectory("CascadeRecallKGMixedDay")
    let store = try CascadeStore(path: directory.appendingPathComponent("cascade.sqlite").path)
    let oldFrame = try writeRecallFrame(named: "morning.heic", in: directory)
    let recentFrame = try writeRecallFrame(named: "afternoon.heic", in: directory)
    let morning = try utcDate("2026-07-01T10:00:00Z")
    let cutoff = try utcDate("2026-07-01T12:00:00Z")
    let afternoon = try utcDate("2026-07-01T13:00:00Z")

    let old = try await store.insert(RecordedContext(
        capturedAt: morning,
        source: .screen,
        appName: "Safari",
        bundleIdentifier: "com.apple.Safari",
        windowTitle: "Morning Archive",
        ocrText: "transitionmarker morning_kg_fact",
        imagePath: oldFrame.path
    ))
    let recent = try await store.insert(RecordedContext(
        capturedAt: afternoon,
        source: .screen,
        appName: "Xcode",
        bundleIdentifier: "com.apple.dt.Xcode",
        windowTitle: "Afternoon Live",
        ocrText: "transitionmarker afternoon_raw_fact",
        imagePath: recentFrame.path
    ))

    _ = try await store.compactAgedContextsIntoKnowledgeGraph(olderThan: cutoff)
    try await pruneRecallRows(through: cutoff, store: store)

    #expect(try await store.context(id: old.id) == nil)
    #expect(try await store.context(id: recent.id) != nil)
    #expect(!FileManager.default.fileExists(atPath: oldFrame.path))
    #expect(FileManager.default.fileExists(atPath: recentFrame.path))

    let utc = try #require(TimeZone(secondsFromGMT: 0))
    let recall = RecordRecall(store: store, presentationTimeZone: utc)
    let formatter = ISO8601DateFormatter()
    let start = formatter.string(from: morning.addingTimeInterval(-60))
    let end = formatter.string(from: afternoon.addingTimeInterval(60))
    let search = await recall.perform(.search(query: "transitionmarker"))
    let timeframe = await recall.perform(.timeframe(startISO: start, endISO: end))
    let sessions = await recall.perform(.sessions(startISO: start, endISO: end))

    #expect(search.contains("morning_kg_fact"))
    #expect(search.contains("afternoon_raw_fact"))
    #expect(search.contains("[KG 2026-07-01]"))
    #expect(search.contains("[#\(recent.id)]"))
    #expect(timeframe.contains("morning_kg_fact"))
    #expect(timeframe.contains("afternoon_raw_fact"))
    #expect(timeframe.contains("[KG 2026-07-01]"))
    #expect(timeframe.contains("[#\(recent.id)]"))
    #expect(sessions.contains("Morning Archive"))
    #expect(sessions.contains("Afternoon Live"))
    #expect(sessions.contains("[KG 2026-07-01]"))
    #expect(sessions.contains("[#\(recent.id)]"))
}

@Test
func recallProjectsKGFactsToTheRequestedTimeframe() async throws {
    let directory = try recallKGDirectory("CascadeRecallKGProjection")
    let store = try CascadeStore(path: directory.appendingPathComponent("cascade.sqlite").path)
    let morningFrame = try writeRecallFrame(named: "morning.heic", in: directory)
    let eveningFrame = try writeRecallFrame(named: "evening.heic", in: directory)
    let morning = try utcDate("2026-06-30T09:00:00Z")
    let evening = try utcDate("2026-06-30T18:00:00Z")
    let cutoff = try utcDate("2026-06-30T19:00:00Z")

    _ = try await store.insert(RecordedContext(
        capturedAt: morning,
        source: .screen,
        appName: "Safari",
        bundleIdentifier: "com.apple.Safari",
        windowTitle: "Morning In Scope",
        ocrText: "morning_scope_fact review the launch brief",
        imagePath: morningFrame.path
    ))
    _ = try await store.insert(RecordedContext(
        capturedAt: evening,
        source: .screen,
        appName: "Xcode",
        bundleIdentifier: "com.apple.dt.Xcode",
        windowTitle: "Evening Outside Scope",
        ocrText: "evening_scope_fact debug the unrelated build",
        imagePath: eveningFrame.path
    ))

    _ = try await store.compactAgedContextsIntoKnowledgeGraph(olderThan: cutoff)
    try await pruneRecallRows(through: cutoff, store: store)

    let utc = try #require(TimeZone(secondsFromGMT: 0))
    let recall = RecordRecall(store: store, presentationTimeZone: utc)
    let formatter = ISO8601DateFormatter()
    let start = formatter.string(from: morning.addingTimeInterval(-60))
    let end = formatter.string(from: morning.addingTimeInterval(120))
    let timeframe = await recall.perform(.timeframe(startISO: start, endISO: end))
    let sessions = await recall.perform(.sessions(startISO: start, endISO: end))

    #expect(timeframe.contains("Safari"))
    #expect(timeframe.contains("Morning In Scope"))
    #expect(timeframe.contains("morning_scope_fact"))
    #expect(!timeframe.contains("Xcode"))
    #expect(!timeframe.contains("Evening Outside Scope"))
    #expect(!timeframe.contains("evening_scope_fact"))
    #expect(sessions.contains("Morning In Scope"))
    #expect(!sessions.contains("Evening Outside Scope"))
}

@Test
func recallProjectsOnlyObservedFactsInsideAContinuousSession() async throws {
    let directory = try recallKGDirectory("CascadeRecallKGContinuousSession")
    let store = try CascadeStore(path: directory.appendingPathComponent("cascade.sqlite").path)
    let firstFrame = try writeRecallFrame(named: "outer-first.heic", in: directory)
    let innerFrame = try writeRecallFrame(named: "inner.heic", in: directory)
    let lastFrame = try writeRecallFrame(named: "outer-last.heic", in: directory)
    let start = try utcDate("2026-06-30T14:00:00Z")
    let inner = start.addingTimeInterval(120)
    let cutoff = start.addingTimeInterval(300)

    _ = try await store.insertContexts([
        RecordedContext(
            capturedAt: start,
            source: .screen,
            appName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            windowTitle: "Outer Unrelated Ledger",
            ocrText: "outer_ledger_fact",
            imagePath: firstFrame.path
        ),
        RecordedContext(
            capturedAt: inner,
            source: .screen,
            appName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            windowTitle: "Inner Relevant Invoice",
            ocrText: "inner_invoice_fact",
            imagePath: innerFrame.path
        ),
        RecordedContext(
            capturedAt: start.addingTimeInterval(240),
            source: .screen,
            appName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            windowTitle: "Outer Unrelated Ledger",
            ocrText: "outer_ledger_fact",
            imagePath: lastFrame.path
        ),
    ])

    _ = try await store.compactAgedContextsIntoKnowledgeGraph(olderThan: cutoff)
    let graph = try #require(try await store.knowledgeGraph(forDay: EventStoreLayout.utcDayKey(for: start)))
    let session = try #require(graph.nodes.first { $0.type == .session })
    #expect(graph.nodes.filter { $0.type == .session }.count == 1)
    let outerNode = try #require(graph.nodes.first { $0.type == .window && $0.label == "Outer Unrelated Ledger" })
    let innerNode = try #require(graph.nodes.first { $0.type == .window && $0.label == "Inner Relevant Invoice" })
    let outerMembership = try #require(graph.edges.first {
        $0.kind == .sessionMembership && $0.from == outerNode.id && $0.to == session.id
    })
    let innerMembership = try #require(graph.edges.first {
        $0.kind == .sessionMembership && $0.from == innerNode.id && $0.to == session.id
    })
    #expect(outerMembership.observedAtMs == [
        EventStoreLayout.capturedMilliseconds(for: start),
        EventStoreLayout.capturedMilliseconds(for: start.addingTimeInterval(240)),
    ])
    #expect(innerMembership.observedAtMs == [EventStoreLayout.capturedMilliseconds(for: inner)])
    try await pruneRecallRows(through: cutoff, store: store)

    #expect(!FileManager.default.fileExists(atPath: firstFrame.path))
    #expect(!FileManager.default.fileExists(atPath: innerFrame.path))
    #expect(!FileManager.default.fileExists(atPath: lastFrame.path))

    let utc = try #require(TimeZone(secondsFromGMT: 0))
    let recall = RecordRecall(store: store, presentationTimeZone: utc)
    let formatter = ISO8601DateFormatter()
    let rangeStart = formatter.string(from: inner.addingTimeInterval(-10))
    let rangeEnd = formatter.string(from: inner.addingTimeInterval(10))
    let timeframe = await recall.perform(.timeframe(startISO: rangeStart, endISO: rangeEnd))
    let sessions = await recall.perform(.sessions(startISO: rangeStart, endISO: rangeEnd))

    #expect(timeframe.contains("Inner Relevant Invoice"))
    #expect(!timeframe.contains("Outer Unrelated Ledger"))
    #expect(sessions.contains("Inner Relevant Invoice"))
    #expect(!sessions.contains("Outer Unrelated Ledger"))
}

@Test
func recallKeepsLocalTimeAndCalendarDayAfterKGFallback() async throws {
    let directory = try recallKGDirectory("CascadeRecallKGTimeZone")
    let store = try CascadeStore(path: directory.appendingPathComponent("cascade.sqlite").path)
    let frame = try writeRecallFrame(named: "clock.heic", in: directory)
    let capturedAt = try utcDate("2026-07-02T02:13:00Z")
    let cutoff = try utcDate("2026-07-02T03:00:00Z")
    let context = try await store.insert(RecordedContext(
        capturedAt: capturedAt,
        source: .screen,
        appName: "Notes",
        bundleIdentifier: "com.apple.Notes",
        windowTitle: "Clock Stable",
        ocrText: "clockstablemarker local presentation time",
        imagePath: frame.path
    ))
    let toronto = try #require(TimeZone(identifier: "America/Toronto"))
    let recall = RecordRecall(store: store, presentationTimeZone: toronto)

    let raw = await recall.perform(.search(query: "clockstablemarker"))
    #expect(raw.contains("22:13"))
    #expect(raw.contains("[#\(context.id)]"))

    _ = try await store.compactAgedContextsIntoKnowledgeGraph(olderThan: cutoff)
    try await pruneRecallRows(through: cutoff, store: store)
    let compacted = await recall.perform(.search(query: "clockstablemarker"))

    #expect(try await store.context(id: context.id) == nil)
    #expect(!FileManager.default.fileExists(atPath: frame.path))
    #expect(compacted.contains("[KG 2026-07-01]"))
    #expect(compacted.contains("22:13"))
    #expect(!compacted.contains("02:13"))
    #expect(!compacted.contains("[#\(context.id)]"))
}

private func observationEnvelope(from rendered: String) throws -> ObservationEnvelope {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(ObservationEnvelope.self, from: Data(rendered.utf8))
}
