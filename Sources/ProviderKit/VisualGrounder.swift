import AppKit
import Foundation

/// Provenance for a grounded target candidate. Kept small and Codable so later
/// routing/verifier code can compare AX/DOM/OCR/cache/model hits without parsing
/// ad hoc strings.
public enum GroundingSource: String, Codable, Equatable, Sendable {
    case accessibility
    case dom
    case ocr
    case uiTars
    case claude
    case cache
    case visualModel
    case compatibility
    case unknown
}

/// Coordinate convention used by a grounding candidate's point/region.
public enum GroundingCoordinateSpace: String, Codable, Equatable, Sendable {
    /// Display-local AppKit points, bottom-left origin; this is the executor's click space.
    case displayLocalAppKitPoints
    /// Pixel coordinates in the screenshot/model image, top-left origin.
    case screenshotPixelsTopLeft
    /// 0...1000 model-normalized coordinates, top-left origin.
    case normalizedThousandths
    /// Web viewport CSS pixels, top-left origin.
    case viewportCSSPixelsTopLeft
    case unknown
}

/// A candidate shown to a model with a visible Set-of-Mark label. ProviderKit keeps
/// this shape independent of ComputerUseKit so prompt/parse code can use it without
/// depending on AX/OCR inventory construction.
public struct MarkedGroundingCandidate: Codable, Equatable, Sendable {
    public let id: String
    public let markNumber: Int
    public let label: String
    public let role: String
    public let source: GroundingSource
    public let confidence: Double
    public let isSafeToClick: Bool
    public let displayBounds: CGRect
    public let imageBounds: CGRect?

    public init(
        id: String,
        markNumber: Int,
        label: String,
        role: String,
        source: GroundingSource,
        confidence: Double,
        isSafeToClick: Bool,
        displayBounds: CGRect,
        imageBounds: CGRect? = nil
    ) {
        self.id = id
        self.markNumber = markNumber
        self.label = label
        self.role = role
        self.source = source
        self.confidence = confidence
        self.isSafeToClick = isSafeToClick
        self.displayBounds = displayBounds
        self.imageBounds = imageBounds
    }

    public var center: CGPoint {
        CGPoint(x: displayBounds.midX, y: displayBounds.midY)
    }
}

/// One possible grounding answer for a named UI target.
public struct GroundingCandidate: Codable, Equatable, Sendable {
    public let point: CGPoint?
    public let region: CGRect?
    public let confidence: Double
    public let source: GroundingSource
    public let coordinateSpace: GroundingCoordinateSpace
    public let rawModel: String?
    public let latency: TimeInterval?
    public let dispersion: Double?
    public let reason: String?
    public let candidateID: String?
    public let markNumber: Int?
    public let displayBounds: CGRect?
    public let imageBounds: CGRect?

    public init(
        point: CGPoint?,
        region: CGRect? = nil,
        confidence: Double,
        source: GroundingSource,
        coordinateSpace: GroundingCoordinateSpace,
        rawModel: String? = nil,
        latency: TimeInterval? = nil,
        dispersion: Double? = nil,
        reason: String? = nil,
        candidateID: String? = nil,
        markNumber: Int? = nil,
        displayBounds: CGRect? = nil,
        imageBounds: CGRect? = nil
    ) {
        self.point = point
        self.region = region
        self.confidence = confidence
        self.source = source
        self.coordinateSpace = coordinateSpace
        self.rawModel = rawModel
        self.latency = latency
        self.dispersion = dispersion
        self.reason = reason
        self.candidateID = candidateID
        self.markNumber = markNumber
        self.displayBounds = displayBounds
        self.imageBounds = imageBounds
    }
}

/// Structured grounding output. The legacy point API reads `legacyPoint`, while
/// newer routing/verifier code can inspect every candidate and why it was chosen.
public struct GroundingResult: Codable, Equatable, Sendable {
    public let candidates: [GroundingCandidate]
    public let selectedIndex: Int?
    public let selectedCandidateID: String?
    public let verifierVerdict: GroundingVerifierVerdict?
    public let verifierFailureKind: GroundingVerifierFailureKind?
    public let alternativeCount: Int

    public init(
        candidates: [GroundingCandidate] = [],
        selectedIndex: Int? = nil,
        selectedCandidateID: String? = nil,
        verifierVerdict: GroundingVerifierVerdict? = nil,
        verifierFailureKind: GroundingVerifierFailureKind? = nil,
        alternativeCount: Int? = nil
    ) {
        self.candidates = candidates
        self.selectedIndex = selectedIndex
        self.selectedCandidateID = selectedCandidateID
            ?? selectedIndex.flatMap { candidates.indices.contains($0) ? candidates[$0].candidateID : nil }
        self.verifierVerdict = verifierVerdict
        self.verifierFailureKind = verifierFailureKind
        self.alternativeCount = alternativeCount ?? max(0, candidates.count - (selectedIndex == nil ? 0 : 1))
    }

    public var selectedCandidate: GroundingCandidate? {
        guard let selectedIndex, candidates.indices.contains(selectedIndex) else { return nil }
        return candidates[selectedIndex]
    }

    public var selectedPoint: CGPoint? {
        selectedCandidate?.point
    }

    public var legacyPoint: CGPoint? {
        selectedPoint
    }

    public var isAbstainedOrRejected: Bool {
        verifierVerdict == .abstain || verifierVerdict == .reject
    }

    public func isActionable(minConfidence: Double = 0.30) -> Bool {
        guard let candidate = selectedCandidate, candidate.point != nil else { return false }
        guard !isAbstainedOrRejected else { return false }
        return candidate.confidence >= minConfidence
    }

    public var abstainReason: String? {
        if let verifierFailureKind, verifierVerdict == .abstain || verifierVerdict == .reject {
            return verifierFailureKind.rawValue
        }
        return selectedCandidate?.reason
    }

    public static func legacy(
        point: CGPoint?,
        source: GroundingSource = .compatibility,
        coordinateSpace: GroundingCoordinateSpace = .displayLocalAppKitPoints,
        latency: TimeInterval? = nil
    ) -> GroundingResult {
        return GroundingResult(
            candidates: [
                GroundingCandidate(
                    point: point,
                    confidence: point == nil ? 0 : 1,
                    source: source,
                    coordinateSpace: coordinateSpace,
                    latency: latency
                )
            ],
            selectedIndex: 0
        )
    }

    private enum CodingKeys: String, CodingKey {
        case candidates
        case selectedIndex
        case selectedCandidateID
        case verifierVerdict
        case verifierFailureKind
        case alternativeCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let candidates = try container.decodeIfPresent([GroundingCandidate].self, forKey: .candidates) ?? []
        let selectedIndex = try container.decodeIfPresent(Int.self, forKey: .selectedIndex)
        self.init(
            candidates: candidates,
            selectedIndex: selectedIndex,
            selectedCandidateID: try container.decodeIfPresent(String.self, forKey: .selectedCandidateID),
            verifierVerdict: try container.decodeIfPresent(GroundingVerifierVerdict.self, forKey: .verifierVerdict),
            verifierFailureKind: try container.decodeIfPresent(GroundingVerifierFailureKind.self, forKey: .verifierFailureKind),
            alternativeCount: try container.decodeIfPresent(Int.self, forKey: .alternativeCount)
        )
    }
}

// MARK: - Grounding split (Phase 1 of the model-downgrade roadmap)
//
// The field consensus — and Cascade's own audited finding — is that *grounding*
// (knowing WHERE to click), not reasoning, is the GUI-agent bottleneck, and the
// way to make the on-screen agent good enough to downgrade the thinker later is to
// move grounding OUT of the model into a dedicated grounder. SOTA open-source
// stacks (Agent-S, trycua/cua) pair a strong planner with a small vision grounder;
// the grounder everyone reaches for is ByteDance's UI-TARS-1.5-7B, which grounds
// from PIXELS ALONE — exactly the case that defeats AX on iWork/Blender canvases
// (audit run 53666: AX exposes only chrome, no slide elements).
//
// This file is the grounder ENGINE only. It is wired STRUCTURALLY (the runtime
// names a target and the runtime acts on the returned point) — never as an
// advisory tool the model must choose to call. That distinction is load-bearing:
// every advisory grounding scaffold tried so far (pushed coords, the Tab recipe,
// the reverted `find_element` tool) was ignored by the model. See
// [[cascade-cu-downgrade-research]].

/// A grounder turns "where is X on this screen" into a clickable point WITHOUT a
/// cloud reasoning round trip in the hot path. Conformers: `UITARSGrounder` (local
/// MLX/vLLM, the cost+latency win) and `ClaudeVisualGrounder` (the proven engine,
/// kept as a fallback and for parity testing).
public protocol VisualGrounder: Sendable {
    /// Returns the target's location in **display-local AppKit points** (bottom-left
    /// origin) — the same coordinate space the executor's click path consumes — or
    /// `nil` when the grounder is unreachable or finds nothing confident.
    func ground(
        screenshot: Data,
        target: String,
        displayWidthPoints: Int,
        displayHeightPoints: Int
    ) async -> CGPoint?

    /// Structured grounding output for verifier/routing code. Existing point-only
    /// grounders inherit the compatibility wrapper in the protocol extension.
    func groundResult(
        screenshot: Data,
        target: String,
        displayWidthPoints: Int,
        displayHeightPoints: Int
    ) async -> GroundingResult

    /// Locates a target as a REGION to frame (the "where is X" marching-ants
    /// highlight) — display-local AppKit rect + a short spoken line. Returns nil
    /// when this grounder can't produce one (unreachable, or not implemented), so
    /// the caller falls back to the proven Claude region locator.
    func groundRegion(
        screenshot: Data,
        target: String,
        displayWidthPoints: Int,
        displayHeightPoints: Int
    ) async -> ElementRegion?

    /// Optional Set-of-Mark path. Conformers that can ask the model to choose a mark
    /// return a selected candidate directly; others inherit the empty fallback.
    func groundMarkedCandidate(
        screenshot: Data,
        target: String,
        displayWidthPoints: Int,
        displayHeightPoints: Int,
        candidates: [MarkedGroundingCandidate]
    ) async -> GroundingResult
}

public extension VisualGrounder {
    func groundResult(
        screenshot: Data, target: String, displayWidthPoints: Int, displayHeightPoints: Int
    ) async -> GroundingResult {
        let start = ContinuousClock.now
        let point = await ground(
            screenshot: screenshot,
            target: target,
            displayWidthPoints: displayWidthPoints,
            displayHeightPoints: displayHeightPoints
        )
        let elapsed = start.duration(to: ContinuousClock.now)
        return GroundingResult.legacy(point: point, latency: elapsed.timeInterval)
    }

    /// Default: no region grounding (the caller falls back to ElementLocator). The
    /// Claude grounder uses this default on purpose — the fallback IS its engine,
    /// at full quality (tight box + spoken line + conversation context).
    func groundRegion(
        screenshot: Data, target: String, displayWidthPoints: Int, displayHeightPoints: Int
    ) async -> ElementRegion? { nil }

    func groundMarkedCandidate(
        screenshot: Data,
        target: String,
        displayWidthPoints: Int,
        displayHeightPoints: Int,
        candidates: [MarkedGroundingCandidate]
    ) async -> GroundingResult { GroundingResult() }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}

// MARK: - Claude-backed grounder (the proven engine, as a fallback)

/// Wraps the existing `ElementLocator` (Claude Computer Use vision) behind the
/// `VisualGrounder` protocol. This is the engine Cascade already proved sound; it
/// costs a cloud round trip, so it is the fallback, not the hot path.
public struct ClaudeVisualGrounder: VisualGrounder {
    private let locator: ElementLocator

    public init(locator: ElementLocator = ElementLocator()) {
        self.locator = locator
    }

    public func ground(
        screenshot: Data,
        target: String,
        displayWidthPoints: Int,
        displayHeightPoints: Int
    ) async -> CGPoint? {
        await locator.guide(
            screenshot: screenshot,
            question: "click \(target)",
            displayWidthPoints: displayWidthPoints,
            displayHeightPoints: displayHeightPoints
        ).point
    }

    public func groundMarkedCandidate(
        screenshot: Data,
        target: String,
        displayWidthPoints: Int,
        displayHeightPoints: Int,
        candidates: [MarkedGroundingCandidate]
    ) async -> GroundingResult {
        await locator.guide(
            screenshot: screenshot,
            question: "click \(target)",
            displayWidthPoints: displayWidthPoints,
            displayHeightPoints: displayHeightPoints,
            markedCandidates: candidates
        ).result
    }
}

/// Hosted GUI-grounder model ids for `cascade.visualGrounder.model` (swap the
/// grounder WITHOUT a rebuild). UI-TARS is the proven default, served on OpenRouter.
/// UI-Venus-1.5 / Holo1.5 are the newer SOTA open grounders (Apache-2.0, ~10–19pp
/// better on ScreenSpot-Pro; see docs/AGENT_FAILURE_RATE_RESEARCH.md) — but as of
/// 2026-06 they are NOT on OpenRouter, so reaching them needs
/// `cascade.visualGrounder.endpoint` pointed at a host that serves them (or
/// UI-Venus-1.5-2B run locally via MLX). They are Qwen3-VL based, so they most
/// likely need `cascade.visualGrounder.coordSpace = "sent"` rather than UI-TARS's
/// smart-resized space — confirm with a live probe (a wrong space misses every click).
public enum GUIGrounderModel {
    public static let uiTars15_7b = "bytedance/ui-tars-1.5-7b"
    public static let uiVenus15_8b = "inclusionAI/UI-Venus-1.5-8B"
    public static let uiVenus15_30bA3b = "inclusionAI/UI-Venus-1.5-30B-A3B"
    public static let holo15_7b = "Hcompany/Holo1.5-7B"
}

// MARK: - UI-TARS local grounder (the cost + latency win)

/// Grounds against a locally-served **UI-TARS-1.5-7B** (Apache-2.0, Qwen2.5-VL
/// based) over an OpenAI-compatible `/v1/chat/completions` endpoint — vLLM,
/// SGLang, LM Studio, or `mlx-community/UI-TARS-1.5-7B-4bit` via mlx-vlm. No cloud
/// round trip, no per-token API cost, sub-second on Apple Silicon.
///
/// SETUP (the user runs this on their Mac; the model can't run in CI):
///   `pip install mlx-vlm` then serve `mlx-community/UI-TARS-1.5-7B-4bit`, or run
///   vLLM/LM Studio on `ByteDance-Seed/UI-TARS-1.5-7B`. Point `baseURL` at it.
///
/// RUNTIME-UNVERIFIED against a live model in this environment — the coordinate
/// parser and scaling math are unit-pinned (a wrong number clicks empty space);
/// the live request/response shape needs a dry run once a model is serving.
public struct UITARSGrounder: VisualGrounder {
    /// How the served model encodes the coordinates it returns. A swapped grounder
    /// read in the wrong space misses every click, so this is explicit + unit-pinned.
    public enum CoordSpace: String, Sendable {
        /// UI-TARS / Qwen2.5-VL: absolute pixels in the SMART-RESIZED image space
        /// (the proven default — coords come back in `smartResize(sent)` space).
        case smartResize
        /// Absolute pixels in the exact image we SENT (no smart-resize remap) — the
        /// likely space for Qwen3-VL grounders like UI-Venus-1.5 / Holo1.5.
        case sent
        /// Normalized to 0–1000 (the Qwen-VL convention), scaled by the sent size.
        case normalized
    }

    private let endpoint: URL
    private let model: String
    private let apiKey: String?
    private let coordSpace: CoordSpace
    private let session: URLSession

    /// - Parameters:
    ///   - baseURL: OpenAI-compatible chat-completions endpoint. Defaults to the
    ///     vLLM/SGLang local default; LM Studio is `http://localhost:1234/v1/...`.
    ///   - model: the served model id (deployment-specific).
    ///   - apiKey: Bearer token for hosted endpoints; omit for a local server.
    public init(
        baseURL: URL = URL(string: "http://localhost:8000/v1/chat/completions")!,
        model: String = "ui-tars-1.5-7b",
        apiKey: String? = nil,
        coordSpace: CoordSpace = .smartResize,
        session: URLSession = .shared
    ) {
        self.endpoint = baseURL
        self.model = model
        self.apiKey = apiKey
        self.coordSpace = coordSpace
        self.session = session
    }

    public func ground(
        screenshot: Data,
        target: String,
        displayWidthPoints: Int,
        displayHeightPoints: Int
    ) async -> CGPoint? {
        // Resize to the same Anthropic-recommended resolution the rest of the agent
        // declares, so coords come back in a known image space (frames captured at
        // this size pass through untouched). UI-TARS-1.5-7B emits ABSOLUTE pixel
        // coords in the input image's space.
        let res = AgentResolution.best(forWidth: displayWidthPoints, height: displayHeightPoints)
        guard let jpeg = Self.resizeJPEG(screenshot, toWidth: res.w, toHeight: res.h) else { return nil }
        guard let content = await callModel(jpeg: jpeg, target: target, declaredW: res.w, declaredH: res.h) else {
            return nil
        }
        guard let imagePoint = Self.parseBox(content) else { return nil }
        // Map the model's coordinate into the sent image's pixel space per its coord
        // convention, THEN scale to the display. UI-TARS (Qwen2.5-VL) emits in the
        // SMART-RESIZED space (live-verified: a 1280×800 send yields coords in
        // 1288×812; mapping through it lands to the pixel — bytedance/UI-TARS
        // README_coordinates.md). A swapped Qwen3-VL grounder (UI-Venus-1.5 / Holo1.5)
        // may emit in the sent space or 0–1000 instead — `coordSpace` selects which.
        let space = Self.resolveImageSpace(
            parsed: imagePoint, sentW: res.w, sentH: res.h, space: coordSpace
        )
        return Self.toDisplayPoint(
            imagePoint: space.point,
            imageW: space.imageW, imageH: space.imageH,
            displayW: displayWidthPoints, displayH: displayHeightPoints
        )
    }

    public func groundResult(
        screenshot: Data,
        target: String,
        displayWidthPoints: Int,
        displayHeightPoints: Int
    ) async -> GroundingResult {
        let start = ContinuousClock.now
        let res = AgentResolution.best(forWidth: displayWidthPoints, height: displayHeightPoints)
        guard let jpeg = Self.resizeJPEG(screenshot, toWidth: res.w, toHeight: res.h) else { return GroundingResult() }
        guard let content = await callModel(jpeg: jpeg, target: target, declaredW: res.w, declaredH: res.h) else {
            return GroundingResult()
        }
        guard let imagePoint = Self.parseBox(content) else {
            return GroundingResult(
                candidates: [
                    GroundingCandidate(
                        point: nil,
                        confidence: 0,
                        source: .uiTars,
                        coordinateSpace: .screenshotPixelsTopLeft,
                        rawModel: content,
                        latency: start.duration(to: ContinuousClock.now).timeInterval,
                        reason: "ui-tars parse miss"
                    )
                ],
                selectedIndex: 0,
                verifierVerdict: .abstain,
                verifierFailureKind: .missingPoint
            )
        }
        let space = Self.resolveImageSpace(
            parsed: imagePoint,
            sentW: res.w,
            sentH: res.h,
            space: coordSpace
        )
        let point = Self.toDisplayPoint(
            imagePoint: space.point,
            imageW: space.imageW,
            imageH: space.imageH,
            displayW: displayWidthPoints,
            displayH: displayHeightPoints
        )
        return GroundingResult(
            candidates: [
                GroundingCandidate(
                    point: point,
                    confidence: 0.82,
                    source: .uiTars,
                    coordinateSpace: .displayLocalAppKitPoints,
                    rawModel: content,
                    latency: start.duration(to: ContinuousClock.now).timeInterval,
                    reason: "ui-tars coordinate"
                )
            ],
            selectedIndex: 0
        )
    }

    public func groundMarkedCandidate(
        screenshot: Data,
        target: String,
        displayWidthPoints: Int,
        displayHeightPoints: Int,
        candidates: [MarkedGroundingCandidate]
    ) async -> GroundingResult {
        guard !candidates.isEmpty else { return GroundingResult() }
        let start = ContinuousClock.now
        let res = AgentResolution.best(forWidth: displayWidthPoints, height: displayHeightPoints)
        guard let jpeg = Self.resizeJPEG(screenshot, toWidth: res.w, toHeight: res.h) else { return GroundingResult() }
        guard let content = await callModel(
            jpeg: jpeg,
            target: target,
            declaredW: res.w,
            declaredH: res.h,
            prompt: Self.markPrompt(target: target, candidates: candidates)
        ) else {
            return GroundingResult()
        }
        let marks = Self.parseMarkIDs(content)
        let selectedMarks = marks
            .reduce(into: [Int]()) { acc, mark in
                if !acc.contains(mark) { acc.append(mark) }
            }
            .prefix(3)
        let selectedCandidates = selectedMarks.compactMap { mark in
            candidates.first(where: { $0.markNumber == mark })
        }
        guard let selected = selectedCandidates.first else {
            return GroundingResult(
                candidates: [
                    GroundingCandidate(
                        point: nil,
                        confidence: 0,
                        source: .uiTars,
                        coordinateSpace: .displayLocalAppKitPoints,
                        rawModel: content,
                        latency: start.duration(to: ContinuousClock.now).timeInterval,
                        reason: "ui-tars mark parse miss"
                    )
                ],
                selectedIndex: nil,
                verifierVerdict: .abstain,
                verifierFailureKind: .noCandidates,
                alternativeCount: candidates.count
            )
        }
        let groundingCandidates = selectedCandidates.map { candidate in
            GroundingCandidate(
                point: candidate.center,
                region: candidate.displayBounds,
                confidence: max(0.78, candidate.confidence),
                source: candidate.source,
                coordinateSpace: .displayLocalAppKitPoints,
                rawModel: content,
                latency: start.duration(to: ContinuousClock.now).timeInterval,
                reason: "ranked Set-of-Mark \(candidate.markNumber)",
                candidateID: candidate.id,
                markNumber: candidate.markNumber,
                displayBounds: candidate.displayBounds,
                imageBounds: candidate.imageBounds
            )
        }
        return GroundingResult(
            candidates: groundingCandidates,
            selectedIndex: 0,
            selectedCandidateID: selected.id,
            alternativeCount: max(0, candidates.count - groundingCandidates.count)
        )
    }

    /// Maps a model-emitted coordinate into (pixel point, image size) for the
    /// grounder's coord convention, so `ground` and the tests share one source of
    /// truth. Pure + pinned — the wrong space offsets or wildly misses every click.
    static func resolveImageSpace(
        parsed: CGPoint, sentW: Int, sentH: Int, space: CoordSpace
    ) -> (point: CGPoint, imageW: Int, imageH: Int) {
        switch space {
        case .smartResize:
            let r = smartResize(width: sentW, height: sentH)
            return (parsed, r.w, r.h)
        case .sent:
            return (parsed, sentW, sentH)
        case .normalized:
            let p = CGPoint(x: parsed.x / 1000 * CGFloat(sentW), y: parsed.y / 1000 * CGFloat(sentH))
            return (p, sentW, sentH)
        }
    }

    /// Reproduces Qwen2.5-VL's `smart_resize` (UI-TARS's image processor): each
    /// dimension is rounded to a multiple of `factor`, and the total pixel count is
    /// kept within [minPixels, maxPixels] at a fixed aspect ratio. UI-TARS emits
    /// click coordinates in THIS resized space, so `ground` maps them back through
    /// it. Pure + pinned — a wrong size offsets every click. Defaults match the
    /// official processor (factor 28, min 100·28², max 16384·28²); a live probe
    /// confirmed a 1280×800 send returns coords in the 1288×812 it produces.
    static func smartResize(
        width: Int, height: Int,
        factor: Int = 28, minPixels: Int = 100 * 28 * 28, maxPixels: Int = 16384 * 28 * 28
    ) -> (w: Int, h: Int) {
        let safeFactor = max(1, factor)
        let safeMinPixels = max(1, minPixels)
        let safeMaxPixels = max(1, maxPixels)
        let w = Double(max(1, width)), h = Double(max(1, height)), f = Double(safeFactor)
        func multiple(_ units: Double) -> Int {
            guard units.isFinite else { return safeFactor }
            let maxUnits = Int.max / safeFactor
            if units <= 1 { return safeFactor }
            if units >= Double(maxUnits) { return maxUnits * safeFactor }
            return Int(units) * safeFactor
        }
        func roundTo(_ v: Double) -> Int { multiple((v / f).rounded()) }
        func floorTo(_ v: Double) -> Int { multiple((v / f).rounded(.down)) }
        func ceilTo(_ v: Double) -> Int { multiple((v / f).rounded(.up)) }
        func productExceeds(_ lhs: Int, _ rhs: Int, _ limit: Int) -> Bool {
            guard lhs > 0, rhs > 0 else { return false }
            return lhs > limit / rhs
        }
        func productBelow(_ lhs: Int, _ rhs: Int, _ limit: Int) -> Bool {
            guard lhs > 0, rhs > 0 else { return true }
            return lhs <= (limit - 1) / rhs
        }
        var wb = max(safeFactor, roundTo(w))
        var hb = max(safeFactor, roundTo(h))
        if productExceeds(wb, hb, safeMaxPixels) {
            let beta = (w * h / Double(safeMaxPixels)).squareRoot()
            wb = max(safeFactor, floorTo(w / beta))
            hb = max(safeFactor, floorTo(h / beta))
        } else if productBelow(wb, hb, safeMinPixels) {
            let beta = (Double(safeMinPixels) / (w * h)).squareRoot()
            wb = ceilTo(w * beta)
            hb = ceilTo(h * beta)
        }
        return (wb, hb)
    }

    /// Region grounding for the highlight: locate the target's click point, then
    /// frame a box around it. UI-TARS grounds to a point; a box around it is plenty
    /// for "show me where X is" (the marquee frames the area). Returns nil on any
    /// miss (unreachable OR not found) so the caller falls back to Claude.
    public func groundRegion(
        screenshot: Data, target: String, displayWidthPoints: Int, displayHeightPoints: Int
    ) async -> ElementRegion? {
        guard let point = await ground(
            screenshot: screenshot, target: target,
            displayWidthPoints: displayWidthPoints, displayHeightPoints: displayHeightPoints
        ) else { return nil }
        let rect = Self.boxAround(point: point, displayW: displayWidthPoints, displayH: displayHeightPoints)
        return ElementRegion(rect: rect, speech: "Here — it's in this area.")
    }

    /// A display-local AppKit rect framing a located point — ~12%×8% of the
    /// display, clamped on screen. Pure + pinned (a bad rect frames empty space).
    static func boxAround(point: CGPoint, displayW: Int, displayH: Int) -> CGRect {
        let w = CGFloat(displayW) * 0.12
        let h = CGFloat(displayH) * 0.08
        let x = max(0, min(point.x - w / 2, CGFloat(displayW) - w))
        let y = max(0, min(point.y - h / 2, CGFloat(displayH) - h))
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// The grounding instruction. Kept minimal and tunable — UI-TARS is trained to
    /// emit an action grammar; for pure grounding we ask for the single click point.
    static func prompt(target: String) -> String {
        """
        You are a GUI grounding model. Look at the screenshot and locate the element \
        described by this instruction:
        "\(target)"
        Respond with ONLY a single click action at that element's center, in the \
        format: click(start_box='(x,y)') where x and y are pixel coordinates in the \
        screenshot. Output nothing else.
        """
    }

    static func markPrompt(target: String, candidates: [MarkedGroundingCandidate]) -> String {
        let list = candidates.prefix(80).map {
            "\($0.markNumber): \($0.label) [\($0.role), \($0.source.rawValue)]"
        }.joined(separator: "\n")
        return """
        You are a GUI grounding model. The screenshot has visible numbered labels drawn \
        on candidate UI elements. Locate the element described by:
        "\(target)"
        Choose up to three candidate marks ranked best-first from the list. Respond with \
        ONLY compact JSON like {"marks": [7, 4, 9]}. If none matches, respond {"marks": []}.

        Candidates:
        \(list)
        """
    }

    static func parseMarkID(_ text: String) -> Int? {
        parseMarkIDs(text).first
    }

    static func parseMarkIDs(_ text: String) -> [Int] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = trimmed.firstIndex(of: "{"),
           let end = trimmed.lastIndex(of: "}"),
           let data = String(trimmed[start...end]).data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["marks", "ranked", "candidates"] {
                if let values = json[key] as? [Any] {
                    return values.compactMap(Self.parseMarkValue)
                }
            }
            if let mark = json["mark"].flatMap(Self.parseMarkValue) { return [mark] }
            if let mark = json["id"].flatMap(Self.parseMarkValue) { return [mark] }
            return []
        }
        let pattern = #"(?i)\b(?:mark|id|#)?\s*(\d{1,4})\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = trimmed as NSString
        return regex.matches(in: trimmed, range: NSRange(location: 0, length: ns.length))
            .compactMap { match in
                guard match.numberOfRanges > 1 else { return nil }
                return Int(ns.substring(with: match.range(at: 1)))
            }
    }

    private static func parseMarkValue(_ value: Any) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    private func callModel(jpeg: Data, target: String, declaredW: Int, declaredH: Int, prompt: String? = nil) async -> String? {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        // Short per-attempt cap: grounding normally returns in ~1s, so a connection
        // that hasn't answered in 8s is dead — fail fast and recycle on the next
        // attempt rather than hang the whole turn. Most failures are immediate
        // resets (not timeouts), so this only bounds the rare true-hang case.
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        // Don't reuse a pooled keep-alive connection: Parasail drops idle ones, and
        // reusing a dead socket is the "broken pipe / SSL bad record mac" failure
        // class. A fresh connection per call sidesteps it (the cost is one TLS
        // handshake — negligible next to inference, and worth it for reliability).
        request.setValue("close", forHTTPHeaderField: "Connection")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")
        }
        let dataURL = "data:image/jpeg;base64,\(jpeg.base64EncodedString())"
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 128,
            "temperature": 0,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "text", "text": prompt ?? Self.prompt(target: target)],
                    ["type": "image_url", "image_url": ["url": dataURL]],
                ],
            ]],
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = bodyData
        // Hosted UI-TARS over OpenRouter hits transient TLS/connection failures
        // (broken pipe, "SSL bad record mac", 429/5xx) on a variable fraction of
        // calls — measured 0–20% in live probes. Treating those as "element not
        // found" produced spurious grounding misses that stacked into a stall. So
        // RETRY transient failures; only a clean 2xx (parsed downstream) or a
        // non-retryable 4xx ends it. A wrong nil here = a dead agent. 5 attempts so
        // a bad patch (each call mostly failing) still resolves before the stall
        // guard trips; failures are fast (immediate reset, not the 12s timeout).
        for attempt in 0..<5 {
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { return nil }
                if (200..<300).contains(http.statusCode) { return Self.extractContent(data) }
                // 4xx won't improve on retry (bad request / auth), except the
                // throttle / request-timeout codes which are transient.
                if (400..<500).contains(http.statusCode), http.statusCode != 408, http.statusCode != 429 {
                    return nil
                }
                // 5xx / 408 / 429 → fall through and retry.
            } catch {
                // Transport error (TLS / connection reset / timeout) → retry.
            }
            if attempt < 4 { try? await Task.sleep(for: .milliseconds(300)) }
        }
        return nil
    }

    /// Pulls `choices[0].message.content` out of an OpenAI chat-completions reply.
    /// `content` may be a plain string or (rarely) an array of content parts.
    static func extractContent(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else { return nil }
        if let text = message["content"] as? String { return text }
        if let parts = message["content"] as? [[String: Any]] {
            return parts.compactMap { $0["text"] as? String }.joined(separator: " ")
        }
        return nil
    }

    /// Parses UI-TARS's coordinate output into a point in **image pixel** space.
    /// Handles the documented grammar variants:
    ///   `click(start_box='(197,525)')`
    ///   `click(start_box='<|box_start|>(100,200)<|box_end|>')`
    ///   `(640, 360)` / `[100, 200]`
    ///   a 4-number region `(x1,y1,x2,y2)` → its center
    /// THE part most likely to be wrong, so it is pure and heavily pinned.
    static func parseBox(_ text: String) -> CGPoint? {
        // Box tokens are framing only — strip them so the numbers read cleanly.
        let cleaned = text
            .replacingOccurrences(of: "<|box_start|>", with: "")
            .replacingOccurrences(of: "<|box_end|>", with: "")

        // Prefer a parenthesised/bracketed group of 2 or 4 numbers.
        let grouped = "[\\(\\[]\\s*(-?\\d+(?:\\.\\d+)?)\\s*,\\s*(-?\\d+(?:\\.\\d+)?)(?:\\s*,\\s*(-?\\d+(?:\\.\\d+)?)\\s*,\\s*(-?\\d+(?:\\.\\d+)?))?\\s*[\\)\\]]"
        if let m = firstMatch(grouped, in: cleaned), let x1 = m[1], let y1 = m[2] {
            if let x2 = m[3], let y2 = m[4] {
                return CGPoint(x: (x1 + x2) / 2, y: (y1 + y2) / 2)  // region → center
            }
            return CGPoint(x: x1, y: y1)
        }
        // Fallback: the first bare comma-separated pair anywhere.
        let pair = "(-?\\d+(?:\\.\\d+)?)\\s*,\\s*(-?\\d+(?:\\.\\d+)?)"
        if let m = firstMatch(pair, in: cleaned), let x = m[1], let y = m[2] {
            return CGPoint(x: x, y: y)
        }
        return nil
    }

    /// Runs `pattern` and returns capture groups 1...n as optional CGFloats
    /// (index 0 is the whole match, kept nil for callers to index groups by number).
    private static func firstMatch(_ pattern: String, in text: String) -> [Int: CGFloat]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
            return nil
        }
        var groups: [Int: CGFloat] = [:]
        for i in 1..<match.numberOfRanges {
            guard let range = Range(match.range(at: i), in: text),
                  let value = Double(text[range]) else { continue }
            groups[i] = CGFloat(value)
        }
        return groups.isEmpty ? nil : groups
    }

    /// Image-pixel point (top-left origin) → display-local AppKit point
    /// (bottom-left origin). Mirrors `ElementLocator.guide`'s scaling exactly so a
    /// UI-TARS point and a Claude point feed the identical click path. A wrong
    /// number here clicks empty space, so it is pure and pinned.
    static func toDisplayPoint(
        imagePoint: CGPoint, imageW: Int, imageH: Int, displayW: Int, displayH: Int
    ) -> CGPoint {
        let clampedX = max(0, min(imagePoint.x, CGFloat(imageW)))
        let clampedY = max(0, min(imagePoint.y, CGFloat(imageH)))
        let scaledX = (clampedX / CGFloat(imageW)) * CGFloat(displayW)
        let scaledYFromTop = (clampedY / CGFloat(imageH)) * CGFloat(displayH)
        let scaledYFromBottom = CGFloat(displayH) - scaledYFromTop
        return CGPoint(x: scaledX, y: scaledYFromBottom)
    }

    /// Exact-pixel JPEG resize (bypasses NSImage's Retina 2× backing) so the image
    /// sent matches the declared dimensions. Frames already captured at the target
    /// size pass through without a re-encode.
    static func resizeJPEG(_ imageData: Data, toWidth width: Int, toHeight height: Int) -> Data? {
        if ImageConformance.isJPEG(imageData, width: width, height: height) { return imageData }
        guard let image = NSImage(data: imageData),
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
              ) else { return nil }
        rep.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current = context
        context?.imageInterpolation = .high
        image.draw(
            in: NSRect(x: 0, y: 0, width: width, height: height),
            from: NSRect(origin: .zero, size: image.size),
            operation: .copy, fraction: 1.0
        )
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }
}
