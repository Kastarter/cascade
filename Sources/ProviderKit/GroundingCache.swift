import CascadeMemory
import Foundation

public enum GroundingCacheMode: String, Hashable, Sendable {
    case coordinate
    case structural
}

public struct GroundingCacheKey: Hashable, Sendable {
    public let targetText: String
    public let appName: String
    public let bundleIdentifier: String?
    public let windowTitle: String?
    public let displayWidthPoints: Int
    public let displayHeightPoints: Int
    public let screenHash: UInt64
    public let gridHashes: [UInt64]
    public let mode: GroundingCacheMode

    public init?(
        targetText: String,
        appName: String,
        bundleIdentifier: String? = nil,
        windowTitle: String? = nil,
        displayWidthPoints: Int,
        displayHeightPoints: Int,
        screenHash: UInt64,
        gridHashes: [UInt64],
        mode: GroundingCacheMode
    ) {
        let target = targetText.trimmingCharacters(in: .whitespacesAndNewlines)
        let app = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        let bundle = Self.normalizedOptional(bundleIdentifier)
        let window = Self.normalizedOptional(windowTitle)

        guard !target.isEmpty,
              !PrivacyRules.isSensitiveText(target),
              !PrivacyRules.isSensitive(appName: app, bundleIdentifier: bundle, windowTitle: window) else {
            return nil
        }

        self.targetText = target
        self.appName = app
        self.bundleIdentifier = bundle
        self.windowTitle = window
        self.displayWidthPoints = displayWidthPoints
        self.displayHeightPoints = displayHeightPoints
        self.screenHash = screenHash
        self.gridHashes = gridHashes
        self.mode = mode
    }

    private static func normalizedOptional(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

public enum GroundingCacheLookup: Equatable, Sendable {
    case hit(GroundingResult)
    case miss
}

public actor GroundingCache {
    private enum Entry: Sendable {
        case hit(GroundingResult)
        case miss(expiresAt: Date)
    }

    private var entries: [GroundingCacheKey: Entry] = [:]
    private let negativeMissTTL: TimeInterval

    public init(negativeMissTTL: TimeInterval = 3) {
        self.negativeMissTTL = negativeMissTTL
    }

    public func store(_ result: GroundingResult, for key: GroundingCacheKey?) {
        guard let key else { return }
        entries[key] = .hit(result)
    }

    public func storeMiss(for key: GroundingCacheKey?, now: Date = Date()) {
        guard let key else { return }
        entries[key] = .miss(expiresAt: now.addingTimeInterval(negativeMissTTL))
    }

    public func lookup(_ key: GroundingCacheKey?, now: Date = Date()) -> GroundingCacheLookup? {
        guard let key, let entry = entries[key] else { return nil }

        switch entry {
        case .hit(let result):
            return .hit(result)
        case .miss(let expiresAt):
            guard now < expiresAt else {
                entries.removeValue(forKey: key)
                return nil
            }
            return .miss
        }
    }

    public func removeAll() {
        entries.removeAll()
    }
}
