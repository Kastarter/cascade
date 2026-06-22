import AppKit
import ApplicationServices
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
    /// `near` (CG global top-left) breaks ties toward where the click was recorded.
    /// Returns nil when Accessibility is unavailable or nothing scores well enough.
    public static func find(label: String, near recorded: CGPoint? = nil) -> Match? {
        let needle = normalize(label)
        guard !needle.isEmpty, AXIsProcessTrusted(),
              let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)

        var best: Match?
        var bestRank = 0.0
        var visited = 0
        for window in windows(of: app) {
            walk(window, depth: 0, visited: &visited) { element, role in
                guard pointableRoles.contains(role), let text = labelText(of: element) else { return }
                let score = matchScore(needle: needle, candidate: normalize(text))
                guard score > 0 else { return }
                guard let frame = frame(of: element), frame.width > 1, frame.height > 1 else { return }
                let center = CGPoint(x: frame.midX, y: frame.midY)
                // Distance only breaks ties between equal text scores.
                let distance = recorded.map { hypot(center.x - $0.x, center.y - $0.y) } ?? 0
                let rank = score * 10_000 - min(distance, 9_999)
                if best == nil || rank > bestRank {
                    best = Match(center: center, role: role, title: text, score: score)
                    bestRank = rank
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
