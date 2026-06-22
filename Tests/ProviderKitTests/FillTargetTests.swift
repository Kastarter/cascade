import CoreGraphics
import Foundation
import Testing

@testable import ProviderKit

/// Pins `fill_target` — the structural grounding split (Phase 1). The model NAMES
/// a target and the RUNTIME grounds it via the injected VisualGrounder, then
/// expands to the same click → cmd+a → type → submit batch as fill_field. The
/// crux: the grounder returns display-local AppKit points already, so the
/// expansion must NOT re-scale them (fill_field scales the model's screenshot
/// pixels; fill_target must not). See [[cascade-cu-downgrade-research]].
@MainActor
struct FillTargetTests {
    /// Returns a fixed point regardless of input — exercises the glue, not a model.
    struct StubGrounder: VisualGrounder {
        let point: CGPoint?
        func ground(screenshot: Data, target: String, displayWidthPoints: Int, displayHeightPoints: Int) async -> CGPoint? {
            point
        }
    }

    private let dummyFrame = Data([0xFF, 0xD8])  // stub grounder ignores content

    // MARK: fillActions — the shared, pure expansion

    @Test func defaultsToSingleClickAndReturn() {
        let a = ComputerUseAgent.fillActions(at: CGPoint(x: 12, y: 34), text: "hi", double: false, submit: nil)
        #expect(a == [.click(x: 12, y: 34), .key("cmd+a"), .type("hi"), .key("return")])
    }

    @Test func doublePlaceholderCmdReturn() {
        let a = ComputerUseAgent.fillActions(at: CGPoint(x: 1, y: 2), text: "X", double: true, submit: "cmd_return")
        #expect(a.first == .doubleClick(x: 1, y: 2))
        #expect(a.last == .key("cmd+return"))
    }

    @Test func submitNoneLeavesCursor() {
        let a = ComputerUseAgent.fillActions(at: .zero, text: "x", double: false, submit: "none")
        #expect(a.count == 3)
        #expect(a.last == .type("x"))
    }

    @Test func submitTab() {
        let a = ComputerUseAgent.fillActions(at: .zero, text: "x", double: false, submit: "tab")
        #expect(a.last == .key("tab"))
    }

    // MARK: expandFillTarget — grounder glue

    @Test func usesGrounderPointWithoutScaling() async {
        let agent = ComputerUseAgent(grounder: StubGrounder(point: CGPoint(x: 500, y: 600)))
        let actions = await agent.expandFillTarget(
            ["target": "the subtitle placeholder", "text": "Market Entry", "click": "double", "submit": "cmd_return"],
            frame: dummyFrame
        )
        #expect(actions?.count == 4)
        // The grounder's display point is used DIRECTLY — not run through scale().
        #expect(actions?.first == .doubleClick(x: 500, y: 600))
        #expect(actions?[2] == .type("Market Entry"))
        #expect(actions?.last == .key("cmd+return"))
    }

    @Test func nilWithoutGrounder() async {
        let agent = ComputerUseAgent()  // grounder defaults nil → feature off
        #expect(await agent.expandFillTarget(["target": "x", "text": "y"], frame: dummyFrame) == nil)
    }

    @Test func nilOnGroundingMiss() async {
        let agent = ComputerUseAgent(grounder: StubGrounder(point: nil))
        #expect(await agent.expandFillTarget(["target": "x", "text": "y"], frame: dummyFrame) == nil)
    }

    @Test func nilOnMalformedCall() async {
        let agent = ComputerUseAgent(grounder: StubGrounder(point: CGPoint(x: 1, y: 1)))
        #expect(await agent.expandFillTarget(["text": "no target"], frame: dummyFrame) == nil)
        #expect(await agent.expandFillTarget(["target": "", "text": "empty target"], frame: dummyFrame) == nil)
        #expect(await agent.expandFillTarget(["target": "x"], frame: dummyFrame) == nil)  // no text
    }

    @Test func nilWithoutAnyFrame() async {
        let agent = ComputerUseAgent(grounder: StubGrounder(point: CGPoint(x: 1, y: 1)))
        // No live frame (begin never called) and none injected → can't ground.
        #expect(await agent.expandFillTarget(["target": "x", "text": "y"]) == nil)
    }
}
