import Foundation

/// One validated SIEM export unit derived from an already-rendered OTel trace.
public struct SIEMExportRecord: Equatable, Sendable {
    public let byteSize: Int
    public let spanCount: Int

    public init(byteSize: Int, spanCount: Int) {
        self.byteSize = byteSize
        self.spanCount = spanCount
    }
}

/// Stub over the EXISTING trace export. GovernanceKit cannot import
/// AgentOrchestrator (not in its dependency set), so it consumes the rendered
/// OTel JSON string — AppShell feeds `AgentTrace.otelJSON()` into it later; no
/// wiring beyond this stub in this task. The constants mirror the OTel GenAI
/// attribute names `AgentTrace.otelJSON()` already emits (AgentTrace.swift:550-565).
public struct SIEMExporter: Sendable {
    /// OTel GenAI semantic-convention attribute names, as emitted by AgentTrace.
    public enum GenAIAttribute {
        public static let operationName = "gen_ai.operation.name"
        public static let providerName = "gen_ai.provider.name"
        public static let requestModel = "gen_ai.request.model"
        public static let usageInputTokens = "gen_ai.usage.input_tokens"
    }

    public init() {}

    /// Validates the OTLP JSON envelope (`resourceSpans` → `scopeSpans` → `spans`)
    /// and returns a record with the payload byte size and total span count.
    /// Malformed input ⇒ `nil` (never throws, never crashes).
    public func makeRecord(fromOTelJSON json: String) -> SIEMExportRecord? {
        guard let data = json.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let resourceSpans = root["resourceSpans"] as? [[String: Any]] else {
            return nil
        }
        var spanCount = 0
        for resource in resourceSpans {
            guard let scopeSpans = resource["scopeSpans"] as? [[String: Any]] else { continue }
            for scope in scopeSpans {
                spanCount += (scope["spans"] as? [[String: Any]])?.count ?? 0
            }
        }
        return SIEMExportRecord(byteSize: data.count, spanCount: spanCount)
    }
}
