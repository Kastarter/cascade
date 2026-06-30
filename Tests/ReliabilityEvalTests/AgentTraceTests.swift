import AgentOrchestrator
import CascadeMemory
import Foundation
import Testing

private func sampleTrace() -> AgentTrace {
    let spans = [
        TraceSpan(id: "s0", parentID: nil, kind: .run, name: "open invoice and extract total",
                  startMs: 0, durationMs: 1800, attributes: ["app": "Numbers"]),
        TraceSpan(id: "s1", parentID: "s0", kind: .model, name: "plan",
                  startMs: 10, durationMs: 600, usage: ModelUsage(inputTokens: 1000, outputTokens: 200, cacheReadTokens: 4000),
                  costUSD: 0.012),
        TraceSpan(id: "s2", parentID: "s0", kind: .tool, name: "read_file",
                  startMs: 620, durationMs: 30, attributes: ["moment_id": "8821"]),
        TraceSpan(id: "s3", parentID: "s0", kind: .model, name: "act",
                  startMs: 700, durationMs: 500, status: .error, failureKind: .noEffect,
                  usage: ModelUsage(inputTokens: 1200, outputTokens: 150), costUSD: 0.009),
    ]
    return AgentTrace(traceID: "t-001", goal: "extract total", surface: "assist", spans: spans)
}

private func otelSpans(from obj: [String: Any]?) -> [[String: Any]]? {
    guard
        let resourceSpans = obj?["resourceSpans"] as? [[String: Any]],
        let scopeSpans = resourceSpans.first?["scopeSpans"] as? [[String: Any]]
    else {
        return nil
    }
    return scopeSpans.first?["spans"] as? [[String: Any]]
}

private func otelStringAttributes(from span: [String: Any]?) -> [String: String] {
    guard let attrs = span?["attributes"] as? [[String: Any]] else { return [:] }
    return attrs.reduce(into: [:]) { result, attr in
        guard
            let key = attr["key"] as? String,
            let value = attr["value"] as? [String: Any],
            let stringValue = value["stringValue"] as? String
        else {
            return
        }
        result[key] = stringValue
    }
}

@Test
func rollupsAggregateUsageCostAndDuration() {
    let trace = sampleTrace()
    #expect(trace.modelCallCount == 2)
    #expect(trace.toolCallCount == 1)
    #expect(trace.inputTokens == 2200)
    #expect(trace.outputTokens == 350)
    #expect(trace.cacheReadTokens == 4000)
    #expect(abs(trace.totalCostUSD - 0.021) < 1e-9)
    #expect(trace.durationMs == 1800)        // run span 0 + 1800
    #expect(trace.succeeded == false)        // s3 errored
    #expect(trace.failureKinds == [.noEffect])
}

@Test
func pricingComputesCostFromUsage() {
    let pricing = ModelPricing(inputPerMTok: 3.0, outputPerMTok: 15.0, cacheReadPerMTok: 0.3, cacheWritePerMTok: 3.75)
    let usage = ModelUsage(inputTokens: 1_000_000, outputTokens: 1_000_000, cacheReadTokens: 1_000_000)
    // 3 + 15 + 0.3 = 18.3
    #expect(abs(pricing.cost(usage) - 18.3) < 1e-9)
    #expect(pricing.cost(ModelUsage()) == 0)
}

@Test
func succeededRequiresEverySpanToBeOk() {
    func trace(statuses: [TraceSpan.Status]) -> AgentTrace {
        AgentTrace(
            traceID: "t-status",
            goal: "g",
            surface: "assist",
            spans: statuses.enumerated().map { index, status in
                TraceSpan(
                    id: "s\(index)",
                    parentID: index == 0 ? nil : "s0",
                    kind: index == 0 ? .run : .tool,
                    name: "span \(index)",
                    startMs: index,
                    durationMs: 1,
                    status: status
                )
            }
        )
    }

    #expect(trace(statuses: [.ok, .ok]).succeeded)
    #expect(!trace(statuses: [.ok, .error]).succeeded)
    #expect(!trace(statuses: [.ok, .refused]).succeeded)
}

@Test
func otelJSONIsValidAndCarriesSemanticKeys() throws {
    let json = sampleTrace().otelJSON()
    let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
    #expect(obj?["trace_id"] as? String == "t-001")
    let spans = otelSpans(from: obj)
    #expect(spans?.count == 4)
    // The model span exposes gen_ai token attributes and the failure span error.type.
    let modelSpan = spans?.first { ($0["name"] as? String) == "act" }
    let attrs = otelStringAttributes(from: modelSpan)
    #expect(attrs["gen_ai.usage.input_tokens"] == "1200")
    #expect(attrs["error.type"] == "noEffect")
}

@Test
func siemJsonlIsOneObjectPerSpan() throws {
    let lines = sampleTrace().siemJSONL().split(separator: "\n")
    #expect(lines.count == 4)
    for line in lines {
        let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        #expect(obj?["trace_id"] as? String == "t-001")
        #expect(obj?["span_id"] != nil)
    }
}

@Test
func csvHasHeaderAndRowPerSpanAndEscapes() {
    let trace = AgentTrace(traceID: "t-002", goal: "g", surface: "assist", spans: [
        TraceSpan(id: "s0", parentID: nil, kind: .run, name: "do a, b, c", startMs: 0, durationMs: 5),
    ])
    let lines = trace.csv().split(separator: "\n")
    #expect(lines.count == 2)                       // header + 1 row
    #expect(lines[0].hasPrefix("trace_id,span_id"))
    #expect(lines[1].contains("\"do a, b, c\""))    // comma-bearing field quoted
}

@Test
func csvEscapesFormulaPrefixedAuditFieldsBeforeQuoteEscaping() {
    let trace = AgentTrace(traceID: "=trace, \"quoted\"", goal: "g", surface: "assist", spans: [
        TraceSpan(
            id: "+span, \"quoted\"",
            parentID: "-parent, \"quoted\"",
            kind: .tool,
            name: "@name, \"quoted\"",
            startMs: 0,
            durationMs: 1,
            status: .error,
            failureKind: .noEffect
        ),
    ])

    let lines = trace.csv().split(separator: "\n", omittingEmptySubsequences: false)
    #expect(lines.count == 2)
    #expect(lines[1] == "\"'=trace, \"\"quoted\"\"\",\"'+span, \"\"quoted\"\"\",\"'-parent, \"\"quoted\"\"\",tool,\"'@name, \"\"quoted\"\"\",0,1,error,noEffect,")
    #expect(AgentTraceCSVFieldEscaper.escape("=failure, \"quoted\"") == "\"'=failure, \"\"quoted\"\"\"")
    #expect(AgentTraceCSVFieldEscaper.escape("\t=HYPERLINK(\"https://example.com\")") == "\"'\t=HYPERLINK(\"\"https://example.com\"\")\"")
    #expect(AgentTraceCSVFieldEscaper.escape("\r=HYPERLINK(\"https://example.com\")") == "\"'\r=HYPERLINK(\"\"https://example.com\"\")\"")
    #expect(AgentTraceCSVFieldEscaper.escape("  =SUM(1)") == "'  =SUM(1)")
}

@Test
func auditExportPackageIncludesManifestAndAllFormatsWithoutRawDetails() throws {
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    let events = [
        AuditEvent(id: 1, createdAt: base, actor: "agent", action: "assist.task", detail: "Email Jane Secret about payroll"),
        AuditEvent(id: 2, createdAt: base.addingTimeInterval(0.1), actor: "agent", action: "harness.read_file", detail: "/Users/example/payroll.txt"),
        AuditEvent(id: 3, createdAt: base.addingTimeInterval(0.2), actor: "agent", action: "agent.run.completed", detail: "agentID=7 labelHash=abc"),
    ]

    let package = AgentAuditExportPackage.build(
        trustedChronologicalEvents: events,
        windowStart: base,
        windowEnd: base.addingTimeInterval(1),
        auditChainStatus: .intact(verified: 3),
        auditHead: AuditHead(count: 3, hash: "abc")
    )
    let combined = AgentAuditExportFormat.allCases.map { package.content(format: $0) }.joined(separator: "\n")

    #expect(package.manifest.auditChainTrusted)
    #expect(package.manifest.auditChainStatus == "intact:3")
    #expect(package.manifest.auditHead == AuditHead(count: 3, hash: "abc"))
    #expect(package.manifest.traceCount == 1)
    #expect(package.manifest.spanCount >= 2)
    #expect(combined.contains("audit-1"))
    #expect(!combined.contains("Jane Secret"))
    #expect(!combined.contains("payroll.txt"))
}

@Test
func valueSummaryCountsOnlyCompletedRunsAndAppliesBudgets() {
    let agents = [
        CascadeAgent(
            id: 1,
            name: "Completed",
            source: .detected,
            signature: "a",
            recipe: AgentRecipe(steps: []),
            estimatedSecondsPerRun: 120,
            runCount: 2
        ),
        CascadeAgent(
            id: 2,
            name: "Never run",
            source: .detected,
            signature: "b",
            recipe: AgentRecipe(steps: []),
            estimatedSecondsPerRun: 300,
            runCount: 0
        ),
    ]
    let traces = [
        AgentTrace(
            traceID: "value",
            goal: "g",
            surface: "assist",
            spans: [
                TraceSpan(id: "value-root", parentID: nil, kind: .run, name: "run", startMs: 0, durationMs: 10),
                TraceSpan(id: "tool", parentID: "value-root", kind: .tool, name: "click", startMs: 1, durationMs: 1, costUSD: 0.04),
            ]
        )
    ]

    let summary = AgentValueSummary.from(
        agents: agents,
        traces: traces,
        hourlyRateUSD: 90,
        budgets: AgentValueBudgets(monthlyRunLimit: 2, monthlyActionLimit: 1, monthlyCostCentsLimit: 4)
    )

    #expect(summary.completedRuns == 2)
    #expect(summary.reclaimedSeconds == 240)
    #expect(abs(summary.estimatedDollarValue - 6.0) < 0.0001)
    #expect(summary.costPerCompletedRunUSD == 0.02)
    #expect(summary.budgetExhausted)
}

@Test
func fleetMetricsEmitAggregateBucketsWithoutTraceDetail() throws {
    let trace = AgentTrace(
        traceID: "trace-secret-123",
        goal: "Rank Jane payroll files",
        surface: "assist",
        spans: [
            TraceSpan(
                id: "root",
                parentID: nil,
                kind: .run,
                name: "Open https://internal.example/payroll",
                startMs: 0,
                durationMs: 80_000,
                attributes: ["prompt": "rank Jane payroll files"]
            ),
            TraceSpan(
                id: "model",
                parentID: "root",
                kind: .model,
                name: "secret planning prompt",
                startMs: 5,
                durationMs: 300,
                usage: ModelUsage(inputTokens: 2_000, outputTokens: 500, cacheReadTokens: 8_000)
            ),
            TraceSpan(
                id: "tool",
                parentID: "root",
                kind: .tool,
                name: "browser_click_internal_url",
                startMs: 400,
                durationMs: 30,
                attributes: [
                    "tool.type": "browser",
                    "permission.state": "denied",
                    "gen_ai.tool.call.arguments": "{\"url\":\"https://internal.example/payroll\"}"
                ]
            ),
            TraceSpan(
                id: "failure",
                parentID: "root",
                kind: .eval,
                name: "verify payroll result",
                startMs: 500,
                durationMs: 10,
                status: .error,
                failureKind: .permissionMissing
            )
        ]
    )
    let policy = AnalyticsPrivacyPolicy(
        clippingBounds: FleetClippingBounds(minimum: 0, maximum: 10_000),
        minCohort: 50
    )

    let events = trace.fleetMetrics(
        period: "2026-06-29",
        policy: policy,
        sourceAuditHead: AuditHead(count: 9, hash: "audit-head"),
        epsilon: 0.5,
        delta: 0,
        mechanism: .laplaceBoundedCount
    )
    let data = try JSONEncoder().encode(events)
    let json = String(decoding: data, as: UTF8.self)

    #expect(events.contains { $0.tenantMetricKey == "model.token_bucket.count" && $0.bucket == "10k_100k" })
    #expect(events.contains { $0.tenantMetricKey == "trace.duration_bucket.count" && $0.bucket == "1m_5m" })
    #expect(events.contains { $0.tenantMetricKey == "tool.class.count" && $0.bucket == "browser" })
    #expect(events.contains { $0.tenantMetricKey == "permission.state.count" && $0.bucket == "blocked" })
    #expect(events.allSatisfy { $0.minCohort == 50 && $0.auditHeadHash == "audit-head" })
    #expect(!json.contains("trace-secret-123"))
    #expect(!json.contains("Jane"))
    #expect(!json.contains("payroll"))
    #expect(!json.contains("internal.example"))
    #expect(!json.contains("secret planning prompt"))

    let export = trace.fleetAnalyticsExport(
        period: "2026-06-29",
        policy: policy,
        sourceAuditHead: AuditHead(count: 9, hash: "audit-head"),
        appBuild: "build-privacy",
        tenantIDHash: "tenant-hash"
    )
    #expect(export.manifest.sourceAuditHead == AuditHead(count: 9, hash: "audit-head"))
    #expect(export.manifest.appBuild == "build-privacy")
    #expect(export.manifest.tenantIDHash == "tenant-hash")
}
