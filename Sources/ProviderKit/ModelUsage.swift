import Foundation

public struct ModelUsage: Sendable, Equatable, Codable {
    public var provider: String
    public var model: String
    public var responseID: String?
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheWriteTokens: Int
    public var reasoningTokens: Int
    public var priceCardVersion: String
    public var costMicrousd: Int64

    public init(
        provider: String = "",
        model: String = "",
        responseID: String? = nil,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        cacheWriteTokens: Int = 0,
        reasoningTokens: Int = 0,
        priceCardVersion: String = ModelPriceCard.defaultVersion,
        costMicrousd: Int64 = 0
    ) {
        self.provider = provider
        self.model = model
        self.responseID = responseID
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.reasoningTokens = reasoningTokens
        self.priceCardVersion = priceCardVersion
        self.costMicrousd = costMicrousd
    }

    public var cacheReadInputTokens: Int {
        get { cacheReadTokens }
        set { cacheReadTokens = newValue }
    }

    public var cacheCreationInputTokens: Int {
        get { cacheWriteTokens }
        set { cacheWriteTokens = newValue }
    }

    public var cacheCreationTokens: Int { cacheWriteTokens }

    public var reasoningOutputTokens: Int {
        get { reasoningTokens }
        set { reasoningTokens = newValue }
    }
}

public struct ModelPriceCard: Sendable, Equatable, Codable {
    public static let defaultVersion = "illustrative-2026-06"

    public let provider: String
    public let model: String
    public let version: String
    public let inputPerMTokMicrousd: Int64
    public let outputPerMTokMicrousd: Int64
    public let cacheReadPerMTokMicrousd: Int64
    public let cacheWritePerMTokMicrousd: Int64
    public let reasoningPerMTokMicrousd: Int64

    public init(
        provider: String = "anthropic",
        model: String = "",
        version: String = Self.defaultVersion,
        inputPerMTokMicrousd: Int64,
        outputPerMTokMicrousd: Int64,
        cacheReadPerMTokMicrousd: Int64,
        cacheWritePerMTokMicrousd: Int64,
        reasoningPerMTokMicrousd: Int64 = 0
    ) {
        self.provider = provider
        self.model = model
        self.version = version
        self.inputPerMTokMicrousd = inputPerMTokMicrousd
        self.outputPerMTokMicrousd = outputPerMTokMicrousd
        self.cacheReadPerMTokMicrousd = cacheReadPerMTokMicrousd
        self.cacheWritePerMTokMicrousd = cacheWritePerMTokMicrousd
        self.reasoningPerMTokMicrousd = reasoningPerMTokMicrousd
    }

    public static func illustrativeAnthropic(model: String) -> ModelPriceCard {
        let lower = model.lowercased()
        if lower.contains("haiku") {
            return ModelPriceCard(
                provider: "anthropic",
                model: model,
                inputPerMTokMicrousd: 1_000_000,
                outputPerMTokMicrousd: 5_000_000,
                cacheReadPerMTokMicrousd: 100_000,
                cacheWritePerMTokMicrousd: 1_250_000
            )
        }
        if lower.contains("sonnet") {
            return ModelPriceCard(
                provider: "anthropic",
                model: model,
                inputPerMTokMicrousd: 3_000_000,
                outputPerMTokMicrousd: 15_000_000,
                cacheReadPerMTokMicrousd: 300_000,
                cacheWritePerMTokMicrousd: 3_750_000
            )
        }
        return ModelPriceCard(
            provider: "anthropic",
            model: model,
            inputPerMTokMicrousd: 15_000_000,
            outputPerMTokMicrousd: 75_000_000,
            cacheReadPerMTokMicrousd: 1_500_000,
            cacheWritePerMTokMicrousd: 18_750_000
        )
    }

    public func costMicrousd(_ usage: ModelUsage) -> Int64 {
        func line(_ tokens: Int, _ rate: Int64) -> Int64 {
            guard tokens > 0, rate > 0 else { return 0 }
            return (Int64(tokens) * rate + 999_999) / 1_000_000
        }
        return line(usage.inputTokens, inputPerMTokMicrousd)
            + line(usage.outputTokens, outputPerMTokMicrousd)
            + line(usage.cacheReadTokens, cacheReadPerMTokMicrousd)
            + line(usage.cacheWriteTokens, cacheWritePerMTokMicrousd)
            + line(usage.reasoningTokens, reasoningPerMTokMicrousd)
    }
}

public struct ModelPricing: Sendable, Equatable {
    public let inputPerMTok: Double
    public let outputPerMTok: Double
    public let cacheReadPerMTok: Double
    public let cacheWritePerMTok: Double

    public init(inputPerMTok: Double, outputPerMTok: Double, cacheReadPerMTok: Double, cacheWritePerMTok: Double) {
        self.inputPerMTok = inputPerMTok
        self.outputPerMTok = outputPerMTok
        self.cacheReadPerMTok = cacheReadPerMTok
        self.cacheWritePerMTok = cacheWritePerMTok
    }

    public func cost(_ usage: ModelUsage) -> Double {
        (
            Double(usage.inputTokens) * inputPerMTok
            + Double(usage.outputTokens) * outputPerMTok
            + Double(usage.cacheReadTokens) * cacheReadPerMTok
            + Double(usage.cacheWriteTokens) * cacheWritePerMTok
        ) / 1_000_000.0
    }
}

extension AnthropicUsage {
    public func normalized(model: String, responseID: String? = nil, priceCard: ModelPriceCard? = nil) -> ModelUsage {
        let card = priceCard ?? .illustrativeAnthropic(model: model)
        var usage = ModelUsage(
            provider: "anthropic",
            model: model,
            responseID: responseID,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadInputTokens,
            cacheWriteTokens: cacheCreationInputTokens,
            priceCardVersion: card.version
        )
        usage.costMicrousd = card.costMicrousd(usage)
        return usage
    }
}
