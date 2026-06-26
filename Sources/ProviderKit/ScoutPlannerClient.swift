import Foundation

/// Scout planner model ids (served OpenAI-compatible over OpenRouter). The Scout
/// brain plans the next on-screen action and NAMES its target; a dedicated grounder
/// (UI-TARS) turns the name into a pixel. Swappable without a rebuild via
/// `cascade.scout.model`. See [[cascade-cu-downgrade-research]].
public enum ScoutModel {
    /// Qwen3.7 Plus — MULTIMODAL (text + image), 1M ctx, built to "read screens and
    /// interact with GUIs." The DEFAULT Scout brain: it SEES the screenshot (with AX
    /// + OCR text marks alongside) and names targets. ~$0.32/$1.28 per MTok.
    public static let qwen37Plus = "qwen/qwen3.7-plus"
    /// GLM-5.2 — TEXT-ONLY alternative (1M ctx). Pair with `cascade.scout.vision =
    /// false` (it can't accept an image): the screen reaches it as AX + OCR text only.
    public static let glm5_2 = "z-ai/glm-5.2"
}

public enum ScoutPlannerError: Error, LocalizedError {
    case missingKey
    case transport(String)
    case http(Int, String)
    case emptyResponse

    public var errorDescription: String? {
        switch self {
        case .missingKey: "Connect your OpenRouter API key in Settings to use the Scout brain."
        case .transport(let message): "Network error: \(message)"
        case .http(402, _): "Your OpenRouter account is out of credits — top it up to run the Scout (Qwen) agent."
        case .http(let code, let message): "Scout planner API error \(code): \(message)"
        case .emptyResponse: "The Scout planner returned an empty response."
        }
    }
}

/// BYOK Scout planner client over an OpenAI-compatible chat-completions endpoint
/// (OpenRouter by default). This is the PLANNING channel for the downgraded
/// on-screen thinker: the planner decides WHAT to do; UI-TARS grounds WHERE. The
/// current user turn is MULTIMODAL when an `imageJPEG` is supplied (a vision model
/// like Qwen3.7 Plus SEES the screenshot, with AX + OCR text marks alongside) and
/// plain TEXT when it isn't (a text-only model like GLM-5.2 plans from the
/// screen-as-text only). Prior (user, assistant) turns are always replayed as plain
/// text — old frames are never resent (words-only memory). Transport is hardened
/// (fresh connection per call + retry on transient TLS/5xx/429) so one network blip
/// never silently ends a run. Reuses GroqClient's OpenAI-compatible parsers.
public struct ScoutPlannerClient: Sendable {
    private let keyStore: OpenRouterKeyStore
    private let session: URLSession
    private let endpoint: URL

    public init(
        keyStore: OpenRouterKeyStore = OpenRouterKeyStore(),
        endpoint: URL = URL(string: "https://openrouter.ai/api/v1/chat/completions")!,
        session: URLSession = .shared
    ) {
        self.keyStore = keyStore
        self.endpoint = endpoint
        self.session = session
    }

    /// The Scout planner model — `qwen/qwen3.7-plus` by default, swappable without a
    /// rebuild via `cascade.scout.model`.
    public static func scoutModel() -> String {
        UserDefaults.standard.string(forKey: "cascade.scout.model")
            .flatMap { $0.isEmpty ? nil : $0 } ?? ScoutModel.qwen37Plus
    }

    /// The Scout planner endpoint — OpenRouter by default; override with
    /// `cascade.scout.endpoint` for another OpenAI-compatible host. A custom host
    /// still reads the OpenRouter-key slot in the Keychain.
    public static func scoutEndpoint() -> URL {
        let raw = UserDefaults.standard.string(forKey: "cascade.scout.endpoint")
        return raw.flatMap { $0.isEmpty ? nil : URL(string: $0) }
            ?? URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    }

    /// Whether the Scout planner is MULTIMODAL (sees the screenshot). Default true —
    /// the default model (Qwen3.7 Plus) is multimodal. Set `cascade.scout.vision =
    /// false` when pointing `cascade.scout.model` at a text-only model (GLM-5.2),
    /// which would otherwise reject the image; the screen then reaches it as AX + OCR
    /// text only.
    public static func visionEnabled() -> Bool {
        (UserDefaults.standard.object(forKey: "cascade.scout.vision") as? Bool) ?? true
    }

    /// One planner turn: optional `system`, replayed `prior` TEXT turns, then the
    /// current `user` message. With `imageJPEG` the current turn is multimodal (text +
    /// image, instruction first for better grounding); without it, plain text.
    public func complete(
        system: String?,
        user: String,
        imageJPEG: Data? = nil,
        model: String = ScoutModel.qwen37Plus,
        maxTokens: Int = 1500,
        prior: [(user: String, assistant: String)] = []
    ) async throws -> String {
        guard let key = keyStore.readKey(), !key.isEmpty else { throw ScoutPlannerError.missingKey }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "authorization")
        // Fresh connection per planner call — a stale keep-alive socket is the usual
        // source of the "network connection lost" / TLS errors that used to kill a run
        // on its very first turn.
        request.setValue("close", forHTTPHeaderField: "connection")
        // The request body is rebuildable so a 402 (insufficient credits) can retry
        // once with fewer tokens — OpenRouter reserves credits against max_tokens.
        var effectiveMax = maxTokens
        var creditReduced = false
        func encodeBody() -> Data? {
            try? JSONSerialization.data(
                withJSONObject: Self.requestBody(model: model, system: system, user: user, imageJPEG: imageJPEG, maxTokens: effectiveMax, prior: prior)
            )
        }
        guard let body = encodeBody() else { throw ScoutPlannerError.transport("Couldn't encode the request.") }
        request.httpBody = body

        // Retry transient transport failures (network lost / TLS / 5xx / 408 / 429):
        // a single blip should not throw straight through to step.failed and end the
        // run silently. 4 attempts, 400ms backoff; non-retryable 4xx give up at once.
        var lastError = ScoutPlannerError.transport("unreachable")
        for attempt in 0..<4 {
            do {
                let (data, response) = try await session.data(for: request)
                let http = response as? HTTPURLResponse
                if let http, (200..<300).contains(http.statusCode) {
                    guard let text = GroqClient.parseContent(data), !text.isEmpty else { throw ScoutPlannerError.emptyResponse }
                    return text
                }
                // 402 = "requires more credits, or fewer max_tokens": the balance can't
                // reserve this request. Try ONCE with far fewer tokens (a single action
                // JSON still fits) so a low-balance account isn't dead on the first turn.
                if let http, http.statusCode == 402, !creditReduced, effectiveMax > 700 {
                    creditReduced = true
                    effectiveMax = 700
                    if let smaller = encodeBody() { request.httpBody = smaller }
                    continue
                }
                // Client errors (bad request / auth / unaffordable) won't improve on
                // retry — surface now.
                if let http, (400..<500).contains(http.statusCode), http.statusCode != 408, http.statusCode != 429 {
                    throw ScoutPlannerError.http(http.statusCode, GroqClient.errorMessage(from: data, status: http.statusCode))
                }
                lastError = http.map { ScoutPlannerError.http($0.statusCode, GroqClient.errorMessage(from: data, status: $0.statusCode)) }
                    ?? .transport("No HTTP response.")
            } catch let e as ScoutPlannerError {
                throw e  // emptyResponse / non-retryable 4xx — surface immediately
            } catch {
                lastError = .transport(error.localizedDescription)  // URLSession transport error — retry
            }
            if attempt < 3 { try? await Task.sleep(for: .milliseconds(400)) }
        }
        throw lastError
    }

    /// OpenAI chat-completions request body: an optional system message, the prior
    /// TEXT turns, then the current user turn — multimodal (text + base64 image, text
    /// FIRST) when `imageJPEG` is present, else plain text. `temperature: 0` for
    /// deterministic planner output. Pure + pinned.
    static func requestBody(
        model: String, system: String?, user: String, imageJPEG: Data?, maxTokens: Int,
        prior: [(user: String, assistant: String)] = []
    ) -> [String: Any] {
        var messages: [[String: Any]] = []
        if let system, !system.isEmpty { messages.append(["role": "system", "content": system]) }
        for turn in prior {
            messages.append(["role": "user", "content": turn.user])
            messages.append(["role": "assistant", "content": turn.assistant])
        }
        if let imageJPEG {
            let dataURL = "data:image/jpeg;base64,\(imageJPEG.base64EncodedString())"
            messages.append([
                "role": "user",
                "content": [
                    ["type": "text", "text": user],
                    ["type": "image_url", "image_url": ["url": dataURL]],
                ],
            ])
        } else {
            messages.append(["role": "user", "content": user])
        }
        return ["model": model, "max_tokens": maxTokens, "temperature": 0, "messages": messages]
    }
}
