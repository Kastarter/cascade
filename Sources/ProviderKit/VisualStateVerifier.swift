import Foundation

public struct VisualStateVerifierResult: Codable, Equatable, Sendable {
    public enum Verdict: String, Codable, Equatable, Sendable {
        case verified
        case negative
        case uncertain
    }

    public let verdict: Verdict
    public let state: String
    public let nextStrategy: String

    enum CodingKeys: String, CodingKey {
        case verdict
        case state
        case nextStrategy = "next_strategy"
    }

    public init(verdict: Verdict, state: String, nextStrategy: String) {
        self.verdict = verdict
        self.state = state
        self.nextStrategy = nextStrategy
    }
}

public struct VisualStateVerifier {
    private let client: AnthropicMessagesClient
    private let model: String

    public init(
        client: AnthropicMessagesClient = AnthropicMessagesClient(),
        model: String = AnthropicModel.haiku
    ) {
        self.client = client
        self.model = model
    }

    public func verify(
        goal: String,
        clickTarget: String,
        expectedState: String?,
        currentScreenshotJPEG: Data,
        visibleContext: String? = nil
    ) async throws -> VisualStateVerifierResult {
        let prompt = """
        The GUI agent clicked a visually grounded target while trying to complete this task:
        \(goal)

        Click target:
        \(clickTarget)

        Expected immediate result:
        \(expectedState ?? "A relevant menu, dialog, field focus, page, or visible state should appear.")

        Current screen context:
        \(visibleContext ?? "(none)")

        Look at the screenshot and return ONLY compact JSON in this exact shape:
        {"verdict":"verified|negative|uncertain","state":"<what visibly happened>","next_strategy":"<one concrete safer next approach>"}
        Use "negative" only when the expected state clearly did not appear. Keep state and next_strategy under 120 characters.
        """
        let messages: [[String: Any]] = [[
            "role": "user",
            "content": [
                ["type": "text", "text": prompt],
                ["type": "image", "source": [
                    "type": "base64",
                    "media_type": "image/jpeg",
                    "data": currentScreenshotJPEG.base64EncodedString(),
                ]],
            ],
        ]]
        _ = try? await client.countTokens(
            model: model,
            maxTokens: 220,
            messages: messages,
            temperature: 0
        )
        let response = try await client.send(
            model: model,
            maxTokens: 220,
            messages: messages,
            temperature: 0,
            timeout: 20
        )
        return try Self.parse(response.text)
    }

    public static func parse(_ raw: String) throws -> VisualStateVerifierResult {
        guard let start = raw.firstIndex(of: "{"),
              let end = raw.lastIndex(of: "}"),
              start <= end,
              let data = String(raw[start...end]).data(using: .utf8) else {
            throw AnthropicError.emptyResponse
        }
        let decoded = try JSONDecoder().decode(VisualStateVerifierResult.self, from: data)
        return VisualStateVerifierResult(
            verdict: decoded.verdict,
            state: String(decoded.state.prefix(120)),
            nextStrategy: String(decoded.nextStrategy.prefix(120))
        )
    }
}
