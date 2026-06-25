import ComputerUseKit
import CoreGraphics
import Testing

@testable import AppShell

/// Pins the background ghost agent's coordinate translation — the model works in a
/// window's local space; a wrong flip presses the wrong row of the wrong app. (The
/// live AX actuation on an occluded window is runtime-verified by hand.)
struct NativeWindowMappingTests {
    private let frame = CGRect(x: 100, y: 200, width: 800, height: 600)

    @Test func windowLocalAppKitToGlobalCG() {
        // AppKit bottom-left origin → global CG top-left.
        // (0,0) = window bottom-left → CG (100, 200+600) = (100, 800).
        #expect(NativeWindowMapping.globalCG(windowLocalAppKit: .zero, windowFrame: frame) == CGPoint(x: 100, y: 800))
        // (0,600) = window top-left → CG (100, 200).
        #expect(NativeWindowMapping.globalCG(windowLocalAppKit: CGPoint(x: 0, y: 600), windowFrame: frame) == CGPoint(x: 100, y: 200))
        // Center maps to the window's CG center.
        #expect(NativeWindowMapping.globalCG(windowLocalAppKit: CGPoint(x: 400, y: 300), windowFrame: frame) == CGPoint(x: 500, y: 500))
    }

    @Test func globalCGToAppKitForCompanion() {
        // Global CG top-left → global AppKit bottom-left given the main display height.
        #expect(NativeWindowMapping.appKit(fromGlobalCG: CGPoint(x: 100, y: 200), mainDisplayHeight: 1000) == CGPoint(x: 100, y: 800))
        // Round-trip a window point: local → CG → AppKit is consistent.
        let cg = NativeWindowMapping.globalCG(windowLocalAppKit: CGPoint(x: 400, y: 300), windowFrame: frame)
        #expect(NativeWindowMapping.appKit(fromGlobalCG: cg, mainDisplayHeight: 1000) == CGPoint(x: 500, y: 500))
    }

    @Test func targetPointResolvesPositionalActionsOnly() {
        // Click resolves to its global-CG point; the drag resolves to its DESTINATION.
        let click = NativeWindowMapping.targetPoint(.click(x: 400, y: 300), windowFrame: frame)
        #expect(click == CGPoint(x: 500, y: 500))
        let drag = NativeWindowMapping.targetPoint(.drag(fromX: 0, fromY: 0, toX: 400, toY: 300), windowFrame: frame)
        #expect(drag == CGPoint(x: 500, y: 500))
        // Non-positional actions have no companion target.
        #expect(NativeWindowMapping.targetPoint(.type("hi"), windowFrame: frame) == nil)
        #expect(NativeWindowMapping.targetPoint(.key("return"), windowFrame: frame) == nil)
    }
}
