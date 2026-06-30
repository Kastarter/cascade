import CryptoKit
import Foundation

public enum AnthropicRequestBuilder {
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
        try AnthropicMessagesClient.bodyData(
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
    }

    public static func stablePrefixHash(system: Any? = nil, tools: [[String: Any]]? = nil) throws -> String {
        var prefix: [String: Any] = [:]
        if let tools {
            prefix["tools"] = tools
        }
        if let system {
            prefix["system"] = stableSystemPrefix(system)
        }
        let data = try JSONSerialization.data(withJSONObject: prefix, options: [.sortedKeys])
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func stableSystemPrefix(_ system: Any) -> Any {
        guard let blocks = system as? [[String: Any]] else { return system }
        var stable: [[String: Any]] = []
        for block in blocks {
            stable.append(block)
            if block["cache_control"] != nil { break }
        }
        return stable
    }
}
