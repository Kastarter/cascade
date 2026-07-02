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
//  • d15: ALL "AX vs vision" routing lives in ONE gate — `GroundingRouter`
//    (ComputerUseKit). AX-first is the default; a request goes to the visual
//    grounder only for canvas concepts, Cascade's own UI, distrusted-AX apps,
//    or a sparse/stale live tree — and every such route carries an audited
//    reason (`grounding.route`). The bullets below describe those rules.
//  • Apps whose AX tree Cascade explicitly distrusts (`axUnreliable`: Blender,
//    Figma, Photoshop) skip AX entirely — the visual grounder owns them.
//  • Only ACTIONABLE-role matches are trusted (a button/field/menu item, never a
//    static-text label or image), so naming "the title" can't hijack a chrome
//    "Title" label when the canvas placeholder is meant — that falls to visual.
//  • A match must score ≥ `minAXScore` (exact, or one string contains the other),
//    never a weak word-overlap, and must land on the captured display.
//  • The no-effect detector remains the backstop: a wrong AX click is caught and
//    re-grounded exactly like a wrong visual click.
//  • d16 (crop-and-refine, ScreenSpot-Pro / DRS-GUI; rides the same
//    `cascade.experimentalCompressedObservation` flag as the d12 picker): when a
//    request DOES reach the visual grounder, weak local AX/OCR evidence first
//    narrows an uncertain region (`LocalRegionNarrower.narrowUncertainRegion`),
//    the capture is cropped to it at native pixel resolution, and the model
//    grounds the CROP — higher effective resolution than a downscaled full
//    screen. Crop-local output maps back through the d01 `CoordinateTransform`
//    (never ad-hoc scale math); any miss falls back to the unchanged full-screen
//    call, so the flag-off path and the no-evidence path are byte-identical.
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
        /// d13: set whenever candidates from DIFFERENT sources (AX vs OCR vs
        /// vision) pointed at materially different places — records who won,
        /// how the conflict was resolved, and the losers. Audit-safe: hashes,
        /// counts, and numeric coordinates only.
        public let disagreement: DisagreementDecision?

        public init(
            result: GroundingResult,
            outcome: VerifiedGroundingOutcome,
            verifierResult: GroundingVerifierResult,
            disagreement: DisagreementDecision? = nil
        ) {
            self.result = result
            self.outcome = outcome
            self.verifierResult = verifierResult
            self.disagreement = disagreement
        }
    }

    // MARK: - d13 disagreement/confidence gate

    /// A non-selected contender in a cross-source grounding disagreement.
    /// Carries ONLY audit-safe fields (source, hash, scores, numeric coords).
    public struct DisagreementLoser: Equatable, Sendable {
        public let source: GroundingSource
        public let candidateHash: String?
        public let score: Double
        public let confidence: Double
        public let x: Double?
        public let y: Double?

        public init(
            source: GroundingSource,
            candidateHash: String?,
            score: Double,
            confidence: Double,
            x: Double?,
            y: Double?
        ) {
            self.source = source
            self.candidateHash = candidateHash
            self.score = score
            self.confidence = confidence
            self.x = x
            self.y = y
        }
    }

    /// How a cross-source grounding disagreement (AX vs OCR vs vision naming
    /// different spots for the same target) was decided.
    public struct DisagreementDecision: Equatable, Sendable {
        public enum Resolution: String, Equatable, Sendable {
            /// The verifier's own arbitration already picked a winner — the
            /// decision is recorded for the audit trail only.
            case verifier
            /// The trust-order gate picked the higher-trust source (native AX
            /// over OCR over synthetic-from-vision) among viable contenders.
            case trustOrder = "trust_order"
            /// Contenders shared a trust tier — verifier score + candidate
            /// confidence broke the tie.
            case confidence
            /// Disagreement detected but the gate is off (flag disabled) — the
            /// would-be winner is recorded so the A/B is observable, with no
            /// behavior change.
            case observed
        }

        public let resolution: Resolution
        public let winnerSource: GroundingSource?
        public let winnerHash: String?
        public let winnerScore: Double?
        public let winnerX: Double?
        public let winnerY: Double?
        public let sourceCount: Int
        public let clusterCount: Int
        public let losers: [DisagreementLoser]

        public init(
            resolution: Resolution,
            winnerSource: GroundingSource?,
            winnerHash: String?,
            winnerScore: Double?,
            winnerX: Double?,
            winnerY: Double?,
            sourceCount: Int,
            clusterCount: Int,
            losers: [DisagreementLoser]
        ) {
            self.resolution = resolution
            self.winnerSource = winnerSource
            self.winnerHash = winnerHash
            self.winnerScore = winnerScore
            self.winnerX = winnerX
            self.winnerY = winnerY
            self.sourceCount = sourceCount
            self.clusterCount = clusterCount
            self.losers = losers
        }
    }

    /// d15: one routed-away-from-AX decision, surfaced for the audit trail.
    /// Emitted ONLY when the routing gate sends a request to the visual
    /// grounder (canvas concept / own UI / distrusted AX / sparse / stale) —
    /// AX-first is the default and needs no row. Audit-safe: enum tokens,
    /// hashes, and counts only.
    public struct RouteOutcome: Equatable, Sendable {
        public let decision: GroundingRouter.Decision
        public let targetHash: String?

        public init(decision: GroundingRouter.Decision, targetHash: String?) {
            self.decision = decision
            self.targetHash = targetHash
        }
    }

    public struct VerifierOutcome: Equatable, Sendable {
        public let target: String
        public let outcome: VerifiedGroundingOutcome
        public let verifierResult: GroundingVerifierResult
        public let candidateCount: Int
        public let selectedSource: GroundingSource?
        public let selectedCandidateHash: String?
        /// d13: present when cross-source candidates disagreed on this ground.
        public let disagreement: DisagreementDecision?

        public init(
            target: String,
            outcome: VerifiedGroundingOutcome,
            verifierResult: GroundingVerifierResult,
            candidateCount: Int,
            selectedSource: GroundingSource? = nil,
            selectedCandidateHash: String? = nil,
            disagreement: DisagreementDecision? = nil
        ) {
            self.target = target
            self.outcome = outcome
            self.verifierResult = verifierResult
            self.candidateCount = candidateCount
            self.selectedSource = selectedSource
            self.selectedCandidateHash = selectedCandidateHash
            self.disagreement = disagreement
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
    /// d12 (AX-SoM picker, default OFF — gated on the same
    /// `cascade.experimentalCompressedObservation` flag that surfaces the mark
    /// ids to the planner in the first place): when the planner names a mark id
    /// from the d10/d11 candidate list, execute via that element's EXACT frame
    /// (semantic AX action at the frame center — the d06 path) with no visual
    /// model round trip; and when the planner names a plain label, try the AX
    /// candidate FIRST, falling to the visual grounder only when AX offers no
    /// candidate.
    private let axPickerEnabled: Bool
    private let previousAnchor: VerifiedGroundingAnchor?
    private let candidateFailureCounts: [String: Int]
    private let onVerifierOutcome: (@Sendable (VerifierOutcome) async -> Void)?
    private let onRuntimeProfile: (@Sendable (AXRuntimeProfile) async -> Void)?
    /// d15: observes every routing-gate decision that sent a request to the
    /// visual grounder, so the reason lands in the `grounding.route` audit.
    private let onRouteDecision: (@Sendable (RouteOutcome) async -> Void)?
    private let groundingCache: GroundingCache?
    private let cacheMode: GroundingCacheMode
    private let cacheContextProvider: @Sendable () async -> AppWindowSnapshot
    private let regionNarrower: (@Sendable (Data, String, Int, Int) async -> ElementRegion?)?
    /// d16 (test seam only): replaces the live `LocalRegionNarrower` uncertain-
    /// region harvest that decides WHERE to crop before a visual round trip.
    /// nil — the shipped default — keeps the real AX/OCR narrowing; tests
    /// inject a fixed region so the crop → ground → map-back chain is provable
    /// without live accessibility.
    private let cropRefineRegionOverride: (@Sendable (Data, String, Int, Int) async -> CGRect?)?
    /// d14 (test seam only): replaces the LIVE bounded AX harvest the d12 mark
    /// picker resolves planner-named ids against. nil — the shipped default —
    /// keeps the real `AXElementResolver.interactables` walk (including the
    /// never-Cascade / never-distrusted-AX guards); tests inject a synthetic
    /// harvest so the mark-id → exact-frame path is provable without live
    /// accessibility.
    private let markPickHarvestOverride: (@MainActor @Sendable () -> [AXElementResolver.Match])?

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
        axPickerEnabled: Bool = false,
        previousAnchor: VerifiedGroundingAnchor? = nil,
        candidateFailureCounts: [String: Int] = [:],
        groundingCache: GroundingCache? = nil,
        cacheMode: GroundingCacheMode = .structural,
        cacheContextProvider: @escaping @Sendable () async -> AppWindowSnapshot = {
            await MainActor.run { AppWindowObserver.snapshot() }
        },
        regionNarrower: (@Sendable (Data, String, Int, Int) async -> ElementRegion?)? = nil,
        cropRefineRegionOverride: (@Sendable (Data, String, Int, Int) async -> CGRect?)? = nil,
        markPickHarvestOverride: (@MainActor @Sendable () -> [AXElementResolver.Match])? = nil,
        onRuntimeProfile: (@Sendable (AXRuntimeProfile) async -> Void)? = nil,
        onRouteDecision: (@Sendable (RouteOutcome) async -> Void)? = nil,
        onVerifierOutcome: (@Sendable (VerifierOutcome) async -> Void)? = nil
    ) {
        self.base = base
        self.skills = skills
        self.minAXScore = minAXScore
        self.verifyCandidates = verifyCandidates
        self.axPickerEnabled = axPickerEnabled
        self.previousAnchor = previousAnchor
        self.candidateFailureCounts = candidateFailureCounts
        self.groundingCache = groundingCache
        self.cacheMode = cacheMode
        self.cacheContextProvider = cacheContextProvider
        self.regionNarrower = regionNarrower
        self.cropRefineRegionOverride = cropRefineRegionOverride
        self.markPickHarvestOverride = markPickHarvestOverride
        self.onRuntimeProfile = onRuntimeProfile
        self.onRouteDecision = onRouteDecision
        self.onVerifierOutcome = onVerifierOutcome
    }

    public func ground(
        screenshot: Data, target: String, displayWidthPoints: Int, displayHeightPoints: Int
    ) async -> CGPoint? {
        var target = await targetWithRuntimeHints(target)
        switch await markPickOutcome(
            target: target, displayWidthPoints: displayWidthPoints, displayHeightPoints: displayHeightPoints
        ) {
        case .picked(let result):
            return result.selectedPoint
        case .fallback(let stripped):
            target = stripped
        case .noMark:
            break
        }
        guard verifyCandidates else {
            // d15: no per-call-site canvas/AX checks here — `axGround` consults
            // the single routing gate (`GroundingRouter`) and returns nil, with
            // the reason audited, whenever the request belongs to vision.
            if let axPoint = await axGround(
                target: target, displayWidthPoints: displayWidthPoints, displayHeightPoints: displayHeightPoints
            ) {
                return axPoint
            }
            guard groundingCache != nil else {
                // d16: try the crop-refined pass first; a nil (flag off / no
                // local evidence / crop miss) leaves the full-screen call
                // exactly as shipped.
                if let refined = await cropRefinedVisualResult(
                    screenshot: screenshot, target: target,
                    displayWidthPoints: displayWidthPoints, displayHeightPoints: displayHeightPoints,
                    options: .default
                ), let refinedPoint = refined.selectedPoint {
                    return refinedPoint
                }
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
        await groundResult(
            screenshot: screenshot,
            target: target,
            displayWidthPoints: displayWidthPoints,
            displayHeightPoints: displayHeightPoints,
            options: .default
        )
    }

    public func groundResult(
        screenshot: Data,
        target: String,
        displayWidthPoints: Int,
        displayHeightPoints: Int,
        options: GroundingRequestOptions
    ) async -> GroundingResult {
        var target = await targetWithRuntimeHints(target)
        // d12: a planner-named AX-SoM mark resolves structurally to the exact
        // element frame — no visual model, no cache, no verifier round trip.
        switch await markPickOutcome(
            target: target, displayWidthPoints: displayWidthPoints, displayHeightPoints: displayHeightPoints
        ) {
        case .picked(let result):
            return result
        case .fallback(let stripped):
            target = stripped
        case .noMark:
            break
        }
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
                // d16: crop-and-refine before the full-screen visual call; nil
                // falls through to the unchanged shipped path.
                if let refined = await cropRefinedVisualResult(
                    screenshot: screenshot,
                    target: target,
                    displayWidthPoints: displayWidthPoints,
                    displayHeightPoints: displayHeightPoints,
                    options: options
                ) {
                    return refined
                }
                let result = await base.groundResult(
                    screenshot: screenshot,
                    target: target,
                    displayWidthPoints: displayWidthPoints,
                    displayHeightPoints: displayHeightPoints,
                    options: options
                )
                let elapsed = start.duration(to: ContinuousClock.now)
                return result.selectedCandidate?.latency == nil
                    ? Self.withLatency(result, elapsed.mixtureTimeInterval)
                    : result
            }
            let start = ContinuousClock.now
            // d15: routing (canvas / own UI / distrusted / sparse / stale AX)
            // is decided inside `axGround` by the single `GroundingRouter`.
            if let axPoint = await axGround(
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
                displayHeightPoints: displayHeightPoints,
                options: options
            )
            let elapsed = start.duration(to: ContinuousClock.now)
            return result.selectedCandidate?.latency == nil
                ? Self.withLatency(result, elapsed.mixtureTimeInterval)
                : result
        }

        // d15: `axVerifierCandidate` consults the single routing gate and is
        // nil (reason audited) for canvas / own-UI / distrusted / sparse /
        // stale-AX requests — no duplicated checks at this call site.
        let axCandidate = await axVerifierCandidate(
            target: target,
            displayWidthPoints: displayWidthPoints,
            displayHeightPoints: displayHeightPoints
        )
        // d12 AX-first gate (flag-gated): when AX offers a candidate, verify it
        // ALONE first and — on a clean accept — return it without ever calling
        // the visual grounder. AX candidates are free, exact, and live; the
        // visual model stays the fallback for targets AX cannot see. Anything
        // short of an accept falls through to the existing merged
        // candidates-plus-verifier path, so the safety net is unchanged.
        if axPickerEnabled, let axCandidate {
            let axOnly = Self.selectVerifiedCandidate(
                axCandidate: axCandidate,
                baseResult: GroundingResult(),
                target: target,
                displayWidthPoints: displayWidthPoints,
                displayHeightPoints: displayHeightPoints,
                previousAnchor: previousAnchor,
                candidateFailureCounts: candidateFailureCounts,
                trustOrderGateEnabled: axPickerEnabled
            )
            if axOnly.verifierResult.verdict == .accept, axOnly.result.selectedPoint != nil {
                await recordVerifierOutcomeIfNeeded(axOnly, target: target)
                return axOnly.result
            }
        }
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
            let ambiguityOptions = Self.ambiguityOptions(
                from: options,
                indexedResult: indexedResult,
                axCandidate: axCandidate,
                target: target,
                candidateFailureCounts: candidateFailureCounts
            )
            let baseResult: GroundingResult
            if ambiguityOptions.sampleCount > options.sampleCount {
                let visualResult = await base.groundResult(
                    screenshot: screenshot,
                    target: target,
                    displayWidthPoints: displayWidthPoints,
                    displayHeightPoints: displayHeightPoints,
                    options: ambiguityOptions
                )
                baseResult = Self.mergedGroundingResult(indexedResult, visualResult)
            } else if let indexedResult {
                baseResult = indexedResult
            } else if let refined = await cropRefinedVisualResult(
                screenshot: screenshot,
                target: target,
                displayWidthPoints: displayWidthPoints,
                displayHeightPoints: displayHeightPoints,
                options: options
            ) {
                // d16: the primary visual call grounds a CROP of the uncertain
                // region when local evidence can localize it; the verifier and
                // any best-of-N escalation below still see display-local
                // points, and the escalation retry deliberately stays
                // full-screen (a second, different look).
                baseResult = refined
            } else {
                baseResult = await base.groundResult(
                    screenshot: screenshot,
                    target: target,
                    displayWidthPoints: displayWidthPoints,
                    displayHeightPoints: displayHeightPoints,
                    options: options
                )
            }
            var selection = Self.selectVerifiedCandidate(
                axCandidate: axCandidate,
                baseResult: baseResult,
                target: target,
                displayWidthPoints: displayWidthPoints,
                displayHeightPoints: displayHeightPoints,
                previousAnchor: previousAnchor,
                candidateFailureCounts: candidateFailureCounts,
                trustOrderGateEnabled: axPickerEnabled
            )
            // Fail fast on noCandidates: if the verifier found NOTHING to ground (an
            // AX-sparse view with no viable candidate), a second visual-grounding pass
            // won't conjure one — it only adds a slow round-trip. Escalate best-of-N ONLY
            // when there WERE candidates but none was accepted (worth another look).
            if selection.verifierResult.verdict != .accept,
               selection.verifierResult.failureKind != .noCandidates,
               ambiguityOptions.sampleCount == options.sampleCount,
               options.sampleCount < 3 {
                let visualResult = await base.groundResult(
                    screenshot: screenshot,
                    target: target,
                    displayWidthPoints: displayWidthPoints,
                    displayHeightPoints: displayHeightPoints,
                    options: Self.escalatedGroundingOptions(from: options)
                )
                let retriedBase = Self.mergedGroundingResult(visualResult, indexedResult ?? baseResult)
                selection = Self.selectVerifiedCandidate(
                    axCandidate: axCandidate,
                    baseResult: retriedBase,
                    target: target,
                    displayWidthPoints: displayWidthPoints,
                    displayHeightPoints: displayHeightPoints,
                    previousAnchor: previousAnchor,
                    candidateFailureCounts: candidateFailureCounts,
                    trustOrderGateEnabled: axPickerEnabled
                )
            }
            await recordVerifierOutcomeIfNeeded(selection, target: target)
            await storeGroundingCacheResult(selection.result, key: key)
            return selection.result
        }
    }

    private static func ambiguityOptions(
        from options: GroundingRequestOptions,
        indexedResult: GroundingResult?,
        axCandidate: GroundingVerifierCandidate?,
        target: String,
        candidateFailureCounts: [String: Int]
    ) -> GroundingRequestOptions {
        guard options.sampleCount < 3 else { return options }
        guard shouldEscalateForAmbiguity(
            indexedResult: indexedResult,
            axCandidate: axCandidate,
            target: target,
            risk: options.risk,
            candidateFailureCounts: candidateFailureCounts
        ) else { return options }
        return escalatedGroundingOptions(from: options)
    }

    private static func escalatedGroundingOptions(from options: GroundingRequestOptions) -> GroundingRequestOptions {
        GroundingRequestOptions(
            sampleCount: 3,
            maxDispersion: min(options.maxDispersion, 24),
            minimumConfidence: max(options.minimumConfidence, 0.72),
            risk: options.risk,
            priorityRegions: options.priorityRegions,
            useRegionBudgeting: options.useRegionBudgeting,
            hostedMode: options.hostedMode
        )
    }

    private static func shouldEscalateForAmbiguity(
        indexedResult: GroundingResult?,
        axCandidate: GroundingVerifierCandidate?,
        target: String,
        risk: GroundingActionRisk,
        candidateFailureCounts: [String: Int]
    ) -> Bool {
        if risk == .high || risk == .destructive { return true }
        if !candidateFailureCounts.isEmpty { return true }
        if looksGenericTarget(target) { return true }
        if (indexedResult?.alternativeCount ?? 0) > 0 { return true }
        if let axCandidate,
           let selected = indexedResult?.selectedCandidate,
           selected.source != axCandidate.candidate.source,
           !pointsAgree(selected.point, axCandidate.candidate.point) {
            return true
        }
        return false
    }

    private static func looksGenericTarget(_ target: String) -> Bool {
        let tokens = Set(target.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty })
        guard !tokens.isEmpty else { return false }
        let generic: Set<String> = [
            "button", "field", "box", "input", "next", "continue", "submit",
            "send", "ok", "done", "cancel", "delete", "search", "link", "tab"
        ]
        return !tokens.isDisjoint(with: generic) && tokens.count <= 4
    }

    private static func mergedGroundingResult(_ lhs: GroundingResult?, _ rhs: GroundingResult?) -> GroundingResult {
        let candidates = [lhs, rhs].compactMap { $0 }.flatMap(\.candidates)
        guard !candidates.isEmpty else { return GroundingResult() }
        let selectedID = lhs?.selectedCandidateID ?? rhs?.selectedCandidateID ?? candidates.first?.candidateID
        let selectedIndex = selectedID.flatMap { id in candidates.firstIndex { $0.candidateID == id } } ?? 0
        return GroundingResult(
            candidates: candidates,
            selectedIndex: selectedIndex,
            selectedCandidateID: selectedID,
            verifierVerdict: lhs?.verifierVerdict ?? rhs?.verifierVerdict,
            verifierFailureKind: lhs?.verifierFailureKind ?? rhs?.verifierFailureKind,
            alternativeCount: max((lhs?.alternativeCount ?? 0) + (rhs?.alternativeCount ?? 0), candidates.count - 1)
        )
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
            // d16: crop-and-refine before the full-screen visual call; the
            // remapped result is display-local, so it caches like any other.
            if let refined = await cropRefinedVisualResult(
                screenshot: screenshot,
                target: target,
                displayWidthPoints: displayWidthPoints,
                displayHeightPoints: displayHeightPoints,
                options: .default
            ) {
                await storeGroundingCacheResult(refined, key: key)
                return refined
            }
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
        displayHeightPoints: Int,
        options: GroundingRequestOptions = .default
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
            } else if let refined = await cropRefinedVisualResult(
                screenshot: screenshot,
                target: target,
                displayWidthPoints: displayWidthPoints,
                displayHeightPoints: displayHeightPoints,
                options: options
            ) {
                // d16: crop-and-refine before the full-screen visual call.
                result = refined
            } else {
                result = await base.groundResult(
                    screenshot: screenshot,
                    target: target,
                    displayWidthPoints: displayWidthPoints,
                    displayHeightPoints: displayHeightPoints,
                    options: options
                )
            }
            await storeGroundingCacheResult(result, key: key)
            return result
        }
    }

    /// d16 (crop-and-refine, ScreenSpot-Pro / DRS-GUI; default OFF — rides the
    /// same `cascade.experimentalCompressedObservation` flag as the d12 picker):
    /// before a full-screen visual round trip, ask the local narrower for the
    /// UNCERTAIN region (the padded union of weak AX/OCR matches), crop the
    /// capture to it at native pixel resolution, and ground the crop — the
    /// model sees the region at far higher effective resolution than the
    /// downscaled full screen. Crop-local output maps back to display points
    /// through the d01 `CoordinateTransform`. Returns nil whenever the flag is
    /// off, no region was found, the crop could not be built, or the crop pass
    /// produced nothing actionable — the caller then runs its existing
    /// full-screen path unchanged, so behavior never regresses.
    private func cropRefinedVisualResult(
        screenshot: Data,
        target: String,
        displayWidthPoints: Int,
        displayHeightPoints: Int,
        options: GroundingRequestOptions
    ) async -> GroundingResult? {
        guard axPickerEnabled else { return nil }
        let region: CGRect?
        if let cropRefineRegionOverride {
            region = await cropRefineRegionOverride(screenshot, target, displayWidthPoints, displayHeightPoints)
        } else {
            let narrower = LocalRegionNarrower(
                skills: skills,
                policy: Self.trustPolicy,
                onRuntimeProfile: onRuntimeProfile
            )
            region = await narrower.narrowUncertainRegion(
                screenshot: screenshot,
                target: target,
                displayWidthPoints: displayWidthPoints,
                displayHeightPoints: displayHeightPoints
            )
        }
        guard let region,
              let plan = LocalRegionNarrower.cropRefinePlan(
                  screenshot: screenshot,
                  region: region,
                  displayWidthPoints: displayWidthPoints,
                  displayHeightPoints: displayHeightPoints
              )
        else { return nil }
        let cropResult = await base.groundResult(
            screenshot: plan.croppedJPEG,
            target: target,
            displayWidthPoints: plan.cropWidthPoints,
            displayHeightPoints: plan.cropHeightPoints,
            options: Self.cropRefineOptions(from: options, plan: plan)
        )
        let refined = Self.cropRefinedResult(cropResult, plan: plan)
        guard refined.isActionable(minConfidence: options.minimumConfidence) else { return nil }
        return refined
    }

    /// Request options for the crop-local pass: sampling/confidence/risk carry
    /// over; priority regions are remapped into crop-local points; region
    /// budgeting is off because the crop IS the focus region.
    static func cropRefineOptions(
        from options: GroundingRequestOptions,
        plan: LocalRegionNarrower.CropRefinePlan
    ) -> GroundingRequestOptions {
        GroundingRequestOptions(
            sampleCount: options.sampleCount,
            maxDispersion: options.maxDispersion,
            minimumConfidence: options.minimumConfidence,
            risk: options.risk,
            priorityRegions: options.priorityRegions.compactMap(plan.cropLocalRect(fromDisplayRect:)),
            useRegionBudgeting: false,
            hostedMode: options.hostedMode
        )
    }

    /// Maps every candidate of a crop-local grounding result back into
    /// display-local AppKit points via the plan's typed transforms, and
    /// rebuilds each coordinate chain against the REAL screenshot geometry so
    /// the `agent.ground` audit shows the true crop rect (numeric geometry
    /// only). Verdicts, selection, and confidences carry over untouched.
    static func cropRefinedResult(
        _ result: GroundingResult,
        plan: LocalRegionNarrower.CropRefinePlan
    ) -> GroundingResult {
        let candidates = result.candidates.map { candidate -> GroundingCandidate in
            let mappedPoint = candidate.point.flatMap(plan.displayPoint(fromCropLocalPoint:))
            return GroundingCandidate(
                point: mappedPoint,
                region: candidate.region.flatMap(plan.displayRect(fromCropLocalRect:)),
                confidence: candidate.confidence,
                source: candidate.source,
                coordinateSpace: candidate.coordinateSpace,
                rawModel: candidate.rawModel,
                latency: candidate.latency,
                dispersion: candidate.dispersion,
                reason: candidate.reason.map { "\($0) crop_refined" } ?? "crop_refined",
                candidateID: candidate.candidateID,
                markNumber: candidate.markNumber,
                displayBounds: candidate.displayBounds.flatMap(plan.displayRect(fromCropLocalRect:)),
                imageBounds: candidate.imageBounds,
                role: candidate.role,
                label: candidate.label,
                nearbyOCRText: candidate.nearbyOCRText,
                ocrDistancePoints: candidate.ocrDistancePoints,
                agreeingSources: candidate.agreeingSources,
                coordinateChain: candidate.point == nil
                    ? candidate.coordinateChain
                    : plan.refinedCoordinateChain(
                        from: candidate.coordinateChain,
                        cropLocalPoint: candidate.point,
                        displayPoint: mappedPoint
                    )
            )
        }
        return GroundingResult(
            candidates: candidates,
            selectedIndex: result.selectedIndex,
            selectedCandidateID: result.selectedCandidateID,
            verifierVerdict: result.verifierVerdict,
            verifierFailureKind: result.verifierFailureKind,
            alternativeCount: result.alternativeCount
        )
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
                    imageBounds: candidate.imageBounds,
                    role: candidate.role,
                    label: candidate.label,
                    nearbyOCRText: candidate.nearbyOCRText,
                    ocrDistancePoints: candidate.ocrDistancePoints,
                    agreeingSources: candidate.agreeingSources,
                    coordinateChain: candidate.coordinateChain
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
                    imageBounds: candidate.imageBounds,
                    role: candidate.role,
                    label: candidate.label,
                    nearbyOCRText: candidate.nearbyOCRText,
                    ocrDistancePoints: candidate.ocrDistancePoints,
                    agreeingSources: candidate.agreeingSources,
                    coordinateChain: candidate.coordinateChain
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

    /// d15: hand a visual-only routing decision to the audit sink. Fire-and-
    /// forget from the synchronous MainActor resolve, mirroring how
    /// `onRuntimeProfile` is surfaced. Hashes only — never the target text.
    private func emitRouteDecision(_ decision: GroundingRouter.Decision, target: String) {
        guard let onRouteDecision else { return }
        let outcome = RouteOutcome(decision: decision, targetHash: Self.auditHash(target))
        Task { await onRouteDecision(outcome) }
    }

    private func recordVerifierOutcomeIfNeeded(
        _ selection: VerifiedGroundingSelection,
        target: String
    ) async {
        guard let onVerifierOutcome else { return }
        await onVerifierOutcome(VerifierOutcome(
            target: target,
            outcome: selection.outcome,
            verifierResult: selection.verifierResult,
            candidateCount: selection.result.candidates.count,
            selectedSource: selection.result.selectedCandidate?.source,
            selectedCandidateHash: Self.auditHash(
                selection.result.selectedCandidate?.candidateID
                    ?? selection.result.selectedCandidate?.rawModel
                    ?? selection.result.selectedCandidateID
                    ?? selection.result.selectedCandidate?.label
            ),
            disagreement: selection.disagreement
        ))
    }

    private static func auditHash(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
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
        let ranked = ScreenElementIndex.rankedCandidates(
            for: target,
            in: indexed,
            policy: Self.trustPolicy,
            within: 0.35,
            limit: 5
        )
        if !ranked.isEmpty {
            return Self.groundingResult(
                from: ranked,
                reason: "clickable-map ranked label match",
                totalCandidateCount: indexed.count
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
        from ranked: [ScreenElementIndex.RankedCandidate],
        reason: String,
        totalCandidateCount: Int
    ) -> GroundingResult {
        let candidates = ranked.map { rankedCandidate -> GroundingCandidate in
            let selected = rankedCandidate.candidate
            let source = Self.groundingSource(selected.source)
            let agreeingSources = selected.contributingSources.compactMap(Self.groundingSource)
            return GroundingCandidate(
                point: selected.center,
                region: selected.bounds.cgRect,
                confidence: min(1, max(selected.confidence, rankedCandidate.score / 3)),
                source: source,
                coordinateSpace: .displayLocalAppKitPoints,
                rawModel: selected.label,
                reason: "\(reason) \(selected.source.rawValue) score \(String(format: "%.2f", rankedCandidate.score))",
                candidateID: selected.id,
                markNumber: selected.mark.number,
                displayBounds: selected.bounds.cgRect,
                imageBounds: selected.imageBounds?.cgRect,
                role: selected.role.rawValue,
                label: selected.label,
                nearbyOCRText: selected.label,
                ocrDistancePoints: selected.source == .ocr ? 0 : nil,
                agreeingSources: agreeingSources.filter { $0 != source }
            )
        }
        return GroundingResult(
            candidates: candidates,
            selectedIndex: 0,
            selectedCandidateID: candidates.first?.candidateID,
            alternativeCount: max(0, totalCandidateCount - 1)
        )
    }

    private static func groundingSource(_ source: ScreenElementIndex.Source) -> GroundingSource {
        switch source {
        case .accessibility:
            return .accessibility
        case .visual:
            return .visualModel
        case .ocr:
            return .ocr
        }
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
        trustOrderGateEnabled: Bool = false,
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
        let selection = Self.arbitratedSelection(
            verifierCandidates: verifierCandidates,
            baseResult: baseResult,
            context: context,
            previousAnchor: previousAnchor,
            candidateFailureCounts: candidateFailureCounts,
            now: now
        )
        // d13: when AX / OCR / vision candidates named materially DIFFERENT
        // places, record the decision + the losers, and — gate on — resolve a
        // verifier-ambiguous stall by trust order (native AX > OCR >
        // synthetic-from-vision) + confidence instead of abstaining.
        return Self.applyingDisagreementGate(
            selection,
            candidates: verifierCandidates,
            context: context,
            gateEnabled: trustOrderGateEnabled
        )
    }

    private static func arbitratedSelection(
        verifierCandidates: [GroundingVerifierCandidate],
        baseResult: GroundingResult,
        context: GroundingVerifierContext,
        previousAnchor: VerifiedGroundingAnchor?,
        candidateFailureCounts: [String: Int],
        now: Date
    ) -> VerifiedGroundingSelection {
        let verifierResult = GroundingVerifier().verify(verifierCandidates, context: context)

        guard let previousAnchor else {
            if verifierResult.failureKind != .ambiguous,
               Self.shouldUseBestOfN(
                baseResult: baseResult,
                verifierResult: verifierResult,
                context: context,
                candidateFailureCounts: candidateFailureCounts
            ), let selectedID = Self.bestOfNCandidateID(
                from: verifierCandidates,
                verifierResult: verifierResult,
                context: context,
                candidateFailureCounts: candidateFailureCounts
            ) {
                let accepted = Self.bestOfNAcceptedResult(selectedID: selectedID, verifierResult: verifierResult)
                return Self.selection(
                    from: verifierCandidates,
                    selectedID: selectedID,
                    outcome: .selected,
                    verifierResult: accepted
                )
            }
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
            if verifierResult.failureKind != .ambiguous,
               let selectedID = Self.bestOfNCandidateID(
                from: verifierCandidates,
                verifierResult: verifierResult,
                context: context,
                candidateFailureCounts: candidateFailureCounts
            ) {
                let accepted = Self.bestOfNAcceptedResult(selectedID: selectedID, verifierResult: verifierResult)
                return Self.selection(
                    from: verifierCandidates,
                    selectedID: selectedID,
                    outcome: .selected,
                    verifierResult: accepted
                )
            }
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
            let accepted = drift.selected.map {
                Self.bestOfNAcceptedResult(selectedID: $0.id, verifierResult: verifierResult)
            } ?? verifierResult
            return Self.selection(
                from: verifierCandidates,
                selectedID: drift.selected?.id,
                outcome: .retryNextCandidate,
                verifierResult: accepted
            )
        case .demote:
            return Self.selection(
                from: verifierCandidates,
                selectedID: nil,
                outcome: .demote,
                verifierResult: verifierResult
            )
        case .ambiguous:
            if let selectedID = Self.bestOfNCandidateID(
                from: verifierCandidates,
                verifierResult: verifierResult,
                context: context,
                candidateFailureCounts: candidateFailureCounts
            ) {
                let accepted = Self.bestOfNAcceptedResult(selectedID: selectedID, verifierResult: verifierResult)
                return Self.selection(
                    from: verifierCandidates,
                    selectedID: selectedID,
                    outcome: .selected,
                    verifierResult: accepted
                )
            }
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

    /// One per-source best viable candidate competing in a disagreement.
    struct DisagreementContender {
        let candidate: GroundingVerifierCandidate
        let score: Double
    }

    /// d13 disagreement/confidence gate. Detects a CROSS-SOURCE disagreement —
    /// viable candidates from at least two different sources whose points sit at
    /// materially different places — and:
    ///  • always attaches an audit-safe `DisagreementDecision` (who won, who
    ///    lost, how) to the selection, so every conflict is visible in the
    ///    `grounding.disagreement` audit row;
    ///  • when `gateEnabled` (rides the same `cascade.experimentalCompressedObservation`
    ///    flag as the d11/d12 AX-first cluster) and the verifier ABSTAINED as
    ///    ambiguous, resolves the stall by trust order — native AX > DOM > OCR >
    ///    synthetic-from-vision (`sourceRank`) — then verifier score, then the
    ///    candidate's own confidence. A native AX contender only competes at all
    ///    when verification did NOT prove it wrong (it must clear the same viable
    ///    floor as everyone else), honoring "AX outranks synthetic unless
    ///    verification proves AX wrong".
    /// Gate off (the default) keeps shipped behavior byte-identical apart from
    /// the added audit record. Same-source ambiguity ("which of two buttons?")
    /// is NOT a trust-order question and always stays ambiguous.
    static func applyingDisagreementGate(
        _ selection: VerifiedGroundingSelection,
        candidates: [GroundingVerifierCandidate],
        context: GroundingVerifierContext,
        gateEnabled: Bool
    ) -> VerifiedGroundingSelection {
        let contenders = disagreementContenders(
            candidates: candidates,
            verifierResult: selection.verifierResult,
            context: context
        )
        guard contenders.count >= 2 else { return selection }
        let clusterCount = locationClusterCount(contenders.compactMap(\.candidate.candidate.point))
        // All sources point at essentially the same spot: corroboration, not
        // disagreement — nothing to arbitrate or audit here.
        guard clusterCount >= 2 else { return selection }
        let sourceCount = Set(contenders.map(\.candidate.candidate.source.rawValue)).count

        switch selection.outcome {
        case .selected, .retryNextCandidate:
            guard selection.result.selectedPoint != nil else { return selection }
            let winnerID = selection.result.selectedCandidateID
            let winner = candidates.first { $0.id == winnerID }
            let winnerScore = selection.verifierResult.scores.first { $0.id == winnerID }?.score
                ?? selection.verifierResult.confidence
            return VerifiedGroundingSelection(
                result: selection.result,
                outcome: selection.outcome,
                verifierResult: selection.verifierResult,
                disagreement: disagreementDecision(
                    resolution: .verifier,
                    winner: winner,
                    winnerScore: winnerScore,
                    contenders: contenders,
                    sourceCount: sourceCount,
                    clusterCount: clusterCount
                )
            )
        case .abstained(.ambiguous), .ambiguous:
            // Contenders arrive pre-sorted by (trust order, score, confidence).
            guard let top = contenders.first else { return selection }
            guard gateEnabled else {
                // Observe-only: record the would-be winner so the flag A/B is
                // measurable, keep the abstain.
                return VerifiedGroundingSelection(
                    result: selection.result,
                    outcome: selection.outcome,
                    verifierResult: selection.verifierResult,
                    disagreement: disagreementDecision(
                        resolution: .observed,
                        winner: top.candidate,
                        winnerScore: top.score,
                        contenders: contenders,
                        sourceCount: sourceCount,
                        clusterCount: clusterCount
                    )
                )
            }
            let runnerUp = contenders.dropFirst().first
            let wonByTrust = runnerUp.map {
                sourceRank(top.candidate.candidate.source) > sourceRank($0.candidate.candidate.source)
            } ?? false
            let accepted = bestOfNAcceptedResult(
                selectedID: top.candidate.id,
                verifierResult: selection.verifierResult
            )
            let resolved = Self.selection(
                from: candidates,
                selectedID: top.candidate.id,
                outcome: .selected,
                verifierResult: accepted
            )
            return VerifiedGroundingSelection(
                result: resolved.result,
                outcome: resolved.outcome,
                verifierResult: resolved.verifierResult,
                disagreement: disagreementDecision(
                    resolution: wonByTrust ? .trustOrder : .confidence,
                    winner: top.candidate,
                    winnerScore: top.score,
                    contenders: contenders,
                    sourceCount: sourceCount,
                    clusterCount: clusterCount
                )
            )
        default:
            return selection
        }
    }

    /// The best VIABLE candidate per source (no verifier failure, score above
    /// the ambiguity floor, an actual point), sorted by trust order → verifier
    /// score → candidate confidence → id. Fewer than two distinct sources means
    /// there is no cross-source disagreement to arbitrate.
    static func disagreementContenders(
        candidates: [GroundingVerifierCandidate],
        verifierResult: GroundingVerifierResult,
        context: GroundingVerifierContext
    ) -> [DisagreementContender] {
        // Anyone the verifier would have accepted alone, or that sat inside the
        // ambiguity margin of an acceptable best, is a legitimate contender; a
        // score below this floor was "proven wrong" and never wins by trust.
        let floor = max(0.45, context.acceptThreshold - context.ambiguityMargin)
        let candidatesByID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var bestPerSource: [GroundingSource: DisagreementContender] = [:]
        let orderedScores = verifierResult.scores.sorted {
            if $0.score == $1.score { return $0.id < $1.id }
            return $0.score > $1.score
        }
        for score in orderedScores where score.failureKind == nil && score.score >= floor {
            guard let candidate = candidatesByID[score.id], candidate.candidate.point != nil else { continue }
            let source = candidate.candidate.source
            guard bestPerSource[source] == nil else { continue }
            bestPerSource[source] = DisagreementContender(candidate: candidate, score: score.score)
        }
        guard bestPerSource.count >= 2 else { return [] }
        return bestPerSource.values.sorted { lhs, rhs in
            let lhsRank = sourceRank(lhs.candidate.candidate.source)
            let rhsRank = sourceRank(rhs.candidate.candidate.source)
            if lhsRank != rhsRank { return lhsRank > rhsRank }
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.candidate.candidate.confidence != rhs.candidate.candidate.confidence {
                return lhs.candidate.candidate.confidence > rhs.candidate.candidate.confidence
            }
            return lhs.candidate.id < rhs.candidate.id
        }
    }

    /// Number of distinct locations among the contenders, using the same
    /// agreement tolerance as the rest of the mixture (`pointsAgree`, 24pt).
    static func locationClusterCount(_ points: [CGPoint]) -> Int {
        var clusters: [CGPoint] = []
        for point in points where !clusters.contains(where: { pointsAgree($0, point) }) {
            clusters.append(point)
        }
        return clusters.count
    }

    private static func disagreementDecision(
        resolution: DisagreementDecision.Resolution,
        winner: GroundingVerifierCandidate?,
        winnerScore: Double?,
        contenders: [DisagreementContender],
        sourceCount: Int,
        clusterCount: Int
    ) -> DisagreementDecision {
        let losers = contenders
            .filter { $0.candidate.id != winner?.id }
            .map { contender in
                DisagreementLoser(
                    source: contender.candidate.candidate.source,
                    candidateHash: auditHash(
                        contender.candidate.candidate.candidateID
                            ?? contender.candidate.candidate.rawModel
                            ?? contender.candidate.label
                    ),
                    score: contender.score,
                    confidence: contender.candidate.candidate.confidence,
                    x: contender.candidate.candidate.point.map { Double($0.x) },
                    y: contender.candidate.candidate.point.map { Double($0.y) }
                )
            }
        return DisagreementDecision(
            resolution: resolution,
            winnerSource: winner?.candidate.source,
            winnerHash: auditHash(
                winner?.candidate.candidateID
                    ?? winner?.candidate.rawModel
                    ?? winner?.label
            ),
            winnerScore: winnerScore,
            winnerX: winner?.candidate.point.map { Double($0.x) },
            winnerY: winner?.candidate.point.map { Double($0.y) },
            sourceCount: sourceCount,
            clusterCount: clusterCount,
            losers: losers
        )
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
        let front = NSWorkspace.shared.frontmostApplication
        let skill = skills.skill(appName: front?.localizedName, bundleIdentifier: front?.bundleIdentifier)
        // d15: THE routing gate. AX-first by default; the visual grounder gets
        // the request ONLY for canvas concepts (a "placeholder"/"canvas" target
        // has no faithful AX node and a fuzzy match would hijack chrome),
        // Cascade's own UI (the audited "Agents"/"Create new…" hijack — the
        // screenshot excludes Cascade's windows, so vision sees the real
        // target), apps whose skill distrusts AX (`axUnreliable`), and sparse
        // or stale-node-dominated live trees. The stale rule is new and rides
        // the d11–d13 experimental flag; everything else reproduces the
        // previously scattered checks in one audited place.
        let decision = GroundingRouter.route(
            target: target,
            requestKind: .labelMatch,
            frontmostBundleIdentifier: front?.bundleIdentifier,
            ownBundleIdentifier: Self.cascadeBundleID,
            axUnreliable: skill?.axUnreliable == true,
            staleAXGateEnabled: axPickerEnabled,
            runtimeProfile: { AXElementResolver.runtimeProfileForFrontmost() }
        )
        guard decision.allowsAX else {
            // Sparse/stale routes still surface the profile to the existing
            // `grounding.ax_profile` audit, exactly like the pre-d15 path.
            if let profile = decision.runtimeProfile {
                Task { await onRuntimeProfile?(profile) }
            }
            emitRouteDecision(decision, target: target)
            return nil
        }
        let runtimeProfile = decision.runtimeProfile
        guard let match = AXElementResolver.find(label: target),
              match.score >= minAXScore else { return nil }
        // Map the matched element center through the typed transform for the display
        // the screenshot came from, selected by matching dimensions.
        guard let capture = Self.captureDisplayGeometry(widthPoints: displayWidthPoints, heightPoints: displayHeightPoints) else {
            return nil
        }
        guard let mapping = Self.displayLocalMapping(
            cgGlobalCenter: match.center,
            displayCGBounds: capture.cgBounds,
            transform: capture.transform
        ) else { return nil }
        let point = mapping.point
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
                displayBounds: candidateBounds.cgRect,
                coordinateChain: mapping.chain
            ),
            role: match.role,
            label: match.title,
            nearbyOCRText: match.title,
            ocrDistancePoints: 0
        )
    }

    // MARK: - d12 AX-SoM mark picking

    /// Confidence assigned to a mark pick. The planner referenced a control BY
    /// ITS STABLE ID from the d10/d11 observation — identity is exact, not a
    /// fuzzy label match — so this clears every per-risk minimum-confidence
    /// gate. The no-effect detector remains the backstop for a stale pick.
    static let markPickConfidence = 0.97

    /// How many controls the mark resolver re-harvests. Must be at least the
    /// d10/d11 note harvests (24) so every id the planner can possibly have
    /// seen is re-findable; 40 is `interactables`' own bound.
    static let markPickHarvestLimit = 40

    /// Outcome of the flag-gated d12 pre-step shared by every grounding entry
    /// point. `.picked` short-circuits with the exact-frame result; `.fallback`
    /// carries the target with the unresolvable mark stripped so the ordinary
    /// path grounds the remaining description; `.noMark` means the target names
    /// no mark (or the picker is off) — proceed unchanged.
    private enum MarkPickOutcome {
        case picked(GroundingResult)
        case fallback(String)
        case noMark
    }

    private func markPickOutcome(
        target: String,
        displayWidthPoints: Int,
        displayHeightPoints: Int
    ) async -> MarkPickOutcome {
        guard axPickerEnabled, let token = AXCompressedObservation.markToken(in: target) else { return .noMark }
        let start = ContinuousClock.now
        guard let candidate = await axMarkPickCandidate(
            token: token,
            displayWidthPoints: displayWidthPoints,
            displayHeightPoints: displayHeightPoints
        ) else {
            // Stale / vanished / ambiguous mark: ground the remaining
            // descriptive text ("[ax:1a2b3c4d] the New Note button" → "the New
            // Note button") through the unchanged AX-label-then-visual path.
            return .fallback(Self.markFallbackTarget(from: target))
        }
        let elapsed = start.duration(to: ContinuousClock.now)
        let result = Self.withLatency(
            GroundingResult(
                candidates: [candidate],
                selectedIndex: 0,
                selectedCandidateID: candidate.candidateID,
                verifierVerdict: .accept,
                alternativeCount: 0
            ),
            elapsed.mixtureTimeInterval
        )
        if let onVerifierOutcome {
            // Audit the pick through the same `grounding.verifier` row the
            // arbitration path writes — hashes/counts only, no raw text.
            await onVerifierOutcome(VerifierOutcome(
                target: target,
                outcome: .selected,
                verifierResult: GroundingVerifierResult(
                    verdict: .accept,
                    selectedCandidateID: candidate.candidateID,
                    confidence: candidate.confidence,
                    failureKind: nil,
                    scores: []
                ),
                candidateCount: 1,
                selectedSource: .accessibility,
                selectedCandidateHash: Self.auditHash(candidate.candidateID)
            ))
        }
        return .picked(result)
    }

    /// The fallback target once a mark failed to resolve: the mark reference
    /// stripped, unless the planner sent ONLY the mark — then keep the original
    /// so the miss is honest instead of grounding an empty string.
    nonisolated static func markFallbackTarget(from target: String) -> String {
        let stripped = AXCompressedObservation.strippingMarkTokens(from: target)
        return stripped.isEmpty ? target : stripped
    }

    /// Resolves a normalized mark token against a fresh bounded AX harvest and
    /// maps the element's EXACT frame into the executor's display-local AppKit
    /// space through the typed transform. Same hard guards as the label path
    /// (never Cascade's own UI, never a distrusted-AX app); nil falls back to
    /// ordinary grounding. AX/NSWorkspace/NSScreen are main-thread surfaces.
    @MainActor
    private func axMarkPickCandidate(
        token: String,
        displayWidthPoints: Int,
        displayHeightPoints: Int
    ) -> GroundingCandidate? {
        let matches: [AXElementResolver.Match]
        if let markPickHarvestOverride {
            // d14 test seam: a synthetic harvest replaces ONLY the live AX walk;
            // the resolve → exact-frame → candidate math below stays shipped.
            matches = markPickHarvestOverride()
        } else {
            let front = NSWorkspace.shared.frontmostApplication
            let skill = skills.skill(appName: front?.localizedName, bundleIdentifier: front?.bundleIdentifier)
            // d15: same routing gate as the label path. `.markPick` applies
            // only the app-level distrust rules (own UI / `axUnreliable`) —
            // a planner-named stable id is exact identity, so the fuzzy-label
            // protections (canvas words, sparse/stale tree) don't gate it.
            let decision = GroundingRouter.route(
                target: token,
                requestKind: .markPick,
                frontmostBundleIdentifier: front?.bundleIdentifier,
                ownBundleIdentifier: Self.cascadeBundleID,
                axUnreliable: skill?.axUnreliable == true
            )
            guard decision.allowsAX else {
                emitRouteDecision(decision, target: token)
                return nil
            }
            matches = AXElementResolver.interactables(limit: Self.markPickHarvestLimit)
        }
        guard let capture = Self.captureDisplayGeometry(
            widthPoints: displayWidthPoints, heightPoints: displayHeightPoints
        ) else { return nil }
        return Self.markPickCandidate(
            mark: token,
            matches: matches,
            displayCGBounds: capture.cgBounds,
            transform: capture.transform
        )
    }

    /// d14 (pure, unit-pinned): the mark-id → exact-frame half of the d12
    /// picker. Resolves the token against ONE harvest (deterministic prefix
    /// resolution — ambiguity refuses rather than guesses) and maps the
    /// element's center through the typed transform, returning a candidate
    /// whose `point` is the EXACT frame center in the executor's display-local
    /// AppKit space and whose `region`/`displayBounds` is the exact element
    /// frame recentred there — so the d06 semantic activation's
    /// `elementAtPosition(point)` hit-tests inside the very control the
    /// planner named. nil → the caller falls back to ordinary grounding.
    nonisolated static func markPickCandidate(
        mark token: String,
        matches: [AXElementResolver.Match],
        displayCGBounds: CGRect,
        transform: CoordinateTransform
    ) -> GroundingCandidate? {
        guard let match = AXCompressedObservation.resolveMark(token, in: matches) else { return nil }
        guard let mapping = Self.displayLocalMapping(
            cgGlobalCenter: match.center,
            displayCGBounds: displayCGBounds,
            transform: transform
        ) else { return nil }
        let point = mapping.point
        // The exact element frame recentred on the mapped point — logical sizes
        // are identical between CG-global and display-local AppKit spaces.
        let size = match.frame?.size ?? CGSize(width: 96, height: 28)
        let displayBounds = CGRect(
            x: point.x - size.width / 2,
            y: point.y - size.height / 2,
            width: size.width,
            height: size.height
        )
        return GroundingCandidate(
            point: point,
            region: displayBounds,
            confidence: Self.markPickConfidence,
            source: .accessibility,
            coordinateSpace: .displayLocalAppKitPoints,
            rawModel: match.title,
            reason: "ax_som_mark_pick",
            candidateID: AXCompressedObservation.stableID(for: match),
            displayBounds: displayBounds,
            role: match.role,
            label: match.title,
            nearbyOCRText: match.title,
            ocrDistancePoints: 0,
            coordinateChain: mapping.chain
        )
    }

    /// Words that denote a drawn surface with no faithful accessibility node, so a
    /// target naming one must be grounded visually, not by AX label match. d15
    /// moved the list into `GroundingRouter` (the single routing gate); this
    /// shim keeps the existing symbol pinned by tests and callers.
    nonisolated static func namesCanvasConcept(_ target: String) -> Bool {
        GroundingRouter.namesCanvasConcept(target)
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
        guard let screen = CoordinateTransform.ScreenGeometry(
            logicalFrame: CGRect(x: 0, y: 0, width: bounds.width, height: CGFloat(displayHeightPoints)),
            backingPixelSize: CGSize(width: bounds.width, height: CGFloat(displayHeightPoints))
        ), let transform = CoordinateTransform(screen: screen) else { return nil }
        return displayLocalMapping(cgGlobalCenter: c, displayCGBounds: bounds, transform: transform)?.point
    }

    nonisolated static func displayLocalMapping(
        cgGlobalCenter c: CGPoint,
        displayCGBounds bounds: CGRect,
        transform: CoordinateTransform
    ) -> (point: CGPoint, chain: GroundingCoordinateChain)? {
        guard bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 0, bounds.height > 0,
              bounds.insetBy(dx: -1, dy: -1).contains(c)
        else { return nil }
        let fx = min(max((c.x - bounds.minX) / bounds.width, 0), 1)
        let fy = min(max((c.y - bounds.minY) / bounds.height, 0), 1)
        let backing = CoordinateTransform.BackingPixelPoint(
            x: fx * transform.screen.backingPixelSize.width,
            y: fy * transform.screen.backingPixelSize.height
        )
        guard let logical = transform.logicalPoint(fromBackingPixel: backing, bounds: .clamp),
              let displayLocal = transform.displayLocalPoint(fromLogical: logical, bounds: .clamp) else {
            return nil
        }
        let crop = transform.cropPixel(fromBackingPixel: backing, bounds: .clamp)
        let chain = GroundingCoordinateChain(
            transform: transform,
            modelCoordinateSpace: nil,
            modelOutputPoint: nil,
            modelMappedPoint: nil,
            cropPoint: crop?.point,
            backingPoint: backing.point,
            mappedPoint: displayLocal,
            modelOutputCount: 0
        )
        return (displayLocal, chain)
    }

    private struct CaptureDisplayGeometry {
        let cgBounds: CGRect
        let transform: CoordinateTransform
    }

    /// CG-global bounds of the display the screenshot came from. The capture path is
    /// always the cursor's display, so prefer the screen under the mouse; among
    /// screens the dimensions must still match the declared size (so a coordinate is
    /// never mapped against the wrong monitor). nil → caller falls back to visual.
    @MainActor
    private static func captureDisplayBounds(widthPoints: Int, heightPoints: Int) -> CGRect? {
        captureDisplayGeometry(widthPoints: widthPoints, heightPoints: heightPoints)?.cgBounds
    }

    @MainActor
    private static func captureDisplayGeometry(widthPoints: Int, heightPoints: Int) -> CaptureDisplayGeometry? {
        func dims(_ s: NSScreen) -> Bool {
            Int(s.frame.width.rounded()) == widthPoints && Int(s.frame.height.rounded()) == heightPoints
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { dims($0) && NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.screens.first(where: dims)
        guard let screen,
              let mapper = DisplayCoordinateMapper(screen: screen),
              let transform = CoordinateTransform(screen: screen) else { return nil }
        return CaptureDisplayGeometry(cgBounds: mapper.cgBounds, transform: transform)
    }

    private static func verifierCandidates(
        axCandidate: GroundingVerifierCandidate?,
        baseResult: GroundingResult
    ) -> [GroundingVerifierCandidate] {
        var baseCandidates = baseResult.candidates.enumerated().map { index, candidate in
            GroundingVerifierCandidate(
                id: candidate.candidateID ?? "base:\(index)",
                candidate: candidate,
                role: candidate.role,
                label: candidate.label ?? candidate.rawModel,
                nearbyOCRText: candidate.nearbyOCRText ?? candidate.rawModel,
                ocrDistancePoints: candidate.ocrDistancePoints ?? candidate.dispersion,
                agreeingSources: candidate.agreeingSources + Self.agreeingSources(for: candidate, axCandidate: axCandidate)
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
                selectedCandidateID: selectedID ?? verifierResult.selectedCandidateID,
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

    private static func shouldUseBestOfN(
        baseResult: GroundingResult,
        verifierResult: GroundingVerifierResult,
        context: GroundingVerifierContext,
        candidateFailureCounts: [String: Int]
    ) -> Bool {
        if verifierResult.verdict != .accept { return true }
        if verifierResult.confidence < max(context.acceptThreshold + 0.04, 0.78) { return true }
        return baseResult.alternativeCount > 0 && !candidateFailureCounts.isEmpty
    }

    private static func bestOfNCandidateID(
        from candidates: [GroundingVerifierCandidate],
        verifierResult: GroundingVerifierResult,
        context: GroundingVerifierContext,
        candidateFailureCounts: [String: Int]
    ) -> String? {
        let candidatesByID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        let ranked = verifierResult.scores
            .compactMap { score -> (id: String, score: Double)? in
                guard score.failureKind == nil,
                      let candidate = candidatesByID[score.id],
                      candidate.candidate.point != nil || candidate.candidate.region != nil else {
                    return nil
                }
                let sourceBonus = Double(sourceRank(candidate.candidate.source)) * 0.03
                let agreementBonus = min(0.12, Double(candidate.agreeingSources.count) * 0.04)
                let confidenceBonus = min(0.12, max(0, candidate.candidate.confidence) * 0.12)
                let failurePenalty = min(0.45, Double(candidateFailureCounts[score.id, default: 0]) * 0.18)
                let centerPenalty: Double
                if let point = candidate.candidate.point {
                    let center = CGPoint(
                        x: CGFloat(context.displayWidthPoints) / 2,
                        y: CGFloat(context.displayHeightPoints) / 2
                    )
                    let normalizedDistance = Double(hypot(point.x - center.x, point.y - center.y))
                        / max(1, hypot(Double(context.displayWidthPoints), Double(context.displayHeightPoints)))
                    centerPenalty = min(0.08, normalizedDistance * 0.05)
                } else {
                    centerPenalty = 0
                }
                return (score.id, score.score + sourceBonus + agreementBonus + confidenceBonus - failurePenalty - centerPenalty)
            }
            .prefix(3)
            .sorted {
                if $0.score == $1.score { return $0.id < $1.id }
                return $0.score > $1.score
            }
        return ranked.first?.id
    }

    private static func bestOfNAcceptedResult(
        selectedID: String,
        verifierResult: GroundingVerifierResult
    ) -> GroundingVerifierResult {
        let confidence = verifierResult.scores.first { $0.id == selectedID }?.score ?? verifierResult.confidence
        return GroundingVerifierResult(
            verdict: .accept,
            selectedCandidateID: selectedID,
            confidence: confidence,
            failureKind: nil,
            scores: verifierResult.scores
        )
    }

    private static func sourceRank(_ source: GroundingSource) -> Int {
        switch source {
        case .accessibility:
            return 5
        case .dom:
            return 4
        case .ocr:
            return 3
        case .uiTars, .claude, .visualModel:
            return 2
        case .cache:
            return 1
        case .compatibility, .unknown:
            return 0
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
