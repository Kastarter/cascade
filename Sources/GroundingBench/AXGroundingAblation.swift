import AppKit
import CascadeMemory
import ComputerUseKit
import CoreGraphics
import Foundation
import MacContextKit
import ProviderKit

// d21: the ablation runner — AX-only vs vision-only vs hybrid over the d19/d20
// corpus. This is THE number that tracks the failure rate: every arm replays
// the same crawled targets through the same execution/final-state scorer
// (`AXGroundingEvalRunner` — does the resolved click LAND on the target,
// verified by a systemwide hit-test, never click-count), so the only variable
// is the grounding stack:
//   • ax_only     — the d19 live AX probe (`AXElementResolver.find` → hit-test);
//                   the visual grounder is never consulted.
//   • vision_only — the shipped visual grounder (UI-TARS via `GrounderRegistry`)
//                   grounds a LIVE capture of the cursor display at the agent
//                   loop's exact geometry (`AgentResolution.best` capture,
//                   display-local AppKit points out, `DisplayCoordinateMapper`
//                   → CG global — the same chain `executeCU` clicks through);
//                   AX is never consulted for the point.
//   • hybrid      — the AX-first policy the d15 router + `MixtureGrounder`
//                   ship: the d15 route decides per target (canvas concept /
//                   distrusted-AX app → vision), an AX structural resolution
//                   wins outright, and vision is consulted ONLY when AX has no
//                   candidate.
// The report proves (or refutes) that the AX-first hybrid wins; its hybrid
// failure rate is the headline regression number. Harness-only: the CLI gates
// this behind the existing `cascade.experimentalGroundingBench` flag, and the
// report carries stable-id hashes, role/arm tokens, counts, and numeric
// coordinates only — never raw label text or OCR content. The real numbers
// REQUIRE a live run (Accessibility + Screen Recording + a grounder endpoint);
// see the CLI usage note.

// MARK: - Arms

public enum AXGroundingAblationArm: String, Codable, CaseIterable, Equatable, Sendable {
    case axOnly = "ax_only"
    case visionOnly = "vision_only"
    case hybrid

    /// Whether this arm needs a constructed visual grounder to run.
    public var needsVisualGrounder: Bool {
        self != .axOnly
    }
}

// MARK: - Report

public struct AXGroundingAblationArmSummary: Codable, Equatable, Sendable {
    public let arm: String
    public let scored: Int
    /// Targets for which the arm produced ANY candidate point (for the AX arm
    /// this is d19 "exposure"; for vision arms, "the grounder answered").
    public let candidates: Int
    public let landed: Int
    public let landRate: Double
    /// 1 − landRate over scored targets — the failure-rate number d21 tracks.
    public let failureRate: Double
    public let p50Latency: TimeInterval?
    public let p95Latency: TimeInterval?

    public init(
        arm: String,
        scored: Int,
        candidates: Int,
        landed: Int,
        landRate: Double,
        failureRate: Double,
        p50Latency: TimeInterval?,
        p95Latency: TimeInterval?
    ) {
        self.arm = arm
        self.scored = scored
        self.candidates = candidates
        self.landed = landed
        self.landRate = landRate
        self.failureRate = failureRate
        self.p50Latency = p50Latency
        self.p95Latency = p95Latency
    }

    private enum CodingKeys: String, CodingKey {
        case arm
        case scored
        case candidates
        case landed
        case landRate = "land_rate"
        case failureRate = "failure_rate"
        case p50Latency = "p50_latency"
        case p95Latency = "p95_latency"
    }
}

public struct AXGroundingAblationReport: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let generatedAt: String
    /// Order-independent hash of the target ids — ties the ablation to the
    /// exact corpus it ran over (hashes only, never text).
    public let corpusHash: String
    public let targetCount: Int
    /// Arm raw value → the full d19-shaped eval report for that arm.
    public let arms: [String: AXGroundingEvalReport]
    /// Ordered ax_only, vision_only, hybrid (present arms only).
    public let summaries: [AXGroundingAblationArmSummary]
    /// hybrid landRate − ax_only landRate; nil unless both arms scored.
    public let hybridMinusAXOnlyLandRate: Double?
    /// hybrid landRate − vision_only landRate; nil unless both arms scored.
    public let hybridMinusVisionOnlyLandRate: Double?
    /// THE d21 headline: the hybrid arm's failure rate on the corpus.
    public let hybridFailureRate: Double?
    /// true when the hybrid land rate ≥ every other scored arm's — the claim
    /// the AX-first plan makes, proven or refuted by a live run.
    public let hybridWins: Bool?

    public init(
        schemaVersion: Int = AXGroundingAblationReport.currentSchemaVersion,
        generatedAt: String,
        corpusHash: String,
        targetCount: Int,
        arms: [String: AXGroundingEvalReport],
        summaries: [AXGroundingAblationArmSummary],
        hybridMinusAXOnlyLandRate: Double?,
        hybridMinusVisionOnlyLandRate: Double?,
        hybridFailureRate: Double?,
        hybridWins: Bool?
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.corpusHash = corpusHash
        self.targetCount = targetCount
        self.arms = arms
        self.summaries = summaries
        self.hybridMinusAXOnlyLandRate = hybridMinusAXOnlyLandRate
        self.hybridMinusVisionOnlyLandRate = hybridMinusVisionOnlyLandRate
        self.hybridFailureRate = hybridFailureRate
        self.hybridWins = hybridWins
    }

    public func jsonString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case generatedAt = "generated_at"
        case corpusHash = "corpus_hash"
        case targetCount = "target_count"
        case arms
        case summaries
        case hybridMinusAXOnlyLandRate = "hybrid_minus_ax_only_land_rate"
        case hybridMinusVisionOnlyLandRate = "hybrid_minus_vision_only_land_rate"
        case hybridFailureRate = "hybrid_failure_rate"
        case hybridWins = "hybrid_wins"
    }
}

// MARK: - Runner

public struct AXGroundingAblationRunner: Sendable {
    /// One arm's per-target probe. Async because the vision arms await a live
    /// capture + grounder round trip; the resolution vocabulary is shared with
    /// the d19 eval (`notExposed` reads as "the arm produced no candidate").
    public typealias ArmProbe = @Sendable (AXGroundingTarget) async -> AXGroundingProbeResolution

    public init() {}

    /// Probes every target through one arm, timing each resolution. The CLI
    /// calls this per app group (so one activation covers all arms) and then
    /// assembles the combined report via `report(targets:observationsByArm:)`.
    public func observations(
        targets: [AXGroundingTarget],
        probe: ArmProbe
    ) async -> [AXGroundingEvalObservation] {
        var rows: [AXGroundingEvalObservation] = []
        for target in targets {
            let started = ContinuousClock.now
            let resolution = await probe(target)
            let latency = started.duration(to: .now).ablationTimeInterval
            rows.append(AXGroundingEvalRunner.observation(for: target, resolution: resolution, latency: latency))
        }
        return rows
    }

    /// Convenience single-pass run: every requested arm over the same targets.
    public func run(
        targets: [AXGroundingTarget],
        probes: [AXGroundingAblationArm: ArmProbe],
        generatedAt: Date = Date()
    ) async -> AXGroundingAblationReport {
        var observationsByArm: [AXGroundingAblationArm: [AXGroundingEvalObservation]] = [:]
        for arm in AXGroundingAblationArm.allCases {
            guard let probe = probes[arm] else { continue }
            observationsByArm[arm] = await observations(targets: targets, probe: probe)
        }
        return Self.report(targets: targets, observationsByArm: observationsByArm, generatedAt: generatedAt)
    }

    /// Pure assembly: per-arm d19 reports + the cross-arm comparison. Same
    /// observations in → same report out, so the math is unit-testable without
    /// a live screen.
    public static func report(
        targets: [AXGroundingTarget],
        observationsByArm: [AXGroundingAblationArm: [AXGroundingEvalObservation]],
        generatedAt: Date = Date()
    ) -> AXGroundingAblationReport {
        var arms: [String: AXGroundingEvalReport] = [:]
        var summaries: [AXGroundingAblationArmSummary] = []
        for arm in AXGroundingAblationArm.allCases {
            guard let rows = observationsByArm[arm] else { continue }
            let armReport = AXGroundingEvalRunner.report(targets: targets, observations: rows)
            arms[arm.rawValue] = armReport
            let latencies = rows.compactMap(\.latency)
            summaries.append(AXGroundingAblationArmSummary(
                arm: arm.rawValue,
                scored: armReport.scoredTargets,
                candidates: armReport.exposedTargets,
                landed: armReport.landedTargets,
                landRate: armReport.landRate,
                failureRate: armReport.scoredTargets == 0 ? 0 : 1 - armReport.landRate,
                p50Latency: GroundingBenchmarkRunner.percentile(latencies, 0.50),
                p95Latency: GroundingBenchmarkRunner.percentile(latencies, 0.95)
            ))
        }
        func landRate(_ arm: AXGroundingAblationArm) -> Double? {
            guard let report = arms[arm.rawValue], report.scoredTargets > 0 else { return nil }
            return report.landRate
        }
        let hybrid = landRate(.hybrid)
        let axOnly = landRate(.axOnly)
        let visionOnly = landRate(.visionOnly)
        let rivals = [axOnly, visionOnly].compactMap { $0 }
        return AXGroundingAblationReport(
            generatedAt: ISO8601DateFormatter().string(from: generatedAt),
            corpusHash: corpusHash(of: targets),
            targetCount: targets.count,
            arms: arms,
            summaries: summaries,
            hybridMinusAXOnlyLandRate: zip2(hybrid, axOnly).map(-),
            hybridMinusVisionOnlyLandRate: zip2(hybrid, visionOnly).map(-),
            hybridFailureRate: hybrid.map { 1 - $0 },
            hybridWins: hybrid.flatMap { rate in
                rivals.isEmpty ? nil : rate >= (rivals.max() ?? 0)
            }
        )
    }

    /// Order-independent hash over the target ids — hashes only, never text.
    public static func corpusHash(of targets: [AXGroundingTarget]) -> String {
        AuditIdentity.hash(targets.map(\.targetID).sorted().joined(separator: "|"))
    }

    private static func zip2<A, B>(_ lhs: A?, _ rhs: B?) -> (A, B)? {
        guard let lhs, let rhs else { return nil }
        return (lhs, rhs)
    }
}

// MARK: - Arm probes

extension AXGroundingAblationRunner {
    /// ax_only: the d19 live probe unchanged — `AXElementResolver.find` for the
    /// candidate, systemwide hit-test for the landing. Vision never runs.
    public static let axOnlyProbe: ArmProbe = { target in
        AXGroundingEvalRunner.liveProbe(target)
    }

    /// vision_only: the shipped visual grounder over a LIVE capture, walking
    /// the exact geometry the agent loop clicks through — capture the cursor
    /// display at `AgentResolution.best`, ground with the display's point size,
    /// map the returned display-local AppKit point to CG global via
    /// `DisplayCoordinateMapper` (the same conversion `executeCU` uses), then
    /// hit-test the landing. AX is never consulted for the point (the hit-test
    /// itself is AX — that is the SCORER, identical across arms).
    ///
    /// The cursor display is what the shipped loop captures, so keep the cursor
    /// on the display of the app under test (single-display expected).
    public static func visionOnlyProbe(grounder: any VisualGrounder) -> ArmProbe {
        { target in
            let frontmost = NSWorkspace.shared.frontmostApplication
            let frontmostKey = frontmost?.bundleIdentifier ?? frontmost?.localizedName
            guard frontmostKey == target.appKey else { return .appNotFrontmost }
            guard let mapper = await MainActor.run(body: Self.cursorDisplayMapper) else {
                return .notExposed
            }
            let widthPoints = Int(mapper.appKitFrame.width)
            let heightPoints = Int(mapper.appKitFrame.height)
            let res = AgentResolution.best(forWidth: widthPoints, height: heightPoints)
            guard let shot = await ScreenCaptureUtility.captureCursorScreenJPEG(width: res.w, height: res.h) else {
                return .notExposed
            }
            guard let local = await grounder.ground(
                screenshot: shot,
                target: target.label,
                displayWidthPoints: widthPoints,
                displayHeightPoints: heightPoints
            ), let cgPoint = mapper.cgGlobal(fromScreenLocal: local) else {
                return .notExposed
            }
            return .resolved(point: cgPoint, hit: Self.hitIdentity(atCG: cgPoint))
        }
    }

    /// hybrid: the shipped AX-first policy at eval granularity. `routesToVision`
    /// is the d15 gate (canvas concept / distrusted-AX app → vision outright);
    /// otherwise AX runs first and its structural resolution WINS — vision is
    /// consulted only when AX has no candidate (`notExposed`), mirroring
    /// `MixtureGrounder`'s fallback order. A frontmost-discipline skip stays a
    /// skip in both arms.
    public static func hybridProbe(
        ax: @escaping ArmProbe,
        vision: @escaping ArmProbe,
        routesToVision: @escaping @Sendable (AXGroundingTarget) -> Bool
    ) -> ArmProbe {
        { target in
            if routesToVision(target) {
                return await vision(target)
            }
            let axResolution = await ax(target)
            if case .notExposed = axResolution {
                return await vision(target)
            }
            return axResolution
        }
    }

    /// The live d15 route for a corpus target: one decision per target through
    /// the SAME `GroundingRouter` gate the shipped mixture consults — canvas
    /// concepts and distrusted-AX apps (`AppSkill.axUnreliable`) go to vision.
    /// The tree-health stages need a live runtime profile scrape mid-run and are
    /// deliberately not replayed here; corpus targets exist because a crawl
    /// proved the tree healthy.
    public static func liveRoutesToVision(skills: AppSkillRegistry) -> @Sendable (AXGroundingTarget) -> Bool {
        { target in
            let skill = skills.skill(appName: target.appName, bundleIdentifier: target.appBundle)
            let decision = GroundingRouter.route(
                target: target.label,
                requestKind: .labelMatch,
                frontmostBundleIdentifier: target.appBundle,
                axUnreliable: skill?.axUnreliable == true,
                runtimeProfile: { nil }
            )
            return !decision.allowsAX
        }
    }

    /// Builds the live probe set for the requested arms. Vision arms require a
    /// constructed grounder; nil means only `axOnly` can run.
    public static func liveProbes(
        arms: [AXGroundingAblationArm],
        grounder: (any VisualGrounder)?,
        skills: AppSkillRegistry
    ) -> [AXGroundingAblationArm: ArmProbe] {
        var probes: [AXGroundingAblationArm: ArmProbe] = [:]
        for arm in arms {
            switch arm {
            case .axOnly:
                probes[.axOnly] = axOnlyProbe
            case .visionOnly:
                guard let grounder else { continue }
                probes[.visionOnly] = visionOnlyProbe(grounder: grounder)
            case .hybrid:
                guard let grounder else { continue }
                probes[.hybrid] = hybridProbe(
                    ax: axOnlyProbe,
                    vision: visionOnlyProbe(grounder: grounder),
                    routesToVision: liveRoutesToVision(skills: skills)
                )
            }
        }
        return probes
    }

    /// The display the shipped loop would capture: the one containing the
    /// cursor, falling back to the main screen (mirrors
    /// `ScreenCaptureUtility.cursorDisplay`).
    @MainActor
    static func cursorDisplayMapper() -> DisplayCoordinateMapper? {
        let cursor = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(cursor, $0.frame, false) } ?? NSScreen.main
        return screen.flatMap(DisplayCoordinateMapper.init(screen:))
    }

    /// Landing identity at a CG global point — the d19 scorer's hit-test.
    static func hitIdentity(atCG point: CGPoint) -> AXGroundingHitIdentity? {
        AXElementResolver.hitTestActionableMatch(atCG: point).flatMap { landed in
            guard let id = landed.id else { return nil }
            return AXGroundingHitIdentity(
                stableID: id,
                role: landed.role,
                label: landed.descriptor?.label ?? landed.title,
                identifier: landed.actionableNode?.identifier ?? landed.descriptor?.identifier
            )
        }
    }
}

// MARK: - Corpus loading (manifest directory -> targets, grouped per app)

public enum AXGroundingAblationCorpusError: Error, Equatable, CustomStringConvertible {
    case missingManifest(String)
    case emptyCorpus

    public var description: String {
        switch self {
        case .missingManifest(let path):
            return "No manifest.json in corpus directory \(path). Generate one with ax-corpus first."
        case .emptyCorpus:
            return "The corpus contains no targets — nothing to ablate."
        }
    }
}

public enum AXGroundingAblationCorpus {
    /// One app's slice of the corpus, in manifest order — the CLI activates
    /// the app once, then runs every requested arm over its targets.
    public struct AppGroup: Equatable, Sendable {
        public let bundleID: String
        public let displayName: String
        public let targets: [AXGroundingTarget]

        public init(bundleID: String, displayName: String, targets: [AXGroundingTarget]) {
            self.bundleID = bundleID
            self.displayName = displayName
            self.targets = targets
        }
    }

    /// Loads a d20 corpus directory (per-app `*.tasks.jsonl` + manifest.json)
    /// into per-app target groups. Apps the manifest recorded as not crawled
    /// are skipped — they contributed no tasks.
    public static func loadGroups(fromCorpusDirectory directory: URL) throws -> [AppGroup] {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw AXGroundingAblationCorpusError.missingManifest(directory.path)
        }
        let manifest = try JSONDecoder().decode(
            AXRegressionCorpusManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        return try manifest.apps.compactMap { entry -> AppGroup? in
            guard entry.status == .crawled, let file = entry.file else { return nil }
            let tasks = try AXRegressionTaskJSONL.load(from: directory.appendingPathComponent(file))
            guard !tasks.isEmpty else { return nil }
            return AppGroup(
                bundleID: entry.bundleID,
                displayName: entry.displayName,
                targets: tasks.map(\.target)
            )
        }
    }

    /// Groups a flat target list (ax-crawl / ax-eval style input) by app,
    /// preserving first-seen order.
    public static func groups(fromTargets targets: [AXGroundingTarget]) -> [AppGroup] {
        var order: [String] = []
        var byApp: [String: [AXGroundingTarget]] = [:]
        var names: [String: (bundle: String, display: String)] = [:]
        for target in targets {
            let key = target.appKey
            if byApp[key] == nil {
                order.append(key)
                names[key] = (bundle: target.appBundle ?? target.appName, display: target.appName)
            }
            byApp[key, default: []].append(target)
        }
        return order.map { key in
            AppGroup(
                bundleID: names[key]?.bundle ?? key,
                displayName: names[key]?.display ?? key,
                targets: byApp[key] ?? []
            )
        }
    }
}

private extension Duration {
    var ablationTimeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1_000_000_000_000_000_000
    }
}
