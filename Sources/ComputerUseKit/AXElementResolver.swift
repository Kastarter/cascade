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

    public struct Candidate: Sendable, Equatable {
        public let id: String
        public let descriptor: AXTargetDescriptorV2
        public let center: CGPoint?

        public init(id: String, descriptor: AXTargetDescriptorV2, center: CGPoint? = nil) {
            self.id = id
            self.descriptor = descriptor
            self.center = center
        }
    }

    public struct RankedCandidate: Sendable, Equatable {
        public let candidate: Candidate
        /// Raw weighted score over available recorded signals. Kept for pinned tests and
        /// audit logs; use `confidence` for the normalized accept/reject threshold.
        public let score: Double
        public let confidence: Double
        public let distance: Double?

        public init(candidate: Candidate, score: Double, confidence: Double, distance: Double? = nil) {
            self.candidate = candidate
            self.score = score
            self.confidence = confidence
            self.distance = distance
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
        // An identifier can match with no label, so don't require a non-empty label
        // up front — `rank` decides per candidate.
        guard !descriptor.label.isEmpty || !(descriptor.identifier ?? "").isEmpty,
              AXIsProcessTrusted(),
              let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)

        var best: Match?
        var bestRank = 0.0
        var visited = 0
        for window in windows(of: app) {
            walk(window, depth: 0, visited: &visited) { element, role in
                guard pointableRoles.contains(role) else { return }
                let text = labelText(of: element)
                let id = identifier(of: element)
                // The container read climbs to the parent — do it lazily, only for
                // candidates that already self-match and only when the recorded target
                // HAS a container, so a heavy tree walk stays cheap.
                let preMatch = (descriptor.identifier.map { !$0.isEmpty && $0 == id } ?? false)
                    || matchScore(needle: normalize(descriptor.label), candidate: normalize(text ?? "")) > 0
                guard preMatch else { return }
                let container = descriptor.container == nil ? nil : containerLabel(of: element)
                let candidate = Descriptor(label: text ?? "", role: role, identifier: id, container: container)
                let score = rank(recorded: descriptor, candidate: candidate)
                guard score > 0 else { return }
                guard let frame = frame(of: element), frame.width > 1, frame.height > 1 else { return }
                let center = CGPoint(x: frame.midX, y: frame.midY)
                // Distance only breaks ties between equally-scored candidates.
                let distance = recorded.map { hypot(center.x - $0.x, center.y - $0.y) } ?? 0
                let combined = score * 10_000 - min(distance, 9_999)
                if best == nil || combined > bestRank {
                    best = Match(center: center, role: role, title: text ?? "", score: score)
                    bestRank = combined
                }
            }
        }
        return best
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
              let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return [] }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)

        var out: [Match] = []
        var seen = Set<String>()
        var visited = 0
        for window in windows(of: app) {
            walk(window, depth: 0, visited: &visited) { element, role in
                guard out.count < limit, actionableRoles.contains(role),
                      let text = labelText(of: element) else { return }
                let key = normalize(text)
                guard !key.isEmpty, key.count <= 60 else { return }
                let dedupe = role + "|" + key
                guard !seen.contains(dedupe) else { return }
                guard let frame = frame(of: element), frame.width > 1, frame.height > 1 else { return }
                seen.insert(dedupe)
                out.append(Match(center: CGPoint(x: frame.midX, y: frame.midY), role: role, title: String(text.prefix(60)), score: 0))
            }
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
            let role = match.role.hasPrefix("AX") ? String(match.role.dropFirst(2)).lowercased() : match.role.lowercased()
            return "“\(match.title)” (\(role))"
        }
        return items.isEmpty ? nil : items.joined(separator: ", ")
    }

    /// A cheap signature of the frontmost app's UI — focused element + the shape of
    /// the focused window's tree. Compare before/after an action: if it didn't
    /// change, the action almost certainly didn't land (tiptour's post-click check).
    public static func frontmostFingerprint() -> Int {
        guard AXIsProcessTrusted(),
              let frontmost = NSWorkspace.shared.frontmostApplication else { return 0 }
        let app = AXUIElementCreateApplication(frontmost.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.25)

        var hasher = Hasher()
        hasher.combine(frontmost.processIdentifier)
        if let focused = element(of: app, attribute: kAXFocusedUIElementAttribute) {
            hasher.combine(string(of: focused, kAXRoleAttribute) ?? "")
            hasher.combine(labelText(of: focused) ?? "")
        }
        if let window = element(of: app, attribute: kAXFocusedWindowAttribute) {
            hasher.combine(string(of: window, kAXTitleAttribute) ?? "")
            var visited = 0
            var nodes = 0
            walk(window, depth: 0, limit: 350, visited: &visited) { node, role in
                nodes += 1
                hasher.combine(role)
                if nodes <= 60, let text = labelText(of: node) { hasher.combine(text) }
            }
            hasher.combine(nodes)
        }
        return hasher.finalize()
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

    /// Similo-style weighted ranking over recorded descriptor signals. Missing recorded
    /// signals are ignored so legacy/thin descriptors do not get unfairly penalized;
    /// missing candidate signals score zero when the recording had that signal.
    public static func rank(
        recorded: AXTargetDescriptorV2,
        candidates: [Candidate],
        near recordedPoint: CGPoint? = nil
    ) -> [RankedCandidate] {
        candidates
            .map { rank(recorded: recorded, candidate: $0, near: recordedPoint) }
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
        candidate: Candidate,
        near recordedPoint: CGPoint? = nil
    ) -> RankedCandidate {
        let scored = weightedScore(recorded: recorded, candidate: candidate.descriptor)
        let confidence = scored.availableWeight > 0 ? min(max(scored.score / scored.availableWeight, 0), 1) : 0
        let distance = distance(from: recordedPoint, to: candidate.center)
        return RankedCandidate(candidate: candidate, score: scored.score, confidence: confidence, distance: distance)
    }

    /// Pure thresholded wrapper for tests and future synthetic candidate harvesters. The
    /// live AX `find(descriptor:)` overload remains the backward-compatible screen path.
    public static func find(
        recorded: AXTargetDescriptorV2,
        candidates: [Candidate],
        near recordedPoint: CGPoint? = nil,
        minimumConfidence: Double = 0.62
    ) -> RankedCandidate? {
        rank(recorded: recorded, candidates: candidates, near: recordedPoint)
            .first { $0.confidence >= minimumConfidence }
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

    private static func weightedScore(
        recorded: AXTargetDescriptorV2,
        candidate: AXTargetDescriptorV2
    ) -> (score: Double, availableWeight: Double) {
        var score = 0.0
        var available = 0.0

        func add(_ weight: Double, active: Bool, similarity: () -> Double) {
            guard active else { return }
            available += weight
            score += weight * min(max(similarity(), 0), 1)
        }

        add(0.22, active: recorded.identifier != nil) {
            exactSimilarity(recorded.identifier, candidate.identifier)
        }
        add(0.17, active: !recorded.label.isEmpty) {
            matchScore(needle: normalize(recorded.label), candidate: normalize(candidate.label)) / 3.0
        }
        add(0.14, active: recorded.semanticHash != nil) {
            exactSimilarity(recorded.semanticHash, candidate.semanticHash)
        }
        add(0.13, active: !recordedStructuralPath(recorded).isEmpty) {
            pathSimilarity(recordedStructuralPath(recorded), recordedStructuralPath(candidate))
        }
        add(0.10, active: !recorded.neighborLabels.isEmpty) {
            labelSetSimilarity(recorded.neighborLabels, candidate.neighborLabels)
        }
        add(0.07, active: recorded.subtreeHash != nil) {
            exactSimilarity(recorded.subtreeHash, candidate.subtreeHash)
        }
        add(0.07, active: recorded.role != nil) {
            exactSimilarity(recorded.role, candidate.role)
        }
        add(0.05, active: recorded.siblingIndex != nil) {
            siblingSimilarity(recorded.siblingIndex, candidate.siblingIndex)
        }
        add(0.05, active: recorded.frameBucket != nil) {
            exactSimilarity(recorded.frameBucket, candidate.frameBucket)
        }

        return (score, available)
    }

    private static func recordedStructuralPath(_ descriptor: AXTargetDescriptorV2) -> [String] {
        if !descriptor.ancestorPath.isEmpty { return descriptor.ancestorPath }
        return descriptor.container.map { [$0] } ?? []
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
