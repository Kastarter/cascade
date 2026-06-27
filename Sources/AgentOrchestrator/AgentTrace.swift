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
    public var modelCallCount: Int { spans.filter { $0.kind == .model }.count }
    public var toolCallCount: Int { spans.filter { $0.kind == .tool }.count }
    public var durationMs: Int { spans.map { $0.startMs + $0.durationMs }.max() ?? 0 }
    public var failureKinds: [AgentFailureKind] { spans.compactMap(\.failureKind) }
    public var succeeded: Bool { spans.allSatisfy { $0.status == .ok } }

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
            if event.action == "assist.task" {
                finishCurrent()
                if pendingEvents.isEmpty {
                    current = RunDraft(index: runs.count, taskEvent: event, eventOrder: item.offset)
                } else {
                    var run = RunDraft(index: runs.count, taskEvent: event, eventOrder: item.offset)
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
                if event.action == "agent.run.completed" {
                    run.completedEvent = event
                    current = run
                    finishCurrent()
                } else {
                    current = run
                }
            }
        }
        finishCurrent()

        return runs.map { $0.trace(surface: surface) }
    }

    private struct RunDraft {
        var index: Int
        var taskEvent: AuditEvent
        var eventOrder: Int
        var events: [SpanEvent] = []
        var completedEvent: AuditEvent?

        func trace(surface: String) -> AgentTrace {
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
                    name: "assist.task",
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
                goal: "assist.task#audit-\(taskEvent.id > 0 ? String(taskEvent.id) : String(eventOrder))",
                surface: surface,
                spans: spans
            )
        }

        private var runStatus: (status: TraceSpan.Status, failureKind: AgentFailureKind?) {
            if completedEvent != nil { return (.ok, nil) }
            if hasFinishedTiming { return (.ok, nil) }
            let failure = events.compactMap { $0.failureKind }.last
            guard let failure else { return (.error, .timeout) }
            return (failure.isDesirableTerminal ? .refused : .error, failure)
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

        private func measuredRunDuration(from start: Date) -> Int {
            var dates = [taskEvent.createdAt] + events.map { $0.event.createdAt }
            if let completedEvent { dates.append(completedEvent.createdAt) }
            let end = dates.max() ?? start
            return max(1, Self.milliseconds(between: start, and: end))
        }

        private static func milliseconds(between start: Date, and end: Date) -> Int {
            Int((end.timeIntervalSince(start) * 1000.0).rounded())
        }
    }

    private struct SpanEvent {
        var event: AuditEvent
        var eventOrder: Int
        var kind: TraceSpan.Kind
        var name: String
        var failureKind: AgentFailureKind?
        var timing: TimingMetrics?

        init?(event: AuditEvent, eventOrder: Int) {
            if event.action.hasPrefix("harness.") {
                self.kind = .tool
                self.name = String(event.action.dropFirst("harness.".count))
            } else if event.action == "agent.recall" {
                self.kind = .retrieval
                self.name = "agent.recall"
            } else if event.action == "agent.ground" {
                self.kind = .retrieval
                self.name = "agent.ground"
            } else if event.action == "assist.timing" {
                self.kind = .model
                self.name = "assist.timing"
            } else if event.action == "agent.run.completed" {
                self.kind = .eval
                self.name = "agent.run.completed"
            } else if let failure = AgentFailureKind(auditAction: event.action, detail: event.detail) {
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
            self.failureKind = AgentFailureKind(auditAction: event.action, detail: event.detail)
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
        [
            "audit.id": event.id > 0 ? String(event.id) : String(order),
            "audit.actor": safeToken(event.actor),
            "audit.action": safeToken(event.action)
        ]
    }

    private static func safeToken(_ value: String) -> String {
        value.filter { character in
            character.isLetter || character.isNumber || character == "." || character == "_" || character == "-"
        }
    }

    private static func spanID(prefix: String, event: AuditEvent, order: Int) -> String {
        "\(prefix)-\(event.id > 0 ? String(event.id) : String(order))"
    }
}
