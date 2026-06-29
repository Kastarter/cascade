import CascadeMemory
import Foundation

/// Token usage for one model call.
public struct ModelUsage: Sendable, Equatable, Codable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheWriteTokens: Int

    public init(inputTokens: Int = 0, outputTokens: Int = 0, cacheReadTokens: Int = 0, cacheWriteTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
    }
}

/// Per-million-token pricing for a model, used to turn usage into a cost ledger.
/// Defaults are ILLUSTRATIVE — update to the current published rates; the cost
/// ledger's value is the structure, and callers can inject exact pricing.
public struct ModelPricing: Sendable, Equatable {
    public let inputPerMTok: Double
    public let outputPerMTok: Double
    public let cacheReadPerMTok: Double
    public let cacheWritePerMTok: Double

    public init(inputPerMTok: Double, outputPerMTok: Double, cacheReadPerMTok: Double, cacheWritePerMTok: Double) {
        self.inputPerMTok = inputPerMTok
        self.outputPerMTok = outputPerMTok
        self.cacheReadPerMTok = cacheReadPerMTok
        self.cacheWritePerMTok = cacheWritePerMTok
    }

    public func cost(_ usage: ModelUsage) -> Double {
        (Double(usage.inputTokens) * inputPerMTok
            + Double(usage.outputTokens) * outputPerMTok
            + Double(usage.cacheReadTokens) * cacheReadPerMTok
            + Double(usage.cacheWriteTokens) * cacheWritePerMTok) / 1_000_000.0
    }
}

/// One node of an agent run trace: a run, a step, a model call, a tool call, a
/// retrieval, or an eval. A span tree (parentID links) reconstructs the full run
/// the way OpenTelemetry GenAI traces do — for a local Trace Explorer and for
/// enterprise SIEM/observability export.
///
/// Privacy: `attributes` must carry only safe references (moment ids, app names,
/// counts, hashes) — never raw OCR/screenshot/prompt text. Raw screen content
/// stays in the local record, referenced by id.
public struct TraceSpan: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable {
        case run, step, model, tool, retrieval, eval
    }
    public enum Status: String, Sendable, Codable {
        case ok, error, refused
    }

    public let id: String
    public let parentID: String?
    public let kind: Kind
    public let name: String
    public let startMs: Int          // ms since the run started
    public let durationMs: Int
    public let status: Status
    public let failureKind: AgentFailureKind?
    public let usage: ModelUsage?
    public let costUSD: Double?
    public let attributes: [String: String]

    public init(
        id: String, parentID: String?, kind: Kind, name: String,
        startMs: Int, durationMs: Int, status: Status = .ok,
        failureKind: AgentFailureKind? = nil, usage: ModelUsage? = nil,
        costUSD: Double? = nil, attributes: [String: String] = [:]
    ) {
        self.id = id
        self.parentID = parentID
        self.kind = kind
        self.name = name
        self.startMs = startMs
        self.durationMs = durationMs
        self.status = status
        self.failureKind = failureKind
        self.usage = usage
        self.costUSD = costUSD
        self.attributes = attributes
    }
}

/// A complete agent-run trace: the spans plus roll-up metrics and enterprise
/// export formats. Pure value type — assembled from captured spans, exportable to
/// OTel JSON (observability), SIEM JSONL (Splunk/Datadog), or CSV (audit/procurement).
public struct AgentTrace: Sendable, Equatable, Codable {
    public let traceID: String
    public let goal: String
    public let surface: String
    public let spans: [TraceSpan]

    public init(traceID: String, goal: String, surface: String, spans: [TraceSpan]) {
        self.traceID = traceID
        self.goal = goal
        self.surface = surface
        self.spans = spans
    }

    // MARK: Roll-ups

    public var totalCostUSD: Double { spans.compactMap(\.costUSD).reduce(0, +) }
    public var inputTokens: Int { spans.compactMap(\.usage).reduce(0) { $0 + $1.inputTokens } }
    public var outputTokens: Int { spans.compactMap(\.usage).reduce(0) { $0 + $1.outputTokens } }
    public var cacheReadTokens: Int { spans.compactMap(\.usage).reduce(0) { $0 + $1.cacheReadTokens } }
    public var preflightInputTokens: Int {
        spans.reduce(0) { partial, span in
            partial + Self.intAttribute(["preflight.input_tokens", "preflightInputTokens"], in: span)
        }
    }
    public var estimatedCostUSD: Double {
        spans.reduce(0) { partial, span in
            partial + Self.doubleAttribute(["preflight.cost_usd", "estimatedCostUSD", "estimatedCostUsd"], in: span)
        }
    }
    public var cacheHitRatio: Double {
        let total = inputTokens + cacheReadTokens
        guard total > 0 else { return 0 }
        return Double(cacheReadTokens) / Double(total)
    }
    public var modelCallCount: Int { spans.filter { $0.kind == .model }.count }
    public var toolCallCount: Int { spans.filter { $0.kind == .tool }.count }
    public var durationMs: Int { spans.map { $0.startMs + $0.durationMs }.max() ?? 0 }
    public var failureKinds: [AgentFailureKind] { spans.compactMap(\.failureKind) }
    public var succeeded: Bool { spans.allSatisfy { $0.status == .ok } }
    public var stepToolSpanCount: Int { spans.filter { $0.kind == .step || $0.kind == .tool }.count }
    public var retryCount: Int { spans.reduce(0) { $0 + Self.retryCount(from: $1) } }

    public var scenarioOutcome: ScenarioOutcome {
        let root = spans.first { $0.kind == .run && $0.parentID == nil } ?? spans.first
        let rootStatus = root?.status ?? (succeeded ? .ok : .error)
        let failureKind = root?.failureKind ?? failureKinds.last
        let status = Self.scenarioStatus(rootStatus: rootStatus, failureKind: failureKind)
        let confidence = spans.compactMap { Self.confidence(from: $0.attributes) }.last
        return ScenarioOutcome(
            id: traceID,
            surface: surface,
            status: status,
            failureKind: failureKind,
            stepsAttempted: stepToolSpanCount,
            retries: retryCount,
            targetTier: spans.compactMap { $0.attributes["target.tier"] ?? $0.attributes["targetTier"] }.last,
            modalCount: Self.countSpans(namedLike: ["modal"], failureKind: .unexpectedModal, in: spans),
            noEffectCount: Self.countSpans(namedLike: ["noeffect", "no_effect"], failureKind: .noEffect, in: spans),
            validatorIncompleteCount: Self.countSpans(namedLike: ["validator", "verify"], failureKind: .validatorIncomplete, in: spans),
            verificationFailureCount: Self.countSpans(namedLike: ["verify", "verification"], failureKind: .verificationUnavailable, in: spans),
            confidence: confidence,
            actualSuccess: confidence == nil ? nil : status == .success
        )
    }

    // MARK: Exports

    /// OTel-flavored JSON: one object per span with gen_ai.* semantic-convention
    /// keys where applicable. Approximate, not a full OTLP envelope.
    public func otelJSON() -> String {
        let objects: [[String: Any]] = spans.map { span in
            var attrs: [String: Any] = [
                "cascade.trace_id": traceID,
                "cascade.surface": surface,
            ]
            for (k, v) in span.attributes { attrs[k] = v }
            if let usage = span.usage {
                attrs["gen_ai.usage.input_tokens"] = usage.inputTokens
                attrs["gen_ai.usage.output_tokens"] = usage.outputTokens
                attrs["gen_ai.usage.cache_read_tokens"] = usage.cacheReadTokens
            }
            if let cost = span.costUSD { attrs["cascade.cost_usd"] = cost }
            if let failure = span.failureKind { attrs["error.type"] = failure.rawValue }
            var object: [String: Any] = [
                "name": span.name,
                "kind": span.kind.rawValue,
                "span_id": span.id,
                "start_ms": span.startMs,
                "duration_ms": span.durationMs,
                "status": span.status.rawValue,
                "attributes": attrs,
            ]
            if let parent = span.parentID { object["parent_span_id"] = parent }
            return object
        }
        let root: [String: Any] = ["trace_id": traceID, "goal": goal, "spans": objects]
        return jsonString(root)
    }

    /// SIEM line-delimited JSON — one flat object per span per line.
    public func siemJSONL() -> String {
        spans.map { span in
            var object: [String: Any] = [
                "trace_id": traceID,
                "surface": surface,
                "span_id": span.id,
                "kind": span.kind.rawValue,
                "name": span.name,
                "start_ms": span.startMs,
                "duration_ms": span.durationMs,
                "status": span.status.rawValue,
            ]
            if let parent = span.parentID { object["parent_span_id"] = parent }
            if let cost = span.costUSD { object["cost_usd"] = cost }
            if let failure = span.failureKind { object["failure_kind"] = failure.rawValue }
            return jsonString(object, sorted: true)
        }.joined(separator: "\n")
    }

    /// CSV (header + one row per span) for audit/procurement review.
    public func csv() -> String {
        var rows = ["trace_id,span_id,parent_span_id,kind,name,start_ms,duration_ms,status,failure_kind,cost_usd"]
        for span in spans {
            let fields = [
                traceID, span.id, span.parentID ?? "", span.kind.rawValue, span.name,
                String(span.startMs), String(span.durationMs), span.status.rawValue,
                span.failureKind?.rawValue ?? "", span.costUSD.map { String(format: "%.6f", $0) } ?? "",
            ]
            rows.append(fields.map(AgentTraceCSVFieldEscaper.escape).joined(separator: ","))
        }
        return rows.joined(separator: "\n")
    }

    // MARK: Helpers

    private func jsonString(_ object: [String: Any], sorted: Bool = false) -> String {
        let options: JSONSerialization.WritingOptions = sorted ? [.sortedKeys] : []
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: options),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }

    private static func scenarioStatus(rootStatus: TraceSpan.Status, failureKind: AgentFailureKind?) -> ScenarioStatus {
        switch rootStatus {
        case .ok:
            return .success
        case .error, .refused:
            guard let failureKind else {
                return rootStatus == .refused ? .refused : .failed
            }
            return ReliabilityRunner.terminalStatus(AgentRecoveryPolicy.plan(for: failureKind).terminal)
        }
    }

    private static func retryCount(from span: TraceSpan) -> Int {
        let explicitKeys = ["retries", "retry.count", "retry_count", "retryCount", "recovery.retries"]
        for key in explicitKeys {
            if let value = span.attributes[key].flatMap(Int.init) {
                return max(0, value)
            }
        }
        if span.attributes["recovery.action"] != nil {
            return 1
        }
        if span.attributes.contains(where: { key, value in
            key.lowercased().contains("retry") && ["1", "true", "yes"].contains(value.lowercased())
        }) {
            return 1
        }
        let name = span.name.lowercased()
        return name.contains("retry") || name.contains("recovery") || name.contains("correction") ? 1 : 0
    }

    private static func confidence(from attributes: [String: String]) -> Double? {
        for key in ["verifier.confidence", "ground.confidence", "confidence"] {
            guard let raw = attributes[key], let value = Double(raw) else { continue }
            return VerifierCalibration.clampConfidence(value)
        }
        return nil
    }

    private static func intAttribute(_ keys: [String], in span: TraceSpan) -> Int {
        for key in keys {
            if let value = span.attributes[key].flatMap(Int.init) { return value }
        }
        return 0
    }

    private static func doubleAttribute(_ keys: [String], in span: TraceSpan) -> Double {
        for key in keys {
            if let value = span.attributes[key].flatMap(Double.init) { return value }
        }
        return 0
    }

    private static func countSpans(namedLike needles: [String], failureKind: AgentFailureKind, in spans: [TraceSpan]) -> Int {
        spans.filter { span in
            guard span.kind != .run else { return false }
            if span.failureKind == failureKind { return true }
            let name = span.name.lowercased()
            return needles.contains { name.contains($0) }
        }.count
    }

}

public enum AgentAuditExportFormat: String, CaseIterable, Sendable, Codable {
    case otelJSON = "otel_json"
    case siemJSONL = "siem_jsonl"
    case csv
    case reliabilityJSONL = "reliability_jsonl"
    case manifestJSON = "manifest_json"
}

public struct AgentAuditExportManifest: Sendable, Equatable, Codable {
    public let schemaVersion: Int
    public let generatedAt: Date
    public let windowStart: Date
    public let windowEnd: Date
    public let auditChainStatus: String
    public let auditChainTrusted: Bool
    public let auditHead: AuditHead?
    public let traceCount: Int
    public let spanCount: Int
    public let supportedFormats: [AgentAuditExportFormat]

    public init(
        schemaVersion: Int = 1,
        generatedAt: Date = Date(),
        windowStart: Date,
        windowEnd: Date,
        auditChainStatus: String,
        auditChainTrusted: Bool,
        auditHead: AuditHead?,
        traceCount: Int,
        spanCount: Int,
        supportedFormats: [AgentAuditExportFormat] = AgentAuditExportFormat.allCases
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.auditChainStatus = auditChainStatus
        self.auditChainTrusted = auditChainTrusted
        self.auditHead = auditHead
        self.traceCount = traceCount
        self.spanCount = spanCount
        self.supportedFormats = supportedFormats
    }
}

public struct AgentAuditExportPackage: Sendable, Equatable {
    public let manifest: AgentAuditExportManifest
    public let traces: [AgentTrace]

    public init(manifest: AgentAuditExportManifest, traces: [AgentTrace]) {
        self.manifest = manifest
        self.traces = traces
    }

    public static func build(
        trustedChronologicalEvents events: [AuditEvent],
        windowStart: Date,
        windowEnd: Date,
        auditChainStatus: AuditChainStatus,
        auditHead: AuditHead?,
        generatedAt: Date = Date()
    ) -> AgentAuditExportPackage {
        let traces = AgentTraceBuilder.fromAuditEvents(events)
        let manifest = AgentAuditExportManifest(
            generatedAt: generatedAt,
            windowStart: windowStart,
            windowEnd: windowEnd,
            auditChainStatus: Self.statusString(auditChainStatus),
            auditChainTrusted: Self.isTrusted(auditChainStatus),
            auditHead: auditHead,
            traceCount: traces.count,
            spanCount: traces.reduce(0) { $0 + $1.spans.count }
        )
        return AgentAuditExportPackage(manifest: manifest, traces: traces)
    }

    public func content(format: AgentAuditExportFormat) -> String {
        switch format {
        case .otelJSON:
            return traces.map { $0.otelJSON() }.joined(separator: "\n")
        case .siemJSONL:
            return traces.map { $0.siemJSONL() }.filter { !$0.isEmpty }.joined(separator: "\n")
        case .csv:
            return Self.combinedCSV(traces)
        case .reliabilityJSONL:
            return ReliabilityReport.fromTraces(traces).jsonl()
        case .manifestJSON:
            return Self.json(manifest)
        }
    }

    public func manifestJSON() -> String {
        Self.json(manifest)
    }

    public static func isTrusted(_ status: AuditChainStatus) -> Bool {
        switch status {
        case .intact, .empty:
            true
        case .broken, .truncated, .unchained:
            false
        }
    }

    public static func statusString(_ status: AuditChainStatus) -> String {
        switch status {
        case .intact(let verified):
            return "intact:\(verified)"
        case .broken(let id):
            return "broken:\(id)"
        case .truncated(let expected, let found):
            return "truncated:\(expected):\(found)"
        case .unchained(let firstID):
            return "unchained:\(firstID)"
        case .empty:
            return "empty"
        }
    }

    private static func combinedCSV(_ traces: [AgentTrace]) -> String {
        guard let first = traces.first else {
            return "trace_id,span_id,parent_span_id,kind,name,start_ms,duration_ms,status,failure_kind,cost_usd"
        }
        let header = first.csv().split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let rows = traces.flatMap { trace in
            trace.csv().split(separator: "\n", omittingEmptySubsequences: false).dropFirst().map(String.init)
        }
        return ([header] + rows).joined(separator: "\n")
    }

    private static func json<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }
}

public struct AgentValueBudgets: Sendable, Equatable, Codable {
    public var monthlyRunLimit: Int?
    public var monthlyActionLimit: Int?
    public var monthlyCostCentsLimit: Int?

    public init(monthlyRunLimit: Int? = nil, monthlyActionLimit: Int? = nil, monthlyCostCentsLimit: Int? = nil) {
        self.monthlyRunLimit = monthlyRunLimit
        self.monthlyActionLimit = monthlyActionLimit
        self.monthlyCostCentsLimit = monthlyCostCentsLimit
    }
}

public struct AgentValueSummary: Sendable, Equatable, Codable {
    public let completedRuns: Int
    public let reclaimedSeconds: Int
    public let modelToolCostUSD: Double
    public let toolActionCount: Int
    public let hourlyRateUSD: Double
    public let estimatedDollarValue: Double
    public let costPerCompletedRunUSD: Double
    public let budgets: AgentValueBudgets
    public let budgetViolations: [String]

    public var budgetExhausted: Bool { !budgetViolations.isEmpty }

    public init(
        completedRuns: Int,
        reclaimedSeconds: Int,
        modelToolCostUSD: Double,
        toolActionCount: Int,
        hourlyRateUSD: Double,
        budgets: AgentValueBudgets = AgentValueBudgets()
    ) {
        self.completedRuns = completedRuns
        self.reclaimedSeconds = reclaimedSeconds
        self.modelToolCostUSD = modelToolCostUSD
        self.toolActionCount = toolActionCount
        self.hourlyRateUSD = hourlyRateUSD
        self.estimatedDollarValue = Double(reclaimedSeconds) / 3600.0 * hourlyRateUSD
        self.costPerCompletedRunUSD = completedRuns > 0 ? modelToolCostUSD / Double(completedRuns) : 0
        self.budgets = budgets
        self.budgetViolations = Self.violations(
            completedRuns: completedRuns,
            toolActionCount: toolActionCount,
            modelToolCostUSD: modelToolCostUSD,
            budgets: budgets
        )
    }

    public static func from(
        agents: [CascadeAgent],
        traces: [AgentTrace],
        hourlyRateUSD: Double,
        budgets: AgentValueBudgets = AgentValueBudgets()
    ) -> AgentValueSummary {
        AgentValueSummary(
            completedRuns: agents.reduce(0) { $0 + $1.runCount },
            reclaimedSeconds: agents.reduce(0) { $0 + ($1.estimatedSecondsPerRun * $1.runCount) },
            modelToolCostUSD: traces.reduce(0) { $0 + $1.totalCostUSD },
            toolActionCount: traces.reduce(0) { $0 + $1.stepToolSpanCount },
            hourlyRateUSD: hourlyRateUSD,
            budgets: budgets
        )
    }

    private static func violations(
        completedRuns: Int,
        toolActionCount: Int,
        modelToolCostUSD: Double,
        budgets: AgentValueBudgets
    ) -> [String] {
        var failures: [String] = []
        if let limit = budgets.monthlyRunLimit, completedRuns >= limit {
            failures.append("monthly run budget \(completedRuns) >= \(limit)")
        }
        if let limit = budgets.monthlyActionLimit, toolActionCount >= limit {
            failures.append("monthly action budget \(toolActionCount) >= \(limit)")
        }
        if let limit = budgets.monthlyCostCentsLimit, Int((modelToolCostUSD * 100.0).rounded(.up)) >= limit {
            failures.append("monthly cost budget exceeded")
        }
        return failures
    }
}

/// Builds local agent traces from the tamper-evident audit log. This is pure and
/// intentionally conservative: only known audit action families become spans, and
/// span attributes keep audit references/metrics instead of raw `detail` text.
public enum AgentTraceBuilder {
    public static func fromAuditEvents(_ events: [AuditEvent], surface: String = "assist") -> [AgentTrace] {
        let ordered = events.enumerated().sorted { left, right in
            if left.element.createdAt != right.element.createdAt {
                return left.element.createdAt < right.element.createdAt
            }
            if left.element.id != right.element.id {
                return left.element.id < right.element.id
            }
            return left.offset < right.offset
        }

        var runs: [RunDraft] = []
        var current: RunDraft?
        var pendingEvents: [SpanEvent] = []

        func finishCurrent() {
            guard let run = current else { return }
            runs.append(run)
            current = nil
        }

        for item in ordered {
            let event = item.element
            if let root = TraceRoot(event: event) {
                finishCurrent()
                if pendingEvents.isEmpty {
                    var run = RunDraft(index: runs.count, root: root, taskEvent: event, eventOrder: item.offset)
                    if root.closesImmediately {
                        runs.append(run)
                    } else {
                        current = run
                    }
                } else {
                    var run = RunDraft(index: runs.count, root: root, taskEvent: event, eventOrder: item.offset)
                    run.events = pendingEvents
                    run.completedEvent = pendingEvents.last { $0.event.action == "agent.run.completed" }?.event
                    runs.append(run)
                    pendingEvents.removeAll()
                }
                continue
            }

            if let spanEvent = SpanEvent(event: event, eventOrder: item.offset) {
                guard var run = current else {
                    pendingEvents.append(spanEvent)
                    continue
                }
                run.events.append(spanEvent)
                if spanEvent.closesRun {
                    if spanEvent.marksCompleted {
                        run.completedEvent = event
                    }
                    current = run
                    finishCurrent()
                } else {
                    current = run
                }
            }
        }
        finishCurrent()
        if current == nil,
           !pendingEvents.isEmpty,
           let synthetic = TraceRoot.synthetic(from: pendingEvents) {
            var run = RunDraft(index: runs.count, root: synthetic.root, taskEvent: synthetic.event, eventOrder: synthetic.eventOrder)
            run.events = pendingEvents
            runs.append(run)
        }

        return runs.map { $0.trace(fallbackSurface: surface) }
    }

    private struct TraceRoot {
        var name: String
        var surface: String?
        var closesImmediately: Bool

        init?(event: AuditEvent) {
            switch event.action {
            case "assist.task":
                self.name = "assist.task"
                self.surface = nil
                self.closesImmediately = false
            case "sandbox.task":
                self.name = "sandbox.task"
                self.surface = "backgroundWeb"
                self.closesImmediately = true
            case "recipe.run.started":
                self.name = "recipe.run.started"
                self.surface = "recipeReplay"
                self.closesImmediately = false
            default:
                return nil
            }
        }

        init(name: String, surface: String) {
            self.name = name
            self.surface = surface
            self.closesImmediately = true
        }

        static func synthetic(from events: [SpanEvent]) -> (root: TraceRoot, event: AuditEvent, eventOrder: Int)? {
            if let terminal = events.last(where: { $0.event.action.hasPrefix("sandbox.") && ($0.failureKind != nil || $0.event.action == "sandbox.done") }) {
                return (TraceRoot(name: "sandbox.task", surface: "backgroundWeb"), terminal.event, terminal.eventOrder)
            }
            if let terminal = events.last(where: { $0.event.action.hasPrefix("recipe.pause.") || $0.event.action == "recipe.run.ended" }) {
                return (TraceRoot(name: "recipe.run.started", surface: "recipeReplay"), terminal.event, terminal.eventOrder)
            }
            return nil
        }
    }

    private struct RunDraft {
        var index: Int
        var root: TraceRoot
        var taskEvent: AuditEvent
        var eventOrder: Int
        var events: [SpanEvent] = []
        var completedEvent: AuditEvent?

        func trace(fallbackSurface: String) -> AgentTrace {
            let runID = spanID(prefix: "run", event: taskEvent, order: eventOrder)
            let start = runStart
            let status = runStatus
            let timing = events.first { $0.event.action == "assist.timing" }?.timing
            let runDuration = timing?.totalMs ?? measuredRunDuration(from: start)
            var spans = [
                TraceSpan(
                    id: runID,
                    parentID: nil,
                    kind: .run,
                    name: root.name,
                    startMs: 0,
                    durationMs: runDuration,
                    status: status.status,
                    failureKind: status.failureKind,
                    attributes: safeAttributes(for: taskEvent, order: eventOrder)
                )
            ]

            for spanEvent in events {
                spans.append(spanEvent.span(runID: runID, runStart: start))
            }

            spans.sort { left, right in
                if left.startMs != right.startMs { return left.startMs < right.startMs }
                return left.id < right.id
            }

            return AgentTrace(
                traceID: "audit-\(taskEvent.id > 0 ? String(taskEvent.id) : String(eventOrder))",
                goal: "\(root.name)#audit-\(taskEvent.id > 0 ? String(taskEvent.id) : String(eventOrder))",
                surface: root.surface ?? fallbackSurface,
                spans: spans
            )
        }

        private var runStatus: (status: TraceSpan.Status, failureKind: AgentFailureKind?) {
            if completedEvent != nil { return (.ok, nil) }
            if isRootedSandboxRun {
                if Self.auditValue("outcome", in: taskEvent.detail) == "completed" { return (.ok, nil) }
                return statusFromLatestFailure()
            }
            if isSyntheticSandboxRun, hasSuccessfulSyntheticSandboxTerminal {
                return (.ok, nil)
            }
            if hasFinishedTiming { return (.ok, nil) }
            if hasSuccessfulTerminal { return (.ok, nil) }
            return statusFromLatestFailure()
        }

        private func statusFromLatestFailure() -> (status: TraceSpan.Status, failureKind: AgentFailureKind?) {
            let failure = latestFailure
            guard let failure else { return (.error, .timeout) }
            return (failure.isDesirableTerminal ? .refused : .error, failure)
        }

        private var latestFailure: AgentFailureKind? {
            events.compactMap { $0.failureKind }.last
        }

        private var isRootedSandboxRun: Bool {
            root.name == "sandbox.task" && taskEvent.action == "sandbox.task"
        }

        private var isSyntheticSandboxRun: Bool {
            root.name == "sandbox.task" && taskEvent.action != "sandbox.task"
        }

        private var runStart: Date {
            ([taskEvent.createdAt] + events.map { $0.event.createdAt }).min() ?? taskEvent.createdAt
        }

        private var hasFinishedTiming: Bool {
            events.contains { event in
                guard event.event.action == "assist.timing" else { return false }
                return event.event.detail
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                    .hasPrefix("finished")
            }
        }

        private var hasSuccessfulTerminal: Bool {
            return events.contains { event in
                switch event.event.action {
                case "recipe.run.ended":
                    return Self.auditValue("status", in: event.event.detail) == "completed"
                default:
                    return false
                }
            }
        }

        private var hasSuccessfulSyntheticSandboxTerminal: Bool {
            guard taskEvent.action == "sandbox.done",
                  Self.auditValue("status", in: taskEvent.detail) == "finished" else {
                return false
            }
            return !events.contains { event in
                event.eventOrder > eventOrder && event.failureKind != nil
            }
        }

        private func measuredRunDuration(from start: Date) -> Int {
            var dates = [taskEvent.createdAt] + events.map { $0.event.createdAt }
            if let completedEvent { dates.append(completedEvent.createdAt) }
            let end = dates.max() ?? start
            return max(1, Self.milliseconds(between: start, and: end))
        }

        private static func milliseconds(between start: Date, and end: Date) -> Int {
            Int((end.timeIntervalSince(start) * 1000.0).rounded())
        }

        private static func auditValue(_ key: String, in detail: String) -> String? {
            let prefix = "\(key)="
            return detail
                .split(separator: " ")
                .first { $0.hasPrefix(prefix) }
                .map { String($0.dropFirst(prefix.count)).lowercased() }
        }
    }

    private struct SpanEvent {
        var event: AuditEvent
        var eventOrder: Int
        var kind: TraceSpan.Kind
        var name: String
        var failureKind: AgentFailureKind?
        var timing: TimingMetrics?
        var closesRun: Bool {
            event.action == "agent.run.completed" || event.action == "recipe.run.ended"
        }
        var marksCompleted: Bool {
            if event.action == "agent.run.completed" { return true }
            if event.action == "recipe.run.ended", Self.auditValue("status", in: event.detail) == "completed" {
                return true
            }
            return false
        }

        init?(event: AuditEvent, eventOrder: Int) {
            if event.action.hasPrefix("harness.") {
                self.kind = .tool
                self.name = String(event.action.dropFirst("harness.".count))
            } else if event.action == "sandbox.harness" {
                self.kind = .tool
                self.name = "sandbox.harness"
            } else if event.action == "sandbox.act" {
                self.kind = .step
                self.name = "sandbox.act"
            } else if event.action == "sandbox.turn" {
                self.kind = .model
                self.name = "sandbox.turn"
            } else if event.action == "sandbox.done" {
                self.kind = .eval
                self.name = "sandbox.done"
            } else if event.action == "sandbox.verify" {
                self.kind = .eval
                self.name = "sandbox.verify"
            } else if event.action.hasPrefix("assist.verify.") {
                self.kind = .eval
                self.name = event.action
            } else if event.action == "assist.validate" {
                self.kind = .eval
                self.name = "assist.validate"
            } else if event.action == "assist.capture" {
                self.kind = .model
                self.name = "assist.capture"
            } else if event.action == "assist.noeffect" || event.action == "assist.stalled" {
                self.kind = .eval
                self.name = event.action
            } else if event.action == "computer.act" || event.action == "computer.zoom" {
                self.kind = .step
                self.name = event.action
            } else if event.action == "recipe.step" {
                self.kind = .step
                self.name = "recipe.step"
            } else if event.action == "recipe.target" {
                self.kind = .retrieval
                self.name = "recipe.target"
            } else if event.action == "recipe.run.ended" {
                self.kind = .eval
                self.name = "recipe.run.ended"
            } else if event.action == "recipe.escalate" {
                self.kind = .eval
                self.name = "recipe.escalate"
            } else if event.action == "agent.recall" {
                self.kind = .retrieval
                self.name = "agent.recall"
            } else if event.action == "agent.ground" || event.action == "agent.ground.miss" {
                self.kind = .retrieval
                self.name = event.action
            } else if event.action == "agent.trajectory_sketch" || event.action.hasPrefix("agent.failure_memory.") {
                self.kind = .retrieval
                self.name = event.action
            } else if event.action == "grounding.verifier" {
                self.kind = .eval
                self.name = "grounding.verifier"
            } else if event.action == "scout.ocr.marks" {
                self.kind = .retrieval
                self.name = "scout.ocr.marks"
            } else if event.action == "assist.timing" {
                self.kind = .model
                self.name = "assist.timing"
            } else if event.action == "agent.run.completed" {
                self.kind = .eval
                self.name = "agent.run.completed"
            } else if let failure = Self.failureKind(for: event) {
                self.kind = .eval
                self.name = event.action
                self.failureKind = failure
                self.event = event
                self.eventOrder = eventOrder
                self.timing = nil
                return
            } else {
                return nil
            }

            self.event = event
            self.eventOrder = eventOrder
            self.failureKind = Self.failureKind(for: event)
            self.timing = event.action == "assist.timing" ? TimingMetrics(detail: event.detail) : nil
        }

        func span(runID: String, runStart: Date) -> TraceSpan {
            let failure = failureKind
            let status: TraceSpan.Status
            if let failure, failure.isDesirableTerminal {
                status = .refused
            } else if failure != nil {
                status = .error
            } else {
                status = .ok
            }
            var attributes = safeAttributes(for: event, order: eventOrder)
            if let timing {
                attributes.merge(timing.attributes) { current, _ in current }
            }
            return TraceSpan(
                id: spanID(prefix: kind.rawValue, event: event, order: eventOrder),
                parentID: runID,
                kind: kind,
                name: name,
                startMs: max(0, Self.milliseconds(between: runStart, and: event.createdAt)),
                durationMs: timing?.modelMs ?? timing?.totalMs ?? 1,
                status: status,
                failureKind: failure,
                attributes: attributes
            )
        }

        private static func milliseconds(between start: Date, and end: Date) -> Int {
            Int((end.timeIntervalSince(start) * 1000.0).rounded())
        }

        private static func failureKind(for event: AuditEvent) -> AgentFailureKind? {
            if event.action == "assist.verify.unavailable" {
                return .verificationUnavailable
            }
            if event.action == "assist.verify.action", auditValue("status", in: event.detail) == "failed" {
                return cascadeFailureKind(auditValue("failureKind", in: event.detail)) ?? .validatorIncomplete
            }
            if event.action == "grounding.verifier",
               let failure = auditValue("failure", in: event.detail),
               failure != "none" {
                return cascadeFailureKind(failure) ?? .groundingMiss
            }
            if event.action == "sandbox.verify", auditValue("status", in: event.detail) == "incomplete" {
                return .validatorIncomplete
            }
            if event.action == "sandbox.done" {
                switch auditValue("status", in: event.detail) {
                case "transport_failure":
                    return .transportFailure
                case "incomplete":
                    return .validatorIncomplete
                default:
                    break
                }
            }
            return AgentFailureKind(auditAction: event.action, detail: event.detail)
        }

        private static func cascadeFailureKind(_ raw: String?) -> AgentFailureKind? {
            switch raw {
            case "wrong_start_state":
                return .wrongStartState
            case "verifier_rejected":
                return .validatorIncomplete
            case "timeout":
                return .timeout
            case "tool_error":
                return .transportFailure
            case "target_not_found":
                return .targetNotFound
            case "grounding_miss":
                return .groundingMiss
            case "permission_denied":
                return .permissionMissing
            case "secure_input":
                return .secureInput
            case "login_required", "modal_blocked":
                return .unexpectedModal
            case "no_effect":
                return .noEffect
            case "stale_frame_batch":
                return .staleFrameBatch
            case "verification_unavailable":
                return .verificationUnavailable
            case "unsafe_action":
                return .unsafeActionRefused
            case "parameter_needs_live_value":
                return .parameterNeedsLiveValue
            case "step_limit":
                return .stepLimit
            case "user_stop":
                return .userStop
            case "artifact_wrong_lane":
                return .artifactWrongLane
            default:
                return nil
            }
        }

        private static func auditValue(_ key: String, in detail: String) -> String? {
            let prefix = "\(key)="
            return detail
                .split(separator: " ")
                .first { $0.hasPrefix(prefix) }
                .map { String($0.dropFirst(prefix.count)).lowercased() }
        }
    }

    private struct TimingMetrics {
        var totalMs: Int?
        var modelMs: Int?
        var actionsMs: Int?
        var turns: Int?

        init(detail: String) {
            self.totalMs = Self.firstInt(in: detail, pattern: #"total\s+(\d+)ms"#)
            self.modelMs = Self.firstInt(in: detail, pattern: #"model\s+(\d+)ms"#)
            self.actionsMs = Self.firstInt(in: detail, pattern: #"actions\s+(\d+)ms"#)
            self.turns = Self.firstInt(in: detail, pattern: #"(\d+)\s+turns"#)
        }

        var attributes: [String: String] {
            var values: [String: String] = [:]
            if let totalMs { values["duration.total_ms"] = String(totalMs) }
            if let modelMs { values["duration.model_ms"] = String(modelMs) }
            if let actionsMs { values["duration.actions_ms"] = String(actionsMs) }
            if let turns { values["agent.turns"] = String(turns) }
            return values
        }

        private static func firstInt(in text: String, pattern: String) -> Int? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: text) else { return nil }
            return Int(text[range])
        }
    }

    private static func safeAttributes(for event: AuditEvent, order: Int) -> [String: String] {
        var attributes = [
            "audit.id": event.id > 0 ? String(event.id) : String(order),
            "audit.actor": safeToken(event.actor),
            "audit.action": safeToken(event.action)
        ]
        if let confidence = confidenceValue(in: event.detail) {
            let key = event.action == "agent.ground" ? "ground.confidence" : "verifier.confidence"
            attributes[key] = String(format: "%.4f", confidence)
            attributes["confidence.bucket"] = VerifierCalibration.bucketLabel(for: confidence)
        }
        if event.action == "grounding.verifier",
           let outcome = auditValue("outcome", in: event.detail) {
            attributes["verifier.outcome"] = safeToken(outcome)
        }
        return attributes
    }

    private static func safeToken(_ value: String) -> String {
        value.filter { character in
            character.isLetter || character.isNumber || character == "." || character == "_" || character == "-"
        }
    }

    private static func confidenceValue(in detail: String) -> Double? {
        for key in ["confidence", "score"] {
            guard let raw = auditValue(key, in: detail),
                  let value = Double(raw) else { continue }
            return VerifierCalibration.clampConfidence(value)
        }
        return nil
    }

    private static func auditValue(_ key: String, in detail: String) -> String? {
        let prefix = "\(key)="
        return detail
            .split(separator: " ")
            .first { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)).lowercased() }
    }

    private static func spanID(prefix: String, event: AuditEvent, order: Int) -> String {
        "\(prefix)-\(event.id > 0 ? String(event.id) : String(order))"
    }
}
