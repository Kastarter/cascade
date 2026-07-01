import CascadeMemory
import ComputerUseKit
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
            #expect(hit.source == .vision)
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

    @Test
    func promoteStoresVerifiedAnchorMetadata() async throws {
        let cache = RecipeTargetCache()
        let context = makeContext()
        let now = Date(timeIntervalSinceReferenceDate: 1_234)

        let entry = await cache.promote(
            context,
            point: CGPoint(x: 12, y: 24),
            tier: .ax,
            verifiedScore: 0.82,
            source: .accessibility,
            anchorHash: "anchor-hash",
            now: now
        )

        #expect(entry.verifiedScore == 0.82)
        #expect(entry.source == .accessibility)
        #expect(entry.anchorHash == "anchor-hash")
        #expect(entry.lastVerifiedAt == now)
    }

    @Test
    func recipeDriftAuditDetailIncludesScoresAndReasons() {
        let step = RecipeStep(order: 3, kind: .click, x: 1, y: 2, appName: "Mail", ocrAnchor: "Send")
        let detail = CascadeAppModel.recipeDriftAuditDetail(
            step: step,
            outcome: .ambiguous,
            reasons: [.closeTopCandidates, .scoreDrop],
            previousScore: 0.92,
            selectedScore: 0.68,
            candidateCount: 2
        )

        #expect(detail.contains("outcome=ambiguous"))
        #expect(detail.contains("previous=0.92"))
        #expect(detail.contains("selected=0.68"))
        #expect(detail.contains("candidates=2"))
        #expect(detail.contains("closeTopCandidates"))
    }

    @Test
    func recipeTargetAuditDetailIncludesConfidenceSourceAndCandidateCount() {
        let step = RecipeStep(order: 4, kind: .click, x: 10, y: 20, appName: "Mail", ocrAnchor: "Archive")
        let detail = CascadeAppModel.recipeTargetAuditDetail(
            step: step,
            tier: "ax_rerank",
            confidence: 0.67,
            source: .accessibility,
            score: 0.67,
            candidateCount: 3,
            drift: .ambiguous
        )

        #expect(detail.contains("tier=ax_rerank"))
        #expect(detail.contains("confidence=0.67"))
        #expect(detail.contains("source=accessibility"))
        #expect(detail.contains("score=0.67"))
        #expect(detail.contains("candidates=3"))
        #expect(detail.contains("drift=ambiguous"))
    }

    @Test
    func replayStateGateRejectsWrongFrontmostApp() {
        #expect(CascadeAppModel.appMatches(
            frontmostName: "Safari",
            frontmostBundle: "com.apple.Safari",
            expectedName: "Mail",
            expectedBundle: "com.apple.mail"
        ) == false)
        #expect(CascadeAppModel.appMatches(
            frontmostName: "Mail",
            frontmostBundle: "com.apple.mail",
            expectedName: "Mail",
            expectedBundle: "com.apple.mail"
        ))
        #expect(CascadeAppModel.appMatches(
            frontmostName: "Google Chrome Helper",
            frontmostBundle: nil,
            expectedName: "Chrome",
            expectedBundle: nil
        ))
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
