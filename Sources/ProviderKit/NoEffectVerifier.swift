import Foundation

public struct NoEffectVerifierResult: Codable, Equatable, Sendable {
    public let state: String
    public let nextStrategy: String
    public let avoid: String

    enum CodingKeys: String, CodingKey {
        case state
        case nextStrategy = "next_strategy"
        case avoid
    }

    public init(state: String, nextStrategy: String, avoid: String) {
        self.state = state
        self.nextStrategy = nextStrategy
        self.avoid = avoid
    }
}

public struct NoEffectVerifier {
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
        lastAction: String,
        currentScreenshotJPEG: Data,
        visibleContext: String? = nil
    ) async throws -> NoEffectVerifierResult {
        let prompt = """
        The GUI agent is trying to complete this task:
        \(goal)

        Its last action appears to have had no visible effect:
        \(lastAction)

        Current screen context:
        \(visibleContext ?? "(none)")

        Look at the screenshot and return ONLY compact JSON in this exact shape:
        {"state":"<what seems true now>","next_strategy":"<one concrete next approach>","avoid":"<what not to repeat>"}
        Keep each field under 120 characters. If unsure, set state to "uncertain" and still suggest a different safe strategy.
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

    public static func parse(_ raw: String) throws -> NoEffectVerifierResult {
        guard let start = raw.firstIndex(of: "{"),
              let end = raw.lastIndex(of: "}"),
              start <= end,
              let data = String(raw[start...end]).data(using: .utf8) else {
            throw AnthropicError.emptyResponse
        }
        let decoded = try JSONDecoder().decode(NoEffectVerifierResult.self, from: data)
        return NoEffectVerifierResult(
            state: String(decoded.state.prefix(120)),
            nextStrategy: String(decoded.nextStrategy.prefix(120)),
            avoid: String(decoded.avoid.prefix(120))
        )
    }
}
