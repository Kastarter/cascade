import AppKit
import ComputerUseKit
import Foundation
import MacContextKit
import ProviderKit

/// Local deterministic region grounding for "where is X" before escalating to a
/// visual/cloud grounder. It reuses the same AX/OCR trust policy as point
/// grounding, but permits passive text candidates because a highlight is not a
/// click.
public struct LocalRegionNarrower: Sendable {
    public typealias SnapshotProvider = @Sendable () async -> AppWindowSnapshot
    public typealias RuntimeProfileProvider = @Sendable () async -> AXRuntimeProfile?
    public typealias AccessibilityCandidateProvider = @Sendable (
        _ displayWidthPoints: Int,
        _ displayHeightPoints: Int,
        _ policy: ScreenElementIndex.TrustPolicy,
        _ hints: AppSkillRuntimeHints?,
        _ runtimeProfile: AXRuntimeProfile?
    ) async -> [ScreenElementIndex.Candidate]
    public typealias OCRCandidateProvider = @Sendable (
        _ screenshot: Data,
        _ target: String,
        _ displayWidthPoints: Int,
        _ displayHeightPoints: Int,
        _ policy: ScreenElementIndex.TrustPolicy
    ) async -> [ScreenElementIndex.Candidate]

    public struct ScoredRegionCandidate: Equatable, Sendable {
        public let candidate: ScreenElementIndex.IndexedCandidate
        public let score: Double
        public let textScore: Double

        public init(candidate: ScreenElementIndex.IndexedCandidate, score: Double, textScore: Double) {
            self.candidate = candidate
            self.score = score
            self.textScore = textScore
        }
    }

    private let skills: AppSkillRegistry
    private let policy: ScreenElementIndex.TrustPolicy
    private let snapshotProvider: SnapshotProvider
    private let runtimeProfileProvider: RuntimeProfileProvider
    private let accessibilityCandidateProvider: AccessibilityCandidateProvider
    private let ocrCandidateProvider: OCRCandidateProvider
    private let onRuntimeProfile: (@Sendable (AXRuntimeProfile) async -> Void)?

    public init(
        skills: AppSkillRegistry,
        policy: ScreenElementIndex.TrustPolicy = .default,
        snapshotProvider: @escaping SnapshotProvider = {
            await MainActor.run { AppWindowObserver.snapshot() }
        },
        runtimeProfileProvider: @escaping RuntimeProfileProvider = {
            await MainActor.run { AXElementResolver.runtimeProfileForFrontmost() }
        },
        accessibilityCandidateProvider: @escaping AccessibilityCandidateProvider = { width, height, policy, hints, profile in
            await MainActor.run {
                ScreenElementIndex.accessibilityCandidates(
                    displayWidthPoints: width,
                    displayHeightPoints: height,
                    policy: policy,
                    appSkillHints: hints,
                    runtimeProfile: profile
                )
            }
        },
        ocrCandidateProvider: @escaping OCRCandidateProvider = { screenshot, target, width, height, policy in
            await Task.detached {
                ScreenElementIndex.ocrCandidates(
                    screenshot: screenshot,
                    target: target,
                    displayWidthPoints: width,
                    displayHeightPoints: height,
                    policy: policy
                )
            }.value
        },
        onRuntimeProfile: (@Sendable (AXRuntimeProfile) async -> Void)? = nil
    ) {
        self.skills = skills
        self.policy = policy
        self.snapshotProvider = snapshotProvider
        self.runtimeProfileProvider = runtimeProfileProvider
        self.accessibilityCandidateProvider = accessibilityCandidateProvider
        self.ocrCandidateProvider = ocrCandidateProvider
        self.onRuntimeProfile = onRuntimeProfile
    }

    public func narrow(
        screenshot: Data,
        target: String,
        displayWidthPoints: Int,
        displayHeightPoints: Int
    ) async -> ElementRegion? {
        let snapshot = await snapshotProvider()
        let hints = skills.skill(appName: snapshot.appName, bundleIdentifier: snapshot.bundleIdentifier)?.hints
        let resolvedTarget = ScreenElementIndex.applyTargetAliases(target, aliases: hints?.targetAliases ?? [:])
        let runtimeProfile = await runtimeProfileProvider()
        if let runtimeProfile {
            await onRuntimeProfile?(runtimeProfile)
        }

        async let axCandidates = accessibilityCandidateProvider(
            displayWidthPoints,
            displayHeightPoints,
            policy,
            hints,
            runtimeProfile
        )
        async let ocrCandidates = ocrCandidateProvider(
            screenshot,
            resolvedTarget,
            displayWidthPoints,
            displayHeightPoints,
            policy
        )

        let collectedAXCandidates = await axCandidates
        let collectedOCRCandidates = await ocrCandidates
        let localCandidates = collectedAXCandidates + collectedOCRCandidates + Self.windowMetadataCandidates(
            snapshot: snapshot,
            displayWidthPoints: displayWidthPoints,
            displayHeightPoints: displayHeightPoints
        )
        let indexed = ScreenElementIndex.build(
            from: ScreenElementIndex.applyPreferredSourceHints(
                localCandidates,
                hints: hints,
                target: resolvedTarget
            )
        )
        guard let selected = Self.bestRegionCandidate(for: resolvedTarget, in: indexed, policy: policy) else {
            return nil
        }
        return ElementRegion(rect: selected.candidate.bounds.cgRect, speech: Self.speech(for: selected.candidate))
    }

    public static func bestRegionCandidate(
        for target: String,
        in candidates: [ScreenElementIndex.IndexedCandidate],
        aliases: [String: [String]] = [:],
        policy: ScreenElementIndex.TrustPolicy = .default,
        minimumScore: Double = 0.90,
        minimumTextScore: Double = 2.0,
        minimumMargin: Double = 0.30
    ) -> ScoredRegionCandidate? {
        let resolvedTarget = ScreenElementIndex.applyTargetAliases(target, aliases: aliases)
        let normalizedTarget = ScreenElementIndex.normalizedSearchLabel(resolvedTarget)
        guard !normalizedTarget.isEmpty, !candidates.isEmpty else { return nil }

        let scored = candidates.compactMap { candidate -> ScoredRegionCandidate? in
            guard candidate.clickSafety != .unsafe else { return nil }
            let normalizedLabel = ScreenElementIndex.normalizedSearchLabel(candidate.label)
            let textScore = ScreenElementIndex.textMatchScore(needle: normalizedTarget, candidate: normalizedLabel)
            guard textScore >= minimumTextScore else { return nil }
            let score = textScore * candidate.trust
                + candidate.confidence * 0.05
                + Double(sourceRank(candidate.source)) * 0.01
            guard score >= minimumScore else { return nil }
            return ScoredRegionCandidate(candidate: candidate, score: score, textScore: textScore)
        }
        .sorted { left, right in
            if left.score != right.score { return left.score > right.score }
            if sourceRank(left.candidate.source) != sourceRank(right.candidate.source) {
                return sourceRank(left.candidate.source) > sourceRank(right.candidate.source)
            }
            if left.candidate.bounds.area != right.candidate.bounds.area {
                return left.candidate.bounds.area < right.candidate.bounds.area
            }
            return left.candidate.id < right.candidate.id
        }

        guard let best = scored.first else { return nil }
        if scored.count > 1, best.score - scored[1].score < minimumMargin {
            return nil
        }
        return best
    }

    public static func windowMetadataCandidates(
        snapshot: AppWindowSnapshot,
        displayWidthPoints: Int,
        displayHeightPoints: Int
    ) -> [ScreenElementIndex.Candidate] {
        let labels = [snapshot.windowTitle, Optional(snapshot.appName)]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "Unknown app" }
        guard !labels.isEmpty else { return [] }

        let height = min(48.0, Double(max(1, displayHeightPoints)))
        let bounds = ScreenElementIndex.Bounds(
            x: 0,
            y: max(0, Double(displayHeightPoints) - height),
            width: Double(max(1, displayWidthPoints)),
            height: height
        )
        var seen = Set<String>()
        return labels.compactMap { label in
            guard seen.insert(label.lowercased()).inserted else { return nil }
            return ScreenElementIndex.Candidate(
                bounds: bounds,
                label: label,
                role: .container,
                source: .visual,
                confidence: 0.50,
                trust: 0.25,
                clickSafety: .passive
            )
        }
    }

    private static func speech(for candidate: ScreenElementIndex.IndexedCandidate) -> String {
        let label = candidate.label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return "Here - it is in this area." }
        return "Here - \(label)."
    }

    private static func sourceRank(_ source: ScreenElementIndex.Source) -> Int {
        switch source {
        case .accessibility: return 3
        case .visual: return 2
        case .ocr: return 1
        }
    }
}
