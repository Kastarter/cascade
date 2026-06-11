import ApplicationServices
import Foundation

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
        // Node caps bound the WORK; this bounds the WAIT — a hung app answers
        // each AX call slowly, and 600 slow calls would stall the recorder.
        AXUIElementSetMessagingTimeout(appRef, 0.2)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &focusedRef) == .success,
              let focusedRef else { return "" }
        let window = focusedRef as! AXUIElement
        AXUIElementSetMessagingTimeout(window, 0.2)

        var lines: [String] = []
        var seen = Set<String>()
        var totalChars = 0
        var visited = 0
        let deadline = Date().addingTimeInterval(0.6)

        // Iterative DFS with explicit depth so the caps are exact.
        var stack: [(AXUIElement, Int)] = [(window, 0)]
        while let (element, depth) = stack.popLast() {
            if visited >= maxNodes || totalChars >= maxChars { break }
            // Wall-clock deadline: better a partial AX harvest than a recorder
            // that falls behind the screen (OCR still covers the frame).
            if visited % 24 == 0, Date() > deadline { break }
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
            var childrenRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
                  let children = childrenRef as? [AXUIElement] else { continue }
            // Reversed so the stack pops children in natural (top-first) order.
            for child in children.reversed() {
                stack.append((child, depth + 1))
            }
        }
        return lines.joined(separator: "\n")
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
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
