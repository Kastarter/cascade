import CoreGraphics
import Foundation
import ProviderKit
import Testing

struct GroundingCacheTests {
    @Test func compatibleKeysHit() async throws {
        let cache = GroundingCache()
        let key = try #require(makeKey(targetText: "  Save  "))
        let compatible = try #require(makeKey(targetText: "Save"))
        let result = GroundingResult.legacy(
            point: CGPoint(x: 120, y: 240),
            source: .cache,
            latency: 0.01
        )

        await cache.store(result, for: key)

        #expect(await cache.lookup(compatible) == .hit(result))
    }

    @Test func changedScreenAppAndWindowKeysMiss() async throws {
        let cache = GroundingCache()
        let key = try #require(makeKey())
        let result = GroundingResult.legacy(point: CGPoint(x: 20, y: 40), source: .cache)

        await cache.store(result, for: key)

        #expect(await cache.lookup(makeKey(screenHash: 0xFFFF)) == nil)
        #expect(await cache.lookup(makeKey(gridHashes: [9, 8, 7])) == nil)
        #expect(await cache.lookup(makeKey(appName: "Notes")) == nil)
        #expect(await cache.lookup(makeKey(windowTitle: "Draft")) == nil)
        #expect(await cache.lookup(makeKey(mode: .coordinate)) == nil)
    }

    @Test func expiredNegativeMissesAreIgnored() async throws {
        let cache = GroundingCache(negativeMissTTL: 2)
        let key = try #require(makeKey())
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        await cache.storeMiss(for: key, now: start)

        #expect(await cache.lookup(key, now: start.addingTimeInterval(1.5)) == .miss)
        #expect(await cache.lookup(key, now: start.addingTimeInterval(2.1)) == nil)
    }

    @Test func sensitiveAndEmptyTargetsAreSkipped() async {
        #expect(makeKey(targetText: "   ") == nil)
        #expect(makeKey(targetText: "password field") == nil)
        #expect(makeKey(appName: "1Password") == nil)
        #expect(makeKey(windowTitle: "Private browsing") == nil)

        let cache = GroundingCache()
        let result = GroundingResult.legacy(point: CGPoint(x: 1, y: 1), source: .cache)

        await cache.store(result, for: makeKey(targetText: "wallet button"))

        #expect(await cache.lookup(makeKey(targetText: "wallet button")) == nil)
    }
}

private func makeKey(
    targetText: String = "Save",
    appName: String = "Safari",
    bundleIdentifier: String? = "com.apple.Safari",
    windowTitle: String? = "Checkout",
    displayWidthPoints: Int = 1440,
    displayHeightPoints: Int = 900,
    screenHash: UInt64 = 0xABCD,
    gridHashes: [UInt64] = [1, 2, 3],
    mode: GroundingCacheMode = .structural
) -> GroundingCacheKey? {
    GroundingCacheKey(
        targetText: targetText,
        appName: appName,
        bundleIdentifier: bundleIdentifier,
        windowTitle: windowTitle,
        displayWidthPoints: displayWidthPoints,
        displayHeightPoints: displayHeightPoints,
        screenHash: screenHash,
        gridHashes: gridHashes,
        mode: mode
    )
}
