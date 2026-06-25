import ApplicationServices
import Foundation
import Testing

@testable import ComputerUseKit

// Pure decision core of ghost (non-blocking) actuation. The live AX press/insert
// need a real tree + a target PID, so they're exercised manually; here we pin the
// logic that decides WHAT to do, which a regression would silently break.
struct GhostActuatorTests {
    private let press = kAXPressAction as String
    private let confirm = kAXConfirmAction as String
    private let pick = kAXPickAction as String
    private let showMenu = kAXShowMenuAction as String

    @Test func clickPrefersPressOverEverything() {
        let action = GhostActuator.chosenAction(available: [confirm, press, pick], showMenu: false)
        #expect(action == press)
    }

    @Test func clickFallsToConfirmThenPickWhenNoPress() {
        #expect(GhostActuator.chosenAction(available: [confirm, pick], showMenu: false) == confirm)
        #expect(GhostActuator.chosenAction(available: [pick], showMenu: false) == pick)
    }

    @Test func rightClickWantsShowMenuOnly() {
        // A right-click must not silently "press" a control just because Press exists.
        #expect(GhostActuator.chosenAction(available: [press, showMenu], showMenu: true) == showMenu)
        #expect(GhostActuator.chosenAction(available: [press, confirm], showMenu: true) == nil)
    }

    @Test func noUsableActionReturnsNil() {
        // An element advertising only menu actions can't be left-clicked, and vice
        // versa — the caller then climbs to the parent or degrades.
        #expect(GhostActuator.chosenAction(available: [showMenu], showMenu: false) == nil)
        #expect(GhostActuator.chosenAction(available: [], showMenu: false) == nil)
    }

    @Test func multiLineEditorIsCaretPlacement() {
        // Text areas are clicked to place a caret, which AX focus can't do → ghost
        // reports missed so a real click positions the insertion point.
        #expect(GhostActuator.isCaretPlacementRole("AXTextArea"))
        #expect(!GhostActuator.isCaretPlacementRole("AXTextField"))
        #expect(!GhostActuator.isCaretPlacementRole("AXSearchField"))
    }

    @Test func textRolesCoverSingleLineInputs() {
        #expect(GhostActuator.textRoles.contains("AXTextField"))
        #expect(GhostActuator.textRoles.contains("AXComboBox"))
        #expect(GhostActuator.textRoles.contains("AXSearchField"))
        #expect(!GhostActuator.textRoles.contains("AXButton"))
    }

    @Test func menuModifierBitmaskDecodes() {
        // Apple's AX encoding: ⌘ present unless bit 3 (8); bit0=⇧, bit1=⌥, bit2=⌃.
        #expect(GhostActuator.menuModifierSet(0) == ["command"])            // ⌘N
        #expect(GhostActuator.menuModifierSet(1) == ["command", "shift"])   // ⌘⇧N
        #expect(GhostActuator.menuModifierSet(2) == ["command", "option"])  // ⌘⌥N
        #expect(GhostActuator.menuModifierSet(4) == ["command", "control"]) // ⌘⌃N
        #expect(GhostActuator.menuModifierSet(8) == [])                     // bare key, no ⌘
        #expect(GhostActuator.menuModifierSet(9) == ["shift"])             // ⇧ only (8|1)
    }

    @Test func requestedModifiersNormalizeToMenuEncoding() {
        // ⌘N typed as "command" must equal the menu item's decoded set for 0.
        #expect(GhostActuator.normalizedModifierSet(["command"]) == GhostActuator.menuModifierSet(0))
        #expect(GhostActuator.normalizedModifierSet(["cmd"]) == ["command"])
        #expect(GhostActuator.normalizedModifierSet(["command", "shift"]) == GhostActuator.menuModifierSet(1))
        #expect(GhostActuator.normalizedModifierSet(["⌘", "⌥"]) == GhostActuator.menuModifierSet(2))
    }

    @Test func commandShortcutsRouteToTheMenuBar() {
        // ⌘/⌃ combos go through the menu bar (reliable in the background); a bare
        // Return/Tab does not (no menu item) and falls to a posted key.
        #expect(GhostActuator.isCommandShortcut(["command"]))
        #expect(GhostActuator.isCommandShortcut(["control"]))
        #expect(GhostActuator.isCommandShortcut(["cmd", "shift"]))
        #expect(!GhostActuator.isCommandShortcut([]))
        #expect(!GhostActuator.isCommandShortcut(["shift"]))
    }

    @Test func ghostSupportsClickTypeKeyButNotComplexGestures() {
        // Single + right click, typing, keys have cursor-free AX / pid equivalents.
        #expect(GhostActuator.supportsGhost(.click))
        #expect(GhostActuator.supportsGhost(.rightClick))
        #expect(GhostActuator.supportsGhost(.type))
        #expect(GhostActuator.supportsGhost(.key))
        // Double/triple click, drag, scroll, bare move do NOT — no AX equivalent and
        // pid-posted mouse is unreliable, so these keep the cursor-restoring path.
        #expect(!GhostActuator.supportsGhost(.doubleClick))
        #expect(!GhostActuator.supportsGhost(.tripleClick))
        #expect(!GhostActuator.supportsGhost(.drag))
        #expect(!GhostActuator.supportsGhost(.scroll))
        #expect(!GhostActuator.supportsGhost(.move))
    }
}
