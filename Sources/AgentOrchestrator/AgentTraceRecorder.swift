import CascadeMemory
import Foundation
import ProviderKit

public struct TraceContext: Sendable, Equatable, Codable {
    public let traceID: String
    public let rootAuditEventID: Int64?
    public let startedAt: Date
    public let surface: String
    public let actor: String
    public let title: String

    public init(
        traceID: String,
        rootAuditEventID: Int64? = nil,
        startedAt: Date = Date(),
        surface: String,
        actor: String = "agent",
        title: String
    ) {
        self.traceID = traceID
        self.rootAuditEventID = rootAuditEventID
        self.startedAt = startedAt
        self.surface = surface
        self.actor = actor
        self.title = title
    }
}

public struct SpanContext: Sendable, Equatable, Codable {
    public let traceID: String
    public let spanID: String
    public let parentSpanID: String?
    public let auditEventID: Int64?
    public let startedAt: Date
    public let kind: AgentStoredSpanKind
    public let name: String
    public let attributes: [String: String]

    public init(
        traceID: String,
        spanID: String,
        parentSpanID: String? = nil,
        auditEventID: Int64? = nil,
        startedAt: Date = Date(),
        kind: AgentStoredSpanKind,
        name: String,
        attributes: [String: String] = [:]
    ) {
        self.traceID = traceID
        self.spanID = spanID
        self.parentSpanID = parentSpanID
        self.auditEventID = auditEventID
        self.startedAt = startedAt
        self.kind = kind
        self.name = name
        self.attributes = attributes
    }
}

public struct TraceStart: Sendable, Equatable, Codable {
    public let surface: String
    public let actor: String
    public let title: String
    public let goalHash: String?
    public let appName: String?
    public let bundleIdentifier: String?
    public let metadata: [String: String]

    public init(
        surface: String,
        actor: String = "agent",
        title: String,
        goalHash: String? = nil,
        appName: String? = nil,
        bundleIdentifier: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.surface = surface
        self.actor = actor
        self.title = title
        self.goalHash = goalHash
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.metadata = metadata
    }
}

public struct SpanStart: Sendable, Equatable, Codable {
    public let kind: AgentStoredSpanKind
    public let name: String
    public let parent: SpanContext?
    public let genAIOperation: String?
    public let modelProvider: String?
    public let modelName: String?
    public let toolName: String?
    public let toolType: String?
    public let appName: String?
    public let recordedContextID: Int64?
    public let inputEventID: Int64?
    public let attributes: [String: String]

    public init(
        kind: AgentStoredSpanKind,
        name: String,
        parent: SpanContext? = nil,
        genAIOperation: String? = nil,
        modelProvider: String? = nil,
        modelName: String? = nil,
        toolName: String? = nil,
        toolType: String? = nil,
        appName: String? = nil,
        recordedContextID: Int64? = nil,
        inputEventID: Int64? = nil,
        attributes: [String: String] = [:]
    ) {
        self.kind = kind
        self.name = name
        self.parent = parent
        self.genAIOperation = genAIOperation
        self.modelProvider = modelProvider
        self.modelName = modelName
        self.toolName = toolName
        self.toolType = toolType
        self.appName = appName
        self.recordedContextID = recordedContextID
        self.inputEventID = inputEventID
        self.attributes = attributes
    }
}

public struct SpanResult: Sendable, Equatable, Codable {
    public let status: AgentStoredTraceStatus
    public let failureKind: AgentFailureKind?
    public let attributes: [String: String]

    public init(
        status: AgentStoredTraceStatus = .ok,
        failureKind: AgentFailureKind? = nil,
        attributes: [String: String] = [:]
    ) {
        self.status = status
        self.failureKind = failureKind
        self.attributes = attributes
    }
}

public struct TraceResult: Sendable, Equatable, Codable {
    public let status: AgentStoredTraceStatus
    public let failureKind: AgentFailureKind?
    public let metadata: [String: String]

    public init(
        status: AgentStoredTraceStatus = .ok,
        failureKind: AgentFailureKind? = nil,
        metadata: [String: String] = [:]
    ) {
        self.status = status
        self.failureKind = failureKind
        self.metadata = metadata
    }
}

public struct TraceEventInput: Sendable, Equatable, Codable {
    public let traceID: String?
    public let name: String
    public let severity: String
    public let failureKind: AgentFailureKind?
    public let attributes: [String: String]

    public init(
        traceID: String? = nil,
        name: String,
        severity: String = "info",
        failureKind: AgentFailureKind? = nil,
        attributes: [String: String] = [:]
    ) {
        self.traceID = traceID
        self.name = name
        self.severity = severity
        self.failureKind = failureKind
        self.attributes = attributes
    }
}

public protocol AgentTraceRecording: Sendable {
    func beginTrace(_ input: TraceStart) async throws -> TraceContext
    func beginSpan(_ input: SpanStart, in trace: TraceContext) async throws -> SpanContext
    func endSpan(_ span: SpanContext, _ result: SpanResult) async throws
    func recordEvent(_ event: TraceEventInput, in span: SpanContext?) async throws
    func recordModelUsage(_ usage: ModelUsage, in span: SpanContext) async throws
    func endTrace(_ trace: TraceContext, _ result: TraceResult) async throws
}

public struct CascadeAgentTraceRecorder: AgentTraceRecording {
    private let store: CascadeStore

    public init(store: CascadeStore) {
        self.store = store
    }

    public func beginTrace(_ input: TraceStart) async throws -> TraceContext {
        let now = Date()
        let audit = try await store.appendAudit(AuditEvent(
            createdAt: now,
            actor: input.actor,
            action: "trace.started",
            detail: Self.detail([
                "surface": input.surface,
                "title": input.title,
                "goalHash": input.goalHash,
            ])
        ))
        let traceID = "trace-\(audit.id)"
        let context = TraceContext(
            traceID: traceID,
            rootAuditEventID: audit.id,
            startedAt: now,
            surface: input.surface,
            actor: input.actor,
            title: input.title
        )
        _ = try await store.upsertAgentTrace(AgentTraceRow(
            traceID: traceID,
            startedAt: now,
            surface: input.surface,
            actor: input.actor,
            title: input.title,
            goalHash: input.goalHash,
            appName: input.appName,
            bundleIdentifier: input.bundleIdentifier,
            status: .running,
            rootAuditEventID: audit.id,
            metadataJSON: Self.json(input.metadata)
        ))
        return context
    }

    public func beginSpan(_ input: SpanStart, in trace: TraceContext) async throws -> SpanContext {
        let now = Date()
        let audit = try await store.appendAudit(AuditEvent(
            createdAt: now,
            actor: trace.actor,
            action: "trace.span.started",
            detail: Self.detail([
                "trace": trace.traceID,
                "kind": input.kind.rawValue,
                "name": input.name,
            ])
        ))
        let spanID = "span-\(audit.id)"
        let context = SpanContext(
            traceID: trace.traceID,
            spanID: spanID,
            parentSpanID: input.parent?.spanID,
            auditEventID: audit.id,
            startedAt: now,
            kind: input.kind,
            name: input.name,
            attributes: input.attributes
        )
        _ = try await store.upsertAgentSpan(AgentSpanRow(
            spanID: spanID,
            traceID: trace.traceID,
            parentSpanID: input.parent?.spanID,
            auditEventID: audit.id,
            kind: input.kind,
            name: input.name,
            startedAt: now,
            status: .running,
            genAIOperation: input.genAIOperation,
            modelProvider: input.modelProvider,
            modelName: input.modelName,
            toolName: input.toolName,
            toolType: input.toolType,
            appName: input.appName,
            recordedContextID: input.recordedContextID,
            inputEventID: input.inputEventID,
            attributesJSON: Self.json(input.attributes)
        ))
        return context
    }

    public func endSpan(_ span: SpanContext, _ result: SpanResult) async throws {
        let now = Date()
        let audit = try await store.appendAudit(AuditEvent(
            createdAt: now,
            actor: "agent",
            action: "trace.span.ended",
            detail: Self.detail([
                "trace": span.traceID,
                "span": span.spanID,
                "status": result.status.rawValue,
                "failure": result.failureKind?.rawValue,
            ])
        ))
        var attrs = span.attributes
        for (key, value) in result.attributes {
            attrs[key] = value
        }
        _ = try await store.upsertAgentSpan(AgentSpanRow(
            spanID: span.spanID,
            traceID: span.traceID,
            parentSpanID: span.parentSpanID,
            auditEventID: span.auditEventID ?? audit.id,
            kind: span.kind,
            name: span.name,
            startedAt: span.startedAt,
            endedAt: now,
            durationMs: max(0, Int((now.timeIntervalSince(span.startedAt) * 1000).rounded())),
            status: result.status,
            failureKind: result.failureKind?.rawValue,
            attributesJSON: Self.json(attrs)
        ))
    }

    public func recordEvent(_ event: TraceEventInput, in span: SpanContext?) async throws {
        guard let traceID = event.traceID ?? span?.traceID else { return }
        let now = Date()
        let audit = try await store.appendAudit(AuditEvent(
            createdAt: now,
            actor: "agent",
            action: "trace.event",
            detail: Self.detail([
                "trace": traceID,
                "span": span?.spanID,
                "name": event.name,
                "severity": event.severity,
                "failure": event.failureKind?.rawValue,
            ])
        ))
        _ = try await store.recordTraceEvent(TraceEventRow(
            eventID: "event-\(audit.id)",
            traceID: traceID,
            spanID: span?.spanID,
            auditEventID: audit.id,
            createdAt: now,
            name: event.name,
            severity: event.severity,
            failureKind: event.failureKind?.rawValue,
            attributesJSON: Self.json(event.attributes)
        ))
    }

    public func recordModelUsage(_ usage: ModelUsage, in span: SpanContext) async throws {
        _ = try await store.recordModelCost(ModelCostLedgerRow(
            traceID: span.traceID,
            spanID: span.spanID,
            provider: usage.provider.isEmpty ? "unknown" : usage.provider,
            model: usage.model.isEmpty ? "unknown" : usage.model,
            responseID: usage.responseID,
            priceCardVersion: usage.priceCardVersion,
            inputTokens: usage.inputTokens,
            cacheReadInputTokens: usage.cacheReadTokens,
            cacheCreationInputTokens: usage.cacheWriteTokens,
            outputTokens: usage.outputTokens,
            reasoningOutputTokens: usage.reasoningTokens,
            costMicrousd: usage.costMicrousd
        ))
        _ = try await store.upsertAgentSpan(AgentSpanRow(
            spanID: span.spanID,
            traceID: span.traceID,
            parentSpanID: span.parentSpanID,
            auditEventID: span.auditEventID,
            kind: span.kind,
            name: span.name,
            startedAt: span.startedAt,
            status: .running,
            modelProvider: usage.provider,
            modelName: usage.model,
            inputTokens: usage.inputTokens,
            cacheReadInputTokens: usage.cacheReadTokens,
            cacheCreationInputTokens: usage.cacheWriteTokens,
            outputTokens: usage.outputTokens,
            reasoningOutputTokens: usage.reasoningTokens,
            costMicrousd: usage.costMicrousd,
            attributesJSON: Self.json(span.attributes)
        ))
    }

    public func endTrace(_ trace: TraceContext, _ result: TraceResult) async throws {
        let now = Date()
        let audit = try await store.appendAudit(AuditEvent(
            createdAt: now,
            actor: trace.actor,
            action: "trace.ended",
            detail: Self.detail([
                "trace": trace.traceID,
                "status": result.status.rawValue,
                "failure": result.failureKind?.rawValue,
            ])
        ))
        let tree = try await store.agentTraceTree(traceID: trace.traceID)
        let spans = tree?.spans ?? []
        _ = try await store.upsertAgentTrace(AgentTraceRow(
            traceID: trace.traceID,
            startedAt: trace.startedAt,
            endedAt: now,
            surface: trace.surface,
            actor: trace.actor,
            title: trace.title,
            status: result.status,
            failureKind: result.failureKind?.rawValue,
            rootAuditEventID: trace.rootAuditEventID ?? audit.id,
            totalInputTokens: spans.reduce(0) { $0 + $1.inputTokens },
            totalCacheReadTokens: spans.reduce(0) { $0 + $1.cacheReadInputTokens },
            totalCacheCreationTokens: spans.reduce(0) { $0 + $1.cacheCreationInputTokens },
            totalOutputTokens: spans.reduce(0) { $0 + $1.outputTokens },
            totalReasoningTokens: spans.reduce(0) { $0 + $1.reasoningOutputTokens },
            totalCostMicrousd: spans.reduce(0) { $0 + $1.costMicrousd },
            metadataJSON: Self.json(result.metadata)
        ))
    }

    private static func json(_ value: [String: String]) -> String? {
        guard !value.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else { return nil }
        return string
    }

    private static func detail(_ fields: [String: String?]) -> String {
        fields.compactMap { key, value -> String? in
            guard let value, !value.isEmpty else { return nil }
            let safe = value
                .replacingOccurrences(of: " ", with: "_")
                .replacingOccurrences(of: "\n", with: "_")
            return "\(key)=\(safe)"
        }.joined(separator: " ")
    }
}

public extension AgentTrace {
    func storageRows(actor: String = "agent", redactionPolicy: String = "content-ref-only") -> (
        trace: AgentTraceRow,
        spans: [AgentSpanRow],
        costs: [ModelCostLedgerRow],
        evals: [TraceEvalRow]
    ) {
        let status: AgentStoredTraceStatus = succeeded ? .ok : .failed
        let rootAuditID = spans.first?.attributes["audit.id"].flatMap(Int64.init)
        let traceRow = AgentTraceRow(
            traceID: traceID,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(Double(durationMs) / 1000.0),
            surface: surface,
            actor: actor,
            title: "\(surface)-trace",
            goalHash: AgentTraceStorageBridge.hash(goal),
            status: status,
            failureKind: failureKinds.first?.rawValue,
            rootAuditEventID: rootAuditID,
            totalInputTokens: inputTokens,
            totalCacheReadTokens: cacheReadTokens,
            totalCacheCreationTokens: spans.compactMap(\.usage).reduce(0) { $0 + $1.cacheWriteTokens },
            totalOutputTokens: outputTokens,
            totalReasoningTokens: spans.compactMap(\.usage).reduce(0) { $0 + $1.reasoningTokens },
            totalCostMicrousd: spans.reduce(0) { $0 + AgentTraceStorageBridge.costMicrousd($1) },
            redactionPolicy: redactionPolicy
        )
        let spanRows = spans.map { span in
            AgentSpanRow(
                spanID: span.id,
                traceID: traceID,
                parentSpanID: span.parentID,
                auditEventID: span.attributes["audit.id"].flatMap(Int64.init),
                kind: AgentStoredSpanKind(rawValue: span.kind.rawValue) ?? .step,
                name: span.name,
                startedAt: startedAt.addingTimeInterval(Double(span.startMs) / 1000.0),
                endedAt: startedAt.addingTimeInterval(Double(span.startMs + span.durationMs) / 1000.0),
                durationMs: span.durationMs,
                status: AgentTraceStorageBridge.status(span.status),
                failureKind: span.failureKind?.rawValue,
                genAIOperation: span.attributes["gen_ai.operation.name"],
                modelProvider: span.usage?.provider ?? span.attributes["model.provider"],
                modelName: span.usage?.model ?? span.attributes["model"],
                toolName: span.attributes["tool.name"] ?? (span.kind == .tool ? span.name : nil),
                toolType: span.attributes["tool.type"],
                appName: span.attributes["app"] ?? span.attributes["app_name"],
                recordedContextID: (span.attributes["recorded_context_id"] ?? span.attributes["moment_id"]).flatMap(Int64.init),
                inputTokens: span.usage?.inputTokens ?? 0,
                cacheReadInputTokens: span.usage?.cacheReadTokens ?? 0,
                cacheCreationInputTokens: span.usage?.cacheWriteTokens ?? 0,
                outputTokens: span.usage?.outputTokens ?? 0,
                reasoningOutputTokens: span.usage?.reasoningTokens ?? 0,
                costMicrousd: AgentTraceStorageBridge.costMicrousd(span),
                promptSHA256: span.attributes["prompt_sha256"],
                responseSHA256: span.attributes["response_sha256"],
                attributesJSON: AgentTraceStorageBridge.json(span.attributes)
            )
        }
        let costs = spans.compactMap { span -> ModelCostLedgerRow? in
            guard let usage = span.usage else { return nil }
            return ModelCostLedgerRow(
                traceID: traceID,
                spanID: span.id,
                createdAt: startedAt.addingTimeInterval(Double(span.startMs) / 1000.0),
                provider: usage.provider.isEmpty ? "unknown" : usage.provider,
                model: usage.model.isEmpty ? "unknown" : usage.model,
                responseID: usage.responseID,
                priceCardVersion: usage.priceCardVersion,
                inputTokens: usage.inputTokens,
                cacheReadInputTokens: usage.cacheReadTokens,
                cacheCreationInputTokens: usage.cacheWriteTokens,
                outputTokens: usage.outputTokens,
                reasoningOutputTokens: usage.reasoningTokens,
                costMicrousd: AgentTraceStorageBridge.costMicrousd(span)
            )
        }
        let evals = spans.compactMap { span -> TraceEvalRow? in
            guard span.kind == .eval || span.attributes["eval.kind"] != nil || span.name.contains("verify") else {
                return nil
            }
            return TraceEvalRow(
                traceID: traceID,
                spanID: span.id,
                createdAt: startedAt.addingTimeInterval(Double(span.startMs) / 1000.0),
                evaluatorKind: TraceEvalKind(rawValue: span.attributes["eval.kind"] ?? "") ?? .verifier,
                evaluatorName: span.attributes["eval.name"] ?? span.name,
                scoreValue: span.attributes["eval.score"].flatMap(Double.init),
                scoreLabel: span.attributes["eval.label"] ?? (span.status == .ok ? "pass" : "fail"),
                explanationRedacted: span.attributes["eval.explanation"],
                confidence: (span.attributes["verifier.confidence"] ?? span.attributes["confidence"]).flatMap(Double.init),
                failureKind: span.failureKind?.rawValue,
                sourceSpanID: span.parentID
            )
        }
        return (traceRow, spanRows, costs, evals)
    }
}

private enum AgentTraceStorageBridge {
    static func status(_ status: TraceSpan.Status) -> AgentStoredTraceStatus {
        switch status {
        case .ok: return .ok
        case .error: return .failed
        case .refused: return .refused
        }
    }

    static func costMicrousd(_ span: TraceSpan) -> Int64 {
        if let usage = span.usage, usage.costMicrousd > 0 { return usage.costMicrousd }
        return span.costUSD.map { Int64(($0 * 1_000_000).rounded()) } ?? 0
    }

    static func json(_ attributes: [String: String]) -> String? {
        guard !attributes.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: attributes, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else { return nil }
        return string
    }

    static func hash(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}
