import ApplicationServices
import CoreGraphics
import Foundation
import Testing

@testable import ComputerUseKit

// d09 observer-cache policy tests. The pure pieces (notification mapping, TTL,
// probe staleness, probe sampling, metrics accounting) plus the lookup flow
// with an injected scrape and the observer requirement bypassed — the live
// AXObserver registration itself needs a real trusted session and is exercised
// manually per [[cascade-verify-by-running]].
struct AXSnapshotCacheTests {
    private static func emptySnapshot() -> AXLiveSnapshot {
        AXLiveSnapshot(
            harvest: AXElementResolver.CandidateHarvest(
                candidates: [],
                diagnostics: AXElementResolver.AXDiagnostics()
            )
        )
    }

    // MARK: - Notification → invalidation mapping

    @Test func focusNotificationsMapToFocus() {
        for name in [
            kAXFocusedWindowChangedNotification,
            kAXMainWindowChangedNotification,
            kAXFocusedUIElementChangedNotification,
        ] {
            #expect(AXSnapshotCache.invalidationReason(forNotification: name as String) == .focus)
        }
    }

    @Test func windowNotificationsMapToWindow() {
        for name in [
            kAXWindowCreatedNotification,
            kAXWindowMovedNotification,
            kAXWindowResizedNotification,
            kAXWindowMiniaturizedNotification,
            kAXWindowDeminiaturizedNotification,
        ] {
            #expect(AXSnapshotCache.invalidationReason(forNotification: name as String) == .window)
        }
    }

    @Test func valueChildrenAndDestroyedMapDistinctly() {
        #expect(AXSnapshotCache.invalidationReason(forNotification: kAXValueChangedNotification as String) == .value)
        #expect(AXSnapshotCache.invalidationReason(forNotification: kAXTitleChangedNotification as String) == .value)
        #expect(AXSnapshotCache.invalidationReason(forNotification: kAXCreatedNotification as String) == .children)
        #expect(AXSnapshotCache.invalidationReason(forNotification: kAXLayoutChangedNotification as String) == .children)
        #expect(AXSnapshotCache.invalidationReason(forNotification: kAXRowCountChangedNotification as String) == .children)
        #expect(AXSnapshotCache.invalidationReason(forNotification: kAXUIElementDestroyedNotification as String) == .destroyed)
    }

    @Test func unknownNotificationInvalidatesConservatively() {
        #expect(AXSnapshotCache.invalidationReason(forNotification: "AXSomethingNew") == .children)
    }

    // MARK: - TTL

    @Test func snapshotExpiresOnlyPastMaxAge() {
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
        #expect(!AXSnapshotCache.isExpired(scrapedAt: t0, now: t0))
        #expect(!AXSnapshotCache.isExpired(scrapedAt: t0, now: t0.addingTimeInterval(AXSnapshotCache.maxSnapshotAge)))
        #expect(AXSnapshotCache.isExpired(scrapedAt: t0, now: t0.addingTimeInterval(AXSnapshotCache.maxSnapshotAge + 0.5)))
    }

    // MARK: - Probe staleness

    @Test func missingProbeFrameIsStale() {
        let original = CGRect(x: 10, y: 10, width: 100, height: 24)
        #expect(AXSnapshotCache.probeIndicatesStale(originalFrame: original, currentFrame: nil))
    }

    @Test func stableProbeFrameIsFresh() {
        let original = CGRect(x: 10, y: 10, width: 100, height: 24)
        let nudged = CGRect(x: 11, y: 9.5, width: 100, height: 24)
        #expect(!AXSnapshotCache.probeIndicatesStale(originalFrame: original, currentFrame: original))
        #expect(!AXSnapshotCache.probeIndicatesStale(originalFrame: original, currentFrame: nudged))
    }

    @Test func movedOrResizedProbeFrameIsStale() {
        let original = CGRect(x: 10, y: 10, width: 100, height: 24)
        let moved = original.offsetBy(dx: 0, dy: 30)
        let resized = CGRect(x: 10, y: 10, width: 160, height: 24)
        #expect(AXSnapshotCache.probeIndicatesStale(originalFrame: original, currentFrame: moved))
        #expect(AXSnapshotCache.probeIndicatesStale(originalFrame: original, currentFrame: resized))
    }

    // MARK: - Probe sampling

    @Test func probeSamplingIsBoundedUniqueAndSpread() {
        #expect(AXSnapshotCache.probeSampleIndices(count: 0).isEmpty)
        #expect(AXSnapshotCache.probeSampleIndices(count: 2) == [0, 1])
        let spread = AXSnapshotCache.probeSampleIndices(count: 101)
        #expect(spread == [0, 50, 100])
        #expect(spread.count <= AXSnapshotCache.maxProbes)
    }

    // MARK: - Lookup flow (injected scrape, observer bypassed)

    @Test func servesSnapshotUntilNotificationInvalidates() {
        let cache = AXSnapshotCache()
        cache.setAssumeObserverRegisteredForTesting(true)
        let pid = pid_t(424_242)
        var scrapes = 0
        let scrape = { () -> AXLiveSnapshot in
            scrapes += 1
            return Self.emptySnapshot()
        }
        let t0 = Date(timeIntervalSinceReferenceDate: 5_000)

        _ = cache.harvest(pid: pid, now: t0, scrape: scrape) // cold miss
        #expect(scrapes == 1)
        _ = cache.harvest(pid: pid, now: t0.addingTimeInterval(1), scrape: scrape) // hit
        #expect(scrapes == 1)

        cache.noteNotification(kAXValueChangedNotification as String, pid: pid)
        _ = cache.harvest(pid: pid, now: t0.addingTimeInterval(2), scrape: scrape) // invalidated → rescrape
        #expect(scrapes == 2)

        let metrics = cache.drainMetrics()
        #expect(metrics?.hits == 1)
        #expect(metrics?.misses == 2)
        #expect(metrics?.coldMisses == 1)
        #expect(metrics?.valueInvalidations == 1)
        // Drained — a second drain with no new activity reports nothing.
        #expect(cache.drainMetrics() == nil)
    }

    @Test func snapshotOlderThanTTLIsRescraped() {
        let cache = AXSnapshotCache()
        cache.setAssumeObserverRegisteredForTesting(true)
        let pid = pid_t(424_243)
        var scrapes = 0
        let scrape = { () -> AXLiveSnapshot in
            scrapes += 1
            return Self.emptySnapshot()
        }
        let t0 = Date(timeIntervalSinceReferenceDate: 9_000)

        _ = cache.harvest(pid: pid, now: t0, scrape: scrape)
        _ = cache.harvest(pid: pid, now: t0.addingTimeInterval(AXSnapshotCache.maxSnapshotAge + 1), scrape: scrape)
        #expect(scrapes == 2)
        let metrics = cache.drainMetrics()
        #expect(metrics?.ttlExpirations == 1)
    }

    @Test func notificationsForUncachedAppsAreIgnored() {
        let cache = AXSnapshotCache()
        cache.noteNotification(kAXValueChangedNotification as String, pid: pid_t(99))
        #expect(cache.drainMetrics() == nil)
    }

    // MARK: - Metrics audit shape

    @Test func safeAuditDetailIsCountsOnly() {
        var metrics = AXSnapshotCacheMetrics()
        metrics.hits = 3
        metrics.record(miss: .cold)
        metrics.record(miss: .staleProbe)
        let detail = metrics.safeAuditDetail
        #expect(detail.contains("axCacheHits=3"))
        #expect(detail.contains("axCacheMisses=2"))
        #expect(detail.contains("axCacheCold=1"))
        #expect(detail.contains("axCacheStaleProbe=1"))
        // Every token is key=integer — no labels, titles, or coordinates.
        for token in detail.split(separator: " ") {
            let parts = token.split(separator: "=")
            #expect(parts.count == 2)
            #expect(Int(parts[1]) != nil)
        }
    }

    @Test func totalActivityGatesDrain() {
        let idle = AXSnapshotCacheMetrics()
        #expect(idle.totalActivity == 0)
        var active = AXSnapshotCacheMetrics()
        active.record(miss: .focus)
        #expect(active.totalActivity == 1)
        #expect(active.focusInvalidations == 1)
    }
}
