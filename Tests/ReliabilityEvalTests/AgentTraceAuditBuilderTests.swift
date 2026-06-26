import AgentOrchestrator
import CascadeMemory
import Foundation
import Testing

@Test
func auditEventsAssembleTrailingAssistTaskWithBufferedSpans() async throws {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("AgentTraceAuditBuilder-\(UUID().uuidString).sqlite")
        .path
    let store = try CascadeStore(path: path)
    let base = Date(timeIntervalSince1970: 1_800_000_000)

    _ = try await store.appendAudit(AuditEvent(createdAt: base, actor: "agent", action: "harness.read_file", detail: "/Users/example/private-payroll.txt"))
    _ = try await store.appendAudit(AuditEvent(createdAt: base.addingTimeInterval(0.1), actor: "agent", action: "agent.recall", detail: "query contained Jane Secret payroll"))
    _ = try await store.appendAudit(AuditEvent(createdAt: base.addingTimeInterval(0.2), actor: "agent", action: "assist.timing", detail: "finished · 3 turns · total 1200ms · model 410ms · actions 80ms · effort medium · claude-sonnet"))
    _ = try await store.appendAudit(AuditEvent(createdAt: base.addingTimeInterval(0.3), actor: "agent", action: "assist.task", detail: "Email Jane Secret about payroll"))

    let events = try await store.auditWindowForTraceAssembly(
        from: base,
        to: base.addingTimeInterval(1),
        enableTraceAssembly: true
    )

    let traces = AgentTraceBuilder.fromAuditEvents(events)

    #expect(traces.count == 1)
    let trace = try #require(traces.first)
    #expect(events.map(\.action) == ["harness.read_file", "agent.recall", "assist.timing", "assist.task"])
    #expect(trace.traceID == "audit-4")
    #expect(trace.durationMs == 1200)
    #expect(trace.spans.map(\.id) == ["run-4", "tool-1", "retrieval-2", "model-3"])
    #expect(trace.spans.map(\.parentID) == [nil, "run-4", "run-4", "run-4"])
    #expect(trace.spans.map(\.kind) == [.run, .tool, .retrieval, .model])
    #expect(trace.spans.map(\.startMs) == [0, 0, 100, 200])
    #expect(trace.spans.first?.status == .ok)
    #expect(trace.spans.first?.failureKind == nil)
    #expect(trace.spans.first { $0.id == "model-3" }?.durationMs == 410)
    #expect(trace.spans.first { $0.id == "model-3" }?.attributes["agent.turns"] == "3")
    #expect(trace.spans.allSatisfy { span in
        !span.attributes.values.joined(separator: " ").contains("Jane")
            && !span.attributes.values.joined(separator: " ").contains("payroll")
            && !span.attributes.values.joined(separator: " ").contains("/Users")
    })
}

@Test
func incompleteAuditRunsAreMarkedErrorOrRefused() {
    let base = Date(timeIntervalSince1970: 1_800_000_100)
    let traces = AgentTraceBuilder.fromAuditEvents([
        AuditEvent(id: 10, createdAt: base, actor: "agent", action: "assist.task", detail: "Try a task"),
        AuditEvent(id: 11, createdAt: base.addingTimeInterval(0.1), actor: "agent", action: "harness.run_command", detail: "command"),
        AuditEvent(id: 20, createdAt: base.addingTimeInterval(1.0), actor: "agent", action: "assist.task", detail: "Do unsafe thing"),
        AuditEvent(id: 21, createdAt: base.addingTimeInterval(1.1), actor: "agent", action: "agent.action.refused", detail: "blocked"),
    ])

    #expect(traces.count == 2)
    #expect(traces[0].spans.first?.status == .error)
    #expect(traces[0].spans.first?.failureKind == .timeout)
    #expect(traces[1].spans.first?.status == .refused)
    #expect(traces[1].spans.first?.failureKind == .unsafeActionRefused)
    #expect(traces[1].spans.last?.status == .refused)
}

@Test
func traceAuditWindowIsOptInAndRecentAuditIsUnchanged() async throws {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("AgentTraceAuditBuilder-\(UUID().uuidString).sqlite")
        .path
    let store = try CascadeStore(path: path)
    let base = Date(timeIntervalSince1970: 1_800_000_200)

    _ = try await store.appendAudit(AuditEvent(createdAt: base, actor: "agent", action: "assist.task", detail: "first"))
    _ = try await store.appendAudit(AuditEvent(createdAt: base.addingTimeInterval(1), actor: "agent", action: "harness.list_folder", detail: "second"))
    _ = try await store.appendAudit(AuditEvent(createdAt: base.addingTimeInterval(2), actor: "agent", action: "agent.run.completed", detail: "third"))

    let recent = try await store.recentAudit(limit: 3)
    let disabled = try await store.auditWindowForTraceAssembly(
        from: base,
        to: base.addingTimeInterval(2),
        enableTraceAssembly: false
    )
    let enabled = try await store.auditWindowForTraceAssembly(
        from: base,
        to: base.addingTimeInterval(2),
        enableTraceAssembly: true
    )

    #expect(recent.map(\.action) == ["agent.run.completed", "harness.list_folder", "assist.task"])
    #expect(disabled.isEmpty)
    #expect(enabled.map(\.action) == ["assist.task", "harness.list_folder", "agent.run.completed"])
}
