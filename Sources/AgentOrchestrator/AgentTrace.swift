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
    public var succeeded: Bool { !spans.contains { $0.status == .error } }

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
            rows.append(fields.map(csvEscape).joined(separator: ","))
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

    private func csvEscape(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"") || field.contains("\n") else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
