import ComputerUseKit
import CoreGraphics
import ProviderKit
import Testing

@testable import AppShell

/// Pins the background-native agent's coordinate + action translation — the model
/// works in a window's local space; a wrong flip pid-clicks the wrong row of the
/// wrong app. (The live pid-posted actuation is runtime-verified by hand.)
struct NativeWindowMappingTests {
    private let frame = CGRect(x: 100, y: 200, width: 800, height: 600)

    @Test func windowLocalAppKitToGlobalCG() {
        // AppKit bottom-left origin → global CG top-left.
        // (0,0) = window bottom-left → CG (100, 200+600) = (100, 800).
        #expect(NativeWindowMapping.globalCG(windowLocalAppKit: .zero, windowFrame: frame) == CGPoint(x: 100, y: 800))
        // (0,600) = window top-left → CG (100, 200).
        #expect(NativeWindowMapping.globalCG(windowLocalAppKit: CGPoint(x: 0, y: 600), windowFrame: frame) == CGPoint(x: 100, y: 200))
        // center.
        #expect(NativeWindowMapping.globalCG(windowLocalAppKit: CGPoint(x: 400, y: 300), windowFrame: frame) == CGPoint(x: 500, y: 500))
    }

    @Test func globalCGToAppKitFlipsAroundMainHeight() {
        #expect(NativeWindowMapping.appKit(fromGlobalCG: CGPoint(x: 100, y: 800), mainDisplayHeight: 900) == CGPoint(x: 100, y: 100))
    }

    @Test func parsesKeyCombos() {
        var r = NativeWindowMapping.parseKey("cmd+a")
        #expect(r.key == "a" && r.modifiers == ["cmd"])
        r = NativeWindowMapping.parseKey("cmd+shift+v")
        #expect(r.key == "v" && r.modifiers == ["cmd", "shift"])
        r = NativeWindowMapping.parseKey("return")
        #expect(r.key == "return" && r.modifiers.isEmpty)
    }

    @Test func translatesActionsToGlobalCG() {
        // A click maps to a global-CG click.
        if case .click(let x, let y)? = NativeWindowMapping.translate(.click(x: 400, y: 300), windowFrame: frame) {
            #expect(x == 500 && y == 500)
        } else { Issue.record("click should translate to a click") }
        // A key combo splits.
        if case .key(let k, let m)? = NativeWindowMapping.translate(.key("cmd+a"), windowFrame: frame) {
            #expect(k == "a" && m == ["cmd"])
        } else { Issue.record("key should translate") }
        // Type passes through.
        if case .typeText(let t)? = NativeWindowMapping.translate(.type("hi"), windowFrame: frame) {
            #expect(t == "hi")
        } else { Issue.record("type should translate") }
        // Observation actions are handled by the loop, not actuated.
        #expect(NativeWindowMapping.translate(.wait, windowFrame: frame) == nil)
        #expect(NativeWindowMapping.translate(.screenshot, windowFrame: frame) == nil)
    }

    @Test func targetPointOnlyForPointerActions() {
        #expect(NativeWindowMapping.targetPoint(.click(x: 400, y: 300), windowFrame: frame) == CGPoint(x: 500, y: 500))
        #expect(NativeWindowMapping.targetPoint(.type("hi"), windowFrame: frame) == nil)
    }
}
