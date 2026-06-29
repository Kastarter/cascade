import CascadeMemory
import CoreGraphics
import Foundation
import Testing

@testable import AppShell

struct RecipeTargetCacheTests {
    @Test
    func promoteStoresHitWithConfidence() async throws {
        let cache = RecipeTargetCache()
        let context = makeContext()

        let entry = await cache.promote(context, point: CGPoint(x: 10, y: 20), tier: .ocr)
        let hit = try #require(await cache.lookup(context))

        #expect(entry.successCount == 1)
        #expect(hit.point == CGPoint(x: 10, y: 20))
        #expect(hit.tier == .ocr)
        #expect(hit.confidence > 0.5)
    }

    @Test
    func identicalActionWithSameStateHits() async throws {
        let cache = RecipeTargetCache()
        let first = makeContext(actionKey: "click save", stateFingerprint: "123")
        let same = makeContext(actionKey: "click save", stateFingerprint: "123")

        await cache.promote(first, point: CGPoint(x: 1, y: 2), tier: .ax)

        #expect(await cache.lookup(same)?.point == CGPoint(x: 1, y: 2))
    }

    @Test
    func changedActionOrStateMisses() async throws {
        let cache = RecipeTargetCache()
        await cache.promote(makeContext(actionKey: "click save"), point: CGPoint(x: 1, y: 2), tier: .ax)

        #expect(await cache.lookup(makeContext(actionKey: "click send")) == nil)
        #expect(await cache.lookup(makeContext(actionKey: "click save", appName: "Notes")) == nil)
        #expect(await cache.lookup(makeContext(actionKey: "click save", windowTitle: "Draft")) == nil)
        #expect(await cache.lookup(makeContext(actionKey: "click save", stateFingerprint: "changed")) == nil)
    }

    @Test
    func demoteLowersConfidenceAndEventuallyRemovesFallbackHit() async throws {
        let cache = RecipeTargetCache()
        let context = makeContext()
        await cache.promote(context, point: CGPoint(x: 5, y: 6), tier: .vision)

        let first = try #require(await cache.demote(context))
        _ = await cache.demote(context)

        #expect(first.failureCount == 1)
        #expect(await cache.lookup(context) == nil)
    }

    @Test
    func sensitiveIdentityCanBeSkippedBeforeInsertion() {
        let sensitive = RecipeStep(
            order: 1,
            kind: .click,
            x: 1,
            y: 2,
            appName: "Safari",
            windowTitleHint: "Bank account",
            ocrAnchor: "Pay"
        )
        let normal = RecipeStep(
            order: 1,
            kind: .click,
            x: 1,
            y: 2,
            appName: "Mail",
            ocrAnchor: "Send"
        )

        #expect(CascadeAppModel.recipeTargetCacheSkipReason(step: sensitive, axUnreliable: false) == "sensitive")
        #expect(CascadeAppModel.recipeTargetCacheSkipReason(step: normal, axUnreliable: true) == "ax_unreliable")
        #expect(CascadeAppModel.recipeTargetCacheSkipReason(step: normal, axUnreliable: false) == nil)
    }

    @Test
    func demotedCacheMissAllowsFallbackPromotion() async throws {
        let cache = RecipeTargetCache()
        let context = makeContext()
        await cache.promote(context, point: CGPoint(x: 10, y: 20), tier: .ax)
        _ = await cache.demote(context)
        _ = await cache.demote(context)

        #expect(await cache.lookup(context) == nil)

        let fallback = await cache.promote(context, point: CGPoint(x: 30, y: 40), tier: .recorded)
        #expect(fallback.point == CGPoint(x: 30, y: 40))
        #expect(fallback.tier == .recorded)
    }
}

private func makeContext(
    actionKey: String = "click save",
    appName: String = "Mail",
    bundleIdentifier: String? = "com.apple.mail",
    windowTitle: String? = "Inbox",
    stateFingerprint: String = "state-1"
) -> RecipeTargetCacheContext {
    RecipeTargetCacheContext(
        actionKey: actionKey,
        appName: appName,
        bundleIdentifier: bundleIdentifier,
        windowTitle: windowTitle,
        stateFingerprint: stateFingerprint
    )
}
