import Foundation

public enum AnthropicRequestVersions {
    public static let messagesAPI = "2023-06-01"
    public static let computerUseBeta = "computer-use-2025-11-24"
}

public struct AnthropicCompletionOptions: Equatable, Sendable {
    public let temperature: Double?
    public let promptVersion: String
    public let schemaVersion: String
    public let callsite: String

    public init(
        temperature: Double? = nil,
        promptVersion: String = "unversioned-prompt",
        schemaVersion: String = "unversioned-schema",
        callsite: String = "unversioned-callsite"
    ) {
        self.temperature = temperature
        self.promptVersion = promptVersion
        self.schemaVersion = schemaVersion
        self.callsite = callsite
    }

    public static let standard = AnthropicCompletionOptions()

    public static func deterministic(
        promptVersion: String,
        schemaVersion: String,
        callsite: String
    ) -> AnthropicCompletionOptions {
        AnthropicCompletionOptions(
            temperature: 0,
            promptVersion: promptVersion,
            schemaVersion: schemaVersion,
            callsite: callsite
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
