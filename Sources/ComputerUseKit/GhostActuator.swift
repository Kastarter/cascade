import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// Ghost actuation: drive the target app through the Accessibility API by PID, with
// ZERO system-cursor movement and no focus steal, so the agent can work while the
// user keeps using their machine. This is the "visible but non-blocking" lane the
// user asked for — the companion cursor (GuidanceOverlay) SHOWS where the agent is
// working; the real effect is delivered here without touching the shared pointer.
//
// The hard-won lesson behind this file (see CLAUDE.md, the 2026-06-22 multi-cursor
// revert): the proven path is **AX-press as PRIMARY**, never pid-posted mouse first.
//   • AXUIElementPerformAction(kAXPressAction) activates a control without a cursor.
//   • AXUIElementCopyElementAtPosition(appElement, …) hit-tests inside the TARGET
//     app's own tree — so it reaches that app's controls even when another window is
//     on top at the same screen point (the linchpin for "act on B while in A"). The
//     system-wide element, by contrast, hit-tests whatever window is frontmost.
//   • Text lands by setting kAXSelectedText on the app's focused element (verified by
//     reading the value back — web <input>/comboboxes accept the set and report
//     success while nothing changes; the audited phantom "can't type").
//
// What ghost mode deliberately does NOT do: synthesise mouse events. A pid-posted
// click is unreliable (many apps read the GLOBAL cursor position, so the click lands
// at the user's real pointer, not the target) — that approach was built and reverted.
// When AX can't press a target (canvas/Electron leaf, unlabeled element), this
// reports `.missed` and the caller decides whether to degrade to the real,
// cursor-restoring CGEvent path or to skip — it never silently warps the cursor.
public enum GhostActuator {
    /// Outcome of a ghost action attempt.
    public enum Outcome: Equatable, Sendable {
        /// Performed an AX action on a control (button / menu item / checkbox / link).
        case pressed
        /// Focused a text input — a following `type` will land in it.
        case focused
        /// Nothing actionable via AX at this point → the caller falls back.
        case missed
    }

    /// The action kinds ghost mode can deliver through AX. Single + right click,
    /// typing, and keys have clean AX / pid-keyboard equivalents; double/triple
    /// click, drag, scroll, and bare moves do NOT (no AX equivalent and pid-mouse
    /// is unreliable), so the caller keeps the cursor-restoring path for those.
    public enum ActionKind: Sendable {
        case click, rightClick, type, key
        case doubleClick, tripleClick, drag, scroll, move
    }

    // MARK: - Pure decision core (unit-tested; no AX calls)

    /// Roles that are clicked to enter text — focusing the element IS the click.
    public static let textRoles: Set<String> = ["AXTextField", "AXComboBox", "AXSearchField", "AXTextArea"]

    /// Multi-line editors (Notes body, TextEdit, Mail compose) are clicked to PLACE
    /// THE CARET at the click point — something AX focus cannot do (it lands the
    /// element but leaves the insertion point stale). Ghost mode reports `.missed`
    /// for these so the caller can position the caret with a real click.
    public static func isCaretPlacementRole(_ role: String) -> Bool { role == "AXTextArea" }

    /// Picks which AX action to perform for a target given the actions the element
    /// actually advertises. A normal click prefers Press, then Confirm, then Pick;
    /// a right-click wants ShowMenu. Returns nil when the element offers none of
    /// them (the caller climbs to the parent, then degrades). Pure + unit-pinned.
    public static func chosenAction(available: [String], showMenu: Bool) -> String? {
        let wanted = showMenu
            ? [kAXShowMenuAction as String]
            : [kAXPressAction as String, kAXConfirmAction as String, kAXPickAction as String]
        return wanted.first { available.contains($0) }
    }

    /// Whether an action kind can be actuated through AX in ghost mode at all.
    /// `false` means "no cursor-free path exists" — the caller keeps the existing
    /// cursor-restoring CGEvent path for that one action.
    public static func supportsGhost(_ kind: ActionKind) -> Bool {
        switch kind {
        case .click, .rightClick, .type, .key: true
        case .doubleClick, .tripleClick, .drag, .scroll, .move: false
        }
    }

    // MARK: - Live AX operations (PID-targeted; need a real tree, not unit-tested)

    /// Presses the control at a CG-global (top-left) point inside the app `pid` owns,
    /// climbing from the hit-test leaf to the nearest ancestor that advertises a
    /// usable action. Zero cursor movement; works on a background/occluded window
    /// because the hit-test runs against the app's OWN element, not the system-wide
    /// one. Text inputs are focused (so a following `type` lands); multi-line
    /// editors return `.missed` (AX can't place a caret). `.missed` when the point
    /// has nothing AX-actionable — the caller then decides how to degrade.
    public static func press(atCG point: CGPoint, pid: pid_t, showMenu: Bool = false) -> Outcome {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        var ref: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &ref) == .success,
              let hit = ref else { return .missed }

        var element: AXUIElement = hit
        // Hit-tests often land on an unlabeled leaf (an image/label inside a button),
        // so climb a few levels looking for something we can actually act on.
        for _ in 0..<5 {
            let role = axString(element, kAXRoleAttribute) ?? ""
            if !showMenu, textRoles.contains(role) {
                if isCaretPlacementRole(role) { return .missed }
                if AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success {
                    return .focused
                }
            }
            if let action = chosenAction(available: actionNames(element), showMenu: showMenu),
               AXUIElementPerformAction(element, action as CFString) == .success {
                return .pressed
            }
            guard let parent = axElement(element, kAXParentAttribute) else { break }
            element = parent
        }
        return .missed
    }

    /// Posts a key combo ("cmd+a", "return", "tab") to a specific PID via
    /// `CGEvent.postToPid` — the only keyboard path that doesn't require the target
    /// to be frontmost. BEST-EFFORT: some apps/keys ignore pid-posted keys to a
    /// background window (documented macOS limitation), so callers must treat a
    /// `true` return as "sent", not "guaranteed landed" — the no-effect detector is
    /// the backstop. Returns false only when the key name is unknown.
    public static func postKey(_ combo: String, pid: pid_t) -> Bool {
        let parts = combo.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let keyName = parts.last, let code = KeyCodes.code(for: keyName) else { return false }
        let flags = KeyCodes.flags(for: Array(parts.dropLast()))
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else { return false }
        down.flags = flags
        up.flags = flags
        down.postToPid(pid)
        up.postToPid(pid)
        return true
    }

    /// Inserts text at the caret of `pid`'s focused element via kAXSelectedText —
    /// no clipboard, no keystrokes, no cursor. Verified by reading the value back
    /// (web inputs accept the set and report success while the value never changes).
    /// Returns false when there's no focused, settable text element, or the write
    /// didn't take — the caller falls back to its tiered text entry.
    public static func insertText(_ text: String, pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        let element = focused as! AXUIElement
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue,
              AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success
        else { return false }
        let after = axString(element, kAXValueAttribute) ?? axString(element, kAXSelectedTextAttribute)
        return after?.contains(text) ?? false
    }

    // MARK: - AX plumbing

    private static func actionNames(_ element: AXUIElement) -> [String] {
        var ref: CFArray?
        guard AXUIElementCopyActionNames(element, &ref) == .success, let names = ref as? [String] else { return [] }
        return names
    }

    private static func axString(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    private static func axElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let value = ref, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}
