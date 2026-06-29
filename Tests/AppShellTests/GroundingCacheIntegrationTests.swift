import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import AppShell
@testable import MacContextKit
@testable import ProviderKit

@Suite(.serialized)
struct GroundingCacheIntegrationTests {
    @Test
    func experimentalGroundingCacheDefaultsOffAndLeavesGroundingUncached() async throws {
        let defaults = UserDefaults(suiteName: "CascadeGroundingCacheOff-\(UUID().uuidString)")!
        let disabledCache = await MainActor.run {
            CascadeAppModel.experimentalGroundingCache(defaults: defaults)
        }
        let counter = GroundingCallCounter()
        let point = CGPoint(x: 44, y: 88)
        let grounder = MixtureGrounder(
            base: CountingGrounder(counter: counter, result: groundingResult(point: point)),
            skills: .init(),
            minAXScore: 999,
            groundingCache: disabledCache,
            cacheContextProvider: { testSnapshot() }
        )
        let screenshot = jpegFixture()
        let target = "Cache canvas target \(UUID().uuidString)"

        _ = await grounder.groundResult(
            screenshot: screenshot,
            target: target,
            displayWidthPoints: 240,
            displayHeightPoints: 240
        )
        _ = await grounder.groundResult(
            screenshot: screenshot,
            target: target,
            displayWidthPoints: 240,
            displayHeightPoints: 240
        )

        #expect(disabledCache == nil)
        #expect(await counter.value() == 2)
    }

    @Test
    func experimentalGroundingCacheEnabledReturnsCachedHitForIdenticalRequest() async throws {
        let defaults = UserDefaults(suiteName: "CascadeGroundingCacheOn-\(UUID().uuidString)")!
        let key = await MainActor.run { CascadeAppModel.experimentalGroundingCacheKey }
        defaults.set(true, forKey: key)
        let cache = try #require(await MainActor.run {
            CascadeAppModel.experimentalGroundingCache(defaults: defaults)
        })
        let counter = GroundingCallCounter()
        let point = CGPoint(x: 120, y: 150)
        let grounder = MixtureGrounder(
            base: CountingGrounder(counter: counter, result: groundingResult(point: point)),
            skills: .init(),
            minAXScore: 999,
            groundingCache: cache,
            cacheContextProvider: { testSnapshot() }
        )
        let screenshot = jpegFixture()
        let target = "Cache canvas target \(UUID().uuidString)"

        let first = await grounder.groundResult(
            screenshot: screenshot,
            target: target,
            displayWidthPoints: 240,
            displayHeightPoints: 240
        )
        let second = await grounder.groundResult(
            screenshot: screenshot,
            target: target,
            displayWidthPoints: 240,
            displayHeightPoints: 240
        )

        #expect(first.selectedPoint == point)
        #expect(second.selectedPoint == point)
        #expect(second.selectedCandidate?.source == .cache)
        #expect(await counter.value() == 1)
    }

    @Test
    func cachedMissSuppressesRepeatLookupUntilTTLExpires() async throws {
        let cache = GroundingCache(negativeMissTTL: 0.05)
        let counter = GroundingCallCounter()
        let grounder = MixtureGrounder(
            base: CountingGrounder(counter: counter, result: GroundingResult()),
            skills: .init(),
            minAXScore: 999,
            groundingCache: cache,
            cacheContextProvider: { testSnapshot() }
        )
        let screenshot = jpegFixture()
        let target = "Missing canvas target \(UUID().uuidString)"

        let first = await grounder.ground(
            screenshot: screenshot,
            target: target,
            displayWidthPoints: 240,
            displayHeightPoints: 240
        )
        let second = await grounder.ground(
            screenshot: screenshot,
            target: target,
            displayWidthPoints: 240,
            displayHeightPoints: 240
        )

        #expect(first == nil)
        #expect(second == nil)
        #expect(await counter.value() == 1)

        try await Task.sleep(nanoseconds: 80_000_000)

        let third = await grounder.ground(
            screenshot: screenshot,
            target: target,
            displayWidthPoints: 240,
            displayHeightPoints: 240
        )

        #expect(third == nil)
        #expect(await counter.value() == 2)
    }
}

private func testSnapshot() -> AppWindowSnapshot {
    AppWindowSnapshot(
        appName: "GroundingCacheTest",
        bundleIdentifier: "com.humain.cascade.tests",
        processIdentifier: 123,
        windowTitle: "Grounding Cache Fixture"
    )
}

private actor GroundingCallCounter {
    private var calls = 0

    func increment() {
        calls += 1
    }

    func value() -> Int {
        calls
    }
}

private struct CountingGrounder: VisualGrounder {
    let counter: GroundingCallCounter
    let result: GroundingResult

    func ground(
        screenshot: Data,
        target: String,
        displayWidthPoints: Int,
        displayHeightPoints: Int
    ) async -> CGPoint? {
        await counter.increment()
        return result.selectedPoint
    }

    func groundResult(
        screenshot: Data,
        target: String,
        displayWidthPoints: Int,
        displayHeightPoints: Int
    ) async -> GroundingResult {
        await counter.increment()
        return result
    }
}

private func groundingResult(point: CGPoint) -> GroundingResult {
    GroundingResult(
        candidates: [
            GroundingCandidate(
                point: point,
                confidence: 0.94,
                source: .visualModel,
                coordinateSpace: .displayLocalAppKitPoints,
                rawModel: "fixture"
            )
        ],
        selectedIndex: 0
    )
}

private func jpegFixture(size: Int = 240) -> Data {
    let ctx = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    ctx.setFillColor(.white)
    ctx.fill(rect)
    ctx.setFillColor(.black)
    ctx.fill(CGRect(x: 24, y: 30, width: 64, height: 92))
    ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
    ctx.fill(CGRect(x: 140, y: 110, width: 58, height: 70))
    let image = ctx.makeImage()!
    let out = NSMutableData()
    let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
    return out as Data
}
