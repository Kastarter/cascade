import Foundation

/// Current Claude model ids. Default to the most capable model; callers can pin
/// a cheaper one. (See platform.claude.com model catalog.)
public enum AnthropicModel {
    public static let opus = "claude-opus-4-8"
    public static let sonnet = "claude-sonnet-4-6"
    public static let haiku = "claude-haiku-4-5"
}

public enum AnthropicError: Error, LocalizedError {
    case missingKey
    case transport(String)
    case http(Int, String)
    case emptyResponse

    public var errorDescription: String? {
        switch self {
        case .missingKey: "Connect your Anthropic API key in Settings first."
        case .transport(let message): "Network error: \(message)"
        case .http(let code, let message): "Claude API error \(code): \(message)"
        case .emptyResponse: "Claude returned an empty response."
        }
    }
}

public struct AnthropicUsage: Sendable, Equatable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadInputTokens: Int
    public var cacheCreationInputTokens: Int

    public init(
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheReadInputTokens: Int = 0,
        cacheCreationInputTokens: Int = 0
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
    }

    public static func parse(_ raw: [String: Any]) -> AnthropicUsage {
        AnthropicUsage(
            inputTokens: Self.int(raw["input_tokens"]),
            outputTokens: Self.int(raw["output_tokens"]),
            cacheReadInputTokens: Self.int(raw["cache_read_input_tokens"]),
            cacheCreationInputTokens: Self.int(raw["cache_creation_input_tokens"])
        )
    }

    public var rawDictionary: [String: Any] {
        [
            "input_tokens": inputTokens,
            "output_tokens": outputTokens,
            "cache_read_input_tokens": cacheReadInputTokens,
            "cache_creation_input_tokens": cacheCreationInputTokens,
        ]
    }

    private static func int(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return 0
    }
}

public struct AnthropicMessagesResponse {
    public let id: String?
    public let content: [[String: Any]]
    public let stopReason: String?
    public let usage: AnthropicUsage
    public let raw: [String: Any]

    public var text: String {
        content.compactMap { block in
            (block["type"] as? String) == "text" ? block["text"] as? String : nil
        }.joined()
    }

    public func normalizedUsage(model: String) -> ModelUsage {
        usage.normalized(model: model, responseID: id)
    }
}

public struct AnthropicTokenCount: Sendable, Equatable {
    public let inputTokens: Int

    public init(inputTokens: Int) {
        self.inputTokens = inputTokens
    }
}

public struct AnthropicMessagesClient: Sendable {
    private let keyStore: AnthropicKeyStore
    private let session: URLSession
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private let countEndpoint = URL(string: "https://api.anthropic.com/v1/messages/count_tokens")!

    public init(keyStore: AnthropicKeyStore = AnthropicKeyStore(), session: URLSession = .shared) {
        self.keyStore = keyStore
        self.session = session
    }

    public func send(
        model: String,
        maxTokens: Int,
        system: Any? = nil,
        messages: [[String: Any]],
        temperature: Double? = nil,
        tools: [[String: Any]]? = nil,
        toolChoice: [String: Any]? = nil,
        thinking: [String: Any]? = nil,
        outputConfig: [String: Any]? = nil,
        betaHeader: String? = nil,
        timeout: TimeInterval = 30
    ) async throws -> AnthropicMessagesResponse {
        guard let key = keyStore.readKey(), !key.isEmpty else { throw AnthropicError.missingKey }
        let bodyData = try Self.bodyData(
            model: model,
            maxTokens: maxTokens,
            system: system,
            messages: messages,
            temperature: temperature,
            tools: tools,
            toolChoice: toolChoice,
            thinking: thinking,
            outputConfig: outputConfig,
            stream: false
        )
        var request = Self.request(
            url: endpoint,
            key: key,
            bodyData: bodyData,
            betaHeader: betaHeader,
            timeout: timeout
        )
        request.httpMethod = "POST"
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AnthropicError.transport(error.localizedDescription)
        }
        try Self.validate(response: response, data: data)
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AnthropicError.emptyResponse
        }
        return Self.response(from: raw)
    }

    public func countTokens(
        model: String,
        maxTokens: Int,
        system: Any? = nil,
        messages: [[String: Any]],
        temperature: Double? = nil,
        tools: [[String: Any]]? = nil,
        toolChoice: [String: Any]? = nil,
        thinking: [String: Any]? = nil,
        outputConfig: [String: Any]? = nil,
        betaHeader: String? = nil,
        timeout: TimeInterval = 20
    ) async throws -> AnthropicTokenCount {
        let bodyData = try Self.bodyData(
            model: model,
            maxTokens: maxTokens,
            system: system,
            messages: messages,
            temperature: temperature,
            tools: tools,
            toolChoice: toolChoice,
            thinking: thinking,
            outputConfig: outputConfig,
            stream: nil
        )
        return try await countTokens(bodyData: bodyData, betaHeader: betaHeader, timeout: timeout)
    }

    public func countTokens(bodyData: Data, betaHeader: String? = nil, timeout: TimeInterval = 20) async throws -> AnthropicTokenCount {
        guard let key = keyStore.readKey(), !key.isEmpty else { throw AnthropicError.missingKey }
        var request = Self.request(url: countEndpoint, key: key, bodyData: bodyData, betaHeader: betaHeader, timeout: timeout)
        request.httpMethod = "POST"
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AnthropicError.transport(error.localizedDescription)
        }
        try Self.validate(response: response, data: data)
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AnthropicError.emptyResponse
        }
        return AnthropicTokenCount(inputTokens: Self.int(raw["input_tokens"]))
    }

    public static func body(
        model: String,
        maxTokens: Int,
        system: Any? = nil,
        messages: [[String: Any]],
        temperature: Double? = nil,
        tools: [[String: Any]]? = nil,
        toolChoice: [String: Any]? = nil,
        thinking: [String: Any]? = nil,
        outputConfig: [String: Any]? = nil,
        stream: Bool? = nil
    ) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "messages": messages,
        ]
        if let system { body["system"] = system }
        if let temperature { body["temperature"] = temperature }
        if let tools { body["tools"] = cappingStrictTools(tools) }
        if let toolChoice { body["tool_choice"] = toolChoice }
        if let thinking { body["thinking"] = thinking }
        if let outputConfig { body["output_config"] = outputConfig }
        if let stream { body["stream"] = stream }
        return body
    }

    /// Anthropic hard-caps STRICT tools at 20 per request; a 21st strict tool → HTTP 400
    /// "Too many strict tools" (surfaces to the user as "I couldn't reach Claude"). As the
    /// agent's tool set grew across SEQs past 20 strict, every computer-use turn 400'd.
    /// Relax `strict` on any tool beyond the 20th — it still works, just isn't strict-validated.
    static func cappingStrictTools(_ tools: [[String: Any]], max: Int = 20) -> [[String: Any]] {
        var strictCount = 0
        return tools.map { tool in
            guard (tool["strict"] as? Bool) == true else { return tool }
            strictCount += 1
            if strictCount <= max { return tool }
            var relaxed = tool
            relaxed.removeValue(forKey: "strict")
            return relaxed
        }
    }

    public static func bodyData(
        model: String,
        maxTokens: Int,
        system: Any? = nil,
        messages: [[String: Any]],
        temperature: Double? = nil,
        tools: [[String: Any]]? = nil,
        toolChoice: [String: Any]? = nil,
        thinking: [String: Any]? = nil,
        outputConfig: [String: Any]? = nil,
        stream: Bool? = nil
    ) throws -> Data {
        let object = body(
            model: model,
            maxTokens: maxTokens,
            system: system,
            messages: messages,
            temperature: temperature,
            tools: tools,
            toolChoice: toolChoice,
            thinking: thinking,
            outputConfig: outputConfig,
            stream: stream
        )
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    public static func response(from raw: [String: Any]) -> AnthropicMessagesResponse {
        AnthropicMessagesResponse(
            id: raw["id"] as? String,
            content: raw["content"] as? [[String: Any]] ?? [],
            stopReason: raw["stop_reason"] as? String,
            usage: AnthropicUsage.parse(raw["usage"] as? [String: Any] ?? [:]),
            raw: raw
        )
    }

    public static func request(
        url: URL,
        key: String,
        bodyData: Data,
        betaHeader: String? = nil,
        timeout: TimeInterval
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(AnthropicRequestVersions.messagesAPI, forHTTPHeaderField: "anthropic-version")
        if let betaHeader { request.setValue(betaHeader, forHTTPHeaderField: "anthropic-beta") }
        request.httpBody = bodyData
        return request
    }

    public static func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw AnthropicError.transport("No HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AnthropicError.http(http.statusCode, AnthropicClient.errorMessage(from: data, status: http.statusCode))
        }
    }

    private static func int(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return 0
    }
}

/// One non-streaming text completion. Abstracted so planners and answerers can be
/// unit-tested without the network; `AnthropicClient` is the production conformer.
public protocol MessageCompleting: Sendable {
    func complete(system: String?, user: String, model: String, maxTokens: Int) async throws -> String
    func complete(system: String?, user: String, model: String, maxTokens: Int, options: AnthropicCompletionOptions) async throws -> String
}

public struct MessageCompletionResult: Sendable, Equatable {
    public let text: String
    public let usage: ModelUsage?
    public let responseID: String?

    public init(text: String, usage: ModelUsage? = nil, responseID: String? = nil) {
        self.text = text
        self.usage = usage
        self.responseID = responseID
    }
}

public extension MessageCompleting {
    func complete(system: String?, user: String, model: String, maxTokens: Int, options: AnthropicCompletionOptions) async throws -> String {
        try await complete(system: system, user: user, model: model, maxTokens: maxTokens)
    }

    /// Convenience for callers that don't need to pin a model.
    func complete(system: String? = nil, user: String) async throws -> String {
        try await complete(system: system, user: user, model: AnthropicModel.opus, maxTokens: 1024)
    }

    func completeWithMetadata(
        system: String?,
        user: String,
        model: String,
        maxTokens: Int,
        options: AnthropicCompletionOptions
    ) async throws -> MessageCompletionResult {
        let text = try await complete(system: system, user: user, model: model, maxTokens: maxTokens, options: options)
        return MessageCompletionResult(text: text)
    }
}

public struct RetryingMessageCompleter: MessageCompleting {
    private let client: any MessageCompleting
    private let retryPolicy: RetryBackoffPolicy

    public init(client: any MessageCompleting, retryPolicy: RetryBackoffPolicy) {
        self.client = client
        self.retryPolicy = retryPolicy
    }

    public func complete(
        system: String?,
        user: String,
        model: String,
        maxTokens: Int
    ) async throws -> String {
        try await complete(system: system, user: user, model: model, maxTokens: maxTokens, options: .standard)
    }

    public func complete(
        system: String?,
        user: String,
        model: String,
        maxTokens: Int,
        options: AnthropicCompletionOptions
    ) async throws -> String {
        try await completeWithMetadata(
            system: system,
            user: user,
            model: model,
            maxTokens: maxTokens,
            options: options
        ).text
    }

    public func completeWithMetadata(
        system: String?,
        user: String,
        model: String,
        maxTokens: Int,
        options: AnthropicCompletionOptions
    ) async throws -> MessageCompletionResult {
        let key = try Self.idempotencyKey(
            system: system,
            user: user,
            model: model,
            maxTokens: maxTokens,
            options: options
        )
        var retryCount = 0

        while true {
            do {
                return try await client.completeWithMetadata(
                    system: system,
                    user: user,
                    model: model,
                    maxTokens: maxTokens,
                    options: options
                )
            } catch {
                let classification = RetryErrorClassifier.classify(error)
                guard let delay = retryPolicy.delay(
                    afterRetryCount: retryCount,
                    retryClass: key.retryClass,
                    classification: classification,
                    key: key
                ) else {
                    throw error
                }
                retryCount += 1
                if delay > 0 {
                    try await Task.sleep(nanoseconds: Self.nanoseconds(for: delay))
                }
            }
        }
    }

    private static func idempotencyKey(
        system: String?,
        user: String,
        model: String,
        maxTokens: Int,
        options: AnthropicCompletionOptions
    ) throws -> ActionIdempotencyKey {
        let body = try AnthropicClient.completionBodyData(
            system: system,
            user: user,
            model: model,
            maxTokens: maxTokens,
            options: options
        )
        let payload = try JSONSerialization.jsonObject(with: body, options: [])
        return try ActionIdempotencyKey(
            retryClass: .pureModelCall,
            operation: options.callsite,
            model: model,
            prompt: options.promptVersion,
            schema: options.schemaVersion,
            payload: payload
        )
    }

    private static func nanoseconds(for delay: TimeInterval) -> UInt64 {
        let maxSeconds = Double(UInt64.max) / 1_000_000_000
        return UInt64((min(delay, maxSeconds) * 1_000_000_000).rounded())
    }
}

/// BYOK Anthropic Messages API client over `URLSession`. The key is read from the
/// macOS Keychain at call time, never cached in the struct.
public struct AnthropicClient: MessageCompleting {
    private let keyStore: AnthropicKeyStore
    private let session: URLSession
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private let messagesClient: AnthropicMessagesClient

    public init(keyStore: AnthropicKeyStore = AnthropicKeyStore(), session: URLSession = .shared) {
        self.keyStore = keyStore
        self.session = session
        self.messagesClient = AnthropicMessagesClient(keyStore: keyStore, session: session)
    }

    public func complete(
        system: String? = nil,
        user: String,
        model: String = AnthropicModel.opus,
        maxTokens: Int = 1024
    ) async throws -> String {
        try await complete(system: system, user: user, model: model, maxTokens: maxTokens, options: .standard)
    }

    public func complete(
        system: String? = nil,
        user: String,
        model: String = AnthropicModel.opus,
        maxTokens: Int = 1024,
        options: AnthropicCompletionOptions
    ) async throws -> String {
        try await completeWithMetadata(
            system: system,
            user: user,
            model: model,
            maxTokens: maxTokens,
            options: options
        ).text
    }

    public func completeWithMetadata(
        system: String? = nil,
        user: String,
        model: String = AnthropicModel.opus,
        maxTokens: Int = 1024,
        options: AnthropicCompletionOptions
    ) async throws -> MessageCompletionResult {
        let response = try await messagesClient.send(
            model: model,
            maxTokens: maxTokens,
            system: system,
            messages: [AnthropicMessageRequestBody.Message(role: "user", content: user).dictionary],
            temperature: options.temperature
        )
        let text = response.text
        guard !text.isEmpty else { throw AnthropicError.emptyResponse }
        return MessageCompletionResult(
            text: text,
            usage: response.normalizedUsage(model: model),
            responseID: response.id
        )
    }

    static func errorMessage(from data: Data, status: Int) -> String {
        if let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data) {
            return envelope.error.message
        }
        return String(data: data, encoding: .utf8) ?? "Status \(status)"
    }

    static func completionBodyData(
        system: String?,
        user: String,
        model: String,
        maxTokens: Int,
        options: AnthropicCompletionOptions
    ) throws -> Data {
        try AnthropicMessagesClient.bodyData(
            model: model,
            maxTokens: maxTokens,
            system: system,
            messages: [AnthropicMessageRequestBody.Message(role: "user", content: user).dictionary],
            temperature: options.temperature
        )
    }

    private struct ResponseBody: Decodable {
        let content: [Block]
        struct Block: Decodable {
            let type: String
            let text: String?
        }
    }

    private struct ErrorEnvelope: Decodable {
        let error: APIError
        struct APIError: Decodable { let message: String }
    }
}

struct AnthropicMessageRequestBody: Encodable, Sendable {
    let model: String
    let maxTokens: Int
    let temperature: Double?
    let system: String?
    let messages: [Message]

    enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case temperature
        case system
        case messages
    }

    struct Message: Encodable, Sendable {
        let role: String
        let content: String

        var dictionary: [String: Any] {
            ["role": role, "content": content]
        }
    }
}
