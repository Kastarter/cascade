import AppKit
import ApplicationServices
import CascadeMemory
import Foundation

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
        /// The element's frame size (points). Lets a caller judge whether the
        /// CENTER is a trustworthy click point: a frame far larger than a control
        /// (a content region / canvas placeholder) has a center that is often empty
        /// space, where a click misses — or, on a slide, spawns a new text box.
        public let size: CGSize

        public init(center: CGPoint, role: String, title: String, score: Double, size: CGSize = .zero) {
            self.center = center
            self.role = role
            self.title = title
            self.score = score
            self.size = size
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
                    best = Match(center: center, role: role, title: text ?? "", score: score, size: frame.size)
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
                out.append(Match(center: CGPoint(x: frame.midX, y: frame.midY), role: role, title: String(text.prefix(60)), score: 0, size: frame.size))
            }
        }
        return out
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
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ref) == .success,
              let windows = ref as? [AXUIElement] else { return [] }
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
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &ref) == .success,
              let children = ref as? [AXUIElement] else { return }
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
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    private static func element(of parent: AXUIElement, attribute: String) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &ref) == .success,
              let value = ref, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// Element frame in CG global (top-left) coordinates.
    private static func frame(of element: AXUIElement) -> CGRect? {
        var ref: CFTypeRef?
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &ref) == .success,
              let posValue = ref, AXValueGetValue(posValue as! AXValue, .cgPoint, &position) else { return nil }
        ref = nil
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &ref) == .success,
              let sizeValue = ref, AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }
}
