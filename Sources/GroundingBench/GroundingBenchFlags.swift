import Foundation

public enum GroundingBenchFlags {
    public static let experimentalGroundingBenchKey = "cascade.experimentalGroundingBench"

    public static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: experimentalGroundingBenchKey)
    }
}
