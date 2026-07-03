import AppKit
import CascadeMemory
import ComputerUseKit
import CoreGraphics
import Foundation

// d19: the AX-grounding eval. The earlier bench could only replay recorded frames
// whose targets are privacy-hashed (audit rows never store raw text), so most
// exported cases were unscoreable. This eval closes that gap by generating its
// target corpus from a LIVE AX crawl of the app under test — the crawl owns the
// ground truth (label + role + identifier + exact frame), no recorded frame or
// hash sidecar involved. Each target is then scored per-app on two questions:
//   1. exposure — does AX still expose the target to `AXElementResolver.find`?
//   2. landing  — does the resolved click point actually LAND on the target,
//      verified by a systemwide hit-test of the final screen state
//      (`AXElementResolver.hitTestActionableMatch`), never by click-count.
// Harness-only: every command that touches this rides the existing
// `cascade.experimentalGroundingBench` flag; report rows carry stable-id hashes,
// role tokens, counts, and numeric coordinates — never raw label text.

// MARK: - Target corpus (from a live AX crawl)

public struct AXGroundingTarget: Codable, Equatable, Sendable {
    /// v2 (d20): adds optional `supportedActions` so the regression corpus can
    /// derive semantic action traces. v1 rows decode unchanged (nil actions).
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    /// Stable AX node id (`ax:<hash>`) from `AXElementResolver.stableNodeID` — the
    /// primary identity the landing check matches against.
    public let targetID: String
    public let appBundle: String?
    public let appName: String
    /// The resolve query. Lives only in the local corpus JSONL (the harness input,
    /// like the fixture cases) — report rows reference the target by `targetID`.
    public let label: String
    public let role: String
    public let subrole: String?
    public let identifier: String?
    public let container: String?
    /// Semantic AX actions the node supported at crawl time (AXPress/…), as
    /// captured by the d05 actionable-node harvest. nil on v1 corpus rows.
    public let supportedActions: [String]?
    public let frameX: Double
    public let frameY: Double
    public let frameWidth: Double
    public let frameHeight: Double

    public init(
        schemaVersion: Int = AXGroundingTarget.currentSchemaVersion,
        targetID: String,
        appBundle: String?,
        appName: String,
        label: String,
        role: String,
        subrole: String? = nil,
        identifier: String? = nil,
        container: String? = nil,
        supportedActions: [String]? = nil,
        frame: CGRect
    ) {
        self.schemaVersion = schemaVersion
        self.targetID = targetID
        self.appBundle = appBundle
        self.appName = appName
        self.label = label
        self.role = role
        self.subrole = subrole
        self.identifier = identifier
        self.container = container
        self.supportedActions = supportedActions.map { $0.sorted() }
        self.frameX = frame.minX
        self.frameY = frame.minY
        self.frameWidth = frame.width
        self.frameHeight = frame.height
    }

    public var frame: CGRect {
        CGRect(x: frameX, y: frameY, width: frameWidth, height: frameHeight)
    }

    public var center: CGPoint {
        CGPoint(x: frame.midX, y: frame.midY)
    }

    public var appKey: String {
        appBundle ?? appName
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case targetID = "target_id"
        case appBundle = "app_bundle"
        case appName = "app_name"
        case label
        case role
        case subrole
        case identifier
        case container
        case supportedActions = "supported_actions"
        case frameX = "frame_x"
        case frameY = "frame_y"
        case frameWidth = "frame_width"
        case frameHeight = "frame_height"
    }
}

public enum AXGroundingTargetJSONL {
    public static func load(from url: URL) throws -> [AXGroundingTarget] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return try text
            .split(whereSeparator: \.isNewline)
            .map { try JSONDecoder().decode(AXGroundingTarget.self, from: Data($0.utf8)) }
    }

    public static func write(_ targets: [AXGroundingTarget], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = try targets
            .map { String(decoding: try encoder.encode($0), as: UTF8.self) }
            .joined(separator: "\n")
        try body.appending(targets.isEmpty ? "" : "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Live crawl

public enum AXGroundingCrawlError: Error, Equatable, CustomStringConvertible {
    case accessibilityUnavailable
    case noFrontmostApplication
    case sensitiveAppRefused(String)
    case appNotRunning(String)
    case frontmostMismatch(expected: String, actual: String)

    public var description: String {
        switch self {
        case .accessibilityUnavailable:
            return "Accessibility permission is unavailable — grant it before crawling."
        case .noFrontmostApplication:
            return "No frontmost application to crawl."
        case .sensitiveAppRefused(let app):
            return "Refusing to crawl sensitive app \(app)."
        case .appNotRunning(let bundle):
            return "No running application with bundle identifier \(bundle)."
        case .frontmostMismatch(let expected, let actual):
            return "Expected \(expected) frontmost after activation, found \(actual). Bring the app forward and retry."
        }
    }
}

public struct AXGroundingCrawl: Equatable, Sendable {
    public let targets: [AXGroundingTarget]
    public let appBundle: String?
    public let appName: String
    public let visitedNodeCount: Int

    public init(targets: [AXGroundingTarget], appBundle: String?, appName: String, visitedNodeCount: Int) {
        self.targets = targets
        self.appBundle = appBundle
        self.appName = appName
        self.visitedNodeCount = visitedNodeCount
    }
}

public enum AXGroundingCrawler {
    /// Activates `bundleIdentifier` (already-running app only — the eval never
    /// launches software) and waits for it to settle so the crawl/eval sees it
    /// frontmost.
    public static func activate(bundleIdentifier: String, settleSeconds: TimeInterval = 1.0) throws {
        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .first(where: { !$0.isTerminated }) else {
            throw AXGroundingCrawlError.appNotRunning(bundleIdentifier)
        }
        app.activate(options: [])
        Thread.sleep(forTimeInterval: max(0, settleSeconds))
        let frontmost = NSWorkspace.shared.frontmostApplication
        guard frontmost?.bundleIdentifier == bundleIdentifier else {
            throw AXGroundingCrawlError.frontmostMismatch(
                expected: bundleIdentifier,
                actual: frontmost?.bundleIdentifier ?? frontmost?.localizedName ?? "none"
            )
        }
    }

    /// Crawls the frontmost app's labeled actionable controls (the same bounded
    /// harvest the grounder itself uses — `AXElementResolver.interactablesWithDiagnostics`)
    /// into eval targets. Sensitive apps are refused outright, matching the
    /// exporter's `PrivacyRules` gate.
    public static func crawlFrontmost(limit: Int = 40) throws -> AXGroundingCrawl {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else {
            throw AXGroundingCrawlError.noFrontmostApplication
        }
        let appName = frontmost.localizedName ?? "Unknown"
        let appBundle = frontmost.bundleIdentifier
        guard !PrivacyRules.isSensitive(appName: appName, bundleIdentifier: appBundle, windowTitle: nil) else {
            throw AXGroundingCrawlError.sensitiveAppRefused(appBundle ?? appName)
        }
        let harvest = AXElementResolver.interactablesWithDiagnostics(limit: limit)
        guard harvest.diagnostics.errorSummary.permissionDeniedCount == 0 else {
            throw AXGroundingCrawlError.accessibilityUnavailable
        }
        let targets = harvest.matches.compactMap { match -> AXGroundingTarget? in
            guard let id = match.id, let frame = match.frame else { return nil }
            let label = match.descriptor?.label ?? match.title
            guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return AXGroundingTarget(
                targetID: id,
                appBundle: appBundle,
                appName: appName,
                label: label,
                role: match.role,
                subrole: match.actionableNode?.subrole,
                identifier: match.actionableNode?.identifier ?? match.descriptor?.identifier,
                container: match.descriptor?.container,
                supportedActions: match.actionableNode?.supportedActions,
                frame: frame
            )
        }
        return AXGroundingCrawl(
            targets: targets,
            appBundle: appBundle,
            appName: appName,
            visitedNodeCount: harvest.diagnostics.visitedNodeCount
        )
    }
}

// MARK: - Probe (live AX resolve + execution hit-test, injectable for tests)

public struct AXGroundingHitIdentity: Equatable, Sendable {
    public let stableID: String
    public let role: String
    public let label: String
    public let identifier: String?

    public init(stableID: String, role: String, label: String, identifier: String? = nil) {
        self.stableID = stableID
        self.role = role
        self.label = label
        self.identifier = identifier
    }
}

public enum AXGroundingProbeResolution: Equatable, Sendable {
    /// The target's app is not frontmost — the final-state check would be
    /// meaningless, so the case is skipped, not failed.
    case appNotFrontmost
    /// `AXElementResolver.find` no longer exposes the target.
    case notExposed
    /// AX resolved a click point; `hit` is what a click there would actually
    /// land on per the systemwide hit-test (nil when the hit-test failed).
    case resolved(point: CGPoint, hit: AXGroundingHitIdentity?)
}

// MARK: - Eval scoring

public enum AXGroundingEvalStatus: String, Codable, Equatable, Sendable {
    /// Execution/final-state pass: the resolved click point hit-tests to the target.
    case landed
    /// AX resolved a point but the click would land on a DIFFERENT element.
    case resolvedOffTarget = "resolved_off_target"
    /// AX resolved a point but the final-state hit-test read nothing there.
    case resolvedHitUnreadable = "resolved_hit_unreadable"
    /// AX no longer exposes the target at all.
    case notExposed = "not_exposed"
    case skippedAppNotFrontmost = "skipped_app_not_frontmost"
}

public struct AXGroundingEvalObservation: Codable, Equatable, Sendable {
    public let targetID: String
    public let appKey: String
    public let role: String
    public let status: AXGroundingEvalStatus
    public let resolvedX: Double?
    public let resolvedY: Double?
    /// Whether the resolved point still falls inside the frame recorded at crawl
    /// time — drift signal only, never the score (controls legitimately move).
    public let withinCrawledFrame: Bool?
    /// Stable id (`ax:<hash>`) of the element the click would actually land on.
    public let hitElementID: String?
    public let latency: TimeInterval?

    public init(
        targetID: String,
        appKey: String,
        role: String,
        status: AXGroundingEvalStatus,
        resolvedX: Double? = nil,
        resolvedY: Double? = nil,
        withinCrawledFrame: Bool? = nil,
        hitElementID: String? = nil,
        latency: TimeInterval? = nil
    ) {
        self.targetID = targetID
        self.appKey = appKey
        self.role = role
        self.status = status
        self.resolvedX = resolvedX
        self.resolvedY = resolvedY
        self.withinCrawledFrame = withinCrawledFrame
        self.hitElementID = hitElementID
        self.latency = latency
    }
}

public struct AXGroundingEvalAppBreakdown: Codable, Equatable, Sendable {
    public let appBundle: String?
    public let appName: String
    public let scored: Int
    public let exposed: Int
    public let landed: Int
    public let exposureRate: Double
    public let landRate: Double
}

public struct AXGroundingEvalReport: Codable, Equatable, Sendable {
    public let totalTargets: Int
    public let scoredTargets: Int
    public let exposedTargets: Int
    public let landedTargets: Int
    public let notExposed: Int
    public let resolvedOffTarget: Int
    public let resolvedHitUnreadable: Int
    public let skippedAppNotFrontmost: Int
    /// Does AX expose the target? exposed / scored.
    public let exposureRate: Double
    /// Does the resolved click LAND on the target (final-state)? landed / scored.
    public let landRate: Double
    public let perApp: [String: AXGroundingEvalAppBreakdown]
    public let observations: [AXGroundingEvalObservation]

    public func jsonString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

public struct AXGroundingEvalRunner: Sendable {
    public typealias Probe = @Sendable (AXGroundingTarget) -> AXGroundingProbeResolution

    public init() {}

    /// Live pass: resolve each target through the real AX stack and hit-test the
    /// resolved point against the current screen. Injectable `probe` keeps the
    /// scoring pure and unit-testable without an AX session.
    public func run(targets: [AXGroundingTarget], probe: Probe = AXGroundingEvalRunner.liveProbe) -> AXGroundingEvalReport {
        var observations: [AXGroundingEvalObservation] = []
        for target in targets {
            let started = ContinuousClock.now
            let resolution = probe(target)
            let latency = started.duration(to: .now).asTimeInterval
            observations.append(Self.observation(for: target, resolution: resolution, latency: latency))
        }
        return Self.report(targets: targets, observations: observations)
    }

    /// The default live probe. Exposure = the resolver re-finds the crawled
    /// descriptor; landing = the systemwide hit-test at the resolved center.
    public static let liveProbe: Probe = { target in
        let frontmost = NSWorkspace.shared.frontmostApplication
        let frontmostKey = frontmost?.bundleIdentifier ?? frontmost?.localizedName
        guard frontmostKey == target.appKey else { return .appNotFrontmost }
        let descriptor = AXElementResolver.Descriptor(
            label: target.label,
            role: target.role,
            identifier: target.identifier,
            container: target.container
        )
        guard let match = AXElementResolver.find(descriptor: descriptor, near: target.center) else {
            return .notExposed
        }
        let hit = AXElementResolver.hitTestActionableMatch(atCG: match.center).flatMap { landed -> AXGroundingHitIdentity? in
            guard let id = landed.id else { return nil }
            return AXGroundingHitIdentity(
                stableID: id,
                role: landed.role,
                label: landed.descriptor?.label ?? landed.title,
                identifier: landed.actionableNode?.identifier ?? landed.descriptor?.identifier
            )
        }
        return .resolved(point: match.center, hit: hit)
    }

    /// Identity match between the crawled target and the element the click lands
    /// on, strictest first: stable id → accessibility identifier (role-confirmed)
    /// → role + resolver-normalized label. Frame proximity is deliberately NOT an
    /// identity signal — controls move; identity, not geometry, is the score.
    public static func identityMatches(target: AXGroundingTarget, hit: AXGroundingHitIdentity) -> Bool {
        if hit.stableID == target.targetID { return true }
        if let targetIdentifier = target.identifier, let hitIdentifier = hit.identifier,
           !targetIdentifier.isEmpty, targetIdentifier == hitIdentifier, hit.role == target.role {
            return true
        }
        let targetLabel = AXElementResolver.normalizedLabel(target.label)
        let hitLabel = AXElementResolver.normalizedLabel(hit.label)
        return hit.role == target.role && !targetLabel.isEmpty && targetLabel == hitLabel
    }

    public static func observation(
        for target: AXGroundingTarget,
        resolution: AXGroundingProbeResolution,
        latency: TimeInterval? = nil
    ) -> AXGroundingEvalObservation {
        switch resolution {
        case .appNotFrontmost:
            return AXGroundingEvalObservation(
                targetID: target.targetID,
                appKey: target.appKey,
                role: target.role,
                status: .skippedAppNotFrontmost,
                latency: latency
            )
        case .notExposed:
            return AXGroundingEvalObservation(
                targetID: target.targetID,
                appKey: target.appKey,
                role: target.role,
                status: .notExposed,
                latency: latency
            )
        case .resolved(let point, let hit):
            let status: AXGroundingEvalStatus
            if let hit {
                status = identityMatches(target: target, hit: hit) ? .landed : .resolvedOffTarget
            } else {
                status = .resolvedHitUnreadable
            }
            return AXGroundingEvalObservation(
                targetID: target.targetID,
                appKey: target.appKey,
                role: target.role,
                status: status,
                resolvedX: point.x,
                resolvedY: point.y,
                withinCrawledFrame: target.frame.contains(point),
                hitElementID: hit?.stableID,
                latency: latency
            )
        }
    }

    public static func report(
        targets: [AXGroundingTarget],
        observations: [AXGroundingEvalObservation]
    ) -> AXGroundingEvalReport {
        func count(_ status: AXGroundingEvalStatus) -> Int {
            observations.filter { $0.status == status }.count
        }
        let landed = count(.landed)
        let offTarget = count(.resolvedOffTarget)
        let unreadable = count(.resolvedHitUnreadable)
        let notExposed = count(.notExposed)
        let skipped = count(.skippedAppNotFrontmost)
        let scored = landed + offTarget + unreadable + notExposed
        let exposed = landed + offTarget + unreadable
        let appNames = Dictionary(
            targets.map { ($0.appKey, $0.appName) },
            uniquingKeysWith: { first, _ in first }
        )
        let appBundles = Dictionary(
            targets.map { ($0.appKey, $0.appBundle) },
            uniquingKeysWith: { first, _ in first }
        )
        let grouped = Dictionary(grouping: observations.filter { $0.status != .skippedAppNotFrontmost }, by: \.appKey)
        let perApp = grouped.mapValues { rows -> AXGroundingEvalAppBreakdown in
            let appLanded = rows.filter { $0.status == .landed }.count
            let appExposed = rows.filter { $0.status != .notExposed }.count
            let appKey = rows[0].appKey
            return AXGroundingEvalAppBreakdown(
                appBundle: appBundles[appKey] ?? nil,
                appName: appNames[appKey] ?? appKey,
                scored: rows.count,
                exposed: appExposed,
                landed: appLanded,
                exposureRate: rows.isEmpty ? 0 : Double(appExposed) / Double(rows.count),
                landRate: rows.isEmpty ? 0 : Double(appLanded) / Double(rows.count)
            )
        }
        return AXGroundingEvalReport(
            totalTargets: targets.count,
            scoredTargets: scored,
            exposedTargets: exposed,
            landedTargets: landed,
            notExposed: notExposed,
            resolvedOffTarget: offTarget,
            resolvedHitUnreadable: unreadable,
            skippedAppNotFrontmost: skipped,
            exposureRate: scored == 0 ? 0 : Double(exposed) / Double(scored),
            landRate: scored == 0 ? 0 : Double(landed) / Double(scored),
            perApp: perApp,
            observations: observations
        )
    }
}

private extension Duration {
    var asTimeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1_000_000_000_000_000_000
    }
}
