// LEAF TARGET — `import Foundation` is SDK-only (for pid_t), not a package dependency.
// The zero-deps guarantee is about SwiftPM targets, not the platform SDK.

import Foundation

/// Identifies the app an action or perception pass targets.
public struct AppTarget: Sendable, Hashable, Codable {
    public let pid: pid_t
    public let bundleID: String
    public let windowHint: String?

    public init(pid: pid_t, bundleID: String, windowHint: String? = nil) {
        self.pid = pid
        self.bundleID = bundleID
        self.windowHint = windowHint
    }
}
