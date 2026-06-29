import CascadeMemory
import CoreGraphics
import Foundation

public enum RecipeTargetCacheTier: String, Codable, Equatable, Sendable {
    case ax
    case ocr
    case vision
    case recorded
}

public struct RecipeTargetCacheContext: Hashable, Sendable {
    public let actionKeyHash: String
    public let appName: String
    public let bundleIdentifier: String?
    public let windowTitleHash: String
    public let stateFingerprint: String

    public init(
        actionKey: String,
        appName: String,
        bundleIdentifier: String?,
        windowTitle: String?,
        stateFingerprint: String
    ) {
        self.actionKeyHash = RecipeActionIdentity.hash(actionKey)
        self.appName = RecipeActionIdentity.normalizedComponent(appName)
        self.bundleIdentifier = RecipeActionIdentity.normalizedComponent(bundleIdentifier).nilIfEmpty
        self.windowTitleHash = AuditIdentity.hash(RecipeActionIdentity.normalizedComponent(windowTitle))
        self.stateFingerprint = stateFingerprint
    }
}

public struct RecipeTargetCacheEntry: Equatable, Sendable {
    public let point: CGPoint
    public let tier: RecipeTargetCacheTier
    public let successCount: Int
    public let failureCount: Int
    public let confidence: Double
    public let lastUsedAt: Date
}

public actor RecipeTargetCache {
    private var entries: [RecipeTargetCacheContext: RecipeTargetCacheEntry] = [:]

    public init() {}

    public func lookup(_ context: RecipeTargetCacheContext, now: Date = Date()) -> RecipeTargetCacheEntry? {
        guard let entry = entries[context], entry.confidence >= 0.35 else { return nil }
        let touched = RecipeTargetCacheEntry(
            point: entry.point,
            tier: entry.tier,
            successCount: entry.successCount,
            failureCount: entry.failureCount,
            confidence: entry.confidence,
            lastUsedAt: now
        )
        entries[context] = touched
        return touched
    }

    @discardableResult
    public func promote(
        _ context: RecipeTargetCacheContext,
        point: CGPoint,
        tier: RecipeTargetCacheTier,
        now: Date = Date()
    ) -> RecipeTargetCacheEntry {
        let previous = entries[context]
        let successCount = (previous?.successCount ?? 0) + 1
        let failureCount = previous?.failureCount ?? 0
        let confidence = min(0.98, max(previous?.confidence ?? 0.55, 0.55) + 0.12)
        let entry = RecipeTargetCacheEntry(
            point: point,
            tier: tier,
            successCount: successCount,
            failureCount: failureCount,
            confidence: confidence,
            lastUsedAt: now
        )
        entries[context] = entry
        return entry
    }

    @discardableResult
    public func demote(_ context: RecipeTargetCacheContext, now: Date = Date()) -> RecipeTargetCacheEntry? {
        guard let previous = entries[context] else { return nil }
        let confidence = max(0, previous.confidence - 0.35)
        let entry = RecipeTargetCacheEntry(
            point: previous.point,
            tier: previous.tier,
            successCount: previous.successCount,
            failureCount: previous.failureCount + 1,
            confidence: confidence,
            lastUsedAt: now
        )
        if confidence < 0.20 {
            entries.removeValue(forKey: context)
        } else {
            entries[context] = entry
        }
        return entry
    }

    public func removeAll() {
        entries.removeAll()
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
