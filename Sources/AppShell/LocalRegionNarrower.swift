import AppKit
import ComputerUseKit
import Foundation
import ImageIO
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
        let harvest = await harvestIndexedCandidates(
            screenshot: screenshot,
            target: target,
            displayWidthPoints: displayWidthPoints,
            displayHeightPoints: displayHeightPoints
        )
        guard let selected = Self.bestRegionCandidate(
            for: harvest.resolvedTarget, in: harvest.candidates, policy: policy
        ) else {
            return nil
        }
        return ElementRegion(rect: selected.candidate.bounds.cgRect, speech: Self.speech(for: selected.candidate))
    }

    /// d16 (crop-and-refine, ScreenSpot-Pro / DRS-GUI): the region worth
    /// CROPPING to before a visual-grounder round trip. Same AX/OCR/window
    /// harvest as `narrow`, but instead of demanding a single confident winner
    /// it returns the padded union of every plausible-but-unconvincing match —
    /// exactly the uncertainty a higher-effective-resolution crop resolves.
    /// Nil when there is no local evidence at all (a crop would be a guess) or
    /// when the evidence spans most of the screen (a crop would not raise the
    /// effective resolution).
    public func narrowUncertainRegion(
        screenshot: Data,
        target: String,
        displayWidthPoints: Int,
        displayHeightPoints: Int
    ) async -> CGRect? {
        let harvest = await harvestIndexedCandidates(
            screenshot: screenshot,
            target: target,
            displayWidthPoints: displayWidthPoints,
            displayHeightPoints: displayHeightPoints
        )
        return Self.uncertainRegion(
            for: harvest.resolvedTarget,
            in: harvest.candidates,
            displayWidthPoints: displayWidthPoints,
            displayHeightPoints: displayHeightPoints
        )
    }

    private func harvestIndexedCandidates(
        screenshot: Data,
        target: String,
        displayWidthPoints: Int,
        displayHeightPoints: Int
    ) async -> (resolvedTarget: String, candidates: [ScreenElementIndex.IndexedCandidate]) {
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
        return (resolvedTarget, indexed)
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

    // MARK: - d16 crop-and-refine (ScreenSpot-Pro / DRS-GUI)

    /// The uncertain region for `target`: the padded, aspect-normalized union
    /// of the best weakly-matching candidates. Deliberately looser than
    /// `bestRegionCandidate` — fuzzy word-overlap (`textMatchScore >= 1`) is
    /// enough evidence to LOCALIZE a search even when it is nowhere near
    /// enough to trust a click. Best-first union: candidates are added while
    /// the resulting crop stays under `maximumScreenAreaFraction` of the
    /// screen; a region that cannot fit under it returns nil (crop useless).
    public static func uncertainRegion(
        for target: String,
        in candidates: [ScreenElementIndex.IndexedCandidate],
        displayWidthPoints: Int,
        displayHeightPoints: Int,
        aliases: [String: [String]] = [:],
        minimumTextScore: Double = 1.0,
        maximumCandidates: Int = 6,
        paddingPoints: Double = 48,
        minimumSidePoints: Double = 160,
        maximumScreenAreaFraction: Double = 0.60
    ) -> CGRect? {
        guard displayWidthPoints > 0, displayHeightPoints > 0 else { return nil }
        let resolvedTarget = ScreenElementIndex.applyTargetAliases(target, aliases: aliases)
        let normalizedTarget = ScreenElementIndex.normalizedSearchLabel(resolvedTarget)
        guard !normalizedTarget.isEmpty else { return nil }

        let scored = candidates.compactMap { candidate -> (bounds: CGRect, score: Double)? in
            guard candidate.clickSafety != .unsafe, candidate.bounds.isValid else { return nil }
            let textScore = ScreenElementIndex.textMatchScore(
                needle: normalizedTarget,
                candidate: ScreenElementIndex.normalizedSearchLabel(candidate.label)
            )
            guard textScore >= minimumTextScore else { return nil }
            return (candidate.bounds.cgRect, textScore * candidate.trust + candidate.confidence * 0.05)
        }
        .sorted { $0.score > $1.score }
        guard !scored.isEmpty else { return nil }

        let displayBounds = CGRect(
            x: 0, y: 0, width: CGFloat(displayWidthPoints), height: CGFloat(displayHeightPoints)
        )
        let maximumArea = displayBounds.width * displayBounds.height * CGFloat(maximumScreenAreaFraction)
        var union: CGRect?
        for entry in scored.prefix(max(1, maximumCandidates)) {
            let expanded = union.map { $0.union(entry.bounds) } ?? entry.bounds
            let candidateRegion = cropRegion(
                around: expanded,
                in: displayBounds,
                paddingPoints: paddingPoints,
                minimumSidePoints: minimumSidePoints
            )
            guard candidateRegion.width * candidateRegion.height <= maximumArea else { break }
            union = expanded
        }
        guard let union else { return nil }
        let region = cropRegion(
            around: union,
            in: displayBounds,
            paddingPoints: paddingPoints,
            minimumSidePoints: minimumSidePoints
        )
        guard region.width >= 16, region.height >= 16,
              region.width * region.height <= maximumArea else { return nil }
        return region
    }

    /// Pads `rect`, enforces a minimum side (a sliver crop starves the model of
    /// context), expands the short side toward the display's aspect ratio (the
    /// grounder stretches the crop to a fixed model resolution — matching the
    /// display aspect avoids the X-axis distortion that wrecks accuracy), then
    /// clamps into the display at integral point coordinates so the declared
    /// crop dimensions are exact.
    static func cropRegion(
        around rect: CGRect,
        in displayBounds: CGRect,
        paddingPoints: Double,
        minimumSidePoints: Double
    ) -> CGRect {
        var region = rect.standardized.insetBy(dx: CGFloat(-paddingPoints), dy: CGFloat(-paddingPoints))
        if region.width < minimumSidePoints {
            region = region.insetBy(dx: -(CGFloat(minimumSidePoints) - region.width) / 2, dy: 0)
        }
        if region.height < minimumSidePoints {
            region = region.insetBy(dx: 0, dy: -(CGFloat(minimumSidePoints) - region.height) / 2)
        }
        if displayBounds.width > 0, displayBounds.height > 0, region.width > 0, region.height > 0 {
            let aspect = displayBounds.width / displayBounds.height
            if region.width / region.height < aspect {
                let width = min(region.height * aspect, displayBounds.width)
                region = CGRect(x: region.midX - width / 2, y: region.minY, width: width, height: region.height)
            } else {
                let height = min(region.width / aspect, displayBounds.height)
                region = CGRect(x: region.minX, y: region.midY - height / 2, width: region.width, height: height)
            }
        }
        region.size.width = min(region.width, displayBounds.width)
        region.size.height = min(region.height, displayBounds.height)
        region.origin.x = min(max(displayBounds.minX, region.origin.x), displayBounds.maxX - region.width)
        region.origin.y = min(max(displayBounds.minY, region.origin.y), displayBounds.maxY - region.height)
        return region.integral.intersection(displayBounds)
    }

    /// Everything a caller needs to ground against a CROP and map the answer
    /// back: the cropped JPEG at full capture resolution, the crop's declared
    /// point dimensions, and the two typed transforms (d01 `CoordinateTransform`)
    /// that carry crop-local grounder output back into display-local points —
    /// no ad-hoc scale math anywhere.
    public struct CropRefinePlan: Equatable, Sendable {
        /// Display-local AppKit points (bottom-left origin) the crop covers.
        public let displayRegion: CGRect
        /// JPEG of just the region, at the capture's native pixel resolution —
        /// the model sees the region at ~full backing resolution instead of a
        /// downscaled full screen.
        public let croppedJPEG: Data
        /// Dimensions declared to the grounder for the crop-local call.
        public let cropWidthPoints: Int
        public let cropHeightPoints: Int
        /// Full-screenshot transform whose `cropInBackingPixels` IS this crop.
        public let transform: CoordinateTransform
        /// Treats the crop itself as a display (logical = crop points, backing
        /// = crop pixels): grounder output in crop-local AppKit points maps
        /// through here into crop pixels, then through `transform` back out.
        public let cropLocalTransform: CoordinateTransform

        /// Crop-local AppKit point (what the grounder returned) → display-local
        /// AppKit point, via crop pixels: never a guessed scale factor.
        public func displayPoint(fromCropLocalPoint point: CGPoint) -> CGPoint? {
            guard let cropPixel = cropLocalTransform.backingPixel(
                fromLogical: .init(point), bounds: .clamp
            ) else { return nil }
            return transform.logicalPoint(
                fromCropPixel: .init(cropPixel.point), bounds: .clamp
            )?.point
        }

        /// Crop-local AppKit rect → display-local AppKit rect through the same
        /// typed pixel chain.
        public func displayRect(fromCropLocalRect rect: CGRect) -> CGRect? {
            guard let cropPixelRect = cropLocalTransform.backingRect(
                fromLogical: .init(rect), bounds: .clamp
            ) else { return nil }
            let crop = transform.cropInBackingPixels.rect
            guard let shifted = CoordinateTransform.BackingPixelRect(
                cropPixelRect.rect.offsetBy(dx: crop.minX, dy: crop.minY)
            ) else { return nil }
            return transform.logicalRect(fromBackingPixelRect: shifted, bounds: .clamp)?.rect
        }

        /// Display-local AppKit rect → crop-local AppKit rect (for remapping
        /// request options like priority regions into the crop's space). Nil
        /// when the rect misses the crop entirely.
        public func cropLocalRect(fromDisplayRect rect: CGRect) -> CGRect? {
            guard let backing = transform.backingRect(fromLogical: .init(rect), bounds: .clamp) else {
                return nil
            }
            let crop = transform.cropInBackingPixels.rect
            let intersection = backing.rect.intersection(crop)
            guard let localPixels = CoordinateTransform.BackingPixelRect(
                intersection.offsetBy(dx: -crop.minX, dy: -crop.minY)
            ) else { return nil }
            return cropLocalTransform.logicalRect(fromBackingPixelRect: localPixels, bounds: .clamp)?.rect
        }

        /// Rebuilds a crop-pass candidate's coordinate chain against the REAL
        /// screenshot geometry (the crop pass believed the crop was the whole
        /// display) so the `agent.ground` audit shows the true crop rect and
        /// the full typed chain. Numeric geometry only — never text.
        public func refinedCoordinateChain(
            from chain: GroundingCoordinateChain?,
            cropLocalPoint: CGPoint?,
            displayPoint: CGPoint?
        ) -> GroundingCoordinateChain? {
            let cropPixel = cropLocalPoint.flatMap {
                cropLocalTransform.backingPixel(fromLogical: .init($0), bounds: .clamp)?.point
            }
            let crop = transform.cropInBackingPixels.rect
            let backingPoint = cropPixel.map { CGPoint(x: crop.minX + $0.x, y: crop.minY + $0.y) }
            return GroundingCoordinateChain(
                screenDisplayID: chain?.screenDisplayID,
                screenFrame: transform.screen.logicalFrame,
                backingPixelSize: transform.screen.backingPixelSize,
                cropRectInBackingPixels: crop,
                resizedInputSize: chain?.resizedInputSize,
                modelCoordinateSpace: chain?.modelCoordinateSpace,
                modelOutputPoint: chain?.modelOutputPoint,
                modelMappedPoint: chain?.modelMappedPoint,
                cropPoint: cropPixel,
                backingPoint: backingPoint,
                mappedPoint: displayPoint,
                modelOutputCount: chain?.modelOutputCount ?? 0
            )
        }
    }

    /// Builds the crop for an uncertain `region` (display-local AppKit points):
    /// decodes the capture, converts the region into backing pixels through the
    /// d01 typed transform, crops at native resolution, and packages the two
    /// transforms the answer maps back through. Nil whenever the geometry or
    /// the image cannot support a faithful crop — the caller then grounds the
    /// full screen exactly as before.
    public static func cropRefinePlan(
        screenshot: Data,
        region: CGRect,
        displayWidthPoints: Int,
        displayHeightPoints: Int,
        compression: Double = 0.9
    ) -> CropRefinePlan? {
        guard displayWidthPoints > 0, displayHeightPoints > 0 else { return nil }
        guard let image = decodeImage(screenshot) else { return nil }
        let displayBounds = CGRect(
            x: 0, y: 0, width: CGFloat(displayWidthPoints), height: CGFloat(displayHeightPoints)
        )
        let clamped = region.standardized.intersection(displayBounds).integral.intersection(displayBounds)
        guard clamped.width >= 16, clamped.height >= 16 else { return nil }
        // A crop that IS the whole screen refines nothing — skip the round trip.
        guard clamped.width < displayBounds.width || clamped.height < displayBounds.height else { return nil }

        guard let geometry = CoordinateTransform.ScreenGeometry(
            logicalFrame: displayBounds,
            backingPixelSize: CGSize(width: image.width, height: image.height)
        ), let fullTransform = CoordinateTransform(screen: geometry) else { return nil }
        guard let backingRect = fullTransform.backingRect(fromLogical: .init(clamped), bounds: .clamp) else {
            return nil
        }
        let pixelBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let pixelRect = backingRect.rect.integral.intersection(pixelBounds)
        guard pixelRect.width >= 8, pixelRect.height >= 8 else { return nil }
        guard let cropped = image.cropping(to: pixelRect) else { return nil }
        guard let jpeg = encodeJPEG(cropped, compression: compression) else { return nil }

        guard let cropBacking = CoordinateTransform.BackingPixelRect(pixelRect),
              let transform = CoordinateTransform(screen: geometry, cropInBackingPixels: cropBacking)
        else { return nil }
        let cropWidthPoints = max(1, Int(clamped.width.rounded()))
        let cropHeightPoints = max(1, Int(clamped.height.rounded()))
        guard let cropGeometry = CoordinateTransform.ScreenGeometry(
            logicalFrame: CGRect(x: 0, y: 0, width: cropWidthPoints, height: cropHeightPoints),
            backingPixelSize: pixelRect.size
        ), let cropLocalTransform = CoordinateTransform(screen: cropGeometry) else { return nil }

        return CropRefinePlan(
            displayRegion: clamped,
            croppedJPEG: jpeg,
            cropWidthPoints: cropWidthPoints,
            cropHeightPoints: cropHeightPoints,
            transform: transform,
            cropLocalTransform: cropLocalTransform
        )
    }

    private static func decodeImage(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func encodeJPEG(_ image: CGImage, compression: Double) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = NSSize(width: image.width, height: image.height)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: compression])
    }
}
