import AppKit
import ApplicationServices
import CascadeMemory
import Foundation
import MacContextKit

public struct AXRuntimeProfile: Equatable, Sendable {
    public let bundleIdentifier: String?
    public let appName: String?
    public let sampledNodeCount: Int
    public let actionableRoleCount: Int
    public let labeledActionableCount: Int
    public let identifierCount: Int
    public let frameFailureCount: Int
    public let timeoutOrErrorCount: Int
    public let canvasSizedElementRatio: Double
    public let manualAccessibilityAttempted: Bool

    public init(
        bundleIdentifier: String?,
        appName: String?,
        sampledNodeCount: Int,
        actionableRoleCount: Int,
        labeledActionableCount: Int,
        identifierCount: Int,
        frameFailureCount: Int,
        timeoutOrErrorCount: Int,
        canvasSizedElementRatio: Double,
        manualAccessibilityAttempted: Bool = false
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.sampledNodeCount = sampledNodeCount
        self.actionableRoleCount = actionableRoleCount
        self.labeledActionableCount = labeledActionableCount
        self.identifierCount = identifierCount
        self.frameFailureCount = frameFailureCount
        self.timeoutOrErrorCount = timeoutOrErrorCount
        self.canvasSizedElementRatio = canvasSizedElementRatio.isFinite ? max(0, min(1, canvasSizedElementRatio)) : 0
        self.manualAccessibilityAttempted = manualAccessibilityAttempted
    }

    public var isSparse: Bool {
        Self.isSparse(
            sampledNodeCount: sampledNodeCount,
            actionableRoleCount: actionableRoleCount,
            labeledActionableCount: labeledActionableCount,
            identifierCount: identifierCount,
            frameFailureCount: frameFailureCount,
            timeoutOrErrorCount: timeoutOrErrorCount,
            canvasSizedElementRatio: canvasSizedElementRatio
        )
    }

    public var shouldRetryManualAccessibility: Bool {
        isSparse && !manualAccessibilityAttempted
    }

    public static func isSparse(
        sampledNodeCount: Int,
        actionableRoleCount: Int,
        labeledActionableCount: Int,
        identifierCount: Int,
        frameFailureCount: Int,
        timeoutOrErrorCount: Int,
        canvasSizedElementRatio: Double
    ) -> Bool {
        if sampledNodeCount < 12 { return true }
        if actionableRoleCount < 3 { return true }
        if labeledActionableCount == 0 { return true }
        if identifierCount == 0 && actionableRoleCount < 6 { return true }
        let denominator = max(sampledNodeCount, 1)
        if Double(frameFailureCount + timeoutOrErrorCount) / Double(denominator) > 0.35 { return true }
        if canvasSizedElementRatio >= 0.45 { return true }
        return false
    }

    public var safeAuditDetail: String {
        [
            "bundleHash=\(AuditIdentity.hash(bundleIdentifier))",
            "appHash=\(AuditIdentity.hash(appName))",
            "nodes=\(sampledNodeCount)",
            "actionable=\(actionableRoleCount)",
            "labeledActionable=\(labeledActionableCount)",
            "identifiers=\(identifierCount)",
            "frameFailures=\(frameFailureCount)",
            "errors=\(timeoutOrErrorCount)",
            "canvasRatio=\(String(format: "%.2f", canvasSizedElementRatio))",
            "manualAccessibility=\(manualAccessibilityAttempted ? "true" : "false")",
            "sparse=\(isSparse ? "true" : "false")",
        ].joined(separator: " ")
    }
}

// Accessibility-tree target resolution for replaying recorded recipes.
// Ported pattern from `milind-soni/tiptour-macos` (`ElementResolver` /
// `AccessibilityTreeResolver` / `WorkflowRunner`, MIT): coordinates are a LAST
// resort — first re-find the element by its recorded label in the live AX tree
// (role-aware, fuzzy title match, nearest-to-recorded-point tiebreak), and after
// acting, verify the UI actually changed via an AX fingerprint instead of
// trusting a fixed sleep. See docs/THIRD_PARTY_NOTICES.md.
public enum AXElementResolver {
    public struct Match: Sendable {
        /// Element center in CGEvent global coordinates (top-left origin).
        public let center: CGPoint
        public let role: String
        public let title: String
        public let score: Double
        public let descriptor: AXTargetDescriptorV2?

        public init(
            center: CGPoint,
            role: String,
            title: String,
            score: Double,
            descriptor: AXTargetDescriptorV2? = nil
        ) {
            self.center = center
            self.role = role
            self.title = title
            self.score = score
            self.descriptor = descriptor
        }
    }

    /// A recorded click target as a ranked tuple of coordinate-free locators
    /// (XCUIAutomation model): the accessibility `identifier` is the most stable
    /// (survives move/rename/localization), `role` disambiguates equal labels, and
    /// the `label` text is the base signal. Replay re-finds the element by ranking
    /// live candidates on these, falling back to label-only, then the recorded pixel.
    public struct Descriptor: Sendable {
        public let label: String
        public let role: String?
        public let identifier: String?
        /// The element's structural container (parent role+title) — disambiguates
        /// identical labels by where they sit (Healenium-style), e.g. the "Save" in
        /// dialog A vs B, or a cell by its row. `nil` when not recorded/available.
        public let container: String?
        public init(label: String, role: String? = nil, identifier: String? = nil, container: String? = nil) {
            self.label = label
            self.role = role
            self.identifier = identifier
            self.container = container
        }
    }

    public enum CandidateSource: String, Codable, Sendable, Equatable {
        case accessibility
        case synthetic
        case unknown
    }

    public struct ScoreBreakdown: Sendable, Equatable {
        public let identifier: Double
        public let label: Double
        public let role: Double
        public let structuralPath: Double
        public let neighborLabels: Double
        public let frameProximity: Double
        public let subtreeHash: Double
        public let semanticText: Double
        public let totalScore: Double
        public let availableWeight: Double
        public let confidence: Double

        public init(
            identifier: Double = 0,
            label: Double = 0,
            role: Double = 0,
            structuralPath: Double = 0,
            neighborLabels: Double = 0,
            frameProximity: Double = 0,
            subtreeHash: Double = 0,
            semanticText: Double = 0,
            totalScore: Double = 0,
            availableWeight: Double = 0,
            confidence: Double = 0
        ) {
            self.identifier = identifier
            self.label = label
            self.role = role
            self.structuralPath = structuralPath
            self.neighborLabels = neighborLabels
            self.frameProximity = frameProximity
            self.subtreeHash = subtreeHash
            self.semanticText = semanticText
            self.totalScore = totalScore
            self.availableWeight = availableWeight
            self.confidence = confidence
        }

        public static let empty = ScoreBreakdown()
    }

    public struct Candidate: Sendable, Equatable {
        public let id: String
        public let center: CGPoint?
        public let frame: CGRect?
        public let descriptor: AXTargetDescriptorV2
        public let source: CandidateSource
        public let componentScores: ScoreBreakdown
        public let totalScore: Double
        public let confidence: Double

        public init(
            id: String,
            descriptor: AXTargetDescriptorV2,
            center: CGPoint? = nil,
            frame: CGRect? = nil,
            source: CandidateSource = .unknown,
            componentScores: ScoreBreakdown = .empty,
            totalScore: Double = 0,
            confidence: Double = 0
        ) {
            self.id = id
            self.center = center
            self.frame = frame
            self.descriptor = descriptor
            self.source = source
            self.componentScores = componentScores
            self.totalScore = totalScore
            self.confidence = confidence
        }

        func ranked(with components: ScoreBreakdown) -> Candidate {
            Candidate(
                id: id,
                descriptor: descriptor,
                center: center,
                frame: frame,
                source: source,
                componentScores: components,
                totalScore: components.totalScore,
                confidence: components.confidence
            )
        }
    }

    public struct RankedCandidate: Sendable, Equatable {
        public let candidate: Candidate
        /// Raw weighted score over available recorded signals. Kept for pinned tests and
        /// audit logs; use `confidence` for the normalized accept/reject threshold.
        public let score: Double
        public let confidence: Double
        public let distance: Double?
        public let components: ScoreBreakdown

        public init(candidate: Candidate, score: Double, confidence: Double, distance: Double? = nil, components: ScoreBreakdown = .empty) {
            self.candidate = candidate
            self.score = score
            self.confidence = confidence
            self.distance = distance
            self.components = components
        }
    }

    /// Roles worth clicking — tiptour's "pointable" set.
    private static let pointableRoles: Set<String> = [
        "AXButton", "AXMenuItem", "AXMenuBarItem", "AXRow", "AXCell", "AXLink",
        "AXTextField", "AXTextArea", "AXSearchField", "AXComboBox", "AXPopUpButton",
        "AXCheckBox", "AXRadioButton", "AXTab", "AXTabGroup", "AXSlider",
        "AXDisclosureTriangle", "AXImage", "AXStaticText", "AXOutlineRow",
    ]

    private static let maxNodes = 1_400
    private static let maxDepth = 16
    public static let automaticHealMinimumConfidence = 0.78
    public static let rerankMinimumConfidence = 0.60
    public static let defaultMinimumConfidence = automaticHealMinimumConfidence

    /// Finds the best element matching `label` in the frontmost app's windows.
    /// Thin wrapper over `find(descriptor:)` for callers that only have a label —
    /// behaviour is identical to the original label-only matcher (no role/identifier
    /// signal means `rank` reduces to the text score).
    public static func find(label: String, near recorded: CGPoint? = nil) -> Match? {
        find(descriptor: Descriptor(label: label), near: recorded)
    }

    /// Finds the best element matching a recorded `descriptor` in the frontmost app's
    /// windows, ranking live candidates by identity (identifier > role-confirmed label
    /// > label) so a moved or renamed control is still re-found. `near` (CG global
    /// top-left) breaks ties toward where the click was recorded. Returns nil when
    /// Accessibility is unavailable or nothing scores above zero.
    public static func find(descriptor: Descriptor, near recorded: CGPoint? = nil) -> Match? {
        let recordedDescriptor = AXTargetDescriptorV2(
            label: descriptor.label,
            role: descriptor.role,
            identifier: descriptor.identifier,
            container: descriptor.container,
            ancestorPath: descriptor.container.map { [$0] } ?? []
        )
        return find(recorded: recordedDescriptor, near: recorded)
    }

    /// Roles that are genuinely actionable controls — the `pointable` set minus
    /// passive things (static text, images, tab groups) that would flood the
    /// "what's clickable" list pushed at a flail moment.
    private static let actionableRoles: Set<String> = [
        "AXButton", "AXMenuItem", "AXMenuBarItem", "AXLink", "AXTextField",
        "AXTextArea", "AXSearchField", "AXComboBox", "AXPopUpButton", "AXCheckBox",
        "AXRadioButton", "AXTab", "AXDisclosureTriangle", "AXRow", "AXCell", "AXSlider",
    ]

    /// The labeled, actionable controls in the frontmost app's windows — the live
    /// "what is actually on screen right now" list. Pushed into the agent's
    /// context ONLY at a flail moment (an action that changed nothing), so it
    /// re-grounds on real controls instead of re-guessing pixels. This is
    /// Cascade's hard-won "push at flail, never a pull tool" lesson married to the
    /// GUI-agent literature's core finding (grounding, not reasoning, is the
    /// bottleneck). Empty when Accessibility is off or the app draws its own UI
    /// (Blender/Electron canvases) — the caller then degrades to a plain nudge.
    /// Reuses the same bounded walk as `find` (≤1400 nodes, 0.3s timeout), so it
    /// can't run away on a huge tree.
    public static func interactables(limit: Int = 40) -> [Match] {
        guard AXIsProcessTrusted(),
              NSWorkspace.shared.frontmostApplication != nil else { return [] }
        var seen = Set<String>()
        var out: [Match] = []
        for candidate in liveCandidates().prefix(limit * 3) {
            let descriptor = candidate.descriptor
            let role = descriptor.role ?? ""
            guard out.count < limit,
                  actionableRoles.contains(role),
                  let center = candidate.center else { continue }
            let key = normalize(descriptor.label)
            guard !key.isEmpty, key.count <= 60 else { continue }
            let dedupe = role + "|" + key
            guard !seen.contains(dedupe) else { continue }
            seen.insert(dedupe)
            out.append(Match(
                center: center,
                role: role,
                title: String(descriptor.label.prefix(60)),
                score: candidate.confidence,
                descriptor: descriptor
            ))
        }
        return out
    }

    public static func runtimeProfileForFrontmost(limit: Int = 600, retryManualAccessibility: Bool = true) -> AXRuntimeProfile? {
        guard AXIsProcessTrusted(),
              let frontmost = NSWorkspace.shared.frontmostApplication else { return nil }
        let app = AXUIElementCreateApplication(frontmost.processIdentifier)
        AXClient.setMessagingTimeout(app)
        let first = runtimeProfile(
            app: app,
            appName: frontmost.localizedName,
            bundleIdentifier: frontmost.bundleIdentifier,
            limit: limit,
            manualAccessibilityAttempted: false
        )
        guard retryManualAccessibility, first.shouldRetryManualAccessibility,
              enableManualAccessibility(app: app) else {
            return first
        }
        return runtimeProfile(
            app: app,
            appName: frontmost.localizedName,
            bundleIdentifier: frontmost.bundleIdentifier,
            limit: limit,
            manualAccessibilityAttempted: true
        )
    }

    /// Compact, LLM-readable list of clickable controls — pushed at a flail moment.
    /// Pure (testable); nil when there's nothing to push so the caller can degrade.
    public static func interactableSummary(_ matches: [Match], limit: Int = 40) -> String? {
        let items = matches.prefix(limit).map { match -> String in
            let descriptor = match.descriptor
            let title = bounded(descriptor?.label ?? match.title, limit: 60) ?? ""
            let role = shortRole(descriptor?.role ?? match.role)
            var hints: [String] = [role]
            if let identifier = bounded(descriptor?.identifier, limit: 48) {
                hints.append("id \(identifier)")
            }
            if let container = bounded(descriptor?.container ?? descriptor?.ancestorPath.last, limit: 60) {
                hints.append("in \(container)")
            }
            if let enabled = descriptor?.enabled, !enabled {
                hints.append("disabled")
            }
            if descriptor?.selected == true {
                hints.append("selected")
            }
            if descriptor?.focused == true {
                hints.append("focused")
            }
            if let sibling = descriptor?.siblingRoleIndex ?? descriptor?.siblingIndex {
                hints.append("roleSibling \(sibling)")
            }
            if let frameBucket = bounded(descriptor?.frameBucket ?? descriptor?.frame, limit: 32) {
                hints.append("frame \(frameBucket)")
            }
            if let source = descriptor?.createdFrom {
                hints.append("source \(source)")
            }
            return "“\(title)” (\(hints.joined(separator: "; ")))"
        }
        return items.isEmpty ? nil : items.joined(separator: ", ")
    }

    private static func shortRole(_ role: String) -> String {
        role.hasPrefix("AX") ? String(role.dropFirst(2)).lowercased() : role.lowercased()
    }

    private static func bounded(_ value: String?, limit: Int) -> String? {
        guard let value else { return nil }
        let normalized = value
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return String(normalized.prefix(limit))
    }

    public static func frontmostState(limit: Int = 600, depth: Int = 10) -> UIStateSnapshot? {
        guard AXIsProcessTrusted(),
              let frontmost = NSWorkspace.shared.frontmostApplication else { return nil }
        let app = AXUIElementCreateApplication(frontmost.processIdentifier)
        AXClient.setMessagingTimeout(app)
        let options = UIStateSnapshot.AXBuildOptions(nodeLimit: limit, maxDepth: depth)
        if let focusedWindow = element(of: app, attribute: kAXFocusedWindowAttribute),
           let snapshot = UIStateSnapshot.snapshot(fromAXRoot: focusedWindow, options: options) {
            return snapshot
        }
        let roots = windows(of: app)
        if !roots.isEmpty {
            return UIStateSnapshot.snapshot(
                fromAXRoots: roots,
                rootKey: "frontmost|\(frontmost.processIdentifier)",
                rootRole: "AXApplication",
                rootTitle: frontmost.localizedName,
                options: options
            )
        }
        return UIStateSnapshot.snapshot(
            fromAXRoot: app,
            options: options
        )
    }

    public static func diff(_ before: UIStateSnapshot, _ after: UIStateSnapshot) -> UIStateDelta {
        UIStateDelta.between(before, after)
    }

    /// Compatibility fingerprint derived from the deterministic snapshot root hash.
    public static func frontmostFingerprint() -> Int {
        guard let snapshot = frontmostState(limit: 350, depth: 10) else { return 0 }
        return Int(truncatingIfNeeded: snapshot.rootHash)
    }

    /// Compact "role: title" label of the element at a CG global point — what the
    /// recorder stores so replay can re-find the target by identity.
    public static func clickLabel(atCG point: CGPoint) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.3)
        var ref: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &ref) == .success,
              var element = ref else { return nil }
        // Climb to the nearest labeled, pointable ancestor — hit-tests often land
        // on an unlabeled leaf (an image or text run inside the button).
        for _ in 0..<4 {
            let role = string(of: element, kAXRoleAttribute) ?? ""
            if let text = labelText(of: element), pointableRoles.contains(role) {
                return String(text.prefix(80))
            }
            guard let parent = self.element(of: element, attribute: kAXParentAttribute) else { break }
            element = parent
        }
        return nil
    }

    // MARK: - Matching

    public typealias SemanticSimilarity = @Sendable (_ recordedPhrase: String, _ candidatePhrase: String) -> Double?

    /// Similo-style weighted ranking over recorded descriptor signals. Missing recorded
    /// signals are ignored so legacy/thin descriptors do not get unfairly penalized;
    /// missing candidate signals score zero when the recording had that signal.
    public static func rank(
        recorded: AXTargetDescriptorV2,
        candidates: [Candidate],
        near recordedPoint: CGPoint? = nil,
        semanticSimilarity: SemanticSimilarity? = nil
    ) -> [RankedCandidate] {
        candidates
            .map { rank(recorded: recorded, candidate: $0, near: recordedPoint, semanticSimilarity: semanticSimilarity) }
            .filter { $0.confidence > 0 }
            .sorted { lhs, rhs in
                if abs(lhs.confidence - rhs.confidence) > 0.000_001 {
                    return lhs.confidence > rhs.confidence
                }
                switch (lhs.distance, rhs.distance) {
                case let (l?, r?) where abs(l - r) > 0.000_001:
                    return l < r
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                default:
                    return lhs.candidate.id < rhs.candidate.id
                }
            }
    }

    public static func rank(
        recorded: AXTargetDescriptorV2,
        near recordedPoint: CGPoint? = nil,
        limit: Int = 5
    ) -> [RankedCandidate] {
        guard recorded.hasSignal,
              AXIsProcessTrusted(),
              NSWorkspace.shared.frontmostApplication != nil else { return [] }
        return Array(rank(recorded: recorded, candidates: liveCandidates(), near: recordedPoint).prefix(max(0, limit)))
    }

    public static func rank(
        recorded: AXTargetDescriptorV2,
        candidate: Candidate,
        near recordedPoint: CGPoint? = nil,
        semanticSimilarity: SemanticSimilarity? = nil
    ) -> RankedCandidate {
        let scored = weightedScore(
            recorded: recorded,
            candidate: candidate.descriptor,
            recordedPoint: recordedPoint,
            candidateCenter: candidate.center,
            semanticSimilarity: semanticSimilarity
        )
        let distance = distance(from: recordedPoint, to: candidate.center)
        let rankedCandidate = candidate.ranked(with: scored)
        return RankedCandidate(
            candidate: rankedCandidate,
            score: scored.totalScore,
            confidence: scored.confidence,
            distance: distance,
            components: scored
        )
    }

    /// Pure thresholded wrapper for tests and future synthetic candidate harvesters. The
    /// live AX `find(descriptor:)` overload remains the backward-compatible screen path.
    public static func find(
        recorded: AXTargetDescriptorV2,
        candidates: [Candidate],
        near recordedPoint: CGPoint? = nil,
        minimumConfidence: Double = defaultMinimumConfidence,
        scoreCap: Double? = nil,
        semanticSimilarity: SemanticSimilarity? = nil
    ) -> RankedCandidate? {
        let threshold = scoreCap ?? minimumConfidence
        return rank(recorded: recorded, candidates: candidates, near: recordedPoint, semanticSimilarity: semanticSimilarity)
            .first { $0.confidence >= threshold }
    }

    public static func find(
        recorded: AXTargetDescriptorV2,
        near recordedPoint: CGPoint? = nil,
        minimumConfidence: Double = defaultMinimumConfidence,
        scoreCap: Double? = nil
    ) -> Match? {
        guard recorded.hasSignal,
              AXIsProcessTrusted(),
              NSWorkspace.shared.frontmostApplication != nil else { return nil }
        let threshold = scoreCap ?? minimumConfidence
        guard let ranked = rank(recorded: recorded, near: recordedPoint, limit: 5)
            .first(where: { $0.confidence >= threshold }),
            let center = ranked.candidate.center else { return nil }
        let descriptor = ranked.candidate.descriptor
        return Match(
            center: center,
            role: descriptor.role ?? "",
            title: descriptor.label,
            score: ranked.confidence,
            descriptor: descriptor
        )
    }

    /// Ranks a live `candidate` against the recorded `descriptor`. 0 = no match (must
    /// never hijack a click). A matching accessibility identifier dominates — it is
    /// unique and survives moves/renames/localization. Otherwise the label text score
    /// is the base, with role agreement nudging same-role candidates above
    /// different-role ones (a menu "Save" vs a button "Save"). Pure + unit-pinned:
    /// label-only descriptors (role/identifier nil, e.g. legacy recipes) reduce
    /// exactly to `matchScore`, so the wrapper preserves the old behaviour.
    static func rank(recorded: Descriptor, candidate: Descriptor) -> Double {
        if let rid = recorded.identifier, !rid.isEmpty,
           let cid = candidate.identifier, !cid.isEmpty, rid == cid {
            return 100
        }
        let labelScore = matchScore(needle: normalize(recorded.label), candidate: normalize(candidate.label))
        guard labelScore > 0 else { return 0 }
        // Role is a TIEBREAKER, not an override: ±0.25 (spread 0.5) keeps the nudge
        // strictly inside one integer label-score tier, so a same-role candidate wins
        // among equal labels but never beats a clearly-better label match in another role.
        let roleBonus: Double
        if let rr = recorded.role, !rr.isEmpty, let cr = candidate.role, !cr.isEmpty {
            roleBonus = (rr == cr) ? 0.25 : -0.25
        } else {
            roleBonus = 0
        }
        // Container is a SUB-tiebreak under role (±0.1): among identical label+role
        // candidates (grid cells, repeated buttons), prefer the one in the recorded
        // structural container. Role+container spread (0.7) still stays inside a tier.
        let containerBonus: Double
        if let rc = recorded.container, !rc.isEmpty, let cc = candidate.container, !cc.isEmpty {
            containerBonus = (normalize(rc) == normalize(cc)) ? 0.1 : -0.1
        } else {
            containerBonus = 0
        }
        return labelScore + roleBonus + containerBonus
    }

    private enum ComponentWeight {
        static let identifier = 0.30
        static let label = 0.20
        static let role = 0.10
        static let structuralPath = 0.15
        static let neighborLabels = 0.10
        static let frameProximity = 0.05
        static let subtreeHash = 0.05
        static let semanticText = 0.05
    }

    private static func weightedScore(
        recorded: AXTargetDescriptorV2,
        candidate: AXTargetDescriptorV2,
        recordedPoint: CGPoint?,
        candidateCenter: CGPoint?,
        semanticSimilarity: SemanticSimilarity?
    ) -> ScoreBreakdown {
        var score = 0.0
        var available = 0.0
        var identifier = 0.0
        var label = 0.0
        var role = 0.0
        var structuralPath = 0.0
        var neighborLabels = 0.0
        var frameProximity = 0.0
        var subtreeHash = 0.0
        var semanticText = 0.0

        func add(_ weight: Double, active: Bool, assign: (Double) -> Void, similarity: () -> Double) {
            guard active else {
                assign(0)
                return
            }
            available += weight
            let value = min(max(similarity(), 0), 1)
            assign(value)
            score += weight * value
        }

        add(ComponentWeight.identifier, active: recorded.identifier != nil, assign: { identifier = $0 }) {
            exactSimilarity(recorded.identifier, candidate.identifier)
        }
        add(ComponentWeight.label, active: !recorded.label.isEmpty, assign: { label = $0 }) {
            matchScore(needle: normalize(recorded.label), candidate: normalize(candidate.label)) / 3.0
        }
        add(ComponentWeight.role, active: recorded.role != nil, assign: { role = $0 }) {
            exactSimilarity(recorded.role, candidate.role)
        }
        add(ComponentWeight.structuralPath, active: hasStructuralPathSignal(recorded), assign: { structuralPath = $0 }) {
            structuralPathSimilarity(recorded, candidate)
        }
        add(ComponentWeight.neighborLabels, active: !recorded.neighborLabels.isEmpty, assign: { neighborLabels = $0 }) {
            labelSetSimilarity(recorded.neighborLabels, candidate.neighborLabels)
        }
        add(
            ComponentWeight.frameProximity,
            active: recorded.frameBucket != nil || recorded.frame != nil || recordedPoint != nil,
            assign: { frameProximity = $0 }
        ) {
            frameSimilarity(recorded, candidate, recordedPoint: recordedPoint, candidateCenter: candidateCenter)
        }
        add(ComponentWeight.subtreeHash, active: recorded.subtreeHash != nil || recorded.visualPatchHash != nil, assign: { subtreeHash = $0 }) {
            max(
                exactSimilarity(recorded.subtreeHash, candidate.subtreeHash),
                exactSimilarity(recorded.visualPatchHash, candidate.visualPatchHash)
            )
        }
        add(ComponentWeight.semanticText, active: hasSemanticSignal(recorded), assign: { semanticText = $0 }) {
            semanticTextSimilarity(recorded, candidate, semanticSimilarity: semanticSimilarity)
        }

        let confidence = available > 0 ? min(max(score / available, 0), 1) : 0

        return ScoreBreakdown(
            identifier: identifier,
            label: label,
            role: role,
            structuralPath: structuralPath,
            neighborLabels: neighborLabels,
            frameProximity: frameProximity,
            subtreeHash: subtreeHash,
            semanticText: semanticText,
            totalScore: score,
            availableWeight: available,
            confidence: confidence
        )
    }

    private static func recordedStructuralPath(_ descriptor: AXTargetDescriptorV2) -> [String] {
        if !descriptor.ancestorPath.isEmpty { return descriptor.ancestorPath }
        return descriptor.container.map { [$0] } ?? []
    }

    private static func hasStructuralPathSignal(_ descriptor: AXTargetDescriptorV2) -> Bool {
        !recordedStructuralPath(descriptor).isEmpty
            || descriptor.pathHash != nil
            || descriptor.siblingIndex != nil
            || descriptor.siblingRoleIndex != nil
    }

    private static func hasSemanticSignal(_ descriptor: AXTargetDescriptorV2) -> Bool {
        descriptor.semanticTextHash != nil
            || descriptor.semanticHash != nil
    }

    private static func exactSimilarity(_ recorded: String?, _ candidate: String?) -> Double {
        guard let recorded = recorded.map(normalize), !recorded.isEmpty,
              let candidate = candidate.map(normalize), !candidate.isEmpty else { return 0 }
        return recorded == candidate ? 1 : 0
    }

    private static func pathSimilarity(_ recorded: [String], _ candidate: [String]) -> Double {
        let r = recorded.map(normalize).filter { !$0.isEmpty }
        let c = candidate.map(normalize).filter { !$0.isEmpty }
        guard !r.isEmpty, !c.isEmpty else { return 0 }
        if r == c { return 1 }
        if let last = r.last, c.contains(last) { return 0.82 }
        var suffix = 0
        while suffix < min(r.count, c.count), r[r.count - 1 - suffix] == c[c.count - 1 - suffix] {
            suffix += 1
        }
        return Double(suffix) / Double(max(r.count, c.count))
    }

    private static func labelSetSimilarity(_ recorded: [String], _ candidate: [String]) -> Double {
        let r = Set(recorded.map(normalize).filter { !$0.isEmpty })
        let c = Set(candidate.map(normalize).filter { !$0.isEmpty })
        guard !r.isEmpty, !c.isEmpty else { return 0 }
        return Double(r.intersection(c).count) / Double(r.union(c).count)
    }

    private static func siblingSimilarity(_ recorded: Int?, _ candidate: Int?) -> Double {
        guard let recorded, let candidate else { return 0 }
        let delta = abs(recorded - candidate)
        if delta == 0 { return 1 }
        if delta == 1 { return 0.66 }
        if delta == 2 { return 0.33 }
        return 0
    }

    private static func structuralPathSimilarity(_ recorded: AXTargetDescriptorV2, _ candidate: AXTargetDescriptorV2) -> Double {
        var best = pathSimilarity(recordedStructuralPath(recorded), recordedStructuralPath(candidate))
        best = max(best, exactSimilarity(recorded.pathHash, candidate.pathHash))
        best = max(best, siblingSimilarity(recorded.siblingRoleIndex, candidate.siblingRoleIndex) * 0.25)
        best = max(best, siblingSimilarity(recorded.siblingIndex, candidate.siblingIndex) * 0.10)
        return best
    }

    private static func frameSimilarity(
        _ recorded: AXTargetDescriptorV2,
        _ candidate: AXTargetDescriptorV2,
        recordedPoint: CGPoint?,
        candidateCenter: CGPoint?
    ) -> Double {
        var best = 0.0
        if let recordedPoint, let candidateCenter {
            let distance = hypot(candidateCenter.x - recordedPoint.x, candidateCenter.y - recordedPoint.y)
            best = max(best, max(0, 1 - distance / 900.0))
        }
        if exactSimilarity(recorded.frameBucket, candidate.frameBucket) == 1 { return 1 }
        if exactSimilarity(recorded.frame, candidate.frame) == 1 { return 1 }
        guard let recordedBucket = bucketTuple(recorded.frameBucket),
              let candidateBucket = bucketTuple(candidate.frameBucket) else { return best }
        let distance = abs(recordedBucket.0 - candidateBucket.0)
            + abs(recordedBucket.1 - candidateBucket.1)
            + abs(recordedBucket.2 - candidateBucket.2)
            + abs(recordedBucket.3 - candidateBucket.3)
        return max(best, max(0, 1 - Double(distance) / 40.0))
    }

    private static func semanticTextSimilarity(
        _ recorded: AXTargetDescriptorV2,
        _ candidate: AXTargetDescriptorV2,
        semanticSimilarity: SemanticSimilarity?
    ) -> Double {
        if exactSimilarity(recorded.semanticTextHash, candidate.semanticTextHash) == 1 { return 1 }
        if exactSimilarity(recorded.semanticHash, candidate.semanticHash) == 1 { return 1 }
        let recordedPhrase = recorded.semanticPhrase
        let candidatePhrase = candidate.semanticPhrase
        if let injected = semanticSimilarity?(recordedPhrase, candidatePhrase) {
            return min(max(injected, 0), 1)
        }
        guard let recordedVector = LocalSemanticVector.vector(for: recordedPhrase),
              let candidateVector = LocalSemanticVector.vector(for: candidatePhrase) else { return 0 }
        return min(max(Double(LocalSemanticVector.cosine(recordedVector, candidateVector)), 0), 1)
    }

    private static func bucketTuple(_ value: String?) -> (Int, Int, Int, Int)? {
        guard let value else { return nil }
        let parts = value.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 4 else { return nil }
        return (parts[0], parts[1], parts[2], parts[3])
    }

    private static func distance(from recorded: CGPoint?, to candidate: CGPoint?) -> Double? {
        guard let recorded, let candidate else { return nil }
        return hypot(candidate.x - recorded.x, candidate.y - recorded.y)
    }

    /// 3 = exact, 2 = one contains the other, 1+overlap = shared words. Below 1 is
    /// no match — vague labels must not hijack a click.
    static func matchScore(needle: String, candidate: String) -> Double {
        guard !needle.isEmpty, !candidate.isEmpty else { return 0 }
        if candidate == needle { return 3 }
        if candidate.contains(needle) || needle.contains(candidate) { return 2 }
        let nWords = Set(needle.split(separator: " "))
        let cWords = Set(candidate.split(separator: " "))
        guard !nWords.isEmpty else { return 0 }
        let overlap = Double(nWords.intersection(cWords).count) / Double(nWords.count)
        return overlap >= 0.6 ? 1 + overlap : 0
    }

    static func normalize(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - AX plumbing

    private static func windows(of app: AXUIElement) -> [AXUIElement] {
        guard case .success(let windows) = AXClient.attribute(app, kAXWindowsAttribute as String, as: [AXUIElement].self) else {
            return []
        }
        return windows
    }

    public static func liveCandidates(limit: Int = 1_400) -> [Candidate] {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return [] }
        let app = AXUIElementCreateApplication(pid)
        AXClient.setMessagingTimeout(app)
        var candidates: [Candidate] = []
        var visited = 0
        for window in windows(of: app) {
            walk(window, depth: 0, limit: limit, visited: &visited) { element, role in
                guard pointableRoles.contains(role),
                      let frame = frame(of: element),
                      frame.width > 1,
                      frame.height > 1 else { return }
                let text = labelText(of: element) ?? ""
                let descriptor = AXTargetDescriptorBuilder.descriptor(for: element, fallbackLabel: text)
                let id = descriptor.identifier
                    ?? descriptor.pathHash
                    ?? "\(role)|\(descriptor.label)|\(candidates.count)"
	                candidates.append(Candidate(
	                    id: id,
	                    descriptor: descriptor,
	                    center: CGPoint(x: frame.midX, y: frame.midY),
	                    frame: frame,
	                    source: .accessibility
	                ))
	            }
	            guard visited < limit else { break }
	        }
        return candidates
    }

    private static func walk(
        _ element: AXUIElement, depth: Int, limit: Int = maxNodes,
        visited: inout Int, visit: (AXUIElement, String) -> Void
    ) {
        guard depth <= maxDepth, visited < limit else { return }
        visited += 1
        let role = string(of: element, kAXRoleAttribute) ?? ""
        visit(element, role)
        guard case .success(let children) = AXClient.children(element) else { return }
        for child in children {
            guard visited < limit else { return }
            walk(child, depth: depth + 1, limit: limit, visited: &visited, visit: visit)
        }
    }

    /// First non-empty of title / description / value / help — tiptour's label read.
    private static func labelText(of element: AXUIElement) -> String? {
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXHelpAttribute] {
            if let text = string(of: element, attribute), !text.trimmingCharacters(in: .whitespaces).isEmpty {
                return text
            }
        }
        return nil
    }

    /// The element's accessibility identifier (`kAXIdentifierAttribute`) — the most
    /// stable locator when an app sets one (many Mac apps don't, hence the cascade).
    private static func identifier(of element: AXUIElement) -> String? {
        guard let id = string(of: element, kAXIdentifierAttribute as String),
              !id.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return id
    }

    /// The element's structural container — its parent's "role: title" via the shared
    /// `AXTargetDescriptor.container` formatter (so it compares equal to what the
    /// recorder captured). `nil` when there's no parent or it carries no signal.
    static func containerLabel(of element: AXUIElement) -> String? {
        guard let parent = self.element(of: element, attribute: kAXParentAttribute) else { return nil }
        let role = string(of: parent, kAXRoleAttribute) ?? ""
        let title = labelText(of: parent) ?? ""
        return AXTargetDescriptor.container(role: role, title: title)
    }

    private static func string(of element: AXUIElement, _ attribute: String) -> String? {
        guard case .success(let value) = AXClient.attribute(element, attribute, as: String.self) else { return nil }
        return value
    }

    private static func element(of parent: AXUIElement, attribute: String) -> AXUIElement? {
        guard case .success(let value) = AXClient.elementAttribute(parent, attribute) else { return nil }
        return value
    }

    /// Element frame in CG global (top-left) coordinates.
    private static func frame(of element: AXUIElement) -> CGRect? {
        guard case .success(let frame) = AXClient.frame(element) else { return nil }
        return frame
    }

    static func decodeAXPoint(_ ref: CFTypeRef?) -> CGPoint? {
        guard let value = ref,
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
        return point
    }

    static func decodeAXSize(_ ref: CFTypeRef?) -> CGSize? {
        guard let value = ref,
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
        return size
    }

    private static func runtimeProfile(
        app: AXUIElement,
        appName: String?,
        bundleIdentifier: String?,
        limit: Int,
        manualAccessibilityAttempted: Bool
    ) -> AXRuntimeProfile {
        let displays = AXClient.activeDisplayBounds()
        let displayArea = displays.map { max(0, $0.width * $0.height) }.max() ?? 1
        var sampled = 0
        var actionable = 0
        var labeledActionable = 0
        var identifiers = 0
        var frameFailures = 0
        var errors = 0
        var canvasSized = 0

        func sample(_ element: AXUIElement, depth: Int) {
            guard sampled < limit, depth <= maxDepth else { return }
            sampled += 1
            let role = string(of: element, kAXRoleAttribute) ?? ""
            let isActionable = actionableRoles.contains(role)
            if isActionable { actionable += 1 }
            if isActionable, labelText(of: element) != nil { labeledActionable += 1 }
            if identifier(of: element) != nil { identifiers += 1 }
            switch AXClient.frame(element, knownDisplays: displays) {
            case .success(let rect):
                if displayArea > 0, rect.width * rect.height / displayArea >= 0.35 {
                    canvasSized += 1
                }
            case .failure:
                frameFailures += 1
            }
            guard depth < maxDepth, sampled < limit else { return }
            switch AXClient.children(element) {
            case .success(let children):
                for child in children {
                    guard sampled < limit else { return }
                    sample(child, depth: depth + 1)
                }
            case .failure:
                errors += 1
            }
        }

        let roots = windows(of: app)
        if roots.isEmpty {
            sample(app, depth: 0)
        } else {
            for window in roots {
                guard sampled < limit else { break }
                sample(window, depth: 0)
            }
        }
        let ratio = sampled > 0 ? Double(canvasSized) / Double(sampled) : 0
        return AXRuntimeProfile(
            bundleIdentifier: bundleIdentifier,
            appName: appName,
            sampledNodeCount: sampled,
            actionableRoleCount: actionable,
            labeledActionableCount: labeledActionable,
            identifierCount: identifiers,
            frameFailureCount: frameFailures,
            timeoutOrErrorCount: errors,
            canvasSizedElementRatio: ratio,
            manualAccessibilityAttempted: manualAccessibilityAttempted
        )
    }

    private static func enableManualAccessibility(app: AXUIElement) -> Bool {
        AXClient.setAttribute(app, "AXManualAccessibility", value: kCFBooleanTrue) == .success
    }
}
