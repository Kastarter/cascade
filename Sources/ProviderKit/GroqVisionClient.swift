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
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "authorization")
        // Fresh connection per planner call — a stale keep-alive socket is the
        // usual source of the "network connection lost" / TLS errors that used
        // to kill the whole Scout run on the very first turn.
        request.setValue("close", forHTTPHeaderField: "connection")
        guard let body = try? JSONSerialization.data(
            withJSONObject: Self.requestBody(model: model, system: system, user: user, imageJPEG: imageJPEG, maxTokens: maxTokens, prior: prior)
        ) else { throw GroqError.transport("Couldn't encode the request.") }
        request.httpBody = body

        // Retry transient transport failures (network lost / TLS / 5xx / 408 / 429):
        // a single blip used to throw straight through to step.failed and end the
        // Scout run silently — which is exactly why Scout "stopped suddenly" while
        // Claude (a more reliable connection, no such death) kept going. Mirrors
        // UITARSGrounder's retry: 4 attempts, 400ms backoff, non-retryable 4xx give up.
        var lastError = GroqError.transport("unreachable")
        for attempt in 0..<4 {
            do {
                let (data, response) = try await session.data(for: request)
                let http = response as? HTTPURLResponse
                if let http, (200..<300).contains(http.statusCode) {
                    guard let text = GroqClient.parseContent(data), !text.isEmpty else { throw GroqError.emptyResponse }
                    return text
                }
                // Client errors (bad request / auth) won't improve on retry — surface now.
                if let http, (400..<500).contains(http.statusCode), http.statusCode != 408, http.statusCode != 429 {
                    throw GroqError.http(http.statusCode, GroqClient.errorMessage(from: data, status: http.statusCode))
                }
                lastError = http.map { GroqError.http($0.statusCode, GroqClient.errorMessage(from: data, status: $0.statusCode)) }
                    ?? .transport("No HTTP response.")
            } catch let e as GroqError {
                throw e  // emptyResponse / non-retryable 4xx — surface immediately
            } catch {
                lastError = .transport(error.localizedDescription)  // URLSession transport error — retry
            }
            if attempt < 3 { try? await Task.sleep(for: .milliseconds(400)) }
        }
        throw lastError
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
