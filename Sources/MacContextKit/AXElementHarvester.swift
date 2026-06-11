import ApplicationServices
import Foundation

/// One control harvested from the Accessibility tree: its role, what it says,
/// and where it is. `frame` is in Quartz global coordinates (origin at the
/// primary display's top-left) exactly as AX reports it — callers map it into
/// their own space.
public struct AXHarvestedElement: Sendable {
    public let role: String
    public let label: String
    public let value: String
    public let enabled: Bool
    public let frame: CGRect

    public init(role: String, label: String, value: String, enabled: Bool, frame: CGRect) {
        self.role = role
        self.label = label
        self.value = value
        self.enabled = enabled
        self.frame = frame
    }
}

/// Harvests the frontmost window's controls — buttons, fields, checkboxes,
/// links, text — with exact labels and bounds, the perception lane that needs
/// no screenshot or vision round trip. Approach modeled on mediar-ai's
/// MacosUseSDK traversal (MIT) — see docs/PORT_MAP.md; the walk itself follows
/// AXTextHarvester's bounded iterative DFS.
///
/// Bounded on every axis (visited nodes, depth, collected elements) so a
/// pathological tree can't stall an agent turn. Fail-closed: without
/// Accessibility permission, or for apps that paint their own canvas, it
/// returns [] and the caller works from the screenshot.
public enum AXElementHarvester {
    static let maxVisited = 1_500
    static let maxDepth = 24
    static let maxElements = 320

    /// Roles whose subtrees never carry useful controls.
    private static let skippedRoles: Set<String> = [
        "AXScrollBar", "AXSplitter", "AXGrowArea", "AXMenuBar",
    ]

    /// Roles collected even without a label — their existence and position is
    /// the information (a bare text field is still the thing to click).
    private static let interactiveRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXTextField", "AXTextArea",
        "AXSecureTextField", "AXComboBox", "AXPopUpButton", "AXMenuButton",
        "AXLink", "AXSlider", "AXIncrementor", "AXTabGroup", "AXTab",
        "AXMenuItem", "AXSearchField", "AXSegmentedControl", "AXColorWell",
        "AXDisclosureTriangle", "AXStepper",
    ]

    /// Visible controls of `pid`'s focused window, in AX tree (≈layout) order.
    /// Safe to call off the main thread — the AX C API is thread-safe.
    public static func elements(forWindowOfPID pid: pid_t) -> [AXHarvestedElement] {
        guard AXIsProcessTrusted() else { return [] }
        let appRef = AXUIElementCreateApplication(pid)
        // A busy app can sit on each AX request for the default 6s timeout —
        // bound it so a hung app costs one second, not a frozen turn.
        AXUIElementSetMessagingTimeout(appRef, 1.0)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &focusedRef) == .success,
              let focusedRef else { return [] }
        let window = focusedRef as! AXUIElement
        let windowFrame = frame(of: window)

        var collected: [AXHarvestedElement] = []
        var seenText = Set<String>()
        var visited = 0
        var stack: [(AXUIElement, Int)] = [(window, 0)]
        while let (element, depth) = stack.popLast() {
            if visited >= maxVisited || collected.count >= maxElements { break }
            visited += 1

            let role = stringAttribute(element, kAXRoleAttribute) ?? ""
            if skippedRoles.contains(role) { continue }

            if let harvested = harvest(element, role: role, windowFrame: windowFrame) {
                // Repeated static text (table cells, list rows) adds nothing the
                // first occurrence didn't; interactive controls always count.
                let isInteractive = interactiveRoles.contains(role)
                let textKey = "\(harvested.label)|\(harvested.value)"
                if isInteractive || seenText.insert(textKey).inserted {
                    collected.append(harvested)
                }
            }

            guard depth < maxDepth else { continue }
            var childrenRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
                  let children = childrenRef as? [AXUIElement] else { continue }
            // Reversed so the stack pops children in natural (top-first) order.
            for child in children.reversed() {
                stack.append((child, depth + 1))
            }
        }
        return collected
    }

    /// One element → harvested record, or nil when it isn't worth reporting
    /// (invisible, unlabeled decoration, scrolled out of the window).
    private static func harvest(_ element: AXUIElement, role: String, windowFrame: CGRect?) -> AXHarvestedElement? {
        guard !role.isEmpty, role != "AXWindow", role != "AXGroup", role != "AXUnknown" else { return nil }
        guard let elementFrame = frame(of: element), elementFrame.width >= 2, elementFrame.height >= 2 else { return nil }
        // Scrolled-out rows report frames far outside the window — useless as
        // click targets and they crowd out what's actually on screen.
        if let windowFrame, !elementFrame.intersects(windowFrame) { return nil }

        let label = stringAttribute(element, kAXTitleAttribute)
            ?? stringAttribute(element, kAXDescriptionAttribute)
            ?? ""
        // Secure fields never leak their content; everything else reports what
        // it holds (checkbox 1/0, field text, slider number).
        let value = role == "AXSecureTextField" ? "" : (anyValueAttribute(element) ?? "")
        let isInteractive = interactiveRoles.contains(role)
        if !isInteractive, label.isEmpty, value.isEmpty { return nil }

        var enabled = true
        var enabledRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &enabledRef) == .success,
           let flag = enabledRef as? Bool {
            enabled = flag
        }
        return AXHarvestedElement(
            role: role,
            label: label.trimmingCharacters(in: .whitespacesAndNewlines),
            value: value.trimmingCharacters(in: .whitespacesAndNewlines),
            enabled: enabled,
            frame: elementFrame
        )
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef, let sizeRef else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionRef as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    /// kAXValue holds strings for fields, numbers for checkboxes/sliders/steppers.
    private static func anyValueAttribute(_ element: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &ref) == .success, let ref else { return nil }
        if let text = ref as? String { return text.isEmpty ? nil : text }
        if let number = ref as? NSNumber { return number.stringValue }
        return nil
    }
}
