import CoreGraphics
import Foundation
import Testing

@testable import ProviderKit

/// Pins the grounder's coordinate conversion — display-local AppKit (bottom-left,
/// what ElementLocator returns) → model-pixel (top-left, what the agent's
/// computer tool clicks). A wrong flip here sends the agent clicking the wrong
/// row, so the round trip must be exact. (The live Claude call is exercised
/// manually; only the math is unit-pinned.)
struct VisualGrounderTests {
    @Test func centerMapsToCenter() {
        // 1440×900 display → AgentResolution.best = 1280×800 (16:10).
        // AppKit center (720,450) → model-pixel center (640,400).
        let p = ClaudeVisualGrounder.modelPixel(
            fromDisplayAppKit: CGPoint(x: 720, y: 450),
            displayWidthPoints: 1440, displayHeightPoints: 900
        )
        #expect(p.x == 640)
        #expect(p.y == 400)
    }

    @Test func flipsBottomLeftToTopLeft() {
        // AppKit bottom-left origin (0,0) is the BOTTOM of the screen → top-left
        // origin max-Y (800). AppKit top-left (0,900) → model-pixel (0,0).
        let bottom = ClaudeVisualGrounder.modelPixel(
            fromDisplayAppKit: CGPoint(x: 0, y: 0),
            displayWidthPoints: 1440, displayHeightPoints: 900
        )
        #expect(bottom.x == 0)
        #expect(bottom.y == 800)

        let topLeft = ClaudeVisualGrounder.modelPixel(
            fromDisplayAppKit: CGPoint(x: 0, y: 900),
            displayWidthPoints: 1440, displayHeightPoints: 900
        )
        #expect(topLeft.x == 0)
        #expect(topLeft.y == 0)
    }

    @Test func zeroDisplayIsSafe() {
        let p = ClaudeVisualGrounder.modelPixel(
            fromDisplayAppKit: CGPoint(x: 10, y: 10), displayWidthPoints: 0, displayHeightPoints: 0
        )
        #expect(p == .zero)
    }
}
