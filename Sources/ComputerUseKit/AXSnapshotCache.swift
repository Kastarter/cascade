import AppKit
import ApplicationServices
import Foundation
import MacContextKit

// d09 (AX-first grounding): event-driven AX observer cache.
//
// The agent harvests the frontmost app's actionable AX nodes several times per
// turn (proactive Set-of-Marks push, descriptor ranking, AX-first grounding).
// Each harvest was a fresh bounded full-tree walk (≤1400 nodes, 0.3s messaging
// timeout per read). This cache keeps ONE per-app snapshot of that walk and
// serves it until macOS tells us the UI changed: an `AXObserver` registered on
// the app element invalidates the snapshot on focus / window / value /
// children / destroyed notifications, a focused-window identity check plus a
// rotating frame probe catches stale nodes the app never announced, and a TTL
// bounds worst-case staleness for apps that under-report. Misses fall through
// to the existing bounded scrape, so behavior is never worse than today —
// and the whole path is default-off behind `cascade.experimentalGroundingCache`.

/// One bounded scrape of the frontmost app: the harvest all callers consume,
/// plus the raw material the cache needs for stale-node detection (a few live
/// element references with their frames, and the focused window's identity).
struct AXLiveSnapshot {
    let harvest: AXElementResolver.CandidateHarvest
    let probes: [AXSnapshotProbe]
    let focusedWindow: AXUIElement?

    init(
        harvest: AXElementResolver.CandidateHarvest,
        probes: [AXSnapshotProbe] = [],
        focusedWindow: AXUIElement? = nil
    ) {
        self.harvest = harvest
        self.probes = probes
        self.focusedWindow = focusedWindow
    }
}

/// A live element sampled from the scrape with the frame it had then. Re-read
/// on cache hits: an AX error or a moved frame means the snapshot is stale.
struct AXSnapshotProbe {
    let element: AXUIElement
    let frame: CGRect
}

/// Why a lookup did not serve the cached snapshot. String values are audit-safe
/// (they name a category, never content).
enum AXSnapshotInvalidation: String, Sendable, Equatable, CaseIterable {
    case cold
    case focus
    case window
    case value
    case children
    case destroyed
    case ttl
    case staleProbe = "stale-probe"
}

/// Counts-only accounting for the observer cache — safe to persist to
/// `audit_event` verbatim (no labels, no titles, no coordinates).
public struct AXSnapshotCacheMetrics: Sendable, Equatable {
    public var hits = 0
    public var misses = 0
    public var coldMisses = 0
    public var focusInvalidations = 0
    public var windowInvalidations = 0
    public var valueInvalidations = 0
    public var childrenInvalidations = 0
    public var destroyedInvalidations = 0
    public var ttlExpirations = 0
    public var staleProbeDetections = 0
    public var observerRegistrationFailures = 0
    public var evictions = 0

    public init() {}

    public var totalActivity: Int {
        hits + misses + observerRegistrationFailures + evictions
    }

    public var safeAuditDetail: String {
        [
            "axCacheHits=\(hits)",
            "axCacheMisses=\(misses)",
            "axCacheCold=\(coldMisses)",
            "axCacheFocus=\(focusInvalidations)",
            "axCacheWindow=\(windowInvalidations)",
            "axCacheValue=\(valueInvalidations)",
            "axCacheChildren=\(childrenInvalidations)",
            "axCacheDestroyed=\(destroyedInvalidations)",
            "axCacheTTL=\(ttlExpirations)",
            "axCacheStaleProbe=\(staleProbeDetections)",
            "axCacheObserverFailures=\(observerRegistrationFailures)",
            "axCacheEvictions=\(evictions)",
        ].joined(separator: " ")
    }

    mutating func record(miss reason: AXSnapshotInvalidation) {
        misses += 1
        switch reason {
        case .cold: coldMisses += 1
        case .focus: focusInvalidations += 1
        case .window: windowInvalidations += 1
        case .value: valueInvalidations += 1
        case .children: childrenInvalidations += 1
        case .destroyed: destroyedInvalidations += 1
        case .ttl: ttlExpirations += 1
        case .staleProbe: staleProbeDetections += 1
        }
    }
}

/// Refcon payload for the C observer callback: which app fired, into which cache.
final class AXSnapshotObserverContext {
    let pid: pid_t
    let cache: AXSnapshotCache

    init(pid: pid_t, cache: AXSnapshotCache) {
        self.pid = pid
        self.cache = cache
    }
}

/// C-convention AXObserver callback — captures nothing; recovers the cache and
/// pid from the refcon and flips the invalidation flag (cheap: one lock, one
/// enum write; no AX calls, so notification storms stay harmless).
private let axSnapshotObserverCallback: AXObserverCallback = { _, _, notification, refcon in
    guard let refcon else { return }
    let context = Unmanaged<AXSnapshotObserverContext>.fromOpaque(refcon).takeUnretainedValue()
    context.cache.noteNotification(notification as String, pid: context.pid)
}

public final class AXSnapshotCache: @unchecked Sendable {
    public static let shared = AXSnapshotCache()

    /// Reuses the existing grounding-cache experiment flag (same family: cached
    /// grounding state that must never change what a fresh look would return).
    public static let flagKey = "cascade.experimentalGroundingCache"

    /// Safety net for apps whose AX server under-reports changes: a snapshot
    /// older than this is re-scraped even without a notification.
    static let maxSnapshotAge: TimeInterval = 10

    /// Frame drift (points) beyond which a probed node counts as stale.
    static let probeFrameTolerance: CGFloat = 2

    /// Bound on cached apps — LRU-evicted with observer teardown beyond this.
    static let maxTrackedApps = 4

    /// Probes sampled per snapshot for stale-node detection.
    static let maxProbes = 3

    private struct Entry {
        var snapshot: AXElementResolver.CandidateHarvest
        var probes: [AXSnapshotProbe]
        var focusedWindow: AXUIElement?
        var probeCursor: Int
        var scrapedAt: Date
        var lastUsedAt: Date
        var invalidatedReason: AXSnapshotInvalidation?
    }

    private struct ObserverBox {
        let observer: AXObserver
        let appElement: AXUIElement
        let context: AXSnapshotObserverContext
        let registered: [String]
        let coreRegistered: Bool
    }

    private let lock = NSLock()
    private var entries: [pid_t: Entry] = [:]
    private var observers: [pid_t: ObserverBox] = [:]
    private var pendingMetrics = AXSnapshotCacheMetrics()
    private var enabledOverride: Bool?
    private var assumeObserverRegisteredForTesting = false

    init() {}

    // MARK: - Flag

    public var isEnabled: Bool {
        lock.lock()
        let override = enabledOverride
        lock.unlock()
        return override ?? UserDefaults.standard.bool(forKey: Self.flagKey)
    }

    func setEnabledOverrideForTesting(_ value: Bool?) {
        lock.lock()
        enabledOverride = value
        lock.unlock()
    }

    func setAssumeObserverRegisteredForTesting(_ value: Bool) {
        lock.lock()
        assumeObserverRegisteredForTesting = value
        lock.unlock()
    }

    // MARK: - Lookup

    /// Serve the per-app snapshot when it is still trustworthy; otherwise run
    /// `scrape` (the existing bounded walk) and cache its result. Validation
    /// AX reads happen OUTSIDE the lock — they can block up to the messaging
    /// timeout and must not stall the observer callback.
    func harvest(
        pid: pid_t,
        now: Date = Date(),
        scrape: () -> AXLiveSnapshot
    ) -> AXElementResolver.CandidateHarvest {
        var cachedHarvest: AXElementResolver.CandidateHarvest?
        var cachedFocusedWindow: AXUIElement?
        var probeToCheck: AXSnapshotProbe?
        var missReason = AXSnapshotInvalidation.cold

        lock.lock()
        if let entry = entries[pid] {
            if let reason = entry.invalidatedReason {
                missReason = reason
            } else if Self.isExpired(scrapedAt: entry.scrapedAt, now: now) {
                missReason = .ttl
            } else {
                cachedHarvest = entry.snapshot
                cachedFocusedWindow = entry.focusedWindow
                if !entry.probes.isEmpty {
                    let index = entry.probeCursor % entry.probes.count
                    probeToCheck = entry.probes[index]
                    entries[pid]?.probeCursor = index + 1
                }
            }
        }
        lock.unlock()

        if let cachedHarvest {
            var stale: AXSnapshotInvalidation?
            let appElement = AXUIElementCreateApplication(pid)
            AXClient.setMessagingTimeout(appElement)
            let currentFocused = try? AXClient
                .elementAttribute(appElement, kAXFocusedWindowAttribute as String).get()
            if !Self.sameElement(cachedFocusedWindow, currentFocused) {
                stale = .focus
            } else if let probe = probeToCheck {
                let currentFrame = try? AXClient.frame(probe.element).get()
                if Self.probeIndicatesStale(originalFrame: probe.frame, currentFrame: currentFrame) {
                    stale = .staleProbe
                }
            }
            if let stale {
                missReason = stale
                lock.lock()
                if entries[pid]?.invalidatedReason == nil {
                    entries[pid]?.invalidatedReason = stale
                }
                lock.unlock()
            } else {
                lock.lock()
                entries[pid]?.lastUsedAt = now
                pendingMetrics.hits += 1
                lock.unlock()
                return cachedHarvest
            }
        }

        let snapshot = scrape()
        let observerReady = ensureObserver(pid: pid)
        var boxesToTearDown: [ObserverBox] = []
        lock.lock()
        pendingMetrics.record(miss: missReason)
        if observerReady {
            entries[pid] = Entry(
                snapshot: snapshot.harvest,
                probes: snapshot.probes,
                focusedWindow: snapshot.focusedWindow,
                probeCursor: 0,
                scrapedAt: now,
                lastUsedAt: now,
                invalidatedReason: nil
            )
            boxesToTearDown = evictIfNeededLocked(keeping: pid)
        } else {
            entries.removeValue(forKey: pid)
        }
        lock.unlock()
        for box in boxesToTearDown {
            Self.tearDown(box)
        }
        return snapshot.harvest
    }

    // MARK: - Invalidation

    /// Observer callback entry: mark the app's snapshot stale. Counted once per
    /// valid→invalid transition so notification storms don't inflate metrics.
    func noteNotification(_ name: String, pid: pid_t) {
        let reason = Self.invalidationReason(forNotification: name)
        lock.lock()
        if var entry = entries[pid], entry.invalidatedReason == nil {
            entry.invalidatedReason = reason
            entries[pid] = entry
        }
        lock.unlock()
    }

    public func removeAll() {
        lock.lock()
        entries.removeAll()
        let boxes = Array(observers.values)
        observers.removeAll()
        lock.unlock()
        for box in boxes {
            Self.tearDown(box)
        }
    }

    // MARK: - Metrics

    /// Activity since the last drain, or nil when idle. The caller audits the
    /// returned counts (`safeAuditDetail`) — hashes/counts only.
    public func drainMetrics() -> AXSnapshotCacheMetrics? {
        lock.lock()
        let metrics = pendingMetrics
        pendingMetrics = AXSnapshotCacheMetrics()
        lock.unlock()
        return metrics.totalActivity > 0 ? metrics : nil
    }

    // MARK: - Pure policy (unit-tested)

    static func isExpired(scrapedAt: Date, now: Date, maxAge: TimeInterval = maxSnapshotAge) -> Bool {
        now.timeIntervalSince(scrapedAt) > maxAge
    }

    /// nil current frame (AX read failed → dead/detached node) or drift beyond
    /// tolerance means the cached tree no longer matches the screen.
    static func probeIndicatesStale(
        originalFrame: CGRect,
        currentFrame: CGRect?,
        tolerance: CGFloat = probeFrameTolerance
    ) -> Bool {
        guard let currentFrame else { return true }
        let dx = abs(currentFrame.midX - originalFrame.midX)
        let dy = abs(currentFrame.midY - originalFrame.midY)
        let dw = abs(currentFrame.width - originalFrame.width)
        let dh = abs(currentFrame.height - originalFrame.height)
        return dx > tolerance || dy > tolerance || dw > tolerance || dh > tolerance
    }

    /// Evenly spread sample indices over the harvested candidates (first /
    /// middle / last for the default 3) so probes cover the tree, bounded.
    static func probeSampleIndices(count: Int, maxProbes: Int = maxProbes) -> [Int] {
        guard count > 0, maxProbes > 0 else { return [] }
        if count <= maxProbes { return Array(0..<count) }
        let last = count - 1
        var indices = Set<Int>()
        for slot in 0..<maxProbes {
            indices.insert(min(last, slot * last / max(1, maxProbes - 1)))
        }
        return indices.sorted()
    }

    static func invalidationReason(forNotification name: String) -> AXSnapshotInvalidation {
        switch name {
        case kAXFocusedWindowChangedNotification as String,
             kAXMainWindowChangedNotification as String,
             kAXFocusedUIElementChangedNotification as String:
            return .focus
        case kAXWindowCreatedNotification as String,
             kAXWindowMovedNotification as String,
             kAXWindowResizedNotification as String,
             kAXWindowMiniaturizedNotification as String,
             kAXWindowDeminiaturizedNotification as String:
            return .window
        case kAXValueChangedNotification as String,
             kAXTitleChangedNotification as String:
            return .value
        case kAXCreatedNotification as String,
             kAXLayoutChangedNotification as String,
             kAXRowCountChangedNotification as String:
            return .children
        case kAXUIElementDestroyedNotification as String:
            return .destroyed
        default:
            // Unknown notifications still mean "something changed" — invalidate
            // conservatively as a structural (children) change.
            return .children
        }
    }

    static func sameElement(_ lhs: AXUIElement?, _ rhs: AXUIElement?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case (let l?, let r?):
            return CFEqual(l, r)
        default:
            return false
        }
    }

    // MARK: - Observer plumbing

    /// Every notification we ask for. Registration failures on CORE ones mean
    /// we can't trust event-driven invalidation for that app → don't cache it
    /// (fall back to a fresh scrape per harvest, i.e. today's behavior).
    static let observedNotifications: [String] = [
        kAXFocusedWindowChangedNotification as String,
        kAXMainWindowChangedNotification as String,
        kAXFocusedUIElementChangedNotification as String,
        kAXWindowCreatedNotification as String,
        kAXWindowMovedNotification as String,
        kAXWindowResizedNotification as String,
        kAXWindowMiniaturizedNotification as String,
        kAXWindowDeminiaturizedNotification as String,
        kAXValueChangedNotification as String,
        kAXTitleChangedNotification as String,
        kAXCreatedNotification as String,
        kAXLayoutChangedNotification as String,
        kAXRowCountChangedNotification as String,
        kAXUIElementDestroyedNotification as String,
    ]

    static let coreNotifications: Set<String> = [
        kAXFocusedWindowChangedNotification as String,
        kAXWindowCreatedNotification as String,
        kAXValueChangedNotification as String,
        kAXCreatedNotification as String,
        kAXLayoutChangedNotification as String,
        kAXUIElementDestroyedNotification as String,
    ]

    /// True when an observer with all core notifications watches `pid`.
    /// Creates and registers one on first use; failures are counted and make
    /// the pid uncacheable (every harvest scrapes fresh).
    private func ensureObserver(pid: pid_t) -> Bool {
        lock.lock()
        if assumeObserverRegisteredForTesting {
            lock.unlock()
            return true
        }
        if let existing = observers[pid] {
            lock.unlock()
            return existing.coreRegistered
        }
        lock.unlock()

        var observerRef: AXObserver?
        guard AXObserverCreate(pid, axSnapshotObserverCallback, &observerRef) == .success,
              let observer = observerRef else {
            lock.lock()
            pendingMetrics.observerRegistrationFailures += 1
            lock.unlock()
            return false
        }
        let context = AXSnapshotObserverContext(pid: pid, cache: self)
        let appElement = AXUIElementCreateApplication(pid)
        AXClient.setMessagingTimeout(appElement)
        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(context).toOpaque())
        var registered: [String] = []
        for name in Self.observedNotifications {
            if AXObserverAddNotification(observer, appElement, name as CFString, refcon) == .success {
                registered.append(name)
            }
        }
        let coreRegistered = Self.coreNotifications.isSubset(of: Set(registered))
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        let box = ObserverBox(
            observer: observer,
            appElement: appElement,
            context: context,
            registered: registered,
            coreRegistered: coreRegistered
        )

        lock.lock()
        if let existing = observers[pid] {
            // Lost a registration race — keep the first, tear down ours.
            lock.unlock()
            Self.tearDown(box)
            return existing.coreRegistered
        }
        guard coreRegistered else {
            // Not trustworthy for invalidation — count it and don't keep a
            // half-observer around; this pid scrapes fresh every harvest.
            pendingMetrics.observerRegistrationFailures += 1
            lock.unlock()
            Self.tearDown(box)
            return false
        }
        observers[pid] = box
        lock.unlock()
        return true
    }

    /// Must be called with `lock` HELD. Returns observer boxes the caller must
    /// tear down after unlocking.
    private func evictIfNeededLocked(keeping pid: pid_t) -> [ObserverBox] {
        var boxes: [ObserverBox] = []
        while entries.count > Self.maxTrackedApps {
            let evictable = entries.filter { $0.key != pid }
            guard let oldest = evictable.min(by: { $0.value.lastUsedAt < $1.value.lastUsedAt }) else { break }
            entries.removeValue(forKey: oldest.key)
            if let box = observers.removeValue(forKey: oldest.key) {
                boxes.append(box)
            }
            pendingMetrics.evictions += 1
        }
        return boxes
    }

    private static func tearDown(_ box: ObserverBox) {
        CFRunLoopRemoveSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(box.observer),
            .defaultMode
        )
        for name in box.registered {
            AXObserverRemoveNotification(box.observer, box.appElement, name as CFString)
        }
    }
}
