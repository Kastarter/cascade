import AgentOrchestrator
import CascadeMemory
import Foundation
import SQLite3
import Testing

private func rawTraceAuditExec(_ path: String, _ sql: String) {
    var db: OpaquePointer?
    guard sqlite3_open(path, &db) == SQLITE_OK else { return }
    defer { sqlite3_close(db) }
    sqlite3_exec(db, sql, nil, nil, nil)
}

private func otelHasStringAttribute(_ key: String, _ value: String, in json: String) throws -> Bool {
    guard
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
        let resourceSpans = obj["resourceSpans"] as? [[String: Any]]
    else {
        return false
    }
    for resourceSpan in resourceSpans {
        guard let scopeSpans = resourceSpan["scopeSpans"] as? [[String: Any]] else { continue }
        for scopeSpan in scopeSpans {
            guard let spans = scopeSpan["spans"] as? [[String: Any]] else { continue }
            for span in spans {
                guard let attrs = span["attributes"] as? [[String: Any]] else { continue }
                if attrs.contains(where: { attr in
                    guard
                        attr["key"] as? String == key,
                        let typedValue = attr["value"] as? [String: Any]
                    else {
                        return false
                    }
                    return typedValue["stringValue"] as? String == value
                }) {
                    return true
                }
            }
        }
    }
    return false
}

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
func agentTraceRootExportKeepsAssistTaskDetailPrivate() throws {
    let base = Date(timeIntervalSince1970: 1_800_000_050)
    let privateDetail = """
    Ask Jane Secret to review payroll adjustment for jane.secret@example.com \
    at https://hr.example.test/payroll?token=secret-token-123 from /Users/khalidsh/Payroll/private.csv
    """
    let trace = try #require(AgentTraceBuilder.fromAuditEvents([
        AuditEvent(id: 42, createdAt: base, actor: "agent", action: "assist.task", detail: privateDetail),
        AuditEvent(id: 43, createdAt: base.addingTimeInterval(0.1), actor: "agent", action: "harness.list_folder", detail: "/Users/khalidsh/Payroll"),
    ]).first)
    let otel = trace.otelJSON()
    let sensitiveFragments = [
        "Jane Secret",
        "payroll adjustment",
        "jane.secret@example.com",
        "secret-token-123",
        "/Users/khalidsh/Payroll/private.csv",
    ]

    #expect(trace.goal == "assist.task#audit-42")
    #expect(trace.traceID == "audit-42")
    #expect(trace.spans.first?.attributes["audit.id"] == "42")
    #expect(otel.contains("\"trace_id\":\"audit-42\""))
    #expect(try otelHasStringAttribute("audit.id", "42", in: otel))
    #expect(sensitiveFragments.allSatisfy { !trace.goal.contains($0) })
    #expect(sensitiveFragments.allSatisfy { !otel.contains($0) })
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

@Test
func traceAuditWindowAssemblesSandboxAndRecipeReplayRuns() async throws {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("AgentTraceSandboxRecipe-\(UUID().uuidString).sqlite")
        .path
    let store = try CascadeStore(path: path)
    let base = Date(timeIntervalSince1970: 1_800_000_250)

    _ = try await store.appendAudit(AuditEvent(createdAt: base, actor: "agent", action: "sandbox.act", detail: "kind=click status=ok"))
    _ = try await store.appendAudit(AuditEvent(createdAt: base.addingTimeInterval(0.1), actor: "agent", action: "sandbox.done", detail: "status=finished acted=true resultChars=12 resultHash=abc"))
    _ = try await store.appendAudit(AuditEvent(createdAt: base.addingTimeInterval(0.2), actor: "agent", action: "sandbox.verify", detail: "status=incomplete resultChars=12 resultHash=abc"))
    _ = try await store.appendAudit(AuditEvent(createdAt: base.addingTimeInterval(0.3), actor: "agent", action: "sandbox.task", detail: "outcome=endedwithoutcompleting taskChars=24 taskHash=def"))
    _ = try await store.appendAudit(AuditEvent(createdAt: base.addingTimeInterval(1.0), actor: "agent", action: "recipe.run.started", detail: "agentID=7 steps=1 nameChars=8 nameHash=abc"))
    _ = try await store.appendAudit(AuditEvent(createdAt: base.addingTimeInterval(1.1), actor: "agent", action: "recipe.step", detail: "step=1 kind=click appChars=6 appHash=aaa hasPoint=true isParameter=false"))
    _ = try await store.appendAudit(AuditEvent(createdAt: base.addingTimeInterval(1.2), actor: "agent", action: "recipe.pause.modal", detail: "modalTitleChars=5 modalTitleHash=bbb"))
    _ = try await store.appendAudit(AuditEvent(createdAt: base.addingTimeInterval(1.3), actor: "agent", action: "recipe.run.ended", detail: "status=paused agentID=7 steps=1 nameChars=8 nameHash=abc"))

    let disabled = try await store.auditWindowForTraceAssembly(
        from: base,
        to: base.addingTimeInterval(2),
        enableTraceAssembly: false
    )
    let events = try await store.auditWindowForTraceAssembly(
        from: base,
        to: base.addingTimeInterval(2),
        enableTraceAssembly: true
    )
    let traces = AgentTraceBuilder.fromAuditEvents(events)
    let sandbox = try #require(traces.first { $0.surface == "backgroundWeb" })
    let recipe = try #require(traces.first { $0.surface == "recipeReplay" })

    #expect(disabled.isEmpty)
    #expect(traces.count == 2)
    #expect(traces.filter { $0.surface == "backgroundWeb" }.count == 1)
    #expect(traces.filter { $0.surface == "recipeReplay" }.count == 1)
    #expect(sandbox.spans.first?.name == "sandbox.task")
    #expect(sandbox.spans.first?.status == .error)
    #expect(sandbox.spans.first?.failureKind == .validatorIncomplete)
    #expect(sandbox.spans.count == 4)
    #expect(recipe.spans.first?.name == "recipe.run.started")
    #expect(recipe.spans.first?.status == .error)
    #expect(recipe.spans.first?.failureKind == .unexpectedModal)
    #expect(recipe.spans.count == 4)
}

@Test
func traceBuilderPreservesVerifierConfidenceAsSafeAttributes() throws {
    let base = Date(timeIntervalSince1970: 1_800_000_275)
    let traces = AgentTraceBuilder.fromAuditEvents([
        AuditEvent(id: 30, createdAt: base, actor: "agent", action: "assist.task", detail: "private task text"),
        AuditEvent(
            id: 31,
            createdAt: base.addingTimeInterval(0.1),
            actor: "agent",
            action: "grounding.verifier",
            detail: "verdict=accept outcome=accepted failure=none confidence=0.91 targetChars=12 targetHash=abc"
        ),
        AuditEvent(id: 32, createdAt: base.addingTimeInterval(0.2), actor: "agent", action: "agent.run.completed", detail: "agentID=1 labelHash=abc"),
    ])

    let trace = try #require(traces.first)
    let verifier = try #require(trace.spans.first { $0.name == "grounding.verifier" })
    let outcome = trace.scenarioOutcome

    #expect(verifier.attributes["verifier.confidence"] == "0.9100")
    #expect(verifier.attributes["confidence.bucket"] == "0.8-1.0")
    #expect(outcome.confidence == 0.91)
    #expect(outcome.confidenceBucket == "0.8-1.0")
    #expect(outcome.actualSuccess == true)
    #expect(outcome.calibrationOutcome == .acceptedCorrect)
}

@Test
func traceBuilderDerivesVerifierFailureAttributesAndCalibration() throws {
    let base = Date(timeIntervalSince1970: 1_800_000_276)
    let traces = AgentTraceBuilder.fromAuditEvents([
        AuditEvent(id: 40, createdAt: base, actor: "agent", action: "assist.task", detail: "private task text"),
        AuditEvent(
            id: 41,
            createdAt: base.addingTimeInterval(0.1),
            actor: "agent",
            action: "grounding.verifier",
            detail: "verdict=abstain outcome=ambiguous failure=ambiguous confidence=0.42 candidates=3 selectedSource=accessibility selectedCandidateHash=abc123 targetChars=12 targetHash=def"
        ),
        AuditEvent(
            id: 42,
            createdAt: base.addingTimeInterval(0.2),
            actor: "agent",
            action: "assist.verify.action",
            detail: "status=failed postEffect=mismatch expectedEffect=frontmost_app failureKind=no_effect"
        ),
        AuditEvent(id: 43, createdAt: base.addingTimeInterval(0.3), actor: "agent", action: "agent.run.completed", detail: "agentID=1 labelHash=abc"),
    ])

    let trace = try #require(traces.first)
    let grounding = try #require(trace.spans.first { $0.name == "grounding.verifier" })
    let actionVerify = try #require(trace.spans.first { $0.name == "assist.verify.action" })
    let outcome = trace.scenarioOutcome

    #expect(grounding.failureKind == .verifierDisagreement)
    #expect(grounding.attributes["verifier.verdict"] == "abstain")
    #expect(grounding.attributes["verifier.failure"] == "ambiguous")
    #expect(grounding.attributes["selected.source"] == "accessibility")
    #expect(grounding.attributes["selected.candidate_hash"] == "abc123")
    #expect(grounding.attributes["candidate.count"] == "3")
    #expect(actionVerify.failureKind == .effectMismatch)
    #expect(actionVerify.attributes["post_effect"] == "mismatch")
    #expect(actionVerify.attributes["expected_effect"] == "frontmost_app")
    #expect(outcome.calibrationOutcome == .abstained)
}

@Test
func traceAuditWindowRejectsUnchainedOnlyRows() async throws {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("AgentTraceLegacyOnly-\(UUID().uuidString).sqlite")
        .path
    _ = try CascadeStore(path: path)
    let base = Date(timeIntervalSince1970: 1_800_000_300)
    rawTraceAuditExec(path, """
    INSERT INTO audit_event (created_at, actor, action, detail)
    VALUES ('2027-01-15T08:05:00.000Z','legacy','assist.task','unchained');
    """)

    let fresh = try CascadeStore(path: path)
    let enabled = try await fresh.auditWindowForTraceAssembly(
        from: base,
        to: base.addingTimeInterval(1),
        enableTraceAssembly: true
    )

    #expect(enabled.isEmpty)
}

@Test
func traceAuditWindowFiltersLegacyPrefixBeforeChainedRows() async throws {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("AgentTraceLegacyPrefix-\(UUID().uuidString).sqlite")
        .path
    let store = try CascadeStore(path: path)
    let base = Date(timeIntervalSince1970: 1_800_000_400)
    rawTraceAuditExec(path, """
    INSERT INTO audit_event (created_at, actor, action, detail)
    VALUES ('2027-01-15T08:06:40.000Z','legacy','assist.task','legacy prefix');
    """)
    _ = try await store.appendAudit(AuditEvent(
        createdAt: base.addingTimeInterval(1),
        actor: "agent",
        action: "harness.list_folder",
        detail: "chained"
    ))

    let enabled = try await store.auditWindowForTraceAssembly(
        from: base,
        to: base.addingTimeInterval(2),
        enableTraceAssembly: true
    )

    #expect(enabled.map(\.action) == ["harness.list_folder"])
}
