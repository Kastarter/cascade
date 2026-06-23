import Foundation

/// Groq-hosted model ids (OpenAI-compatible inference). Part of the model-
/// downgrade work — cheap, fast models for the pieces that don't need Claude:
/// the task planner and completion validators (text), and the on-screen thinker
/// (Scout, multimodal). See [[cascade-cu-downgrade-research]].
public enum GroqModel {
    /// Text-only, 128K ctx, ~$0.59/$0.79 per MTok. The planner + validators run here.
    public static let llama33_70b = "llama-3.3-70b-versatile"
    /// Multimodal (accepts images) — the vision thinker (Tier 2).
    public static let llama4Scout = "meta-llama/llama-4-scout-17b-16e-instruct"
    public static let llama4Maverick = "meta-llama/llama-4-maverick-17b-128e-instruct"
}

/// Picks the (client, model) for the downgraded helper tasks — the task planner
/// and the completion validators. Uses Groq llama-3.3-70b when a Groq key is
/// present (the cost win); otherwise falls back to the prior Anthropic haiku path
/// so the app still works with no Groq key. Both consumers fail gracefully (the
/// planner degrades to a single subtask, the validators fail open), so the swap
/// can never break a run. See [[cascade-cu-downgrade-research]].
public enum TextHelperModel {
    public static func resolve(
        anthropicKeyStore: AnthropicKeyStore = AnthropicKeyStore(),
        groqKeyStore: GroqKeyStore = GroqKeyStore()
    ) -> (client: any MessageCompleting, model: String) {
        if groqKeyStore.hasKey() {
            return (GroqClient(), GroqModel.llama33_70b)
        }
        return (AnthropicClient(keyStore: anthropicKeyStore), AnthropicModel.haiku)
    }
}

public enum GroqError: Error, LocalizedError {
    case missingKey
    case transport(String)
    case http(Int, String)
    case emptyResponse

    public var errorDescription: String? {
        switch self {
        case .missingKey: "Connect your Groq API key in Settings first."
        case .transport(let message): "Network error: \(message)"
        case .http(let code, let message): "Groq API error \(code): \(message)"
        case .emptyResponse: "Groq returned an empty response."
        }
    }
}

/// Keychain-backed store for the user's Groq API key.
public struct GroqKeyStore: Sendable {
    private let service = "com.humain.cascade"
    private let account = "groq-api-key"

    public init() {}

    public func hasKey() -> Bool { readKey() != nil }

    public func readKey() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func save(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProviderKeyStoreError.emptyKey }
        try? delete()
        var item = baseQuery()
        item[kSecValueData as String] = Data(trimmed.utf8)
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw ProviderKeyStoreError.unexpectedStatus(status) }
    }

    public func delete() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        if status == errSecItemNotFound { return }
        guard status == errSecSuccess else { throw ProviderKeyStoreError.unexpectedStatus(status) }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

/// BYOK Groq client over the OpenAI-compatible chat-completions API. Conforms to
/// `MessageCompleting`, so any text component already on that seam (the planner,
/// the validators) routes to a Groq model just by swapping the injected client +
/// model id — no call-site rewrite. The key is read from the Keychain at call
/// time, never cached in the struct (mirrors `AnthropicClient`).
public struct GroqClient: MessageCompleting {
    private let keyStore: GroqKeyStore
    private let session: URLSession
    private let endpoint = URL(string: "https://api.groq.com/openai/v1/chat/completions")!

    public init(keyStore: GroqKeyStore = GroqKeyStore(), session: URLSession = .shared) {
        self.keyStore = keyStore
        self.session = session
    }

    public func complete(
        system: String? = nil,
        user: String,
        model: String = GroqModel.llama33_70b,
        maxTokens: Int = 1024
    ) async throws -> String {
        guard let key = keyStore.readKey(), !key.isEmpty else { throw GroqError.missingKey }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "authorization")
        guard let body = try? JSONSerialization.data(
            withJSONObject: Self.requestBody(model: model, system: system, user: user, maxTokens: maxTokens)
        ) else { throw GroqError.transport("Couldn't encode the request.") }
        request.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw GroqError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw GroqError.transport("No HTTP response.") }
        guard (200..<300).contains(http.statusCode) else {
            throw GroqError.http(http.statusCode, Self.errorMessage(from: data, status: http.statusCode))
        }
        guard let text = Self.parseContent(data), !text.isEmpty else { throw GroqError.emptyResponse }
        return text
    }

    /// OpenAI chat-completions request body: a system message (when present) then
    /// the user message. `temperature: 0` for deterministic planner/validator
    /// output. Pure + pinned.
    static func requestBody(model: String, system: String?, user: String, maxTokens: Int) -> [String: Any] {
        var messages: [[String: String]] = []
        if let system, !system.isEmpty { messages.append(["role": "system", "content": system]) }
        messages.append(["role": "user", "content": user])
        return ["model": model, "max_tokens": maxTokens, "temperature": 0, "messages": messages]
    }

    /// Extracts `choices[0].message.content` from an OpenAI-compatible reply. Pure
    /// + pinned. (Content can be a string or, rarely, an array of parts.)
    static func parseContent(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else { return nil }
        if let content = message["content"] as? String {
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let parts = message["content"] as? [[String: Any]] {
            return parts.compactMap { $0["text"] as? String }.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    static func errorMessage(from data: Data, status: Int) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        return String(data: data, encoding: .utf8) ?? "Status \(status)"
    }
}
