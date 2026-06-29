import CascadeMemory
import Foundation

public struct TraceFailureCluster: Sendable, Equatable, Codable {
    public let key: String
    public let failureKind: AgentFailureKind
    public let surface: String
    public let appName: String?
    public let toolName: String?
    public let targetTier: String?
    public let recoveryAction: RecoveryAction
    public let traceIDs: [String]
    public let count: Int

    public init(
        key: String,
        failureKind: AgentFailureKind,
        surface: String,
        appName: String? = nil,
        toolName: String? = nil,
        targetTier: String? = nil,
        recoveryAction: RecoveryAction,
        traceIDs: [String]
    ) {
        self.key = key
        self.failureKind = failureKind
        self.surface = surface
        self.appName = appName
        self.toolName = toolName
        self.targetTier = targetTier
        self.recoveryAction = recoveryAction
        self.traceIDs = traceIDs.sorted()
        self.count = traceIDs.count
    }

    public var recoveryEvidenceHash: String {
        Self.stableHash(key)
    }

    public func failureMemoryCandidate(minCount: Int = 2) -> CascadeMemory.AgentFailureMemory? {
        guard count >= minCount else { return nil }
        let memoryKind = CascadeMemory.AgentFailureKind(rawValue: failureKind.rawValue) ?? .unknown
        let tokens = Self.goalTokens(surface: surface, appName: appName, toolName: toolName)
        return CascadeMemory.AgentFailureMemory(
            appName: appName ?? surface,
            normalizedGoalTokens: tokens,
            failureKind: memoryKind,
            firstBadAction: toolName,
            screenSignatureHash: targetTier.map { "target-tier:\($0)" },
            targetHash: targetTier,
            stateSummary: Self.stateSummary(failureKind: failureKind, surface: surface, toolName: toolName, targetTier: targetTier),
            repairHint: Self.repairHint(action: recoveryAction),
            recoveryEvidenceHash: recoveryEvidenceHash
        )
    }

    private static func goalTokens(surface: String, appName: String?, toolName: String?) -> [String] {
        let raw = [surface, appName, toolName]
            .compactMap { $0 }
            .flatMap { $0.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init) }
            .filter { $0.count >= 3 && !PrivacyRules.isSensitiveText($0) }
        return Array(Set(raw)).sorted()
    }

    private static func stateSummary(
        failureKind: AgentFailureKind,
        surface: String,
        toolName: String?,
        targetTier: String?
    ) -> String {
        [
            "failure=\(failureKind.rawValue)",
            "surface=\(surface)",
            toolName.map { "tool=\($0)" },
            targetTier.map { "targetTier=\($0)" },
        ].compactMap { $0 }.joined(separator: " ")
    }

    private static func repairHint(action: RecoveryAction) -> String {
        switch action {
        case .reharvestAX:
            return "Refresh accessibility candidates before retrying the target."
        case .regroundVisual:
            return "Use visual grounding as the fallback target source."
        case .recapture:
            return "Recapture the screen before deciding the action had no effect."
        case .alternateTarget:
            return "Choose a different visible target for the same intent."
        case .safeDismiss:
            return "Pause or dismiss only a known safe modal before continuing."
        case .diagnosticProbe:
            return "Run a narrow diagnostic probe before another action."
        case .rerunVerifier:
            return "Re-run the verifier with focused evidence."
        case .backoffRetry:
            return "Retry after transient backoff."
        case .retryOnce:
            return "Retry once, then stop if the same failure repeats."
        case .escalate:
            return "Escalate to the assist loop when deterministic replay is brittle."
        case .pauseForUser:
            return "Pause and show evidence to the user."
        case .failWithReason:
            return "Stop with a clear failure reason."
        case .refuse:
            return "Refuse unsafe work."
        case .stop:
            return "Honor the user stop."
        case .none:
            return "Do not retry automatically."
        }
    }

    private static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}

public enum TraceFailureClusterer {
    public static func clusters(from traces: [AgentTrace], minCount: Int = 2) -> [TraceFailureCluster] {
        var buckets: [String: (kind: AgentFailureKind, surface: String, app: String?, tool: String?, tier: String?, traces: Set<String>)] = [:]
        for trace in traces {
            guard let failureKind = trace.scenarioOutcome.failureKind else { continue }
            let app = safeAttribute(["app", "app_name"], in: trace)
            let tool = safeAttribute(["tool.name", "tool_name"], in: trace)
            let tier = trace.scenarioOutcome.targetTier
            let recovery = AgentRecoveryPolicy.plan(for: failureKind).terminal
            let key = [failureKind.rawValue, trace.surface, app ?? "", tool ?? "", tier ?? "", recovery.rawValue]
                .joined(separator: "|")
            var bucket = buckets[key] ?? (failureKind, trace.surface, app, tool, tier, [])
            bucket.traces.insert(trace.traceID)
            buckets[key] = bucket
        }
        return buckets.map { key, bucket in
            TraceFailureCluster(
                key: key,
                failureKind: bucket.kind,
                surface: bucket.surface,
                appName: bucket.app,
                toolName: bucket.tool,
                targetTier: bucket.tier,
                recoveryAction: AgentRecoveryPolicy.plan(for: bucket.kind).terminal,
                traceIDs: Array(bucket.traces)
            )
        }
        .filter { $0.count >= minCount }
        .sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            return $0.key < $1.key
        }
    }

    private static func safeAttribute(_ keys: [String], in trace: AgentTrace) -> String? {
        for span in trace.spans {
            for key in keys {
                guard let value = span.attributes[key],
                      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !PrivacyRules.isSensitiveText(value) else { continue }
                return value
            }
        }
        return nil
    }
}
