// LEAF TARGET — no package dependencies. See Geometry.swift header.
//
// MOVED VERBATIM from Sources/ProviderKit/Planner.swift (cases and String rawValues
// byte-identical: low/elevated/high/destructive) so every persisted Codable encoding
// is unchanged. ProviderKit keeps `public typealias ActionRisk = PerceptionCore.ActionRisk`
// at the old location so callsites compile unchanged.

public enum ActionRisk: String, Sendable, Equatable, Codable {
    case low
    case elevated
    case high
    case destructive
}
