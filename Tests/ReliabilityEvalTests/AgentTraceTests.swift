import AgentOrchestrator
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
    let spans = obj?["spans"] as? [[String: Any]]
    #expect(spans?.count == 4)
    // The model span exposes gen_ai token attributes and the failure span error.type.
    let modelSpan = spans?.first { ($0["name"] as? String) == "act" }
    let attrs = modelSpan?["attributes"] as? [String: Any]
    #expect(attrs?["gen_ai.usage.input_tokens"] as? Int == 1200)
    #expect(attrs?["error.type"] as? String == "noEffect")
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
