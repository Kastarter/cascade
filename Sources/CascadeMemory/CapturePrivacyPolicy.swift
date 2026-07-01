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
    public var privateModeEnabled: Bool
    public var sensitiveKeywords: [String]
    public var deniedAppNames: [String]
    public var deniedBundleIdentifiers: [String]
    public var deniedWindowTitleKeywords: [String]
    public var allowedBundleIdentifiers: [String]
    public var retentionByDataClass: [String: CaptureRetentionPolicy]

    public init(
        version: String = Self.defaultVersion,
        privateModeEnabled: Bool = false,
        sensitiveKeywords: [String] = PrivacyRules.defaultSensitiveKeywords,
        deniedAppNames: [String] = [],
        deniedBundleIdentifiers: [String] = [],
        deniedWindowTitleKeywords: [String] = [],
        allowedBundleIdentifiers: [String] = [],
        retentionByDataClass: [String: CaptureRetentionPolicy] = [:]
    ) {
        self.version = version
        self.privateModeEnabled = privateModeEnabled
        self.sensitiveKeywords = sensitiveKeywords
        self.deniedAppNames = deniedAppNames
        self.deniedBundleIdentifiers = deniedBundleIdentifiers
        self.deniedWindowTitleKeywords = deniedWindowTitleKeywords
        self.allowedBundleIdentifiers = allowedBundleIdentifiers
        self.retentionByDataClass = retentionByDataClass
    }

    public static let `default` = CapturePrivacyPolicy()

    public func decision(
        appName: String,
        bundleIdentifier: String?,
        windowTitle: String?,
        text: String? = nil
    ) -> CapturePrivacyDecision {
        // Private mode must NOT drop the whole capture — that stopped ALL recording
        // (the Reel froze the instant it was toggled). Recording continues; instead,
        // FrameRedactor redacts EVERY on-screen text box in private mode (screenshots
        // stay, text is kept private), and genuinely sensitive frames are still dropped
        // by the keyword checks below.
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
}
