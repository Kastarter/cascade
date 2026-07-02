import AppKit
import CoreGraphics
import Foundation
import ProviderKit
import Testing

@testable import AppShell
@testable import ComputerUseKit

/// d18: a configured canvas grounder (self-hosted UI-Venus) owns exactly the
/// visual calls whose target names a canvas concept — the SAME pure predicate
/// the d15 router audits as `canvas_concept` — while the baseline grounder
/// keeps every other visual call. The shipped default (nil canvas grounder)
/// must stay byte-identical to `base`.
struct CanvasGrounderRoutingTests {
    // MARK: pure request-owner selection

    @Test func requestOwnerMatchesTheRouterCanvasPredicate() {
        let base = PointStubGrounder(counter: CallCounter(), point: CGPoint(x: 10, y: 10))
        let canvas = PointStubGrounder(counter: CallCounter(), point: CGPoint(x: 99, y: 99))
        let grounder = MixtureGrounder(base: base, canvasGrounder: canvas, skills: AppSkillRegistry())

        #expect(Self.stubPoint(grounder.visualBase(for: "the title placeholder")) == CGPoint(x: 99, y: 99))
        #expect(Self.stubPoint(grounder.visualBase(for: "drag the shape on the canvas")) == CGPoint(x: 99, y: 99))
        #expect(Self.stubPoint(grounder.visualBase(for: "the Save button")) == CGPoint(x: 10, y: 10))
    }

    @Test func nilCanvasGrounderKeepsEveryCallOnBase() {
        let base = PointStubGrounder(counter: CallCounter(), point: CGPoint(x: 10, y: 10))
        let grounder = MixtureGrounder(base: base, skills: AppSkillRegistry())

        #expect(Self.stubPoint(grounder.visualBase(for: "the title placeholder")) == CGPoint(x: 10, y: 10))
        #expect(Self.stubPoint(grounder.visualBase(for: "the Save button")) == CGPoint(x: 10, y: 10))
    }

    // MARK: end-to-end through `ground`

    @Test func canvasTargetGroundsThroughTheCanvasGrounder() async throws {
        let screenshot = try #require(CropRefineGroundingTests.solidJPEG(width: 800, height: 600))
        let baseCalls = CallCounter()
        let canvasCalls = CallCounter()
        let grounder = MixtureGrounder(
            base: PointStubGrounder(counter: baseCalls, point: CGPoint(x: 11, y: 12)),
            canvasGrounder: PointStubGrounder(counter: canvasCalls, point: CGPoint(x: 333, y: 444)),
            skills: AppSkillRegistry(),
            axPickerEnabled: false,
            cropRefineRegionOverride: { _, _, _, _ in nil }
        )

        let point = await grounder.ground(
            screenshot: screenshot,
            target: "the circle drawn on the canvas",
            displayWidthPoints: 800,
            displayHeightPoints: 600
        )

        #expect(point == CGPoint(x: 333, y: 444))
        #expect(await canvasCalls.value == 1)
        #expect(await baseCalls.value == 0)
    }

    @Test func nonCanvasTargetStaysOnTheBaseline() async throws {
        let screenshot = try #require(CropRefineGroundingTests.solidJPEG(width: 800, height: 600))
        let baseCalls = CallCounter()
        let canvasCalls = CallCounter()
        let grounder = MixtureGrounder(
            base: PointStubGrounder(counter: baseCalls, point: CGPoint(x: 11, y: 12)),
            canvasGrounder: PointStubGrounder(counter: canvasCalls, point: CGPoint(x: 333, y: 444)),
            skills: AppSkillRegistry(),
            axPickerEnabled: false,
            cropRefineRegionOverride: { _, _, _, _ in nil }
        )

        let point = await grounder.ground(
            screenshot: screenshot,
            target: "zqx nonexistent d18 target",
            displayWidthPoints: 800,
            displayHeightPoints: 600
        )

        #expect(point == CGPoint(x: 11, y: 12))
        #expect(await baseCalls.value == 1)
        #expect(await canvasCalls.value == 0)
    }

    // MARK: audit row

    @Test func routeAuditRowCarriesOwnershipTokenOnlyWhenCanvasGrounderOwns() {
        let decision = GroundingRouter.route(
            target: "the canvas placeholder",
            frontmostBundleIdentifier: "com.example.someapp",
            axUnreliable: false
        )
        #expect(decision.visualReason == .canvasConcept)

        let owned = MixtureGrounder.RouteOutcome(
            decision: decision, targetHash: "abc123", canvasGrounderOwns: true
        )
        let ownedDetail = CascadeAppModel.groundingRouteAuditDetail(owned)
        #expect(ownedDetail.contains("reason=canvas_concept"))
        #expect(ownedDetail.contains("canvasGrounder=owned"))

        // Unconfigured (the shipped default): the row is byte-identical to d15.
        let unowned = MixtureGrounder.RouteOutcome(decision: decision, targetHash: "abc123")
        #expect(!CascadeAppModel.groundingRouteAuditDetail(unowned).contains("canvasGrounder"))
    }

    // MARK: helpers

    private static func stubPoint(_ grounder: any VisualGrounder) -> CGPoint? {
        (grounder as? PointStubGrounder)?.point
    }
}

private actor CallCounter {
    private(set) var value = 0
    func bump() { value += 1 }
}

/// Minimal visual grounder that answers a fixed point and counts its calls, so
/// the tests prove WHICH grounder a request was routed to.
private struct PointStubGrounder: VisualGrounder {
    let counter: CallCounter
    let point: CGPoint

    func ground(
        screenshot: Data, target: String, displayWidthPoints: Int, displayHeightPoints: Int
    ) async -> CGPoint? {
        await counter.bump()
        return point
    }

    func groundResult(
        screenshot: Data, target: String, displayWidthPoints: Int, displayHeightPoints: Int
    ) async -> GroundingResult {
        await counter.bump()
        return GroundingResult(
            candidates: [
                GroundingCandidate(
                    point: point,
                    confidence: 0.9,
                    source: .uiTars,
                    coordinateSpace: .displayLocalAppKitPoints,
                    reason: "stub"
                )
            ],
            selectedIndex: 0
        )
    }
}
