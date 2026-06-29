import Foundation

public enum AgentStoredTraceStatus: String, Codable, Sendable {
    case running
    case ok
    case failed
    case stopped
    case refused
}

public enum AgentStoredSpanKind: String, Codable, Sendable {
    case run
    case step
    case model
    case tool
    case retrieval
    case eval
    case export
}

public enum TraceEvalKind: String, Codable, Sendable {
    case rule
    case verifier
    case llmJudge = "llm_judge"
    case human
}

public struct AgentTraceRow: Codable, Equatable, Sendable {
    public var traceID: String
    public var startedAt: Date
    public var endedAt: Date?
    public var surface: String
    public var actor: String
    public var title: String
    public var goalHash: String?
    public var appName: String?
    public var bundleIdentifier: String?
    public var status: AgentStoredTraceStatus
    public var failureKind: String?
    public var rootAuditEventID: Int64?
    public var totalInputTokens: Int
    public var totalCacheReadTokens: Int
    public var totalCacheCreationTokens: Int
    public var totalOutputTokens: Int
    public var totalReasoningTokens: Int
    public var totalCostMicrousd: Int64
    public var redactionPolicy: String
    public var metadataJSON: String?

    public init(
        traceID: String,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        surface: String,
        actor: String = "agent",
        title: String,
        goalHash: String? = nil,
        appName: String? = nil,
        bundleIdentifier: String? = nil,
        status: AgentStoredTraceStatus = .running,
        failureKind: String? = nil,
        rootAuditEventID: Int64? = nil,
        totalInputTokens: Int = 0,
        totalCacheReadTokens: Int = 0,
        totalCacheCreationTokens: Int = 0,
        totalOutputTokens: Int = 0,
        totalReasoningTokens: Int = 0,
        totalCostMicrousd: Int64 = 0,
        redactionPolicy: String = "content-ref-only",
        metadataJSON: String? = nil
    ) {
        self.traceID = traceID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.surface = surface
        self.actor = actor
        self.title = title
        self.goalHash = goalHash
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.status = status
        self.failureKind = failureKind
        self.rootAuditEventID = rootAuditEventID
        self.totalInputTokens = totalInputTokens
        self.totalCacheReadTokens = totalCacheReadTokens
        self.totalCacheCreationTokens = totalCacheCreationTokens
        self.totalOutputTokens = totalOutputTokens
        self.totalReasoningTokens = totalReasoningTokens
        self.totalCostMicrousd = totalCostMicrousd
        self.redactionPolicy = redactionPolicy
        self.metadataJSON = metadataJSON
    }
}

public struct AgentSpanRow: Codable, Equatable, Sendable {
    public var spanID: String
    public var traceID: String
    public var parentSpanID: String?
    public var auditEventID: Int64?
    public var kind: AgentStoredSpanKind
    public var name: String
    public var startedAt: Date
    public var endedAt: Date?
    public var durationMs: Int?
    public var status: AgentStoredTraceStatus
    public var failureKind: String?
    public var genAIOperation: String?
    public var modelProvider: String?
    public var modelName: String?
    public var toolName: String?
    public var toolType: String?
    public var appName: String?
    public var recordedContextID: Int64?
    public var inputEventID: Int64?
    public var inputTokens: Int
    public var cacheReadInputTokens: Int
    public var cacheCreationInputTokens: Int
    public var outputTokens: Int
    public var reasoningOutputTokens: Int
    public var costMicrousd: Int64
    public var promptSHA256: String?
    public var responseSHA256: String?
    public var attributesJSON: String?

    public init(
        spanID: String,
        traceID: String,
        parentSpanID: String? = nil,
        auditEventID: Int64? = nil,
        kind: AgentStoredSpanKind,
        name: String,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        durationMs: Int? = nil,
        status: AgentStoredTraceStatus = .running,
        failureKind: String? = nil,
        genAIOperation: String? = nil,
        modelProvider: String? = nil,
        modelName: String? = nil,
        toolName: String? = nil,
        toolType: String? = nil,
        appName: String? = nil,
        recordedContextID: Int64? = nil,
        inputEventID: Int64? = nil,
        inputTokens: Int = 0,
        cacheReadInputTokens: Int = 0,
        cacheCreationInputTokens: Int = 0,
        outputTokens: Int = 0,
        reasoningOutputTokens: Int = 0,
        costMicrousd: Int64 = 0,
        promptSHA256: String? = nil,
        responseSHA256: String? = nil,
        attributesJSON: String? = nil
    ) {
        self.spanID = spanID
        self.traceID = traceID
        self.parentSpanID = parentSpanID
        self.auditEventID = auditEventID
        self.kind = kind
        self.name = name
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationMs = durationMs
        self.status = status
        self.failureKind = failureKind
        self.genAIOperation = genAIOperation
        self.modelProvider = modelProvider
        self.modelName = modelName
        self.toolName = toolName
        self.toolType = toolType
        self.appName = appName
        self.recordedContextID = recordedContextID
        self.inputEventID = inputEventID
        self.inputTokens = inputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.outputTokens = outputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
        self.costMicrousd = costMicrousd
        self.promptSHA256 = promptSHA256
        self.responseSHA256 = responseSHA256
        self.attributesJSON = attributesJSON
    }
}

public struct TraceEventRow: Codable, Equatable, Sendable {
    public var eventID: String
    public var traceID: String
    public var spanID: String?
    public var auditEventID: Int64?
    public var createdAt: Date
    public var name: String
    public var severity: String
    public var failureKind: String?
    public var attributesJSON: String?

    public init(
        eventID: String,
        traceID: String,
        spanID: String? = nil,
        auditEventID: Int64? = nil,
        createdAt: Date = Date(),
        name: String,
        severity: String = "info",
        failureKind: String? = nil,
        attributesJSON: String? = nil
    ) {
        self.eventID = eventID
        self.traceID = traceID
        self.spanID = spanID
        self.auditEventID = auditEventID
        self.createdAt = createdAt
        self.name = name
        self.severity = severity
        self.failureKind = failureKind
        self.attributesJSON = attributesJSON
    }
}

public struct ModelCostLedgerRow: Codable, Equatable, Sendable {
    public var id: Int64
    public var traceID: String
    public var spanID: String
    public var createdAt: Date
    public var provider: String
    public var model: String
    public var responseID: String?
    public var priceCardVersion: String
    public var inputTokens: Int
    public var cacheReadInputTokens: Int
    public var cacheCreationInputTokens: Int
    public var outputTokens: Int
    public var reasoningOutputTokens: Int
    public var costMicrousd: Int64
    public var billable: Bool

    public init(
        id: Int64 = 0,
        traceID: String,
        spanID: String,
        createdAt: Date = Date(),
        provider: String,
        model: String,
        responseID: String? = nil,
        priceCardVersion: String,
        inputTokens: Int = 0,
        cacheReadInputTokens: Int = 0,
        cacheCreationInputTokens: Int = 0,
        outputTokens: Int = 0,
        reasoningOutputTokens: Int = 0,
        costMicrousd: Int64 = 0,
        billable: Bool = true
    ) {
        self.id = id
        self.traceID = traceID
        self.spanID = spanID
        self.createdAt = createdAt
        self.provider = provider
        self.model = model
        self.responseID = responseID
        self.priceCardVersion = priceCardVersion
        self.inputTokens = inputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.outputTokens = outputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
        self.costMicrousd = costMicrousd
        self.billable = billable
    }
}

public struct TraceEvalRow: Codable, Equatable, Sendable {
    public var id: Int64
    public var traceID: String
    public var spanID: String?
    public var createdAt: Date
    public var evaluatorKind: TraceEvalKind
    public var evaluatorName: String
    public var scoreValue: Double?
    public var scoreLabel: String?
    public var explanationRedacted: String?
    public var confidence: Double?
    public var failureKind: String?
    public var sourceSpanID: String?

    public init(
        id: Int64 = 0,
        traceID: String,
        spanID: String? = nil,
        createdAt: Date = Date(),
        evaluatorKind: TraceEvalKind,
        evaluatorName: String,
        scoreValue: Double? = nil,
        scoreLabel: String? = nil,
        explanationRedacted: String? = nil,
        confidence: Double? = nil,
        failureKind: String? = nil,
        sourceSpanID: String? = nil
    ) {
        self.id = id
        self.traceID = traceID
        self.spanID = spanID
        self.createdAt = createdAt
        self.evaluatorKind = evaluatorKind
        self.evaluatorName = evaluatorName
        self.scoreValue = scoreValue
        self.scoreLabel = scoreLabel
        self.explanationRedacted = explanationRedacted
        self.confidence = confidence
        self.failureKind = failureKind
        self.sourceSpanID = sourceSpanID
    }
}

public struct AgentTraceQuery: Sendable, Equatable {
    public var from: Date?
    public var to: Date?
    public var status: AgentStoredTraceStatus?
    public var failureKind: String?
    public var limit: Int

    public init(
        from: Date? = nil,
        to: Date? = nil,
        status: AgentStoredTraceStatus? = nil,
        failureKind: String? = nil,
        limit: Int = 100
    ) {
        self.from = from
        self.to = to
        self.status = status
        self.failureKind = failureKind
        self.limit = limit
    }
}

public struct AgentTraceTree: Equatable, Sendable {
    public let trace: AgentTraceRow
    public let spans: [AgentSpanRow]
    public let events: [TraceEventRow]
    public let costs: [ModelCostLedgerRow]
    public let evals: [TraceEvalRow]

    public init(
        trace: AgentTraceRow,
        spans: [AgentSpanRow],
        events: [TraceEventRow] = [],
        costs: [ModelCostLedgerRow] = [],
        evals: [TraceEvalRow] = []
    ) {
        self.trace = trace
        self.spans = spans
        self.events = events
        self.costs = costs
        self.evals = evals
    }
}
