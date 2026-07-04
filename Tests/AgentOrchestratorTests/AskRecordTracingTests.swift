import AgentOrchestrator
import CascadeMemory
import Foundation
import ProviderKit
import Testing

// EXERCISED ON-path tests for the default-off `cascade.recordAnswerTracing`
// diagnosis flag: the flag-ON path drives the REAL askRecord fallback chain
// (agentic fail → grounding → local) and must leave a coherent trace timeline
// in audit_event; the flag-OFF path must write ZERO trace rows.

/// Fails deterministically without the network so the agentic layer's failure
/// path is exercised even on machines that have a real key in the keychain.
private struct ThrowingTraceRecordAnswerer: RecordAnswering {
    func answer(question: String, conversation: [(user: String, assistant: String)]) async throws -> RecordAnswer {
        throw CocoaError(.featureUnsupported)
    }
}

private struct ThrowingTraceAnswerer: ContextQuestionAnswering {
    func answer(question: String, grounding: ChatGrounding) async throws -> String {
        throw CocoaError(.featureUnsupported)
    }
}

private struct CannedLocalAnswerer: ContextQuestionAnswering {
    func answer(question: String, grounding: ChatGrounding) async throws -> String {
        "local answer"
    }
}

private func makeTracingStore() throws -> CascadeStore {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("AskRecordTracingTests-\(UUID().uuidString).sqlite")
        .path
    return try CascadeStore(path: path)
}

private func makeSuite(tracing: Bool) -> UserDefaults {
    let suite = UserDefaults(suiteName: "AskRecordTracingTests-\(UUID().uuidString)")!
    if tracing {
        suite.set(true, forKey: RecordAnswerTracer.flagKey)
    }
    return suite
}

private func makeOrchestrator(store: CascadeStore, suite: UserDefaults) -> CascadeOrchestrator {
    CascadeOrchestrator(
        store: store,
        localAnswerer: CannedLocalAnswerer(),
        claudeAnswerer: ThrowingTraceAnswerer(),
        recordAnswerer: ThrowingTraceRecordAnswerer(),
        tracingDefaults: RecordAnswerTracingDefaults(suite)
    )
}

private func traceRows(in store: CascadeStore) async throws -> [AuditEvent] {
    try await store.recentAudit(limit: 200).filter { $0.action == RecordAnswerTracer.auditAction }
}

@Test
func askRecordTracesTheRealFallbackChainWhenEnabled() async throws {
    let store = try makeTracingStore()
    let suite = makeSuite(tracing: true)
    let orchestrator = makeOrchestrator(store: store, suite: suite)
    let question = "what did I do today"

    let answer = try await orchestrator.askRecord(question)

    // The real chain ran to the local fallback (both keyed answerers throw).
    #expect(answer.text == "local answer")

    let rows = try await traceRows(in: store)
    let details = rows.map(\.detail)
    #expect(details.contains { $0.contains("stage=orchestrator.begin") })
    #expect(details.contains { $0.contains("stage=grounding.done") })
    #expect(details.contains { $0.contains("stage=orchestrator.exit") && $0.contains("reason=local") })
    // The keyed layers only run when a real key is in the keychain; when they
    // do, their failure must be traced with the error kind.
    if AnthropicKeyStore().hasKey() {
        #expect(details.contains { $0.contains("stage=agentic.exit") && $0.contains("err=") })
        #expect(details.contains { $0.contains("stage=singleshot.exit") && $0.contains("err=") })
    }
    // Every row correlates: ask= id, t= offset, and the question only as a hash.
    let begin = try #require(details.first { $0.contains("stage=orchestrator.begin") })
    #expect(begin.contains("qhash=\(AuditIdentity.hash(question))"))
    for detail in details {
        #expect(detail.contains("ask="))
        #expect(detail.contains(" t="))
        #expect(!detail.contains(question)) // raw question text is NEVER stored
    }
}

@Test
func askRecordTracesSourceMismatchExit() async throws {
    let store = try makeTracingStore()
    let suite = makeSuite(tracing: true)
    let orchestrator = makeOrchestrator(store: store, suite: suite)
    let plan = SourcePlan(routingIntent: .webFact, candidateSources: [.web], cleanQuery: "weather in tokyo")

    let answer = try await orchestrator.askRecord("weather in tokyo", sourcePlan: plan)

    #expect(answer.text.contains("source-mismatch"))
    let details = try await traceRows(in: store).map(\.detail)
    #expect(details.contains { $0.contains("stage=orchestrator.begin") && $0.contains("plan=web_fact") })
    #expect(details.contains { $0.contains("stage=orchestrator.exit") && $0.contains("reason=source-mismatch") })
    // The mismatch exits BEFORE grounding — no later stages.
    #expect(!details.contains { $0.contains("stage=grounding.done") })
}

@Test
func askRecordWritesZeroTraceRowsWhenFlagOff() async throws {
    let store = try makeTracingStore()
    let suite = makeSuite(tracing: false)
    let orchestrator = makeOrchestrator(store: store, suite: suite)

    let answer = try await orchestrator.askRecord("what did I do today")

    #expect(answer.text == "local answer")
    let rows = try await traceRows(in: store)
    #expect(rows.isEmpty)
}
