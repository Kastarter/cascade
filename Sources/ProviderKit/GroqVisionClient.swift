import Foundation

/// BYOK Groq multimodal client — sends a screenshot + prompt to a vision model
/// (Llama 4 Scout/Maverick) over the OpenAI-compatible chat-completions API and
/// returns the text reply. This is the PERCEPTION + PLANNING channel for the
/// downgraded on-screen thinker (Tier 2): Scout decides WHAT to do from the
/// screen; UI-TARS grounds WHERE. Reuses GroqKeyStore / GroqError /
/// GroqClient.parseContent. See [[cascade-cu-downgrade-research]].
public struct GroqVisionClient: Sendable {
    private let keyStore: GroqKeyStore
    private let session: URLSession
    private let endpoint = URL(string: "https://api.groq.com/openai/v1/chat/completions")!

    public init(keyStore: GroqKeyStore = GroqKeyStore(), session: URLSession = .shared) {
        self.keyStore = keyStore
        self.session = session
    }

    /// One multimodal turn: `user` text + one JPEG screenshot. `prior` carries the
    /// session's earlier (user, assistant) turns as plain text replayed ahead of
    /// the current frame — old screenshots are never resent (the same words-only
    /// memory pattern the Claude agent uses).
    public func complete(
        system: String?,
        user: String,
        imageJPEG: Data,
        model: String = GroqModel.llama4Scout,
        maxTokens: Int = 1024,
        prior: [(user: String, assistant: String)] = []
    ) async throws -> String {
        guard let key = keyStore.readKey(), !key.isEmpty else { throw GroqError.missingKey }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "authorization")
        guard let body = try? JSONSerialization.data(
            withJSONObject: Self.requestBody(model: model, system: system, user: user, imageJPEG: imageJPEG, maxTokens: maxTokens, prior: prior)
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
            throw GroqError.http(http.statusCode, GroqClient.errorMessage(from: data, status: http.statusCode))
        }
        guard let text = GroqClient.parseContent(data), !text.isEmpty else { throw GroqError.emptyResponse }
        return text
    }

    /// OpenAI multimodal request body: optional system message, prior text turns,
    /// then the current user turn carrying text + one `image_url` (base64 data
    /// URL). Pure + pinned. Instruction text precedes the image (better grounding).
    static func requestBody(
        model: String, system: String?, user: String, imageJPEG: Data, maxTokens: Int,
        prior: [(user: String, assistant: String)] = []
    ) -> [String: Any] {
        var messages: [[String: Any]] = []
        if let system, !system.isEmpty { messages.append(["role": "system", "content": system]) }
        for turn in prior {
            messages.append(["role": "user", "content": turn.user])
            messages.append(["role": "assistant", "content": turn.assistant])
        }
        let dataURL = "data:image/jpeg;base64,\(imageJPEG.base64EncodedString())"
        messages.append([
            "role": "user",
            "content": [
                ["type": "text", "text": user],
                ["type": "image_url", "image_url": ["url": dataURL]],
            ],
        ])
        return ["model": model, "max_tokens": maxTokens, "temperature": 0, "messages": messages]
    }
}
