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

/// One non-streaming text completion. Abstracted so planners and answerers can be
/// unit-tested without the network; `AnthropicClient` is the production conformer.
public protocol MessageCompleting: Sendable {
    func complete(system: String?, user: String, model: String, maxTokens: Int) async throws -> String
    func complete(system: String?, user: String, model: String, maxTokens: Int, options: AnthropicCompletionOptions) async throws -> String
}

public extension MessageCompleting {
    func complete(system: String?, user: String, model: String, maxTokens: Int, options: AnthropicCompletionOptions) async throws -> String {
        try await complete(system: system, user: user, model: model, maxTokens: maxTokens)
    }

    /// Convenience for callers that don't need to pin a model.
    func complete(system: String? = nil, user: String) async throws -> String {
        try await complete(system: system, user: user, model: AnthropicModel.opus, maxTokens: 1024)
    }
}

/// BYOK Anthropic Messages API client over `URLSession`. The key is read from the
/// macOS Keychain at call time, never cached in the struct.
public struct AnthropicClient: MessageCompleting {
    private let keyStore: AnthropicKeyStore
    private let session: URLSession
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    public init(keyStore: AnthropicKeyStore = AnthropicKeyStore(), session: URLSession = .shared) {
        self.keyStore = keyStore
        self.session = session
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
        guard let key = keyStore.readKey(), !key.isEmpty else { throw AnthropicError.missingKey }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(AnthropicRequestVersions.messagesAPI, forHTTPHeaderField: "anthropic-version")
        let body = try Self.completionBodyData(
            system: system,
            user: user,
            model: model,
            maxTokens: maxTokens,
            options: options
        )
        _ = try options.cacheRequest(model: model, maxTokens: maxTokens, body: body)
        request.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AnthropicError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw AnthropicError.transport("No HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AnthropicError.http(http.statusCode, Self.errorMessage(from: data, status: http.statusCode))
        }

        let decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
        let text = decoded.content.filter { $0.type == "text" }.compactMap(\.text).joined()
        guard !text.isEmpty else { throw AnthropicError.emptyResponse }
        return text
    }

    private static func errorMessage(from data: Data, status: Int) -> String {
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
        try JSONEncoder().encode(
            AnthropicMessageRequestBody(
                model: model,
                maxTokens: maxTokens,
                temperature: options.temperature,
                system: system,
                messages: [.init(role: "user", content: user)]
            )
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
    }
}
