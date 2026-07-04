import Foundation

/// MDM-managed tenant policy (stub). Managed (forced) preferences surface through
/// `UserDefaults`, so `loadManaged` decodes JSON `Data`, a JSON `String`, or a
/// plist dictionary at the managed-prefs key. Absent or malformed ⇒ `nil` — fail
/// to the built-in default policy, never crash.
public struct TenantPolicy: Codable, Equatable, Sendable {
    public static let managedPreferenceKey = "cascade.tenantPolicy"
    public static let defaultVersion = "tenant-policy-v1"

    public var version: String
    public var deniedBundleIdentifiers: [String]
    public var deniedURLHosts: [String]
    public var retentionDaysByDataClass: [String: Int]
    /// Locked false in the default policy (dab9e5c: never redact-only).
    public var allowRedactOnly: Bool

    public init(
        version: String = Self.defaultVersion,
        deniedBundleIdentifiers: [String] = [],
        deniedURLHosts: [String] = [],
        retentionDaysByDataClass: [String: Int] = [:],
        allowRedactOnly: Bool = false
    ) {
        self.version = version
        self.deniedBundleIdentifiers = deniedBundleIdentifiers
        self.deniedURLHosts = deniedURLHosts
        self.retentionDaysByDataClass = retentionDaysByDataClass
        self.allowRedactOnly = allowRedactOnly
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case deniedBundleIdentifiers
        case deniedURLHosts
        case retentionDaysByDataClass
        case allowRedactOnly
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(String.self, forKey: .version) ?? Self.defaultVersion
        deniedBundleIdentifiers = try container.decodeIfPresent([String].self, forKey: .deniedBundleIdentifiers) ?? []
        deniedURLHosts = try container.decodeIfPresent([String].self, forKey: .deniedURLHosts) ?? []
        retentionDaysByDataClass = try container.decodeIfPresent([String: Int].self, forKey: .retentionDaysByDataClass) ?? [:]
        allowRedactOnly = try container.decodeIfPresent(Bool.self, forKey: .allowRedactOnly) ?? false
    }

    public static func loadManaged(defaults: UserDefaults = .standard) -> TenantPolicy? {
        guard let raw = defaults.object(forKey: managedPreferenceKey) else { return nil }
        let data: Data?
        if let d = raw as? Data {
            data = d
        } else if let s = raw as? String {
            data = s.data(using: .utf8)
        } else if let dict = raw as? [String: Any], JSONSerialization.isValidJSONObject(dict) {
            data = try? JSONSerialization.data(withJSONObject: dict)
        } else {
            data = nil
        }
        guard let data else { return nil }
        return try? JSONDecoder().decode(TenantPolicy.self, from: data)
    }
}
