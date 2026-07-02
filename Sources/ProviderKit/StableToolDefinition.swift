import Foundation

/// Shared shape for Cascade-owned custom tools. Anthropic's built-in computer tool
/// is intentionally not routed through this helper because its schema is provider
/// defined.
public enum StableToolDefinition {
    public static func strict(
        _ definition: [String: Any],
        examples: [[String: Any]] = []
    ) -> [String: Any] {
        var out = definition
        out["strict"] = true
        var schema = out["input_schema"] as? [String: Any] ?? [
            "type": "object",
            "properties": [String: Any](),
        ]
        if schema["type"] == nil { schema["type"] = "object" }
        if schema["properties"] == nil { schema["properties"] = [String: Any]() }
        schema["additionalProperties"] = false
        out["input_schema"] = schema
        if !examples.isEmpty {
            out["input_examples"] = examples
        }
        return out
    }

    public static func strictAll(_ definitions: [[String: Any]]) -> [[String: Any]] {
        definitions.map { strict($0) }
    }
}

/// Machine-readable non-success tool_result text. Successful untrusted payloads
/// should keep using InjectionGuard envelopes so their trust boundary stays explicit.
public enum ToolResultStatusEnvelope {
    public enum Status: String, Codable, Sendable, Equatable {
        case error
        case refused
        case noResult = "no_result"
    }

    public struct Parsed: Sendable, Equatable {
        public let status: Status
        public let kind: String
        public let message: String
        public let tool: String?

        public init(status: Status, kind: String, message: String, tool: String? = nil) {
            self.status = status
            self.kind = kind
            self.message = message
            self.tool = tool
        }
    }

    public static func render(
        _ status: Status,
        kind: String,
        message: String,
        tool: String? = nil
    ) -> String {
        var object: [String: Any] = [
            "status": status.rawValue,
            "kind": kind,
            "message": message,
        ]
        if let tool { object["tool"] = tool }
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "[tool_result status=\(status.rawValue) kind=\(kind)] \(message)"
        }
        return text
    }

    public static func parse(_ rendered: String) -> Parsed? {
        guard let data = rendered.data(using: .utf8),
              let object = try? JSONDecoder().decode(StatusDTO.self, from: data) else {
            return nil
        }
        return Parsed(
            status: object.status,
            kind: object.kind,
            message: object.message,
            tool: object.tool
        )
    }

    private struct StatusDTO: Decodable {
        let status: Status
        let kind: String
        let message: String
        let tool: String?
    }
}
