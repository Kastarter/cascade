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
    private let groundingCache: GroundingCache?
    private let cacheMode: GroundingCacheMode
    private let cacheContextProvider: @Sendable () async -> AppWindowSnapshot

    /// AX roles a CLICK target may legitimately resolve to. Excludes the passive
    /// roles `AXElementResolver.find` will also match (AXStaticText, AXImage) — a
    /// label of static text is almost never the thing to click, and trusting it
    /// would let "the title" grab a chrome label instead of the canvas placeholder.
    /// Cascade's own bundle id — its UI must never be an AX grounding target.
    static let cascadeBundleID = "com.humain.cascade"

    static let clickableRoles: Set<String> = [
        "AXButton", "AXMenuItem", "AXMenuBarItem", "AXLink", "AXTextField",
        "AXTextArea", "AXSearchField", "AXComboBox", "AXPopUpButton", "AXCheckBox",
        "AXRadioButton", "AXTab", "AXDisclosureTriangle", "AXRow", "AXCell", "AXSlider",
    ]

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
        self.onVerifierOutcome = onVerifierOutcome
    }

    public func ground(
        screenshot: Data, target: String, displayWidthPoints: Int, displayHeightPoints: Int
    ) async -> CGPoint? {
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
        guard verifyCandidates else {
            guard groundingCache != nil else {
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
            let result = await baseGroundingResult(
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
            let baseResult = await base.groundResult(
                screenshot: screenshot,
                target: target,
                displayWidthPoints: displayWidthPoints,
                displayHeightPoints: displayHeightPoints
            )
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
                    dispersion: candidate.dispersion
                )
            },
            selectedIndex: result.selectedIndex
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
                    dispersion: candidate.dispersion
                )
            },
            selectedIndex: result.selectedIndex
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

    /// Region grounding (the "where is X" highlight) stays the base grounder's job —
    /// a marquee frames an area, which the visual grounder produces and AX point
    /// matching does not improve.
    public func groundRegion(
        screenshot: Data, target: String, displayWidthPoints: Int, displayHeightPoints: Int
    ) async -> ElementRegion? {
        // On-screen TEXT (a document heading/section, a labeled link) is exactly what
        // the visual grounder misses — it's trained on UI CONTROLS, so "the student
        // evaluation section" in a PDF resolved to a toolbar button (the audited
        // ■ square next to Download). Match the literal text by OCR FIRST; fall back to
        // the visual grounder for icons / canvas / non-text targets.
        if let region = await Self.ocrTextRegion(
            screenshot: screenshot, target: target,
            displayWidthPoints: displayWidthPoints, displayHeightPoints: displayHeightPoints
        ) {
            return region
        }
        return await base.groundRegion(
            screenshot: screenshot, target: target,
            displayWidthPoints: displayWidthPoints, displayHeightPoints: displayHeightPoints
        )
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
        if let skill = skills.skill(appName: front?.localizedName, bundleIdentifier: front?.bundleIdentifier),
           skill.axUnreliable {
            return nil
        }
        guard let match = AXElementResolver.find(label: target),
              match.score >= minAXScore,
              Self.clickableRoles.contains(match.role) else { return nil }
        // Map the matched element center (CG-global, top-left) into the display-local
        // AppKit point the executor consumes. Use the display the screenshot came
        // from — the cursor's — selected by matching the declared dimensions.
        guard let bounds = Self.captureDisplayBounds(widthPoints: displayWidthPoints, heightPoints: displayHeightPoints) else {
            return nil
        }
        guard let point = Self.displayLocalPoint(
            cgGlobalCenter: match.center, displayCGBounds: bounds, displayHeightPoints: displayHeightPoints
        ) else { return nil }

        return GroundingVerifierCandidate(
            id: "ax:0",
            candidate: GroundingCandidate(
                point: point,
                confidence: min(1, max(0, match.score / 3)),
                source: .accessibility,
                coordinateSpace: .displayLocalAppKitPoints
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
        guard bounds.width > 0, bounds.height > 0,
              c.x >= bounds.minX - 1, c.x <= bounds.maxX + 1,
              c.y >= bounds.minY - 1, c.y <= bounds.maxY + 1 else { return nil }
        let localX = c.x - bounds.minX
        let localYFromTop = c.y - bounds.minY
        let localYFromBottom = CGFloat(displayHeightPoints) - localYFromTop
        return CGPoint(x: localX, y: localYFromBottom)
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
        guard let screen else { return nil }
        let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        return CGDisplayBounds(id ?? CGMainDisplayID())
    }

    private static func verifierCandidates(
        axCandidate: GroundingVerifierCandidate?,
        baseResult: GroundingResult
    ) -> [GroundingVerifierCandidate] {
        var baseCandidates = baseResult.candidates.enumerated().map { index, candidate in
            GroundingVerifierCandidate(
                id: "base:\(index)",
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
            result: GroundingResult(candidates: candidates.map(\.candidate), selectedIndex: selectedIndex),
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
}

private extension Duration {
    var mixtureTimeInterval: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
