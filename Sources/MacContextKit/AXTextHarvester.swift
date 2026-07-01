import ApplicationServices
import Foundation

func decodeAXElement(_ ref: CFTypeRef?) -> AXUIElement? {
    guard let value = ref,
          CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return value as! AXUIElement
}

/// Harvests the *exact* text of the focused window through the Accessibility
/// tree — the text channel that no resolution cap or OCR error can touch. For
/// native apps this is character-perfect; for canvas/web apps it returns little
/// and the OCR channel carries the frame instead.
///
/// Bounded on every axis (nodes, depth, characters, per-value length) so a
/// pathological tree (giant web page, infinite table) can't stall the recorder.
/// Fail-closed: without Accessibility permission it returns "" and the recorder
/// proceeds on OCR alone.
public enum AXTextHarvester {
    static let maxNodes = 600
    static let maxDepth = 16
    static let maxChars = 12_000
    static let maxValueLength = 1_000

    /// Roles whose children are never text-bearing — skipping them keeps the
    /// walk fast on busy windows.
    private static let skippedRoles: Set<String> = [
        "AXScrollBar", "AXSplitter", "AXGrowArea", "AXMenuBar", "AXImage",
    ]

    /// Visible text of `pid`'s focused window, top-to-bottom-ish (AX tree order).
    /// Safe to call off the main thread — the AX C API is thread-safe; it is the
    /// recorder actor's job to not call this concurrently with itself.
    public static func text(forWindowOfPID pid: pid_t) -> String {
        guard AXIsProcessTrusted() else { return "" }
        let appRef = AXUIElementCreateApplication(pid)
        AXClient.setMessagingTimeout(appRef)
        guard case .success(let focused) = AXClient.elementAttribute(appRef, kAXFocusedWindowAttribute as String) else {
            return ""
        }
        return text(forWindow: focused)
    }

    /// Visible form controls in the focused window. This is intentionally compact:
    /// it gives the OCR structurer enough AX evidence to pair labels and values
    /// without importing agent/harness code into MacContextKit.
    public static func controls(forWindowOfPID pid: pid_t) -> [ScreenContentStructurer.AXControl] {
        guard AXIsProcessTrusted() else { return [] }
        let appRef = AXUIElementCreateApplication(pid)
        AXClient.setMessagingTimeout(appRef)
        guard case .success(let focused) = AXClient.elementAttribute(appRef, kAXFocusedWindowAttribute as String) else {
            return []
        }
        return controls(forWindow: focused)
    }

    static func text(forFocusedWindowRef focusedRef: CFTypeRef?) -> String {
        guard let window = decodeAXElement(focusedRef) else { return "" }
        return text(forWindow: window)
    }

    static func controls(forFocusedWindowRef focusedRef: CFTypeRef?) -> [ScreenContentStructurer.AXControl] {
        guard let window = decodeAXElement(focusedRef) else { return [] }
        return controls(forWindow: window)
    }

    private static func text(forWindow window: AXUIElement) -> String {

        var lines: [String] = []
        var seen = Set<String>()
        var totalChars = 0
        var visited = 0

        // Iterative DFS with explicit depth so the caps are exact.
        var stack: [(AXUIElement, Int)] = [(window, 0)]
        while let (element, depth) = stack.popLast() {
            if visited >= maxNodes || totalChars >= maxChars { break }
            visited += 1

            let role = stringAttribute(element, kAXRoleAttribute) ?? ""
            if skippedRoles.contains(role) { continue }

            for attribute in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
                guard totalChars < maxChars else { break }
                guard var value = stringAttribute(element, attribute) else { continue }
                value = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard value.count >= 2, !value.allSatisfy(\.isWhitespace) else { continue }
                if value.count > maxValueLength { value = String(value.prefix(maxValueLength)) }
                guard seen.insert(value).inserted else { continue }
                lines.append(value)
                totalChars += value.count
            }

            guard depth < maxDepth else { continue }
            guard case .success(let children) = AXClient.children(element) else { continue }
            // Reversed so the stack pops children in natural (top-first) order.
            for child in children.reversed() {
                stack.append((child, depth + 1))
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func controls(forWindow window: AXUIElement) -> [ScreenContentStructurer.AXControl] {
        var controls: [ScreenContentStructurer.AXControl] = []
        var visited = 0
        var stack: [(AXUIElement, Int)] = [(window, 0)]

        while let (element, depth) = stack.popLast() {
            if visited >= maxNodes || controls.count >= 160 { break }
            visited += 1

            let role = stringAttribute(element, kAXRoleAttribute) ?? ""
            if skippedRoles.contains(role) { continue }

            if let kind = controlKind(for: role) {
                let label = firstStringAttribute(element, [
                    kAXTitleAttribute as String,
                    kAXDescriptionAttribute as String,
                    "AXPlaceholderValue",
                    "AXHelp",
                ])
                let value = valueString(element)
                let rect: CGRect?
                if case .success(let frame) = AXClient.frame(element) {
                    rect = frame
                } else {
                    rect = nil
                }
                controls.append(ScreenContentStructurer.AXControl(
                    id: "ax-control-\(String(format: "%04d", controls.count + 1))",
                    kind: kind,
                    label: label,
                    value: value,
                    rect: rect,
                    confidence: 0.86
                ))
            }

            guard depth < maxDepth else { continue }
            guard case .success(let children) = AXClient.children(element) else { continue }
            for child in children.reversed() {
                stack.append((child, depth + 1))
            }
        }

        return controls
    }

    /// Combines the two text channels into one record: AX text (exact) leads,
    /// then OCR lines that AX didn't already cover (icons, canvases, images of
    /// text). Pure function — unit-tested directly.
    public static func merge(ax: String, ocr: String) -> String {
        let axTrimmed = ax.trimmingCharacters(in: .whitespacesAndNewlines)
        let ocrTrimmed = ocr.trimmingCharacters(in: .whitespacesAndNewlines)
        if axTrimmed.isEmpty { return ocrTrimmed }
        if ocrTrimmed.isEmpty { return axTrimmed }
        let axLower = axTrimmed.lowercased()
        let novel = ocrTrimmed.split(separator: "\n").filter { line in
            let needle = line.trimmingCharacters(in: .whitespaces).lowercased()
            return needle.count >= 3 && !axLower.contains(needle)
        }
        guard !novel.isEmpty else { return axTrimmed }
        return axTrimmed + "\n" + novel.joined(separator: "\n")
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        guard case .success(let value) = AXClient.attribute(element, attribute, as: String.self) else { return nil }
        return value
    }

    private static func firstStringAttribute(_ element: AXUIElement, _ attributes: [String]) -> String? {
        for attribute in attributes {
            guard let value = stringAttribute(element, attribute)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !value.isEmpty else { continue }
            return value
        }
        return nil
    }

    private static func valueString(_ element: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &ref) == .success,
              let ref else { return nil }
        if let value = ref as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let value = ref as? NSNumber {
            return value.stringValue
        }
        return nil
    }

    private static func controlKind(for role: String) -> ScreenContentStructurer.AXControlKind? {
        switch role {
        case "AXTextField", "AXTextArea", "AXSecureTextField":
            return .textField
        case "AXCheckBox":
            return .checkbox
        case "AXRadioButton":
            return .radio
        case "AXPopUpButton":
            return .popup
        case "AXComboBox":
            return .comboBox
        default:
            return nil
        }
    }
}
