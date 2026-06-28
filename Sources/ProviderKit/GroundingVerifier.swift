import CoreGraphics
import Foundation

public enum GroundingVerifierVerdict: String, Equatable, Sendable {
    case accept
    case reject
    case abstain
}

public enum GroundingVerifierFailureKind: String, Equatable, Sendable {
    case noCandidates
    case missingPoint
    case offscreen
    case passiveRole
    case canvasSkipped
    case lowEvidence
    case ambiguous
}

public struct GroundingVerifierContext: Equatable, Sendable {
    public let targetText: String
    public let displayWidthPoints: Int
    public let displayHeightPoints: Int
    public let allowCanvasCandidates: Bool
    public let acceptThreshold: Double
    public let ambiguityMargin: Double

    public init(
        targetText: String,
        displayWidthPoints: Int,
        displayHeightPoints: Int,
        allowCanvasCandidates: Bool = false,
        acceptThreshold: Double = 0.72,
        ambiguityMargin: Double = 0.08
    ) {
        self.targetText = targetText
        self.displayWidthPoints = displayWidthPoints
        self.displayHeightPoints = displayHeightPoints
        self.allowCanvasCandidates = allowCanvasCandidates
        self.acceptThreshold = acceptThreshold
        self.ambiguityMargin = ambiguityMargin
    }
}

public struct GroundingVerifierCandidate: Equatable, Sendable {
    public let id: String
    public let candidate: GroundingCandidate
    public let role: String?
    public let label: String?
    public let nearbyOCRText: String?
    public let ocrDistancePoints: Double?
    public let agreeingSources: [GroundingSource]

    public init(
        id: String,
        candidate: GroundingCandidate,
        role: String? = nil,
        label: String? = nil,
        nearbyOCRText: String? = nil,
        ocrDistancePoints: Double? = nil,
        agreeingSources: [GroundingSource] = []
    ) {
        self.id = id
        self.candidate = candidate
        self.role = role
        self.label = label
        self.nearbyOCRText = nearbyOCRText
        self.ocrDistancePoints = ocrDistancePoints
        self.agreeingSources = agreeingSources
    }
}

public struct GroundingVerifierScore: Equatable, Sendable {
    public let id: String
    public let score: Double
    public let labelSimilarity: Double
    public let ocrProximity: Double
    public let sourceAgreement: Double
    public let failureKind: GroundingVerifierFailureKind?

    public init(
        id: String,
        score: Double,
        labelSimilarity: Double,
        ocrProximity: Double,
        sourceAgreement: Double,
        failureKind: GroundingVerifierFailureKind?
    ) {
        self.id = id
        self.score = score
        self.labelSimilarity = labelSimilarity
        self.ocrProximity = ocrProximity
        self.sourceAgreement = sourceAgreement
        self.failureKind = failureKind
    }
}

public struct GroundingVerifierResult: Equatable, Sendable {
    public let verdict: GroundingVerifierVerdict
    public let selectedCandidateID: String?
    public let confidence: Double
    public let failureKind: GroundingVerifierFailureKind?
    public let scores: [GroundingVerifierScore]

    public init(
        verdict: GroundingVerifierVerdict,
        selectedCandidateID: String?,
        confidence: Double,
        failureKind: GroundingVerifierFailureKind?,
        scores: [GroundingVerifierScore]
    ) {
        self.verdict = verdict
        self.selectedCandidateID = selectedCandidateID
        self.confidence = confidence
        self.failureKind = failureKind
        self.scores = scores
    }
}

public struct GroundingVerifier: Sendable {
    public init() {}

    public func verify(
        _ candidates: [GroundingVerifierCandidate],
        context: GroundingVerifierContext
    ) -> GroundingVerifierResult {
        guard !candidates.isEmpty else {
            return GroundingVerifierResult(
                verdict: .reject,
                selectedCandidateID: nil,
                confidence: 1,
                failureKind: .noCandidates,
                scores: []
            )
        }

        let scores = candidates
            .map { score($0, context: context) }
            .sorted {
                if $0.score == $1.score { return $0.id < $1.id }
                return $0.score > $1.score
            }
        let viable = scores.filter { $0.failureKind == nil }

        guard let best = viable.first else {
            let failure = scores
                .compactMap(\.failureKind)
                .sorted(by: Self.failurePriority)
                .first ?? .lowEvidence
            return GroundingVerifierResult(
                verdict: .reject,
                selectedCandidateID: nil,
                confidence: 1,
                failureKind: failure,
                scores: scores
            )
        }

        guard best.score >= context.acceptThreshold else {
            let verdict: GroundingVerifierVerdict = best.score < 0.45 ? .reject : .abstain
            return GroundingVerifierResult(
                verdict: verdict,
                selectedCandidateID: verdict == .reject ? nil : best.id,
                confidence: clamp(best.score),
                failureKind: .lowEvidence,
                scores: scores
            )
        }

        if let second = viable.dropFirst().first,
           best.score - second.score < context.ambiguityMargin {
            return GroundingVerifierResult(
                verdict: .abstain,
                selectedCandidateID: best.id,
                confidence: clamp(best.score),
                failureKind: .ambiguous,
                scores: scores
            )
        }

        return GroundingVerifierResult(
            verdict: .accept,
            selectedCandidateID: best.id,
            confidence: clamp(best.score),
            failureKind: nil,
            scores: scores
        )
    }

    private func score(
        _ candidate: GroundingVerifierCandidate,
        context: GroundingVerifierContext
    ) -> GroundingVerifierScore {
        if candidate.candidate.point == nil, candidate.candidate.region == nil {
            return rejected(candidate, kind: .missingPoint)
        }
        guard isOnDisplay(candidate.candidate, context: context) else {
            return rejected(candidate, kind: .offscreen)
        }

        let role = Self.normalizedRole(candidate.role)
        if Self.canvasRoles.contains(role), !context.allowCanvasCandidates {
            return rejected(candidate, kind: .canvasSkipped)
        }
        if Self.passiveRoles.contains(role) {
            return rejected(candidate, kind: .passiveRole)
        }

        // A dedicated visual grounder (UI-TARS et al.) returns a bare, confident
        // POINT with no AX role, label, or OCR text to score against — which is the
        // case it exists for (canvas/custom controls AX can't see). The
        // evidence-weighted score below structurally caps such a candidate at ~0.42,
        // far under the 0.72 accept bar, so an evidence-only verifier rejects EVERY
        // visual ground (audit: 0 accepts / 24 rejects, all constant 0.42). The
        // structural vetoes above already dropped offscreen / passive / canvas /
        // missing-point hits, so a metadata-less survivor from a visual source is a
        // clean hit: trust the grounder's own confidence rather than penalizing it
        // for evidence it can never carry.
        let hasTextEvidence = !Self.normalizedText(candidate.label).isEmpty
            || !Self.normalizedText(candidate.nearbyOCRText).isEmpty
        if role.isEmpty, !hasTextEvidence, Self.visualSources.contains(candidate.candidate.source) {
            return GroundingVerifierScore(
                id: candidate.id,
                score: clamp(0.55 + (0.35 * clamp(candidate.candidate.confidence))),
                labelSimilarity: 0,
                ocrProximity: 0,
                sourceAgreement: Self.sourceAgreement(candidate),
                failureKind: nil
            )
        }

        let roleScore = Self.actionableRoles.contains(role) ? 1.0 : (role.isEmpty ? 0.35 : 0.15)
        let labelSimilarity = Self.textSimilarity(context.targetText, candidate.label)
        let ocrProximity = Self.ocrProximity(
            target: context.targetText,
            text: candidate.nearbyOCRText,
            distance: candidate.ocrDistancePoints,
            source: candidate.candidate.source
        )
        let sourceAgreement = Self.sourceAgreement(candidate)

        let score = clamp(
            (0.20 * clamp(candidate.candidate.confidence)) +
            (0.20 * roleScore) +
            0.15 +
            (0.25 * labelSimilarity) +
            (0.12 * ocrProximity) +
            (0.08 * sourceAgreement)
        )

        return GroundingVerifierScore(
            id: candidate.id,
            score: score,
            labelSimilarity: labelSimilarity,
            ocrProximity: ocrProximity,
            sourceAgreement: sourceAgreement,
            failureKind: nil
        )
    }

    private func rejected(
        _ candidate: GroundingVerifierCandidate,
        kind: GroundingVerifierFailureKind
    ) -> GroundingVerifierScore {
        GroundingVerifierScore(
            id: candidate.id,
            score: 0,
            labelSimilarity: 0,
            ocrProximity: 0,
            sourceAgreement: 0,
            failureKind: kind
        )
    }

    private func isOnDisplay(_ candidate: GroundingCandidate, context: GroundingVerifierContext) -> Bool {
        let bounds = coordinateBounds(for: candidate.coordinateSpace, context: context)
        guard bounds.width > 0, bounds.height > 0 else { return false }

        if let point = candidate.point {
            return bounds.contains(point)
        }

        if let region = candidate.region,
           !region.isNull,
           !region.isEmpty,
           region.intersects(bounds) {
            return true
        }

        return false
    }

    private func coordinateBounds(
        for space: GroundingCoordinateSpace,
        context: GroundingVerifierContext
    ) -> CGRect {
        switch space {
        case .normalizedThousandths:
            return CGRect(x: 0, y: 0, width: 1000, height: 1000)
        case .displayLocalAppKitPoints, .screenshotPixelsTopLeft, .viewportCSSPixelsTopLeft, .unknown:
            return CGRect(
                x: 0,
                y: 0,
                width: max(0, context.displayWidthPoints),
                height: max(0, context.displayHeightPoints)
            )
        }
    }

    private static func failurePriority(
        _ lhs: GroundingVerifierFailureKind,
        _ rhs: GroundingVerifierFailureKind
    ) -> Bool {
        priority(lhs) < priority(rhs)
    }

    private static func priority(_ kind: GroundingVerifierFailureKind) -> Int {
        switch kind {
        case .offscreen: return 0
        case .passiveRole: return 1
        case .canvasSkipped: return 2
        case .missingPoint: return 3
        case .ambiguous: return 4
        case .lowEvidence: return 5
        case .noCandidates: return 6
        }
    }

    private static let actionableRoles: Set<String> = [
        "button", "axbutton",
        "link", "axlink",
        "menuitem", "axmenuitem", "menubaritem", "axmenubaritem",
        "checkbox", "axcheckbox",
        "radiobutton", "axradiobutton",
        "tab", "axtab",
        "row", "axrow", "outlinerow", "axoutlinerow",
        "cell", "axcell",
        "textfield", "axtextfield",
        "textarea", "textbox", "axtextarea",
        "combobox", "axcombobox",
        "popupbutton", "axpopupbutton",
        "slider", "axslider",
        "incrementor", "axincrementor"
    ]

    private static let passiveRoles: Set<String> = [
        "statictext", "axstatictext",
        "image", "aximage",
        "group", "axgroup",
        "layoutarea", "axlayoutarea",
        "separator", "axseparator"
    ]

    private static let canvasRoles: Set<String> = [
        "canvas", "axcanvas",
        "webarea", "axwebarea"
    ]

    /// Grounders whose candidates are pixel-derived points: a metadata-less hit from
    /// one of these is a confident visual ground, not a weak AX/DOM/OCR candidate.
    private static let visualSources: Set<GroundingSource> = [
        .uiTars, .visualModel, .claude, .compatibility, .cache
    ]

    private static func normalizedText(_ text: String?) -> String {
        (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedRole(_ role: String?) -> String {
        role?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber } ?? ""
    }

    private static func textSimilarity(_ lhs: String, _ rhs: String?) -> Double {
        let left = tokens(lhs)
        let right = tokens(rhs ?? "")
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        if left == right { return 1 }
        if Set(left).isSubset(of: Set(right)) || Set(right).isSubset(of: Set(left)) {
            return 0.9
        }

        let leftSet = Set(left)
        let rightSet = Set(right)
        let intersection = leftSet.intersection(rightSet).count
        let union = leftSet.union(rightSet).count
        guard union > 0 else { return 0 }
        return Double(intersection) / Double(union)
    }

    private static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !fillerWords.contains($0) }
    }

    private static let fillerWords: Set<String> = [
        "the", "a", "an", "button", "field", "box", "icon", "link",
        "menu", "item", "placeholder", "input", "tab", "control"
    ]

    private static func ocrProximity(
        target: String,
        text: String?,
        distance: Double?,
        source: GroundingSource
    ) -> Double {
        if let text {
            let similarity = textSimilarity(target, text)
            guard similarity > 0 else { return 0 }
            let distanceScore = distance.map { clamp(1 - ($0 / 80)) } ?? 0.5
            return similarity * (0.35 + (0.65 * distanceScore))
        }

        return source == .ocr ? 0.55 : 0
    }

    private static func sourceAgreement(_ candidate: GroundingVerifierCandidate) -> Double {
        let uniqueSources = Set(([candidate.candidate.source] + candidate.agreeingSources).map(\.rawValue))
        switch uniqueSources.count {
        case 0, 1:
            return 0
        case 2:
            return 0.75
        default:
            return 1
        }
    }
}

private func clamp(_ value: Double) -> Double {
    min(1, max(0, value))
}
