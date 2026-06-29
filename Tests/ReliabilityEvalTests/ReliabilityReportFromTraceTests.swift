import AgentOrchestrator
import Testing

@Test
func reliabilityReportBuildsScenarioOutcomesFromLiveTraces() {
    let traces = [
        trace(
            id: "completed",
            surface: "assist",
            rootStatus: .ok,
            spans: [
                TraceSpan(id: "completed-step", parentID: "completed-root", kind: .step, name: "plan", startMs: 10, durationMs: 1),
                TraceSpan(id: "completed-tool", parentID: "completed-root", kind: .tool, name: "read_file", startMs: 20, durationMs: 1),
            ]
        ),
        trace(
            id: "failed",
            surface: "assist",
            rootStatus: .error,
            rootFailure: .transportFailure,
            spans: [
                TraceSpan(
                    id: "failed-tool",
                    parentID: "failed-root",
                    kind: .tool,
                    name: "run_command",
                    startMs: 10,
                    durationMs: 1,
                    status: .error,
                    failureKind: .transportFailure
                ),
            ]
        ),
        trace(
            id: "stopped",
            surface: "recipeReplay",
            rootStatus: .refused,
            rootFailure: .userStop,
            spans: [
                TraceSpan(
                    id: "stopped-step",
                    parentID: "stopped-root",
                    kind: .step,
                    name: "recipe.step",
                    startMs: 10,
                    durationMs: 1,
                    status: .refused,
                    failureKind: .userStop
                ),
            ]
        ),
        trace(
            id: "retried",
            surface: "backgroundWeb",
            rootStatus: .ok,
            spans: [
                TraceSpan(
                    id: "retried-first-step",
                    parentID: "retried-root",
                    kind: .step,
                    name: "sandbox.act",
                    startMs: 10,
                    durationMs: 1,
                    status: .error,
                    failureKind: .groundingMiss
                ),
                TraceSpan(
                    id: "retried-recovery",
                    parentID: "retried-root",
                    kind: .eval,
                    name: "recovery reground",
                    startMs: 20,
                    durationMs: 1,
                    attributes: ["recovery.action": "regroundVisual"]
                ),
                TraceSpan(id: "retried-tool", parentID: "retried-root", kind: .tool, name: "click", startMs: 30, durationMs: 1),
            ]
        ),
    ]

    let report = ReliabilityReport.fromTraces(traces)

    #expect(report.outcomes == [
        ScenarioOutcome(id: "completed", surface: "assist", status: .success, failureKind: nil, stepsAttempted: 2, retries: 0),
        ScenarioOutcome(id: "failed", surface: "assist", status: .failed, failureKind: .transportFailure, stepsAttempted: 1, retries: 0),
        ScenarioOutcome(id: "stopped", surface: "recipeReplay", status: .userStop, failureKind: .userStop, stepsAttempted: 1, retries: 0),
        ScenarioOutcome(id: "retried", surface: "backgroundWeb", status: .success, failureKind: .groundingMiss, stepsAttempted: 2, retries: 1),
    ])
    #expect(report.total == 4)
    #expect(report.count(byStatus: .success) == 2)
    #expect(report.count(byStatus: .failed) == 1)
    #expect(report.count(byStatus: .userStop) == 1)
    #expect(report.successRatesBySurface == [
        "assist": 0.5,
        "backgroundWeb": 1.0,
        "recipeReplay": 0.0,
    ])
    #expect(report.failureCountsByKind == [
        .transportFailure: 1,
        .userStop: 1,
        .groundingMiss: 1,
    ])
    #expect(report.totalRetries == 1)
    #expect(report.retriesBySurface == [
        "assist": 0,
        "backgroundWeb": 1,
        "recipeReplay": 0,
    ])
}

@Test
func sloSnapshotAppliesSurfaceCostDurationAndLoopBudgets() {
    let traces = [
        trace(
            id: "assist-ok",
            surface: "assist",
            rootStatus: .ok,
            spans: [
                TraceSpan(id: "assist-cost", parentID: "assist-ok-root", kind: .model, name: "model", startMs: 5, durationMs: 90, costUSD: 0.04),
            ]
        ),
        trace(
            id: "web-stall",
            surface: "backgroundWeb",
            rootStatus: .error,
            rootFailure: .noEffect,
            spans: [
                TraceSpan(id: "web-noeffect", parentID: "web-stall-root", kind: .tool, name: "sandbox.noeffect", startMs: 5, durationMs: 400, status: .error, failureKind: .noEffect),
            ]
        ),
    ]
    var budgets = ReliabilityReport.Budgets()
    budgets.minSuccessRatesBySurface = ["assist": 1.0, "backgroundWeb": 0.75]
    budgets.maxNoEffectCount = 0
    budgets.maxStallCount = 0
    budgets.maxCostPerSuccessfulRunUSD = 0.01
    budgets.maxDurationMs = 300

    let snapshot = ReliabilityReport.sloSnapshot(from: traces, budgets: budgets)

    #expect(snapshot.totalRuns == 2)
    #expect(snapshot.successRate == 0.5)
    #expect(snapshot.successRatesBySurface["assist"] == 1.0)
    #expect(snapshot.successRatesBySurface["backgroundWeb"] == 0.0)
    #expect(snapshot.noEffectCount == 1)
    #expect(snapshot.maxDurationMs == 405)
    #expect(!snapshot.passesReleaseGate)
    #expect(snapshot.violations.contains { $0.contains("backgroundWeb success rate") })
    #expect(snapshot.violations.contains { $0.contains("cost per successful run") })
    #expect(snapshot.violations.contains { $0.contains("max duration") })
}

private func trace(
    id: String,
    surface: String,
    rootStatus: TraceSpan.Status,
    rootFailure: AgentFailureKind? = nil,
    spans: [TraceSpan]
) -> AgentTrace {
    AgentTrace(
        traceID: id,
        goal: "goal-\(id)",
        surface: surface,
        spans: [
            TraceSpan(
                id: "\(id)-root",
                parentID: nil,
                kind: .run,
                name: "run",
                startMs: 0,
                durationMs: 100,
                status: rootStatus,
                failureKind: rootFailure
            ),
        ] + spans
    )
}
