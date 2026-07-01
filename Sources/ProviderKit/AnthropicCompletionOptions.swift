import CascadeMemory
import Foundation

public enum AnthropicRequestVersions {
    public static let messagesAPI = "2023-06-01"
    public static let computerUseBeta = "computer-use-2025-11-24"
}

public enum ModelCallCachePolicy: String, Codable, Equatable, Sendable {
    case readWrite
    case readOnly
    case writeOnly
    case bypass

    public var allowsLookup: Bool {
        switch self {
        case .readWrite, .readOnly: true
        case .writeOnly, .bypass: false
        }
    }

    public var allowsStore: Bool {
        switch self {
        case .readWrite, .writeOnly: true
        case .readOnly, .bypass: false
        }
    }
}

public struct AnthropicCompletionOptions: Equatable, Sendable {
    public let temperature: Double?
    public let promptVersion: String
    public let schemaVersion: String
    public let callsite: String
    public let cachePolicy: ModelCallCachePolicy
    public let idempotencyClass: ActionRetryClass
    public let retryPolicy: RetryBackoffPolicy?
    public let attemptRecorder: (any ModelRequestAttemptRecording)?

    public init(
        temperature: Double? = nil,
        promptVersion: String = "unversioned-prompt",
        schemaVersion: String = "unversioned-schema",
        callsite: String = "unversioned-callsite",
        cachePolicy: ModelCallCachePolicy = .readWrite,
        idempotencyClass: ActionRetryClass = .pureModelCall,
        retryPolicy: RetryBackoffPolicy? = nil,
        attemptRecorder: (any ModelRequestAttemptRecording)? = nil
    ) {
        self.temperature = temperature
        self.promptVersion = promptVersion
        self.schemaVersion = schemaVersion
        self.callsite = callsite
        self.cachePolicy = cachePolicy
        self.idempotencyClass = idempotencyClass
        self.retryPolicy = retryPolicy
        self.attemptRecorder = attemptRecorder
    }

    public static let standard = AnthropicCompletionOptions()

    public static func == (lhs: AnthropicCompletionOptions, rhs: AnthropicCompletionOptions) -> Bool {
        lhs.temperature == rhs.temperature
            && lhs.promptVersion == rhs.promptVersion
            && lhs.schemaVersion == rhs.schemaVersion
            && lhs.callsite == rhs.callsite
            && lhs.cachePolicy == rhs.cachePolicy
            && lhs.idempotencyClass == rhs.idempotencyClass
            && lhs.retryPolicy == rhs.retryPolicy
    }

    public static func deterministic(
        promptVersion: String,
        schemaVersion: String,
        callsite: String
    ) -> AnthropicCompletionOptions {
        AnthropicCompletionOptions(
            temperature: 0,
            promptVersion: promptVersion,
            schemaVersion: schemaVersion,
            callsite: callsite,
            cachePolicy: .readWrite,
            idempotencyClass: .pureModelCall
        )
    }

    public func withRetryPolicy(_ retryPolicy: RetryBackoffPolicy?) -> AnthropicCompletionOptions {
        AnthropicCompletionOptions(
            temperature: temperature,
            promptVersion: promptVersion,
            schemaVersion: schemaVersion,
            callsite: callsite,
            cachePolicy: cachePolicy,
            idempotencyClass: idempotencyClass,
            retryPolicy: retryPolicy,
            attemptRecorder: attemptRecorder
        )
    }

    public func withAttemptRecorder(_ attemptRecorder: (any ModelRequestAttemptRecording)?) -> AnthropicCompletionOptions {
        AnthropicCompletionOptions(
            temperature: temperature,
            promptVersion: promptVersion,
            schemaVersion: schemaVersion,
            callsite: callsite,
            cachePolicy: cachePolicy,
            idempotencyClass: idempotencyClass,
            retryPolicy: retryPolicy,
            attemptRecorder: attemptRecorder
        )
    }

    public func cacheRequest(
        model: String,
        maxTokens: Int,
        body: Data,
        apiVersion: String = AnthropicRequestVersions.messagesAPI,
        betaVersion: String? = nil
    ) throws -> ModelCallRequest {
        try ModelCallRequest(
            model: model,
            apiVersion: apiVersion,
            betaVersion: betaVersion,
            temperature: temperature,
            maxTokens: maxTokens,
            promptVersion: promptVersion,
            schemaVersion: schemaVersion,
            callsite: callsite,
            body: body
        )
    }
}

public struct AnthropicModelPricing: Equatable, Sendable {
    public let inputPerMTok: Double
    public let outputPerMTok: Double
    public let cacheReadPerMTok: Double
    public let cacheWritePerMTok: Double

    public init(
        inputPerMTok: Double,
        outputPerMTok: Double,
        cacheReadPerMTok: Double,
        cacheWritePerMTok: Double
    ) {
        self.inputPerMTok = inputPerMTok
        self.outputPerMTok = outputPerMTok
        self.cacheReadPerMTok = cacheReadPerMTok
        self.cacheWritePerMTok = cacheWritePerMTok
    }

    public static func illustrative(for model: String) -> AnthropicModelPricing {
        let lowercased = model.lowercased()
        if lowercased.contains("haiku") {
            return AnthropicModelPricing(inputPerMTok: 1, outputPerMTok: 5, cacheReadPerMTok: 0.1, cacheWritePerMTok: 1.25)
        }
        if lowercased.contains("sonnet") {
            return AnthropicModelPricing(inputPerMTok: 3, outputPerMTok: 15, cacheReadPerMTok: 0.3, cacheWritePerMTok: 3.75)
        }
        return AnthropicModelPricing(inputPerMTok: 15, outputPerMTok: 75, cacheReadPerMTok: 1.5, cacheWritePerMTok: 18.75)
    }

    public func cost(
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int = 0,
        cacheWriteTokens: Int = 0
    ) -> Double {
        (
            Double(inputTokens) * inputPerMTok
            + Double(outputTokens) * outputPerMTok
            + Double(cacheReadTokens) * cacheReadPerMTok
            + Double(cacheWriteTokens) * cacheWritePerMTok
        ) / 1_000_000.0
    }
}

public struct EpisodeBudget: Equatable, Sendable {
    public var preflightInputTokens: Int
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheWriteTokens: Int
    public var estimatedCostUSD: Double
    public var actualCostUSD: Double
    public var actionCount: Int
    public var noEffectCount: Int
    public var screenshotCount: Int
    public var compactedToolResults: Int
    public var pricing: AnthropicModelPricing

    public init(
        preflightInputTokens: Int = 0,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        cacheWriteTokens: Int = 0,
        estimatedCostUSD: Double = 0,
        actualCostUSD: Double = 0,
        actionCount: Int = 0,
        noEffectCount: Int = 0,
        screenshotCount: Int = 0,
        compactedToolResults: Int = 0,
        pricing: AnthropicModelPricing = .illustrative(for: AnthropicModel.sonnet)
    ) {
        self.preflightInputTokens = preflightInputTokens
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.estimatedCostUSD = estimatedCostUSD
        self.actualCostUSD = actualCostUSD
        self.actionCount = actionCount
        self.noEffectCount = noEffectCount
        self.screenshotCount = screenshotCount
        self.compactedToolResults = compactedToolResults
        self.pricing = pricing
    }

    public var cacheHitRatio: Double {
        let total = inputTokens + cacheReadTokens + cacheWriteTokens
        guard total > 0 else { return 0 }
        return Double(cacheReadTokens) / Double(total)
    }

    public mutating func recordPreflight(inputTokens: Int, maxOutputTokens: Int) {
        preflightInputTokens += inputTokens
        estimatedCostUSD += pricing.cost(inputTokens: inputTokens, outputTokens: maxOutputTokens)
    }

    public mutating func recordActual(_ usage: AnthropicUsage) {
        inputTokens += usage.inputTokens
        outputTokens += usage.outputTokens
        cacheReadTokens += usage.cacheReadInputTokens
        cacheWriteTokens += usage.cacheCreationInputTokens
        actualCostUSD += pricing.cost(
            inputTokens: usage.inputTokens,
            outputTokens: usage.outputTokens,
            cacheReadTokens: usage.cacheReadInputTokens,
            cacheWriteTokens: usage.cacheCreationInputTokens
        )
    }
}
