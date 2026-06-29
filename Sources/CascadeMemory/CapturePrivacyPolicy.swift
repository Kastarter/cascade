import Foundation

public struct CapturePrivacyDecision: Equatable, Sendable {
    public let allowed: Bool
    public let reason: String?

    public static let allow = CapturePrivacyDecision(allowed: true, reason: nil)

    public static func deny(_ reason: String) -> CapturePrivacyDecision {
        CapturePrivacyDecision(allowed: false, reason: reason)
    }
}

public struct CaptureRetentionPolicy: Codable, Equatable, Sendable {
    public var maxAgeDays: Int?
    public var maxBytes: Int64?

    public init(maxAgeDays: Int? = nil, maxBytes: Int64? = nil) {
        self.maxAgeDays = maxAgeDays
        self.maxBytes = maxBytes
    }
}

/// Local, JSON-serializable capture policy. The default preserves the historical
/// `PrivacyRules` keyword behavior while giving managed deployments explicit app,
/// bundle, window-title, private-mode, and per-data-class retention knobs.
public struct CapturePrivacyPolicy: Codable, Equatable, Sendable {
    public static let defaultVersion = "capture-policy-v1"

    public var version: String
    public var recordingAvailable: Bool
    public var privateModeEnabled: Bool
    public var backgroundWebRunsAvailable: Bool
    public var scheduledRunsAvailable: Bool
    public var powerHarnessAvailable: Bool
    public var recordRecallAvailable: Bool
    public var forceIrreversibleActionGuard: Bool
    public var sensitiveKeywords: [String]
    public var deniedAppNames: [String]
    public var deniedBundleIdentifiers: [String]
    public var deniedWindowTitleKeywords: [String]
    public var deniedURLHosts: [String]
    public var deniedURLKeywords: [String]
    public var allowedBundleIdentifiers: [String]
    public var retentionByDataClass: [String: CaptureRetentionPolicy]

    private enum CodingKeys: String, CodingKey {
        case version
        case recordingAvailable
        case privateModeEnabled
        case backgroundWebRunsAvailable
        case scheduledRunsAvailable
        case powerHarnessAvailable
        case recordRecallAvailable
        case forceIrreversibleActionGuard
        case sensitiveKeywords
        case deniedAppNames
        case deniedBundleIdentifiers
        case deniedWindowTitleKeywords
        case deniedURLHosts
        case deniedURLKeywords
        case allowedBundleIdentifiers
        case retentionByDataClass
    }

    public init(
        version: String = Self.defaultVersion,
        recordingAvailable: Bool = true,
        privateModeEnabled: Bool = false,
        backgroundWebRunsAvailable: Bool = true,
        scheduledRunsAvailable: Bool = true,
        powerHarnessAvailable: Bool = true,
        recordRecallAvailable: Bool = true,
        forceIrreversibleActionGuard: Bool = false,
        sensitiveKeywords: [String] = PrivacyRules.defaultSensitiveKeywords,
        deniedAppNames: [String] = [],
        deniedBundleIdentifiers: [String] = [],
        deniedWindowTitleKeywords: [String] = [],
        deniedURLHosts: [String] = [],
        deniedURLKeywords: [String] = [],
        allowedBundleIdentifiers: [String] = [],
        retentionByDataClass: [String: CaptureRetentionPolicy] = [:]
    ) {
        self.version = version
        self.recordingAvailable = recordingAvailable
        self.privateModeEnabled = privateModeEnabled
        self.backgroundWebRunsAvailable = backgroundWebRunsAvailable
        self.scheduledRunsAvailable = scheduledRunsAvailable
        self.powerHarnessAvailable = powerHarnessAvailable
        self.recordRecallAvailable = recordRecallAvailable
        self.forceIrreversibleActionGuard = forceIrreversibleActionGuard
        self.sensitiveKeywords = sensitiveKeywords
        self.deniedAppNames = deniedAppNames
        self.deniedBundleIdentifiers = deniedBundleIdentifiers
        self.deniedWindowTitleKeywords = deniedWindowTitleKeywords
        self.deniedURLHosts = deniedURLHosts
        self.deniedURLKeywords = deniedURLKeywords
        self.allowedBundleIdentifiers = allowedBundleIdentifiers
        self.retentionByDataClass = retentionByDataClass
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decodeIfPresent(String.self, forKey: .version) ?? Self.defaultVersion
        self.recordingAvailable = try container.decodeIfPresent(Bool.self, forKey: .recordingAvailable) ?? true
        self.privateModeEnabled = try container.decodeIfPresent(Bool.self, forKey: .privateModeEnabled) ?? false
        self.backgroundWebRunsAvailable = try container.decodeIfPresent(Bool.self, forKey: .backgroundWebRunsAvailable) ?? true
        self.scheduledRunsAvailable = try container.decodeIfPresent(Bool.self, forKey: .scheduledRunsAvailable) ?? true
        self.powerHarnessAvailable = try container.decodeIfPresent(Bool.self, forKey: .powerHarnessAvailable) ?? true
        self.recordRecallAvailable = try container.decodeIfPresent(Bool.self, forKey: .recordRecallAvailable) ?? true
        self.forceIrreversibleActionGuard = try container.decodeIfPresent(Bool.self, forKey: .forceIrreversibleActionGuard) ?? false
        self.sensitiveKeywords = try container.decodeIfPresent([String].self, forKey: .sensitiveKeywords) ?? PrivacyRules.defaultSensitiveKeywords
        self.deniedAppNames = try container.decodeIfPresent([String].self, forKey: .deniedAppNames) ?? []
        self.deniedBundleIdentifiers = try container.decodeIfPresent([String].self, forKey: .deniedBundleIdentifiers) ?? []
        self.deniedWindowTitleKeywords = try container.decodeIfPresent([String].self, forKey: .deniedWindowTitleKeywords) ?? []
        self.deniedURLHosts = try container.decodeIfPresent([String].self, forKey: .deniedURLHosts) ?? []
        self.deniedURLKeywords = try container.decodeIfPresent([String].self, forKey: .deniedURLKeywords) ?? []
        self.allowedBundleIdentifiers = try container.decodeIfPresent([String].self, forKey: .allowedBundleIdentifiers) ?? []
        self.retentionByDataClass = try container.decodeIfPresent([String: CaptureRetentionPolicy].self, forKey: .retentionByDataClass) ?? [:]
    }

    public static let `default` = CapturePrivacyPolicy()

    public func decision(
        appName: String,
        bundleIdentifier: String?,
        windowTitle: String?,
        text: String? = nil
    ) -> CapturePrivacyDecision {
        if privateModeEnabled { return .deny("private_mode") }
        if !allowedBundleIdentifiers.isEmpty {
            guard let bundleIdentifier,
                  allowedBundleIdentifiers.contains(where: { matches($0, bundleIdentifier) }) else {
                return .deny("bundle_not_allowed")
            }
        }
        if deniedAppNames.contains(where: { matches($0, appName) }) { return .deny("denied_app") }
        if let bundleIdentifier,
           deniedBundleIdentifiers.contains(where: { matches($0, bundleIdentifier) }) {
            return .deny("denied_bundle")
        }
        if let windowTitle,
           deniedWindowTitleKeywords.contains(where: { windowTitle.localizedCaseInsensitiveContains($0) }) {
            return .deny("denied_window_title")
        }
        let haystack = [appName, bundleIdentifier ?? "", windowTitle ?? "", text ?? ""]
            .joined(separator: " ")
            .lowercased()
        if haystack.contains("<sensitive_text>") { return .deny("redacted_sensitive_text") }
        if let keyword = sensitiveKeywords.first(where: { haystack.contains($0.lowercased()) }) {
            return .deny("sensitive_keyword:\(keyword)")
        }
        return .allow
    }

    public func agentDecision(urlString: String? = nil) -> CapturePrivacyDecision {
        if let denied = deniedURLReason(in: urlString) {
            return .deny(denied)
        }
        return .allow
    }

    public func deniedURLReason(in value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let lower = value.lowercased()
        if let host = URLComponents(string: value)?.host?.lowercased() ?? URL(string: value)?.host?.lowercased(),
           deniedURLHosts.contains(where: { matchesURLHost(rule: $0, host: host) }) {
            return "denied_url_host"
        }
        if deniedURLHosts.contains(where: { rule in
            let normalized = rule.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            return !normalized.isEmpty && lower.contains(normalized)
        }) {
            return "denied_url_host"
        }
        if deniedURLKeywords.contains(where: { keyword in
            let normalized = keyword.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            return !normalized.isEmpty && lower.contains(normalized)
        }) {
            return "denied_url_keyword"
        }
        return nil
    }

    public func isSensitiveText(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains("<sensitive_text>") { return true }
        return sensitiveKeywords.contains { lower.contains($0.lowercased()) }
    }

    public func redactingSensitiveKeywords(in text: String) -> String {
        var redacted = text
        for keyword in sensitiveKeywords where !keyword.isEmpty {
            redacted = redacted.replacingOccurrences(
                of: NSRegularExpression.escapedPattern(for: keyword),
                with: "<SENSITIVE_TEXT>",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return redacted
    }

    public func exportedJSONData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public func exportedJSONString() -> String {
        guard let data = try? exportedJSONData(),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    public static func importJSONData(_ data: Data) throws -> CapturePrivacyPolicy {
        try JSONDecoder().decode(CapturePrivacyPolicy.self, from: data)
    }

    public static func importJSONString(_ json: String) throws -> CapturePrivacyPolicy {
        try importJSONData(Data(json.utf8))
    }

    private func matches(_ rule: String, _ value: String) -> Bool {
        value.localizedCaseInsensitiveCompare(rule) == .orderedSame
            || value.localizedCaseInsensitiveContains(rule)
    }

    private func matchesURLHost(rule: String, host: String) -> Bool {
        let normalized = rule.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        return host == normalized || host.hasSuffix(".\(normalized)")
    }
}
