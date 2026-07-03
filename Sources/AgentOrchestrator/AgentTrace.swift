import CascadeMemory
import Foundation
import ProviderKit

public typealias ModelUsage = ProviderKit.ModelUsage
public typealias ModelPricing = ProviderKit.ModelPricing

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

public struct FleetMetricEvent: Sendable, Equatable, Codable {
    public let period: String
    public let tenantMetricKey: String
    public let bucket: String
    public let count: Int
    public let sum: Int
    public let epsilon: Double?
    public let delta: Double?
    public let mechanism: LocalDPMechanism?
    public let minCohort: Int
    public let auditHeadHash: String?

    public init(
        period: String,
        tenantMetricKey: String,
        bucket: String = "all",
        count: Int,
        sum: Int = 0,
        epsilon: Double? = nil,
        delta: Double? = nil,
        mechanism: LocalDPMechanism? = nil,
        minCohort: Int,
        auditHeadHash: String? = nil
    ) {
        self.period = period
        self.tenantMetricKey = tenantMetricKey
        self.bucket = bucket
        self.count = count
        self.sum = sum
        self.epsilon = epsilon
        self.delta = delta
        self.mechanism = mechanism
        self.minCohort = minCohort
        self.auditHeadHash = auditHeadHash
    }
}

/// A complete agent-run trace: the spans plus roll-up metrics and enterprise
/// export formats. Pure value type — assembled from captured spans, exportable to
/// OTel JSON (observability), SIEM JSONL (Splunk/Datadog), or CSV (audit/procurement).
public struct AgentTrace: Sendable, Equatable, Codable {
    public let traceID: String
    public let goal: String
    public let surface: String
    public let startedAt: Date
    public let spans: [TraceSpan]

    public init(traceID: String, goal: String, surface: String, startedAt: Date = Date(), spans: [TraceSpan]) {
        self.traceID = traceID
        self.goal = goal
        self.surface = surface
        self.startedAt = startedAt
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
    public var actionCacheHits: Int {
        spans.filter { $0.attributes["audit.action"] == "action_cache.hit" && $0.attributes["status"] == "hit" }.count
    }
    public var semanticTrajectoryHits: Int {
        spans.filter { $0.attributes["audit.action"] == "action_cache.hit" && $0.attributes["status"] == "semantic" }.count
    }
    public var actionCacheDemotions: Int {
        spans.filter { $0.attributes["audit.action"] == "action_cache.demote" }.count
    }
    public var cacheFalseHitCount: Int { actionCacheDemotions }
    public var cacheSavedModelCalls: Int { actionCacheHits }
    public var cacheBypassReasons: [String] {
        spans.compactMap { span in
            guard span.attributes["audit.action"]?.hasPrefix("action_cache.") == true else { return nil }
            return span.attributes["reason"]
        }
    }
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
        let calibrationOutcome = Self.calibrationOutcome(
            in: spans,
            status: status,
            retries: retryCount
        )
        let noEffectCount = Self.countSpans(namedLike: ["noeffect", "no_effect"], failureKind: .noEffect, in: spans)
        let subgoals = Self.subgoalMetrics(in: spans)
        let redundantStepCount = Self.redundantStepCount(in: spans)
        let wrongStartStateCount = Self.countSpans(namedLike: ["wrongstate", "wrong_start"], failureKind: .wrongStartState, in: spans)
        return ScenarioOutcome(
            id: traceID,
            surface: surface,
            status: status,
            failureKind: failureKind,
            stepsAttempted: stepToolSpanCount,
            retries: retryCount,
            targetTier: spans.compactMap { $0.attributes["target.tier"] ?? $0.attributes["targetTier"] }.last,
            modalCount: Self.countSpans(namedLike: ["modal"], failureKind: .unexpectedModal, in: spans),
            noEffectCount: noEffectCount,
            validatorIncompleteCount: Self.countSpans(namedLike: ["validator", "verify"], failureKind: .validatorIncomplete, in: spans),
            verificationFailureCount: Self.countSpans(namedLike: ["verify", "verification"], failureKind: .verificationUnavailable, in: spans),
            subgoalCount: subgoals.total,
            subgoalsSucceeded: subgoals.succeeded,
            redundantStepCount: redundantStepCount,
            wrongStartStateCount: wrongStartStateCount,
            confidence: confidence,
            actualSuccess: confidence == nil ? nil : status == .success,
            calibrationOutcome: calibrationOutcome
        )
    }

    public func fleetMetrics(
        period: String,
        policy: AnalyticsPrivacyPolicy = AnalyticsPrivacyPolicy(),
        sourceAuditHead: AuditHead? = nil,
        epsilon: Double? = nil,
        delta: Double? = nil,
        mechanism: LocalDPMechanism? = nil
    ) -> [FleetMetricEvent] {
        var events: [FleetMetricEvent] = []
        func append(_ key: String, bucket: String = "all", count: Int, sum: Int = 0) {
            guard policy.allowedCounters.contains(key) else { return }
            let clippedCount = policy.clippingBounds.clipped(count).value
            let clippedSum = policy.clippingBounds.clipped(sum).value
            events.append(FleetMetricEvent(
                period: period,
                tenantMetricKey: key,
                bucket: bucket,
                count: clippedCount,
                sum: clippedSum,
                epsilon: epsilon,
                delta: delta,
                mechanism: mechanism,
                minCohort: policy.minCohort,
                auditHeadHash: sourceAuditHead?.hash
            ))
        }

        append("agent.run.completed.count", count: succeeded ? 1 : 0)
        append("agent.run.failed.count", count: succeeded ? 0 : 1)
        append("model.call.count", count: modelCallCount)
        append("tool.call.count", count: toolCallCount)
        append("trace.duration_ms.count", count: durationMs)
        append("trace.duration_bucket.count", bucket: Self.durationBucket(durationMs), count: 1, sum: durationMs)

        let totalTokens = inputTokens + outputTokens + cacheReadTokens
        append("model.token_bucket.count", bucket: Self.tokenBucket(totalTokens), count: totalTokens > 0 ? 1 : 0, sum: totalTokens)

        for (bucket, count) in Dictionary(grouping: spans.filter { $0.kind == .tool }, by: Self.toolClass).mapValues(\.count) {
            append("tool.class.count", bucket: bucket, count: count)
        }
        for (bucket, count) in Dictionary(grouping: failureKinds.map(\.rawValue), by: { $0 }).mapValues(\.count) {
            append("failure.kind.count", bucket: bucket, count: count)
        }
        for (bucket, count) in Dictionary(grouping: spans.compactMap(Self.permissionState), by: { $0 }).mapValues(\.count) {
            append("permission.state.count", bucket: bucket, count: count)
        }

        return events.sorted {
            if $0.tenantMetricKey != $1.tenantMetricKey {
                return $0.tenantMetricKey < $1.tenantMetricKey
            }
            return $0.bucket < $1.bucket
        }
    }

    public func fleetAnalyticsExport(
        period: String,
        policy: AnalyticsPrivacyPolicy = AnalyticsPrivacyPolicy(),
        sourceAuditHead: AuditHead? = nil,
        appBuild: String? = nil,
        tenantIDHash: String? = nil
    ) -> FleetAnalyticsExport {
        let candidates = fleetMetrics(period: period, policy: policy, sourceAuditHead: sourceAuditHead)
            .reduce(into: [String: FleetMetricInput]()) { result, event in
                result[event.tenantMetricKey] = .counter((result[event.tenantMetricKey]?.counterValue ?? 0) + event.count)
            }
        return policy.export(
            candidates: candidates,
            sourceAuditHead: sourceAuditHead,
            appBuild: appBuild,
            tenantIDHash: tenantIDHash,
            periodStart: period,
            periodEnd: period
        )
    }

    // MARK: Exports

    /// Collector-ready OTLP JSON envelope. Content-bearing GenAI attributes are
    /// intentionally omitted; Cascade exports ids, hashes, counts, timings, and cost.
    public func otelJSON() -> String {
        let otlpTraceID = Self.otelTraceID(traceID)
        let objects: [[String: Any]] = spans.map { span in
            let startNano = Self.unixNano(startedAt.addingTimeInterval(Double(span.startMs) / 1000.0))
            let endNano = Self.unixNano(startedAt.addingTimeInterval(Double(span.startMs + span.durationMs) / 1000.0))
            var object: [String: Any] = [
                "traceId": otlpTraceID,
                "spanId": Self.otelSpanID(span.id),
                "name": span.name,
                "kind": "SPAN_KIND_INTERNAL",
                "startTimeUnixNano": String(startNano),
                "endTimeUnixNano": String(endNano),
                "status": ["code": span.status == .ok ? "STATUS_CODE_OK" : "STATUS_CODE_ERROR"],
                "attributes": Self.otelAttributes(traceID: traceID, surface: surface, span: span),
                "events": Self.otelEvents(for: span),
            ]
            if let parent = span.parentID {
                object["parentSpanId"] = Self.otelSpanID(parent)
            }
            return object
        }
        let root: [String: Any] = [
            "trace_id": traceID,
            "resourceSpans": [[
                "resource": ["attributes": [
                    ["key": "service.name", "value": ["stringValue": "com.humain.cascade"]],
                    ["key": "service.namespace", "value": ["stringValue": "Cascade"]],
                ]],
                "scopeSpans": [[
                    "scope": ["name": "Cascade.AgentTrace", "version": "1"],
                    "spans": objects,
                ]],
            ]],
        ]
        return jsonString(root)
    }

    /// SIEM line-delimited JSON — one flat object per span per line.
    public func siemJSONL() -> String {
        spans.map { span in
            let timestamp = Self.iso8601(startedAt.addingTimeInterval(Double(span.startMs) / 1000.0))
            let usage = span.usage
            var object: [String: Any] = [
                "timestamp": timestamp,
                "product": "Cascade",
                "trace_id": traceID,
                "span_id": span.id,
                "surface": surface,
                "actor": span.attributes["actor"] ?? "agent",
                "span_kind": span.kind.rawValue,
                "operation": Self.genAIOperation(for: span),
                "name": span.name,
                "duration_ms": span.durationMs,
                "status": span.status.rawValue,
                "input_tokens": usage?.inputTokens ?? 0,
                "cache_read_input_tokens": usage?.cacheReadTokens ?? 0,
                "cache_creation_input_tokens": usage?.cacheWriteTokens ?? 0,
                "output_tokens": usage?.outputTokens ?? 0,
                "reasoning_output_tokens": usage?.reasoningTokens ?? 0,
                "cost_microusd": Self.costMicrousd(for: span),
                "redaction_policy": "content-ref-only",
            ]
            if let parent = span.parentID { object["parent_span_id"] = parent }
            if let auditID = span.attributes["audit.id"] ?? span.attributes["audit_event_id"] {
                object["audit_event_id"] = auditID
            }
            if let contextID = span.attributes["recorded_context_id"] ?? span.attributes["moment_id"] {
                object["recorded_context_id"] = contextID
            }
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

    public func csvBundleFiles() -> [String: String] {
        [
            "traces.csv": traceCSV(),
            "spans.csv": spansCSV(),
            "costs.csv": costsCSV(),
            "evals.csv": evalsCSV(),
        ]
    }

    public func exportManifestJSON(
        policy: AgentTraceExportPolicy = .default,
        auditChainStatus: String = "not_checked",
        auditChainTrusted: Bool = false,
        priceCardVersion: String = ModelPriceCard.defaultVersion
    ) -> String {
        let manifest = TraceRedactionManifest(
            policy: policy,
            generatedAt: Date(),
            traceCount: 1,
            spanCount: spans.count,
            auditChainStatus: auditChainStatus,
            auditChainTrusted: auditChainTrusted,
            priceCardVersion: priceCardVersion
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(manifest),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }

    // MARK: Helpers

    private func jsonString(_ object: [String: Any], sorted: Bool = false) -> String {
        let options: JSONSerialization.WritingOptions = sorted ? [.sortedKeys] : []
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: options),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }

    private static func durationBucket(_ durationMs: Int) -> String {
        switch max(0, durationMs) {
        case 0..<1_000: "lt_1s"
        case 1_000..<10_000: "1s_10s"
        case 10_000..<60_000: "10s_60s"
        case 60_000..<300_000: "1m_5m"
        default: "gte_5m"
        }
    }

    private static func tokenBucket(_ tokens: Int) -> String {
        switch max(0, tokens) {
        case 0: "zero"
        case 1..<1_000: "1_999"
        case 1_000..<10_000: "1k_10k"
        case 10_000..<100_000: "10k_100k"
        default: "gte_100k"
        }
    }

    private static func toolClass(_ span: TraceSpan) -> String {
        let explicit = (span.attributes["tool.class"] ?? span.attributes["tool.type"] ?? "").lowercased()
        let candidate = explicit.isEmpty ? span.name.lowercased() : explicit
        if candidate.contains("browser") || candidate.contains("web") || candidate.contains("dom") {
            return "browser"
        }
        if candidate.contains("file") || candidate.contains("read") || candidate.contains("write") {
            return "file"
        }
        if candidate.contains("click") || candidate.contains("key") || candidate.contains("type") || candidate.contains("scroll") {
            return "input"
        }
        if candidate.contains("shell") || candidate.contains("command") || candidate.contains("process") {
            return "system"
        }
        return "other"
    }

    private static func permissionState(_ span: TraceSpan) -> String? {
        let raw = span.attributes["permission.state"] ?? span.attributes["permissionState"]
        guard let value = raw?.lowercased(), !value.isEmpty else { return nil }
        if value.contains("granted") || value == "ok" || value == "allowed" {
            return "granted"
        }
        if value.contains("denied") || value.contains("missing") || value.contains("blocked") {
            return "blocked"
        }
        return "unknown"
    }

    private func traceCSV() -> String {
        let endedAt = startedAt.addingTimeInterval(Double(durationMs) / 1000.0)
        let appName = spans.compactMap { span in
            span.attributes["app"] ?? span.attributes["app_name"]
        }.first ?? ""
        let modelDurationMs = spans
            .filter { $0.kind == .model }
            .reduce(0) { partial, span in partial + span.durationMs }
        let toolDurationMs = spans
            .filter { $0.kind == .tool }
            .reduce(0) { partial, span in partial + span.durationMs }
        let costMicrousd = spans.reduce(Int64(0)) { partial, span in
            partial + Self.costMicrousd(for: span)
        }
        let fields = [
            traceID,
            Self.iso8601(startedAt),
            Self.iso8601(endedAt),
            surface,
            appName,
            succeeded ? "ok" : "failed",
            failureKinds.first?.rawValue ?? "",
            String(durationMs),
            String(modelDurationMs),
            String(toolDurationMs),
            String(inputTokens),
            String(cacheReadTokens),
            String(outputTokens),
            String(costMicrousd),
        ]
        return (["trace_id,started_at,ended_at,surface,app,status,failure_kind,duration_ms,model_duration_ms,tool_duration_ms,input_tokens,cache_read_input_tokens,output_tokens,cost_microusd"]
            + [fields.map(AgentTraceCSVFieldEscaper.escape).joined(separator: ",")]).joined(separator: "\n")
    }

    private func spansCSV() -> String {
        var rows = ["trace_id,span_id,parent_span_id,kind,name,status,failure_kind,duration_ms,model_provider,model_name,tool_name,audit_event_id"]
        for span in spans {
            let fields = [
                traceID,
                span.id,
                span.parentID ?? "",
                span.kind.rawValue,
                span.name,
                span.status.rawValue,
                span.failureKind?.rawValue ?? "",
                String(span.durationMs),
                span.usage?.provider ?? span.attributes["model.provider"] ?? "",
                span.usage?.model ?? span.attributes["model"] ?? "",
                span.attributes["tool.name"] ?? (span.kind == .tool ? span.name : ""),
                span.attributes["audit.id"] ?? "",
            ]
            rows.append(fields.map(AgentTraceCSVFieldEscaper.escape).joined(separator: ","))
        }
        return rows.joined(separator: "\n")
    }

    private func costsCSV() -> String {
        var rows = ["trace_id,span_id,provider,model,response_id,price_card_version,input_tokens,cache_read_input_tokens,cache_creation_input_tokens,output_tokens,reasoning_output_tokens,cost_microusd"]
        for span in spans where span.usage != nil || span.costUSD != nil {
            let usage = span.usage
            let priceCardVersion: String = usage?.priceCardVersion ?? ModelPriceCard.defaultVersion
            let costMicrousd: String = String(Self.costMicrousd(for: span))
            var fields: [String] = [traceID, span.id]
            fields.append(usage?.provider ?? "")
            fields.append(usage?.model ?? "")
            fields.append(usage?.responseID ?? "")
            fields.append(priceCardVersion)
            fields.append(String(usage?.inputTokens ?? 0))
            fields.append(String(usage?.cacheReadTokens ?? 0))
            fields.append(String(usage?.cacheWriteTokens ?? 0))
            fields.append(String(usage?.outputTokens ?? 0))
            fields.append(String(usage?.reasoningTokens ?? 0))
            fields.append(costMicrousd)
            rows.append(fields.map(AgentTraceCSVFieldEscaper.escape).joined(separator: ","))
        }
        return rows.joined(separator: "\n")
    }

    private func evalsCSV() -> String {
        var rows = ["trace_id,span_id,evaluator_kind,evaluator_name,score_value,score_label,confidence,failure_kind"]
        for span in spans where span.kind == .eval || span.attributes["eval.kind"] != nil || span.name.contains("verify") {
            let fields = [
                traceID,
                span.id,
                span.attributes["eval.kind"] ?? "verifier",
                span.attributes["eval.name"] ?? span.name,
                span.attributes["eval.score"] ?? "",
                span.attributes["eval.label"] ?? (span.status == .ok ? "pass" : "fail"),
                span.attributes["verifier.confidence"] ?? span.attributes["confidence"] ?? "",
                span.failureKind?.rawValue ?? "",
            ]
            rows.append(fields.map(AgentTraceCSVFieldEscaper.escape).joined(separator: ","))
        }
        return rows.joined(separator: "\n")
    }

    private static func otelAttributes(traceID: String, surface: String, span: TraceSpan) -> [[String: Any]] {
        var attrs = span.attributes
        attrs["cascade.trace.id"] = traceID
        attrs["cascade.span.id"] = span.id
        attrs["cascade.trace.surface"] = surface
        attrs["cascade.redaction.policy"] = "content-ref-only"
        attrs["gen_ai.operation.name"] = genAIOperation(for: span)
        if let failure = span.failureKind {
            attrs["error.type"] = failure.rawValue
        }
        if let usage = span.usage {
            if !usage.provider.isEmpty { attrs["gen_ai.provider.name"] = usage.provider }
            if !usage.model.isEmpty { attrs["gen_ai.request.model"] = usage.model }
            if !usage.model.isEmpty { attrs["gen_ai.response.model"] = usage.model }
            if let responseID = usage.responseID { attrs["gen_ai.response.id"] = responseID }
            attrs["gen_ai.usage.input_tokens"] = String(usage.inputTokens)
            attrs["gen_ai.usage.output_tokens"] = String(usage.outputTokens)
            attrs["gen_ai.usage.cache_read_input_tokens"] = String(usage.cacheReadTokens)
            attrs["gen_ai.usage.cache_creation_input_tokens"] = String(usage.cacheWriteTokens)
            attrs["gen_ai.usage.reasoning_output_tokens"] = String(usage.reasoningTokens)
            attrs["cascade.cost_microusd"] = String(costMicrousd(for: span))
            attrs["cascade.price_card.version"] = usage.priceCardVersion
        } else if let cost = span.costUSD {
            attrs["cascade.cost_microusd"] = String(Int64((cost * 1_000_000).rounded()))
        }
        if span.kind == .tool {
            attrs["gen_ai.tool.name"] = attrs["tool.name"] ?? span.name
            attrs["gen_ai.tool.type"] = attrs["tool.type"] ?? "local"
        }
        if span.kind == .eval {
            attrs["gen_ai.evaluation.result"] = span.status == .ok ? "pass" : "fail"
        }
        let denied = [
            "gen_ai.input.messages", "gen_ai.output.messages", "gen_ai.system_instructions",
            "gen_ai.tool.call.arguments", "gen_ai.tool.call.result", "prompt", "response",
            "ocr_text", "image_path", "metadata_json", "detail",
        ]
        for key in denied { attrs.removeValue(forKey: key) }
        return attrs.sorted { $0.key < $1.key }.map { key, value in
            ["key": key, "value": ["stringValue": value]]
        }
    }

    private static func otelEvents(for span: TraceSpan) -> [[String: Any]] {
        guard span.kind == .eval || span.failureKind != nil else { return [] }
        let name = span.kind == .eval ? "gen_ai.evaluation.result" : "exception"
        return [[
            "name": name,
            "timeUnixNano": String(unixNano(Date())),
            "attributes": span.failureKind.map { failure in
                [["key": "error.type", "value": ["stringValue": failure.rawValue]]]
            } ?? [],
        ]]
    }

    private static func genAIOperation(for span: TraceSpan) -> String {
        if let explicit = span.attributes["gen_ai.operation.name"] { return explicit }
        switch span.kind {
        case .run: return surfaceRunOperation(span.name)
        case .model: return "chat"
        case .tool: return "execute_tool"
        case .retrieval: return "retrieval"
        case .eval: return "evaluation"
        case .step: return "invoke_workflow"
        }
    }

    private static func surfaceRunOperation(_ name: String) -> String {
        name.contains("recipe") ? "invoke_workflow" : "invoke_agent"
    }

    private static func costMicrousd(for span: TraceSpan) -> Int64 {
        if let usage = span.usage, usage.costMicrousd > 0 { return usage.costMicrousd }
        return span.costUSD.map { Int64(($0 * 1_000_000).rounded()) } ?? 0
    }

    private static func otelTraceID(_ value: String) -> String {
        hexDigest(value, length: 32)
    }

    private static func otelSpanID(_ value: String) -> String {
        hexDigest(value, length: 16)
    }

    private static func hexDigest(_ value: String, length: Int) -> String {
        let bytes = Array(value.utf8)
        var state: UInt64 = 0xcbf29ce484222325
        for byte in bytes {
            state ^= UInt64(byte)
            state &*= 0x100000001b3
        }
        var output = ""
        var cursor = state
        while output.count < length {
            output += String(format: "%016llx", cursor)
            cursor ^= cursor << 13
            cursor ^= cursor >> 7
            cursor ^= cursor << 17
        }
        return String(output.prefix(length))
    }

    private static func unixNano(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000_000_000).rounded())
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
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

    private static func calibrationOutcome(
        in spans: [TraceSpan],
        status: ScenarioStatus,
        retries: Int
    ) -> VerifierCalibrationOutcome? {
        let verifierSpans = spans.filter { span in
            span.attributes["verifier.verdict"] != nil
                || span.attributes["verifier.outcome"] != nil
                || span.name == "grounding.verifier"
                || span.name == "assist.verify.action"
        }
        guard !verifierSpans.isEmpty else { return nil }
        if verifierSpans.contains(where: { span in
            let verdict = span.attributes["verifier.verdict"] ?? span.attributes["verdict"]
            let outcome = span.attributes["verifier.outcome"] ?? span.attributes["outcome"]
            return verdict == "abstain" || verdict == "reject" || outcome == "abstained" || outcome == "rejected"
        }) {
            return status == .paused ? .paused : .abstained
        }
        if status == .paused { return .paused }
        let accepted = verifierSpans.contains { span in
            let verdict = span.attributes["verifier.verdict"] ?? span.attributes["verdict"]
            let outcome = span.attributes["verifier.outcome"] ?? span.attributes["outcome"]
            return verdict == "accept" || outcome == "selected"
        }
        guard accepted else { return nil }
        return status == .success
            ? (retries > 0 ? .regrounded : .acceptedCorrect)
            : .falseAccept
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
	            guard needles.contains(where: { name.contains($0) }) else { return false }
	            switch failureKind {
	            case .validatorIncomplete, .verificationUnavailable:
	                let status = span.attributes["status"]?.lowercased()
	                return span.status != .ok || status == "failed" || status == "incomplete"
	            default:
	                return true
	            }
	        }.count
	    }

    private static func subgoalMetrics(in spans: [TraceSpan]) -> (total: Int, succeeded: Int) {
        let starts = spans.filter { $0.name == "assist.subgoal.start" }.count
        let verifies = spans.filter { $0.name == "assist.subgoal.verify" && $0.status == .ok && $0.failureKind == nil }.count
        let failures = spans.filter { $0.name == "assist.subgoal.fail" || ($0.name == "assist.subgoal.verify" && $0.failureKind != nil) }.count
        let total = max(starts, verifies + failures)
        return (total, min(verifies, total))
    }

    private static func redundantStepCount(in spans: [TraceSpan]) -> Int {
        spans.filter { span in
            guard span.kind != .run else { return false }
            let name = span.name.lowercased()
            if name.contains("redundant") || name.contains("repeated") { return true }
            if name.contains("noeffect") || name.contains("no_effect") || name.contains("stalled") { return true }
            if let status = span.attributes["status"]?.lowercased(),
               status.contains("unchanged") || status.contains("stopping") {
                return true
            }
            return false
        }.count
    }

}

public enum AgentAuditExportFormat: String, CaseIterable, Sendable, Codable {
    case otelJSON = "otel_json"
    case siemJSONL = "siem_jsonl"
    case csv
    case reliabilityJSONL = "reliability_jsonl"
    case manifestJSON = "manifest_json"
    case diagnosticBundleMetadata = "diagnostic_bundle_metadata"
}

public struct AgentTraceExportPolicy: Sendable, Equatable, Codable {
    public let name: String
    public let includeScreenshots: Bool
    public let includePrompts: Bool
    public let includeToolPayloads: Bool
    public let includeOCR: Bool
    public let includeMetadataJSON: Bool
    public let omittedFields: [String]

    public init(
        name: String = "content-ref-only",
        includeScreenshots: Bool = false,
        includePrompts: Bool = false,
        includeToolPayloads: Bool = false,
        includeOCR: Bool = false,
        includeMetadataJSON: Bool = false,
        omittedFields: [String] = [
            "screenshots", "prompts", "tool_payloads", "ocr_text", "image_path",
            "metadata_json", "gen_ai.input.messages", "gen_ai.output.messages",
        ]
    ) {
        self.name = name
        self.includeScreenshots = includeScreenshots
        self.includePrompts = includePrompts
        self.includeToolPayloads = includeToolPayloads
        self.includeOCR = includeOCR
        self.includeMetadataJSON = includeMetadataJSON
        self.omittedFields = omittedFields
    }

    public static let `default` = AgentTraceExportPolicy()
}

public struct TraceRedactionManifest: Sendable, Equatable, Codable {
    public let schemaVersion: Int
    public let policy: AgentTraceExportPolicy
    public let generatedAt: Date
    public let appVersion: String
    public let traceCount: Int
    public let spanCount: Int
    public let redactedFieldCounts: [String: Int]
    public let auditChainStatus: String
    public let auditChainTrusted: Bool
    public let priceCardVersion: String

    public init(
        schemaVersion: Int = 1,
        policy: AgentTraceExportPolicy = .default,
        generatedAt: Date = Date(),
        appVersion: String = "CascadeNative",
        traceCount: Int,
        spanCount: Int,
        redactedFieldCounts: [String: Int] = [:],
        auditChainStatus: String,
        auditChainTrusted: Bool,
        priceCardVersion: String = ModelPriceCard.defaultVersion
    ) {
        self.schemaVersion = schemaVersion
        self.policy = policy
        self.generatedAt = generatedAt
        self.appVersion = appVersion
        self.traceCount = traceCount
        self.spanCount = spanCount
        self.redactedFieldCounts = redactedFieldCounts
        self.auditChainStatus = auditChainStatus
        self.auditChainTrusted = auditChainTrusted
        self.priceCardVersion = priceCardVersion
    }
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
    public let redactionManifest: TraceRedactionManifest

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
        supportedFormats: [AgentAuditExportFormat] = AgentAuditExportFormat.allCases,
        redactionManifest: TraceRedactionManifest? = nil
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
        self.redactionManifest = redactionManifest ?? TraceRedactionManifest(
            generatedAt: generatedAt,
            traceCount: traceCount,
            spanCount: spanCount,
            auditChainStatus: auditChainStatus,
            auditChainTrusted: auditChainTrusted
        )
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
        case .diagnosticBundleMetadata:
            return Self.json(manifest.redactionManifest)
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
            return "traces.csv\ntrace_id,started_at,ended_at,surface,app,status,failure_kind,duration_ms,model_duration_ms,tool_duration_ms,input_tokens,cache_read_input_tokens,output_tokens,cost_microusd"
        }
        let bundle = first.csvBundleFiles().keys.sorted().map { name -> String in
            let content = traces.map { $0.csvBundleFiles()[name] ?? "" }
            let header = content.first?.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let rows = content.flatMap { $0.split(separator: "\n", omittingEmptySubsequences: false).dropFirst().map(String.init) }
            return "# \(name)\n" + ([header] + rows).joined(separator: "\n")
        }
        return bundle.joined(separator: "\n\n")
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
                    let run = RunDraft(index: runs.count, root: root, taskEvent: event, eventOrder: item.offset)
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
                startedAt: start,
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
            } else if event.action == "assist.plan" {
                self.kind = .model
                self.name = "assist.plan"
            } else if event.action == "assist.subgoal.start" {
                self.kind = .step
                self.name = "assist.subgoal.start"
            } else if event.action == "assist.subgoal.verify"
                || event.action == "assist.subgoal.fail"
                || event.action == "assist.subgoal.replan" {
                self.kind = .eval
                self.name = event.action
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
            } else if event.action.hasPrefix("action_cache.") {
                self.kind = event.action == "action_cache.hit" ? .retrieval : .eval
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
                if auditValue("postEffect", in: event.detail) == "mismatch" {
                    return .effectMismatch
                }
                return cascadeFailureKind(auditValue("failureKind", in: event.detail)) ?? .preconditionFailed
            }
            if event.action == "grounding.verifier",
               let verdict = auditValue("verdict", in: event.detail),
               verdict == "reject" || verdict == "abstain" {
                if auditValue("failure", in: event.detail) == "ambiguous"
                    || auditValue("outcome", in: event.detail) == "ambiguous" {
                    return .verifierDisagreement
                }
                return .lowConfidenceGrounding
            }
            if event.action == "sandbox.verify", auditValue("status", in: event.detail) == "incomplete" {
                return .validatorIncomplete
            }
            if event.action == "assist.subgoal.verify" {
                switch auditValue("status", in: event.detail) {
                case "failed", "incomplete":
                    return cascadeFailureKind(auditValue("failureKind", in: event.detail))
                        ?? cascadeFailureKind(auditValue("failure", in: event.detail))
                        ?? .validatorIncomplete
                default:
                    return nil
                }
            }
            if event.action == "assist.subgoal.fail" {
                return cascadeFailureKind(auditValue("failureKind", in: event.detail))
                    ?? cascadeFailureKind(auditValue("failure", in: event.detail))
                    ?? .validatorIncomplete
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
            let normalized = raw?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "-", with: "_")
            switch normalized {
            case "wrongstartstate", "wrong_start_state":
                return .wrongStartState
            case "validatorincomplete", "validator_incomplete":
                return .validatorIncomplete
            case "unsafeactionrefused", "unsafe_action_refused":
                return .unsafeActionRefused
            case "noeffect", "no_effect":
                return .noEffect
            case "groundingmiss", "grounding_miss":
                return .groundingMiss
            case "lowconfidencegrounding", "low_confidence_grounding":
                return .lowConfidenceGrounding
            case "preconditionfailed", "precondition_failed":
                return .preconditionFailed
            case "effectmismatch", "effect_mismatch":
                return .effectMismatch
            case "verifierdisagreement", "verifier_disagreement":
                return .verifierDisagreement
            case "parameterneedslivevalue", "parameter_needs_live_value":
                return .parameterNeedsLiveValue
            case "artifactwronglane", "artifact_wrong_lane":
                return .artifactWrongLane
            default:
                break
            }
            switch normalized {
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
            case "low_confidence_grounding":
                return .lowConfidenceGrounding
            case "precondition_failed":
                return .preconditionFailed
            case "effect_mismatch":
                return .effectMismatch
            case "verifier_disagreement":
                return .verifierDisagreement
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
        if let verdict = auditValue("verdict", in: event.detail) {
            attributes["verifier.verdict"] = safeToken(verdict)
        }
        if let failure = auditValue("failure", in: event.detail) {
            attributes["verifier.failure"] = safeToken(failure)
        }
        if let selectedSource = auditValue("selectedSource", in: event.detail) ?? auditValue("source", in: event.detail) {
            attributes["selected.source"] = safeToken(selectedSource)
        }
        if let candidateHash = auditValue("selectedCandidateHash", in: event.detail) ?? auditValue("candidateHash", in: event.detail) {
            attributes["selected.candidate_hash"] = safeToken(candidateHash)
        }
        if let candidates = auditValue("candidates", in: event.detail) {
            attributes["candidate.count"] = safeToken(candidates)
        }
        if let postEffect = auditValue("postEffect", in: event.detail) {
            attributes["post_effect"] = safeToken(postEffect)
        }
        if let expectedEffect = auditValue("expectedEffect", in: event.detail) {
            attributes["expected_effect"] = safeToken(expectedEffect)
        }
        for key in ["status", "outcome", "failure", "failureKind", "recoveryAction"] {
            if let value = auditValue(key, in: event.detail) {
                attributes[key] = safeToken(value)
            }
        }
        if event.action.hasPrefix("action_cache.") {
            for key in ["reason", "rowHash", "goalHash", "appHash", "bundleHash", "windowHash", "targetHash", "kind", "successes", "failures", "candidates"] {
                if let value = auditValue(key, in: event.detail) {
                    attributes["action_cache.\(key)"] = safeToken(value)
                    if key == "reason" || key == "kind" || key == "candidates" {
                        attributes[key] = safeToken(value)
                    }
                }
            }
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

private extension FleetMetricInput {
    var counterValue: Int? {
        guard case .counter(let value) = self else { return nil }
        return value
    }
}
