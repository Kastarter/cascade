import AppKit
import ComputerUseKit
import Foundation
import ImageIO
import MacContextKit
import ProviderKit

// MARK: - Mixture-of-grounding (Agent-S2's specialist routing)
//
// The grounding split (see VisualGrounder.swift) moves "where is X" out of the
// reasoning model into a dedicated grounder. Agent-S2's headline finding goes one
// step further: route each target to the RIGHT grounder instead of one visual
// model for everything. Cascade already harvests the frontmost app's accessibility
// tree (AXElementResolver) — for any labeled chrome control AX can see (buttons,
// menu items, fields, checkboxes), a structural match is FREE, EXACT, and immune
// to the OpenRouter transport flakiness that stalls UI-TARS. The visual grounder
// is uniquely needed only for what AX CANNOT see: canvas elements (Keynote/Pages
// slides, Blender, design tools) and custom-drawn controls.
//
// So this wrapper tries an AX structural match FIRST and falls back to the injected
// visual grounder (UI-TARS / Claude) on any miss. It is shared by BOTH on-screen
// paths (Scout and the Opus structural loop) through `assistGrounder()`, so it
// aligns them on the same, better grounding. It directly fixes the audited Scout
// failure at Keynote's "New Document" startup chooser — AX exposes that button, so
// it now grounds for free instead of round-tripping the flaky hosted grounder.
//
// SAFETY (the canvas case must not regress — it is why the visual grounder exists):
//  • Apps whose AX tree Cascade explicitly distrusts (`axUnreliable`: Blender,
//    Figma, Photoshop) skip AX entirely — the visual grounder owns them.
//  • Only ACTIONABLE-role matches are trusted (a button/field/menu item, never a
//    static-text label or image), so naming "the title" can't hijack a chrome
//    "Title" label when the canvas placeholder is meant — that falls to visual.
//  • A match must score ≥ `minAXScore` (exact, or one string contains the other),
//    never a weak word-overlap, and must land on the captured display.
//  • The no-effect detector remains the backstop: a wrong AX click is caught and
//    re-grounded exactly like a wrong visual click.
// Toggle off with `cascade.mixtureGrounding = false` to A/B against pure visual.
// See [[cascade-cu-downgrade-research]].

/// A `VisualGrounder` that resolves a named target structurally (accessibility
/// tree) when it can, and defers to a visual grounder otherwise.
public struct MixtureGrounder: VisualGrounder {
    public struct VerifiedGroundingAnchor: Equatable, Sendable {
        public let score: Double
        public let source: GroundingSource
        public let hash: String?
        public let verifiedAt: Date

        public init(score: Double, source: GroundingSource, hash: String? = nil, verifiedAt: Date) {
            self.score = score
            self.source = source
            self.hash = hash
            self.verifiedAt = verifiedAt
        }
    }

    public enum VerifiedGroundingOutcome: Equatable, Sendable {
        case selected
        case rejected(GroundingVerifierFailureKind?)
        case abstained(GroundingVerifierFailureKind?)
        case drifted
        case ambiguous
        case demote
        case retryNextCandidate
    }

    public struct VerifiedGroundingSelection: Equatable, Sendable {
        public let result: GroundingResult
        public let outcome: VerifiedGroundingOutcome
        public let verifierResult: GroundingVerifierResult

        public init(
            result: GroundingResult,
            outcome: VerifiedGroundingOutcome,
            verifierResult: GroundingVerifierResult
        ) {
            self.result = result
            self.outcome = outcome
            self.verifierResult = verifierResult
        }
    }

    public struct VerifierOutcome: Equatable, Sendable {
        public let target: String
        public let outcome: VerifiedGroundingOutcome
        public let verifierResult: GroundingVerifierResult
        public let candidateCount: Int

        public init(
            target: String,
            outcome: VerifiedGroundingOutcome,
            verifierResult: GroundingVerifierResult,
            candidateCount: Int
        ) {
            self.target = target
            self.outcome = outcome
            self.verifierResult = verifierResult
            self.candidateCount = candidateCount
        }
    }

    private let base: any VisualGrounder
    private let skills: AppSkillRegistry
    /// Minimum AX label-match score to TRUST a structural hit: 2 = one string
    /// contains the other (e.g. "the Save button" ⊇ "Save"); 3 = exact. Below
    /// this is only fuzzy word-overlap — defer to the visual grounder rather than
    /// risk a confident click on a vague match.
    private let minAXScore: Double
    private let verifyCandidates: Bool
    private let previousAnchor: VerifiedGroundingAnchor?
    private let candidateFailureCounts: [String: Int]
    private let onVerifierOutcome: (@Sendable (VerifierOutcome) async -> Void)?
    private let onRuntimeProfile: (@Sendable (AXRuntimeProfile) async -> Void)?
    private let groundingCache: GroundingCache?
    private let cacheMode: GroundingCacheMode
    private let cacheContextProvider: @Sendable () async -> AppWindowSnapshot
    private let regionNarrower: (@Sendable (Data, String, Int, Int) async -> ElementRegion?)?

    /// AX roles a CLICK target may legitimately resolve to. Excludes the passive
    /// roles `AXElementResolver.find` will also match (AXStaticText, AXImage) — a
    /// label of static text is almost never the thing to click, and trusting it
    /// would let "the title" grab a chrome label instead of the canvas placeholder.
    /// Cascade's own bundle id — its UI must never be an AX grounding target.
    static let cascadeBundleID = "com.humain.cascade"

    static let trustPolicy = ScreenElementIndex.TrustPolicy.default
    static let clickableRoles = ScreenElementIndex.TrustPolicy.default.actionableAXRoles

    public init(
        base: any VisualGrounder,
        skills: AppSkillRegistry,
        minAXScore: Double = 2,
        verifyCandidates: Bool = false,
        previousAnchor: VerifiedGroundingAnchor? = nil,
        candidateFailureCounts: [String: Int] = [:],
        groundingCache: GroundingCache? = nil,
        cacheMode: GroundingCacheMode = .structural,
        cacheContextProvider: @escaping @Sendable () async -> AppWindowSnapshot = {
            await MainActor.run { AppWindowObserver.snapshot() }
        },
        regionNarrower: (@Sendable (Data, String, Int, Int) async -> ElementRegion?)? = nil,
        onRuntimeProfile: (@Sendable (AXRuntimeProfile) async -> Void)? = nil,
        onVerifierOutcome: (@Sendable (VerifierOutcome) async -> Void)? = nil
    ) {
        self.base = base
        self.skills = skills
        self.minAXScore = minAXScore
        self.verifyCandidates = verifyCandidates
        self.previousAnchor = previousAnchor
        self.candidateFailureCounts = candidateFailureCounts
        self.groundingCache = groundingCache
        self.cacheMode = cacheMode
        self.cacheContextProvider = cacheContextProvider
        self.regionNarrower = regionNarrower
        self.onRuntimeProfile = onRuntimeProfile
        self.onVerifierOutcome = onVerifierOutcome
    }

    public func ground(
        screenshot: Data, target: String, displayWidthPoints: Int, displayHeightPoints: Int
    ) async -> CGPoint? {
        let target = await targetWithRuntimeHints(target)
        guard verifyCandidates else {
            if !Self.namesCanvasConcept(target),
               let axPoint = await axGround(
                target: target, displayWidthPoints: displayWidthPoints, displayHeightPoints: displayHeightPoints
            ) {
                return axPoint
            }
            guard groundingCache != nil else {
                return await base.ground(
                    screenshot: screenshot, target: target,
                    displayWidthPoints: displayWidthPoints, displayHeightPoints: displayHeightPoints
                )
            }
            return await baseGroundingResult(
                screenshot: screenshot,
                target: target,
                displayWidthPoints: displayWidthPoints,
                displayHeightPoints: displayHeightPoints
            ).selectedPoint
        }

        return await groundResult(
            screenshot: screenshot,
            target: target,
            displayWidthPoints: displayWidthPoints,
            displayHeightPoints: displayHeightPoints
        ).selectedPoint
    }

    public func groundResult(
        screenshot: Data,
        target: String,
        displayWidthPoints: Int,
        displayHeightPoints: Int
    ) async -> GroundingResult {
        let target = await targetWithRuntimeHints(target)
        guard verifyCandidates else {
            guard groundingCache != nil else {
                if let indexed = await screenElementIndexGrounding(
                    screenshot: screenshot,
                    target: target,
                    displayWidthPoints: displayWidthPoints,
                    displayHeightPoints: displayHeightPoints
                ) {
                    return indexed
                }
                let start = ContinuousClock.now
                let point = await ground(
                    screenshot: screenshot,
                    target: target,
                    displayWidthPoints: displayWidthPoints,
                    displayHeightPoints: displayHeightPoints
                )
                let elapsed = start.duration(to: ContinuousClock.now)
                return GroundingResult.legacy(point: point, latency: elapsed.mixtureTimeInterval)
            }
            let start = ContinuousClock.now
            if !Self.namesCanvasConcept(target),
               let axPoint = await axGround(
                target: target,
                displayWidthPoints: displayWidthPoints,
                displayHeightPoints: displayHeightPoints
            ) {
                let elapsed = start.duration(to: ContinuousClock.now)
                return GroundingResult.legacy(point: axPoint, latency: elapsed.mixtureTimeInterval)
            }
            let result = await indexedOrBaseGroundingResult(
                screenshot: screenshot,
                target: target,
                displayWidthPoints: displayWidthPoints,
                displayHeightPoints: displayHeightPoints
            )
            let elapsed = start.duration(to: ContinuousClock.now)
            return result.selectedCandidate?.latency == nil
                ? Self.withLatency(result, elapsed.mixtureTimeInterval)
                : result
        }

        let axCandidate = Self.namesCanvasConcept(target) ? nil : await axVerifierCandidate(
            target: target,
            displayWidthPoints: displayWidthPoints,
            displayHeightPoints: displayHeightPoints
        )
        let cacheProbe = await groundingCacheProbe(
            screenshot: screenshot,
            target: target,
            displayWidthPoints: displayWidthPoints,
            displayHeightPoints: displayHeightPoints
        )
        switch cacheProbe {
        case .hit(let result):
            return result
        case .miss:
            return GroundingResult()
        case .key(let key):
            let indexedResult = await screenElementIndexGrounding(
                screenshot: screenshot,
                target: target,
                displayWidthPoints: displayWidthPoints,
                displayHeightPoints: displayHeightPoints
            )
            let baseResult: GroundingResult
            if let indexedResult {
                baseResult = indexedResult
            } else {
                baseResult = await base.groundResult(
                    screenshot: screenshot,
                    target: target,
                    displayWidthPoints: displayWidthPoints,
                    displayHeightPoints: displayHeightPoints
                )
            }
            let selection = Self.selectVerifiedCandidate(
                axCandidate: axCandidate,
                baseResult: baseResult,
                target: target,
                displayWidthPoints: displayWidthPoints,
                displayHeightPoints: displayHeightPoints,
                previousAnchor: previousAnchor,
                candidateFailureCounts: candidateFailureCounts
            )
            await recordVerifierOutcomeIfNeeded(selection, target: target)
            await storeGroundingCacheResult(selection.result, key: key)
            return selection.result
        }
    }

    private enum CacheProbe {
        case hit(GroundingResult)
        case miss
        case key(GroundingCacheKey?)
    }

    private func baseGroundingResult(
        screenshot: Data,
        target: String,
        displayWidthPoints: Int,
        displayHeightPoints: Int
    ) async -> GroundingResult {
        let cacheProbe = await groundingCacheProbe(
            screenshot: screenshot,
            target: target,
            displayWidthPoints: displayWidthPoints,
            displayHeightPoints: displayHeightPoints
        )
        switch cacheProbe {
        case .hit(let result):
            return result
        case .miss:
            return GroundingResult()
        case .key(let key):
            let result = await base.groundResult(
                screenshot: screenshot,
                target: target,
                displayWidthPoints: displayWidthPoints,
                displayHeightPoints: displayHeightPoints
            )
            await storeGroundingCacheResult(result, key: key)
            return result
        }
    }

    private func indexedOrBaseGroundingResult(
        screenshot: Data,
        target: String,
        displayWidthPoints: Int,
        displayHeightPoints: Int
    ) async -> GroundingResult {
        let cacheProbe = await groundingCacheProbe(
            screenshot: screenshot,
            target: target,
            displayWidthPoints: displayWidthPoints,
            displayHeightPoints: displayHeightPoints
        )
        switch cacheProbe {
        case .hit(let result):
            return result
        case .miss:
            return GroundingResult()
        case .key(let key):
            let result: GroundingResult
            if let indexed = await screenElementIndexGrounding(
                screenshot: screenshot,
                target: target,
                displayWidthPoints: displayWidthPoints,
                displayHeightPoints: displayHeightPoints
            ) {
                result = indexed
            } else {
                result = await base.groundResult(
                    screenshot: screenshot,
                    target: target,
                    displayWidthPoints: displayWidthPoints,
                    displayHeightPoints: displayHeightPoints
                )
            }
            await storeGroundingCacheResult(result, key: key)
            return result
        }
    }

    private func groundingCacheProbe(
        screenshot: Data,
        target: String,
        displayWidthPoints: Int,
        displayHeightPoints: Int
    ) async -> CacheProbe {
        guard let groundingCache else { return .key(nil) }
        let key = await groundingCacheKey(
            screenshot: screenshot,
            target: target,
            displayWidthPoints: displayWidthPoints,
            displayHeightPoints: displayHeightPoints
        )
        guard let lookup = await groundingCache.lookup(key) else { return .key(key) }
        switch lookup {
        case .hit(let result):
            return .hit(result)
        case .miss:
            return .miss
        }
    }

    private func groundingCacheKey(
        screenshot: Data,
        target: String,
        displayWidthPoints: Int,
        displayHeightPoints: Int
    ) async -> GroundingCacheKey? {
        guard let gridHashes = Self.gridHashes(ofJPEG: screenshot) else { return nil }
        let snapshot = await cacheContextProvider()
        return GroundingCacheKey(
            targetText: target,
            appName: snapshot.appName,
            bundleIdentifier: snapshot.bundleIdentifier,
            windowTitle: snapshot.windowTitle,
            displayWidthPoints: displayWidthPoints,
            displayHeightPoints: displayHeightPoints,
            screenHash: PerceptualHash.combinedHash(gridHashes),
            gridHashes: gridHashes,
            mode: cacheMode
        )
    }

    private func storeGroundingCacheResult(_ result: GroundingResult, key: GroundingCacheKey?) async {
        guard let groundingCache else { return }
        if result.selectedPoint != nil {
            await groundingCache.store(Self.cached(result), for: key)
        } else {
            await groundingCache.storeMiss(for: key)
        }
    }

    private static func cached(_ result: GroundingResult) -> GroundingResult {
        GroundingResult(
            candidates: result.candidates.map { candidate in
                GroundingCandidate(
                    point: candidate.point,
                    region: candidate.region,
                    confidence: candidate.confidence,
                    source: .cache,
                    coordinateSpace: candidate.coordinateSpace,
                    rawModel: candidate.rawModel,
                    latency: candidate.latency,
                    dispersion: candidate.dispersion,
                    reason: candidate.reason ?? "cached \(candidate.source.rawValue) candidate",
                    candidateID: candidate.candidateID,
                    markNumber: candidate.markNumber,
                    displayBounds: candidate.displayBounds,
                    imageBounds: candidate.imageBounds
                )
            },
            selectedIndex: result.selectedIndex,
            selectedCandidateID: result.selectedCandidateID,
            verifierVerdict: result.verifierVerdict,
            verifierFailureKind: result.verifierFailureKind,
            alternativeCount: result.alternativeCount
        )
    }

    private static func withLatency(_ result: GroundingResult, _ latency: TimeInterval) -> GroundingResult {
        GroundingResult(
            candidates: result.candidates.map { candidate in
                GroundingCandidate(
                    point: candidate.point,
                    region: candidate.region,
                    confidence: candidate.confidence,
                    source: candidate.source,
                    coordinateSpace: candidate.coordinateSpace,
                    rawModel: candidate.rawModel,
                    latency: latency,
                    dispersion: candidate.dispersion,
                    reason: candidate.reason,
                    candidateID: candidate.candidateID,
                    markNumber: candidate.markNumber,
                    displayBounds: candidate.displayBounds,
                    imageBounds: candidate.imageBounds
                )
            },
            selectedIndex: result.selectedIndex,
            selectedCandidateID: result.selectedCandidateID,
            verifierVerdict: result.verifierVerdict,
            verifierFailureKind: result.verifierFailureKind,
            alternativeCount: result.alternativeCount
        )
    }

    private static func gridHashes(ofJPEG data: Data) -> [UInt64]? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return PerceptualHash.gridHashes(image)
    }

    private func recordVerifierOutcomeIfNeeded(
        _ selection: VerifiedGroundingSelection,
        target: String
    ) async {
        guard let onVerifierOutcome else { return }
        switch selection.outcome {
        case .rejected, .abstained:
            await onVerifierOutcome(VerifierOutcome(
                target: target,
                outcome: selection.outcome,
                verifierResult: selection.verifierResult,
                candidateCount: selection.result.candidates.count
            ))
        case .selected, .drifted, .ambiguous, .demote, .retryNextCandidate:
            break
        }
    }

    /// Region grounding (the "where is X" highlight) first tries a deterministic
    /// local AX/OCR/text-index pass, then falls back to the visual/cloud grounder
    /// only when local evidence is missing or ambiguous.
    public func groundRegion(
        screenshot: Data, target: String, displayWidthPoints: Int, displayHeightPoints: Int
    ) async -> ElementRegion? {
        let target = await targetWithRuntimeHints(target)
        if let regionNarrower {
            if let region = await regionNarrower(screenshot, target, displayWidthPoints, displayHeightPoints) {
                return region
            }
        } else {
            let narrower = LocalRegionNarrower(
                skills: skills,
                policy: Self.trustPolicy,
                onRuntimeProfile: onRuntimeProfile
            )
            if let region = await narrower.narrow(
                screenshot: screenshot,
                target: target,
                displayWidthPoints: displayWidthPoints,
                displayHeightPoints: displayHeightPoints
            ) {
                return region
            }
        }
        return await base.groundRegion(
            screenshot: screenshot, target: target,
            displayWidthPoints: displayWidthPoints, displayHeightPoints: displayHeightPoints
        )
    }

    private func screenElementIndexGrounding(
        screenshot: Data,
        target: String,
        displayWidthPoints: Int,
        displayHeightPoints: Int
    ) async -> GroundingResult? {
        let appHints = await runtimeHintsForFrontmostApp()
        let runtimeProfile = await runtimeProfileForFrontmost()
        let axCandidates = await MainActor.run {
            ScreenElementIndex.accessibilityCandidates(
                displayWidthPoints: displayWidthPoints,
                displayHeightPoints: displayHeightPoints,
                policy: Self.trustPolicy,
                appSkillHints: appHints,
                runtimeProfile: runtimeProfile
            )
        }
        let ocrCandidates = await Task.detached {
            ScreenElementIndex.ocrCandidates(
                screenshot: screenshot,
                target: target,
                displayWidthPoints: displayWidthPoints,
                displayHeightPoints: displayHeightPoints,
                policy: Self.trustPolicy
            )
        }.value
        let indexed = ScreenElementIndex.build(
            from: Self.applyPreferredSourceHints(
                axCandidates + ocrCandidates,
                hints: appHints,
                target: target
            )
        )
        guard !indexed.isEmpty else { return nil }
        if let selected = ScreenElementIndex.bestCandidate(for: target, in: indexed, policy: Self.trustPolicy) {
            return Self.groundingResult(
                from: selected,
                reason: "clickable-map \(selected.source.rawValue) label match",
                alternativeCount: max(0, indexed.count - 1)
            )
        }
        guard let markedJPEG = ScreenElementIndex.renderMarkedJPEG(
            screenshot: screenshot,
            candidates: indexed,
            displayWidthPoints: displayWidthPoints,
            displayHeightPoints: displayHeightPoints
        ) else { return nil }
        let marked = Self.markedCandidates(from: indexed)
        let markedResult = await base.groundMarkedCandidate(
            screenshot: markedJPEG,
            target: target,
            displayWidthPoints: displayWidthPoints,
            displayHeightPoints: displayHeightPoints,
            candidates: marked
        )
        guard !markedResult.candidates.isEmpty || markedResult.verifierVerdict != nil else { return nil }
        return markedResult
    }

    private static func groundingResult(
        from selected: ScreenElementIndex.IndexedCandidate,
        reason: String,
        alternativeCount: Int
    ) -> GroundingResult {
        let source: GroundingSource = selected.source == .accessibility ? .accessibility : .ocr
        return GroundingResult(
            candidates: [
                GroundingCandidate(
                    point: selected.center,
                    region: selected.bounds.cgRect,
                    confidence: selected.confidence,
                    source: source,
                    coordinateSpace: .displayLocalAppKitPoints,
                    rawModel: selected.label,
                    reason: reason,
                    candidateID: selected.id,
                    markNumber: selected.mark.number,
                    displayBounds: selected.bounds.cgRect,
                    imageBounds: selected.imageBounds?.cgRect
                )
            ],
            selectedIndex: 0,
            selectedCandidateID: selected.id,
            alternativeCount: alternativeCount
        )
    }

    private static func markedCandidates(
        from indexed: [ScreenElementIndex.IndexedCandidate]
    ) -> [MarkedGroundingCandidate] {
        indexed.map { candidate in
            MarkedGroundingCandidate(
                id: candidate.id,
                markNumber: candidate.mark.number,
                label: candidate.label,
                role: candidate.role.rawValue,
                source: candidate.source == .accessibility ? .accessibility : .ocr,
                confidence: candidate.confidence,
                isSafeToClick: candidate.isSafeToClick,
                displayBounds: candidate.bounds.cgRect,
                imageBounds: candidate.imageBounds?.cgRect
            )
        }
    }

    private func runtimeHintsForFrontmostApp() async -> AppSkillRuntimeHints? {
        await MainActor.run {
            let front = NSWorkspace.shared.frontmostApplication
            return skills.skill(appName: front?.localizedName, bundleIdentifier: front?.bundleIdentifier)?.hints
        }
    }

    private func targetWithRuntimeHints(_ target: String) async -> String {
        guard let hints = await runtimeHintsForFrontmostApp() else { return target }
        return Self.applyTargetAliases(target, aliases: hints.targetAliases)
    }

    static func applyTargetAliases(_ target: String, aliases: [String: [String]]) -> String {
        ScreenElementIndex.applyTargetAliases(target, aliases: aliases)
    }

    private static func applyPreferredSourceHints(
        _ candidates: [ScreenElementIndex.Candidate],
        hints: AppSkillRuntimeHints?,
        target: String
    ) -> [ScreenElementIndex.Candidate] {
        ScreenElementIndex.applyPreferredSourceHints(candidates, hints: hints, target: target)
    }

    @MainActor
    private static func indexCandidatesFromAccessibility(
        displayWidthPoints: Int,
        displayHeightPoints: Int
    ) -> [ScreenElementIndex.Candidate] {
        guard let bounds = captureDisplayBounds(widthPoints: displayWidthPoints, heightPoints: displayHeightPoints) else {
            return []
        }
        return AXElementResolver.interactables(limit: 48).compactMap { match in
            guard let point = displayLocalPoint(
                cgGlobalCenter: match.center,
                displayCGBounds: bounds,
                displayHeightPoints: displayHeightPoints
            ) else { return nil }
            let role = indexRole(fromAXRole: match.role)
            let size = role == .textField ? CGSize(width: 180, height: 28) : CGSize(width: 96, height: 28)
            return ScreenElementIndex.Candidate(
                bounds: ScreenElementIndex.Bounds(
                    x: Double(point.x - size.width / 2),
                    y: Double(point.y - size.height / 2),
                    width: Double(size.width),
                    height: Double(size.height)
                ),
                label: match.title,
                role: role,
                source: .accessibility,
                confidence: min(1, max(0.72, match.score / 3)),
                trust: 0.95,
                clickSafety: .safe
            )
        }
    }

    private static func indexCandidatesFromOCR(
        screenshot: Data,
        displayWidthPoints: Int,
        displayHeightPoints: Int,
        target: String
    ) -> [ScreenElementIndex.Candidate] {
        ScreenTextRecognizer.recognizeBoxes(inImageData: screenshot, level: .fast).compactMap { box in
            let text = box.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= 2, text.count <= 80 else { return nil }
            let rect = rectFromVisionBox(
                box.boundingBox,
                displayWidthPoints: displayWidthPoints,
                displayHeightPoints: displayHeightPoints
            )
            let role: ScreenElementIndex.Role = targetLooksFillable(target) ? .textField : .text
            return ScreenElementIndex.Candidate(
                bounds: ScreenElementIndex.Bounds(
                    x: Double(rect.minX),
                    y: Double(rect.minY),
                    width: Double(rect.width),
                    height: Double(rect.height)
                ),
                label: text,
                role: role,
                source: .ocr,
                confidence: Double(box.confidence),
                trust: role == .textField ? 0.68 : 0.45,
                clickSafety: role == .textField ? .safe : .passive
            )
        }
    }

    private static func bestIndexedCandidate(
        for target: String,
        in candidates: [ScreenElementIndex.IndexedCandidate]
    ) -> ScreenElementIndex.IndexedCandidate? {
        let target = normalizedIndexLabel(target)
        guard !target.isEmpty else { return nil }
        var best: (candidate: ScreenElementIndex.IndexedCandidate, score: Double)?
        for candidate in candidates where candidate.isSafeToClick {
            let score = indexMatchScore(needle: target, candidate: normalizedIndexLabel(candidate.label)) * candidate.trust
            guard score >= 1.30 else { continue }
            if best == nil
                || score > best!.score
                || (score == best!.score && indexSourceRank(candidate.source) > indexSourceRank(best!.candidate.source))
                || (score == best!.score && indexSourceRank(candidate.source) == indexSourceRank(best!.candidate.source) && candidate.bounds.area < best!.candidate.bounds.area) {
                best = (candidate, score)
            }
        }
        return best?.candidate
    }

    private static func indexSourceRank(_ source: ScreenElementIndex.Source) -> Int {
        switch source {
        case .accessibility: return 3
        case .visual: return 2
        case .ocr: return 1
        }
    }

    private static func indexRole(fromAXRole role: String) -> ScreenElementIndex.Role {
        switch role {
        case "AXButton", "AXMenuBarItem": return .button
        case "AXMenuItem": return .menuItem
        case "AXLink": return .link
        case "AXCheckBox", "AXRadioButton": return .checkbox
        case "AXTextField", "AXTextArea", "AXSearchField", "AXComboBox": return .textField
        case "AXPopUpButton", "AXTab", "AXDisclosureTriangle", "AXRow", "AXCell", "AXSlider": return .option
        default: return .unknown
        }
    }

    private static func targetLooksFillable(_ target: String) -> Bool {
        let t = target.lowercased()
        return t.contains("field") || t.contains("box") || t.contains("search") || t.contains("placeholder") || t.contains("input")
    }

    private static func normalizedIndexLabel(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: #"\b(the|a|an|button|field|box|link|menu|item|placeholder|input)\b"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func indexMatchScore(needle: String, candidate: String) -> Double {
        guard !needle.isEmpty, !candidate.isEmpty else { return 0 }
        if needle == candidate { return 3 }
        if candidate.contains(needle) || needle.contains(candidate) { return 2 }
        let needleWords = Set(needle.split(separator: " "))
        let candidateWords = Set(candidate.split(separator: " "))
        guard !needleWords.isEmpty else { return 0 }
        let overlap = Double(needleWords.intersection(candidateWords).count) / Double(needleWords.count)
        return overlap >= 0.75 ? 1 + overlap : 0
    }

    /// Locate a target that is literal ON-SCREEN TEXT (document content, a heading, a
    /// labeled link) by OCR — the case a UI-control grounder misses. Frames the matched
    /// text; nil when nothing matches confidently (→ visual grounder). OCR runs off-main.
    static func ocrTextRegion(
        screenshot: Data, target: String, displayWidthPoints: Int, displayHeightPoints: Int
    ) async -> ElementRegion? {
        let boxes = await Task.detached { ScreenTextRecognizer.recognizeBoxes(inImageData: screenshot) }.value
        guard let match = ScreenTextRecognizer.bestMatch(anchor: target, in: boxes) else { return nil }
        let rect = rectFromVisionBox(
            match.boundingBox, displayWidthPoints: displayWidthPoints, displayHeightPoints: displayHeightPoints
        )
        return ElementRegion(rect: rect, speech: "Here — “\(match.text)”.")
    }

    /// Vision-normalized box (0…1, LOWER-LEFT origin) → display-local AppKit rect
    /// (bottom-left origin too, so NO Y flip). Pure + pinned — a wrong number frames
    /// empty space.
    nonisolated static func rectFromVisionBox(
        _ box: CGRect, displayWidthPoints w: Int, displayHeightPoints h: Int
    ) -> CGRect {
        CGRect(
            x: box.minX * CGFloat(w), y: box.minY * CGFloat(h),
            width: box.width * CGFloat(w), height: box.height * CGFloat(h)
        )
    }

    public static func selectVerifiedCandidate(
        axCandidate: GroundingVerifierCandidate?,
        baseResult: GroundingResult,
        target: String,
        displayWidthPoints: Int,
        displayHeightPoints: Int,
        previousAnchor: VerifiedGroundingAnchor? = nil,
        candidateFailureCounts: [String: Int] = [:],
        now: Date = Date()
    ) -> VerifiedGroundingSelection {
        let context = GroundingVerifierContext(
            targetText: target,
            displayWidthPoints: displayWidthPoints,
            displayHeightPoints: displayHeightPoints
        )
        let verifierCandidates = Self.verifierCandidates(
            axCandidate: axCandidate,
            baseResult: baseResult
        )
        let verifierResult = GroundingVerifier().verify(verifierCandidates, context: context)

        guard let previousAnchor else {
            return Self.selection(
                from: verifierCandidates,
                selectedID: verifierResult.verdict == .accept ? verifierResult.selectedCandidateID : nil,
                outcome: Self.outcome(for: verifierResult),
                verifierResult: verifierResult
            )
        }

        let strongScores = verifierResult.scores.filter {
            $0.failureKind == nil && $0.score >= context.acceptThreshold
        }
        guard !strongScores.isEmpty else {
            return Self.selection(
                from: verifierCandidates,
                selectedID: verifierResult.verdict == .accept ? verifierResult.selectedCandidateID : nil,
                outcome: Self.outcome(for: verifierResult),
                verifierResult: verifierResult
            )
        }

        let candidatesByID = Dictionary(uniqueKeysWithValues: verifierCandidates.map { ($0.id, $0) })
        let driftCandidates = strongScores.compactMap { score -> AnchorDriftScorer.Candidate? in
            guard let candidate = candidatesByID[score.id] else { return nil }
            return AnchorDriftScorer.Candidate(
                id: score.id,
                score: score.score,
                source: Self.anchorSource(for: candidate.candidate.source),
                hash: Self.anchorHash(for: candidate),
                failureCount: candidateFailureCounts[score.id, default: 0]
            )
        }
        let drift = AnchorDriftScorer.evaluate(
            previous: AnchorDriftScorer.VerifiedAnchor(
                score: previousAnchor.score,
                source: Self.anchorSource(for: previousAnchor.source),
                hash: previousAnchor.hash,
                verifiedAt: previousAnchor.verifiedAt
            ),
            rankedCandidates: driftCandidates,
            now: now
        )

        switch drift.outcome {
        case .stable:
            return Self.selection(
                from: verifierCandidates,
                selectedID: drift.selected?.id,
                outcome: .selected,
                verifierResult: verifierResult
            )
        case .retryNextCandidate:
            return Self.selection(
                from: verifierCandidates,
                selectedID: drift.selected?.id,
                outcome: .retryNextCandidate,
                verifierResult: verifierResult
            )
        case .demote:
            return Self.selection(
                from: verifierCandidates,
                selectedID: nil,
                outcome: .demote,
                verifierResult: verifierResult
            )
        case .ambiguous:
            return Self.selection(
                from: verifierCandidates,
                selectedID: nil,
                outcome: .ambiguous,
                verifierResult: verifierResult
            )
        case .drifted:
            return Self.selection(
                from: verifierCandidates,
                selectedID: nil,
                outcome: .drifted,
                verifierResult: verifierResult
            )
        }
    }

    private func runtimeProfileForFrontmost() async -> AXRuntimeProfile? {
        await MainActor.run {
            let profile = AXElementResolver.runtimeProfileForFrontmost()
            if let profile {
                Task { await onRuntimeProfile?(profile) }
            }
            return profile
        }
    }

    /// Resolve `target` against the frontmost app's accessibility tree, returning a
    /// display-local AppKit point (the executor's space) — or nil to fall back to
    /// the visual grounder. AX/NSWorkspace/NSScreen are main-thread surfaces, so the
    /// whole resolve runs on the MainActor.
    @MainActor
    private func axGround(target: String, displayWidthPoints: Int, displayHeightPoints: Int) -> CGPoint? {
        axVerifierCandidate(
            target: target,
            displayWidthPoints: displayWidthPoints,
            displayHeightPoints: displayHeightPoints
        )?.candidate.point
    }

    @MainActor
    private func axVerifierCandidate(
        target: String,
        displayWidthPoints: Int,
        displayHeightPoints: Int
    ) -> GroundingVerifierCandidate? {
        // Canvas concepts are visual-only: a target named as a "placeholder" or
        // "canvas" element (Keynote/Pages slide boxes, drawing surfaces) has no
        // faithful AX node, but a short generic chrome label CAN substring-match it
        // (naming "the title placeholder" would hijack a Format-panel "Title"
        // checkbox — actionable, and toggling it even defeats the no-effect
        // backstop). Such targets go straight to the visual grounder. General, not
        // app-specific: these words denote a drawn surface in any app.
        if Self.namesCanvasConcept(target) { return nil }
        let front = NSWorkspace.shared.frontmostApplication
        // NEVER ground Cascade's OWN UI. When Cascade's window is frontmost, AX-first
        // reads ITS tree and matches Cascade's buttons/fields (the audited
        // "Agents"/"Create new…" hijack) — the agent then clicks and types into
        // Cascade instead of the target app behind it (the "can't type" report). The
        // captured screenshot excludes Cascade's own windows, so the visual grounder
        // sees the real target — defer to it.
        if front?.bundleIdentifier == Self.cascadeBundleID { return nil }
        // Distrusted-AX apps (canvas/Electron) are the visual grounder's domain.
        let skill = skills.skill(appName: front?.localizedName, bundleIdentifier: front?.bundleIdentifier)
        if skill?.axUnreliable == true {
            return nil
        }
        let runtimeProfile = AXElementResolver.runtimeProfileForFrontmost()
        if runtimeProfile?.isSparse == true {
            if let runtimeProfile {
                Task { await onRuntimeProfile?(runtimeProfile) }
            }
            return nil
        }
        guard let match = AXElementResolver.find(label: target),
              match.score >= minAXScore else { return nil }
        // Map the matched element center (CG-global, top-left) into the display-local
        // AppKit point the executor consumes. Use the display the screenshot came
        // from — the cursor's — selected by matching the declared dimensions.
        guard let bounds = Self.captureDisplayBounds(widthPoints: displayWidthPoints, heightPoints: displayHeightPoints) else {
            return nil
        }
        guard let point = Self.displayLocalPoint(
            cgGlobalCenter: match.center, displayCGBounds: bounds, displayHeightPoints: displayHeightPoints
        ) else { return nil }
        let candidateBounds = ScreenElementIndex.Bounds(
            x: Double(point.x - 48),
            y: Double(point.y - 14),
            width: 96,
            height: 28
        )
        guard Self.trustPolicy.acceptsAXCandidate(
            role: match.role,
            score: match.score,
            bounds: candidateBounds,
            displayWidthPoints: displayWidthPoints,
            displayHeightPoints: displayHeightPoints,
            appSkillHints: skill?.hints,
            runtimeProfile: runtimeProfile
        ) else { return nil }
        let candidateID = "ax:\(Self.indexHash(match.role + "|" + match.title))"

        return GroundingVerifierCandidate(
            id: candidateID,
            candidate: GroundingCandidate(
                point: point,
                confidence: min(1, max(0, match.score / 3)),
                source: .accessibility,
                coordinateSpace: .displayLocalAppKitPoints,
                rawModel: match.title,
                reason: "accessibility label match score \(String(format: "%.2f", match.score))",
                candidateID: candidateID,
                displayBounds: candidateBounds.cgRect
            ),
            role: match.role,
            label: match.title,
            nearbyOCRText: match.title,
            ocrDistancePoints: 0
        )
    }

    /// Words that denote a drawn surface with no faithful accessibility node, so a
    /// target naming one must be grounded visually, not by AX label match. Pure +
    /// pinned. Kept tiny and generic — these are not app-specific UI labels.
    nonisolated static func namesCanvasConcept(_ target: String) -> Bool {
        let t = target.lowercased()
        return t.contains("placeholder") || t.contains("canvas")
    }

    /// CG-global top-left element center → display-local AppKit point (bottom-left
    /// origin), mirroring `ElementLocator.guide` / `UITARSGrounder.toDisplayPoint`
    /// so an AX point and a visual point feed the IDENTICAL click path. Returns nil
    /// when the center isn't on the captured display (off-screen / another monitor),
    /// so a stray match never clicks blind. Pure + unit-pinned — a wrong number here
    /// clicks empty space.
    nonisolated static func displayLocalPoint(
        cgGlobalCenter c: CGPoint, displayCGBounds bounds: CGRect, displayHeightPoints: Int
    ) -> CGPoint? {
        guard bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 0, bounds.height > 0,
              displayHeightPoints > 0
        else { return nil }
        let mapper = DisplayCoordinateMapper(
            displayID: CGMainDisplayID(),
            appKitFrame: CGRect(x: 0, y: 0, width: bounds.width, height: CGFloat(displayHeightPoints)),
            cgBounds: bounds,
            backingScaleFactor: 1
        )
        return mapper.screenLocalAppKit(fromCGGlobal: c)
    }

    /// CG-global bounds of the display the screenshot came from. The capture path is
    /// always the cursor's display, so prefer the screen under the mouse; among
    /// screens the dimensions must still match the declared size (so a coordinate is
    /// never mapped against the wrong monitor). nil → caller falls back to visual.
    @MainActor
    private static func captureDisplayBounds(widthPoints: Int, heightPoints: Int) -> CGRect? {
        func dims(_ s: NSScreen) -> Bool {
            Int(s.frame.width.rounded()) == widthPoints && Int(s.frame.height.rounded()) == heightPoints
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { dims($0) && NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.screens.first(where: dims)
        guard let screen, let mapper = DisplayCoordinateMapper(screen: screen) else { return nil }
        return mapper.cgBounds
    }

    private static func verifierCandidates(
        axCandidate: GroundingVerifierCandidate?,
        baseResult: GroundingResult
    ) -> [GroundingVerifierCandidate] {
        var baseCandidates = baseResult.candidates.enumerated().map { index, candidate in
            GroundingVerifierCandidate(
                id: candidate.candidateID ?? "base:\(index)",
                candidate: candidate,
                label: candidate.rawModel,
                nearbyOCRText: candidate.rawModel,
                ocrDistancePoints: candidate.dispersion,
                agreeingSources: Self.agreeingSources(for: candidate, axCandidate: axCandidate)
            )
        }

        guard let axCandidate else { return baseCandidates }
        let axAgreement = baseCandidates
            .filter { Self.pointsAgree(axCandidate.candidate.point, $0.candidate.point) }
            .map(\.candidate.source)
        let axWithAgreement = GroundingVerifierCandidate(
            id: axCandidate.id,
            candidate: axCandidate.candidate,
            role: axCandidate.role,
            label: axCandidate.label,
            nearbyOCRText: axCandidate.nearbyOCRText,
            ocrDistancePoints: axCandidate.ocrDistancePoints,
            agreeingSources: axCandidate.agreeingSources + axAgreement
        )
        baseCandidates.insert(axWithAgreement, at: 0)
        return baseCandidates
    }

    private static func agreeingSources(
        for candidate: GroundingCandidate,
        axCandidate: GroundingVerifierCandidate?
    ) -> [GroundingSource] {
        guard let axCandidate,
              pointsAgree(candidate.point, axCandidate.candidate.point) else { return [] }
        return [axCandidate.candidate.source]
    }

    private static func pointsAgree(_ lhs: CGPoint?, _ rhs: CGPoint?) -> Bool {
        guard let lhs, let rhs else { return false }
        return hypot(lhs.x - rhs.x, lhs.y - rhs.y) <= 24
    }

    private static func selection(
        from candidates: [GroundingVerifierCandidate],
        selectedID: String?,
        outcome: VerifiedGroundingOutcome,
        verifierResult: GroundingVerifierResult
    ) -> VerifiedGroundingSelection {
        let selectedIndex = selectedID.flatMap { id in candidates.firstIndex { $0.id == id } }
        return VerifiedGroundingSelection(
            result: GroundingResult(
                candidates: candidates.map(\.candidate),
                selectedIndex: selectedIndex,
                selectedCandidateID: verifierResult.selectedCandidateID,
                verifierVerdict: verifierResult.verdict,
                verifierFailureKind: verifierResult.failureKind,
                alternativeCount: max(0, candidates.count - (selectedIndex == nil ? 0 : 1))
            ),
            outcome: outcome,
            verifierResult: verifierResult
        )
    }

    private static func outcome(for result: GroundingVerifierResult) -> VerifiedGroundingOutcome {
        switch result.verdict {
        case .accept:
            return .selected
        case .reject:
            return .rejected(result.failureKind)
        case .abstain:
            return .abstained(result.failureKind)
        }
    }

    private static func anchorSource(for source: GroundingSource) -> AnchorDriftScorer.AnchorSource {
        switch source {
        case .accessibility:
            return .accessibility
        case .cache:
            return .recordedPoint
        case .dom:
            return .semantic
        case .ocr, .uiTars, .claude, .visualModel:
            return .vision
        case .compatibility, .unknown:
            return .unknown
        }
    }

    private static func anchorHash(for candidate: GroundingVerifierCandidate) -> String? {
        if let rawModel = candidate.candidate.rawModel, !rawModel.isEmpty {
            return rawModel
        }
        if let label = candidate.label, !label.isEmpty {
            return "\(candidate.role ?? "unknown"):\(label)"
        }
        return nil
    }

    private static func indexHash(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 36)
    }
}

private extension Duration {
    var mixtureTimeInterval: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
