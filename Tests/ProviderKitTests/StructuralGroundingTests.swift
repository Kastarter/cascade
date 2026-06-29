import CoreGraphics
import Foundation
import Testing

@testable import ProviderKit

/// Pins the STRUCTURAL grounding split: the computer tool is withheld and the
/// model drives the screen by NAMING targets (click_target / scroll), which the
/// runtime grounds via the injected VisualGrounder. Two contracts matter most:
/// (1) the grounder returns display-local AppKit points already, so the click is
/// taken DIRECTLY (no re-scale — a wrong scale clicks empty space); (2) structural
/// mode NEVER engages without a grounder, so the proven coordinate path always
/// has something to fall back to. See [[cascade-cu-downgrade-research]].
@MainActor
struct StructuralGroundingTests {
    /// Returns a fixed point regardless of input — exercises the glue, not a model.
    struct StubGrounder: VisualGrounder {
        let point: CGPoint?
        let counter: GroundingCallCounter?

        init(point: CGPoint?, counter: GroundingCallCounter? = nil) {
            self.point = point
            self.counter = counter
        }

        func ground(screenshot: Data, target: String, displayWidthPoints: Int, displayHeightPoints: Int) async -> CGPoint? {
            await counter?.increment()
            return point
        }

        func groundResult(screenshot: Data, target: String, displayWidthPoints: Int, displayHeightPoints: Int) async -> GroundingResult {
            await counter?.increment()
            return .legacy(point: point, source: .visualModel)
        }
    }

    struct ResultGrounder: VisualGrounder {
        let result: GroundingResult
        func ground(screenshot: Data, target: String, displayWidthPoints: Int, displayHeightPoints: Int) async -> CGPoint? {
            result.selectedPoint
        }
        func groundResult(screenshot: Data, target: String, displayWidthPoints: Int, displayHeightPoints: Int) async -> GroundingResult {
            result
        }
    }

    private let dummyFrame = Data([0xFF, 0xD8])  // stub grounder ignores content

    // MARK: isStructural — the fallback-safety contract

    @Test func structuralActiveWhenModeAndGrounderPresent() {
        let agent = ComputerUseAgent(grounder: StubGrounder(point: .zero), groundingMode: .structural)
        #expect(agent.isStructural)
    }

    @Test func structuralFallsBackWithoutGrounder() {
        // Asking for structural with no grounder must DOWNGRADE to coordinate —
        // there would be nothing to ground named targets with otherwise.
        let agent = ComputerUseAgent(groundingMode: .structural)
        #expect(!agent.isStructural)
    }

    @Test func coordinateModeIsDefaultEvenWithGrounder() {
        let agent = ComputerUseAgent(grounder: StubGrounder(point: .zero))  // mode defaults .coordinate
        #expect(!agent.isStructural)
    }

    // MARK: groundedClick — click by named target

    @Test func clickUsesGrounderPointDirectly() async {
        let agent = ComputerUseAgent(grounder: StubGrounder(point: CGPoint(x: 500, y: 600)), groundingMode: .structural)
        let action = await agent.groundedClick(["target": "the Save button"], frame: dummyFrame)
        // The grounder's display point is used as-is — NOT run through scale().
        #expect(action == .click(x: 500, y: 600))
    }

    @Test func clickHonoursDoubleAndRight() async {
        let agent = ComputerUseAgent(grounder: StubGrounder(point: CGPoint(x: 10, y: 20)), groundingMode: .structural)
        #expect(await agent.groundedClick(["target": "x", "click": "double"], frame: dummyFrame) == .doubleClick(x: 10, y: 20))
        #expect(await agent.groundedClick(["target": "x", "click": "right"], frame: dummyFrame) == .rightClick(x: 10, y: 20))
        #expect(await agent.groundedClick(["target": "x", "click": "single"], frame: dummyFrame) == .click(x: 10, y: 20))
    }

    @Test func clickNilOnMissOrNoTargetOrNoGrounder() async {
        let hit = ComputerUseAgent(grounder: StubGrounder(point: CGPoint(x: 1, y: 1)), groundingMode: .structural)
        #expect(await hit.groundedClick(["click": "double"], frame: dummyFrame) == nil)   // no target
        #expect(await hit.groundedClick(["target": ""], frame: dummyFrame) == nil)         // empty target

        let miss = ComputerUseAgent(grounder: StubGrounder(point: nil), groundingMode: .structural)
        #expect(await miss.groundedClick(["target": "x"], frame: dummyFrame) == nil)        // grounding miss

        let none = ComputerUseAgent()  // no grounder at all
        #expect(await none.groundedClick(["target": "x"], frame: dummyFrame) == nil)
    }

    // MARK: concurrent grounding cache — the pre-grounded point is used as-is

    @Test func groundedClickPrefersCacheOverGrounder() async {
        // The pre-pass grounds all targets concurrently into a cache; a cache HIT
        // must be used instead of re-calling the grounder. Grounder says (1,1),
        // cache says (42,43) → cache wins.
        let agent = ComputerUseAgent(grounder: StubGrounder(point: CGPoint(x: 1, y: 1)), groundingMode: .structural)
        let action = await agent.groundedClick(
            ["target": "Save"],
            frame: dummyFrame,
            cache: ["Save": .legacy(point: CGPoint(x: 42, y: 43))]
        )
        #expect(action == .click(x: 42, y: 43))
    }

    @Test func groundedClickCacheMissFallsToGrounder() async {
        // A target absent from the cache grounds live (single-target turns, or a
        // target the pre-pass didn't cover).
        let agent = ComputerUseAgent(grounder: StubGrounder(point: CGPoint(x: 1, y: 1)), groundingMode: .structural)
        let action = await agent.groundedClick(
            ["target": "Save"],
            frame: dummyFrame,
            cache: ["Other": .legacy(point: CGPoint(x: 9, y: 9))]
        )
        #expect(action == .click(x: 1, y: 1))
    }

    @Test func groundedClickCachedMissReturnsNil() async {
        // A cached MISS (the pre-pass grounded it and found nothing) returns nil
        // without re-grounding — behaviour-identical to a live miss.
        let agent = ComputerUseAgent(grounder: StubGrounder(point: CGPoint(x: 1, y: 1)), groundingMode: .structural)
        let action = await agent.groundedClick(
            ["target": "Save"],
            frame: dummyFrame,
            cache: ["Save": .legacy(point: nil)]
        )
        #expect(action == nil)
    }

    @Test func persistentGroundingCacheSuppressesRepeatedGrounderCalls() async throws {
        let cache = GroundingCache()
        let counter = GroundingCallCounter()
        let agent = ComputerUseAgent(
            grounder: StubGrounder(point: CGPoint(x: 7, y: 8), counter: counter),
            groundingMode: .structural,
            groundingCache: cache,
            groundingCacheKeyProvider: { _, target, width, height, mode in
                makeGroundingCacheKey(targetText: target, displayWidthPoints: width, displayHeightPoints: height, mode: mode)
            }
        )

        #expect(await agent.groundedClick(["target": "Save"], frame: dummyFrame) == .click(x: 7, y: 8))
        #expect(await agent.groundedClick(["target": "Save"], frame: dummyFrame) == .click(x: 7, y: 8))

        #expect(await counter.value() == 1)
    }

    @Test func persistentGroundingCacheMissesWhenStateKeyChanges() async throws {
        let cache = GroundingCache()
        let counter = GroundingCallCounter()
        let agent = ComputerUseAgent(
            grounder: StubGrounder(point: CGPoint(x: 3, y: 4), counter: counter),
            groundingMode: .structural,
            groundingCache: cache,
            groundingCacheKeyProvider: { frame, target, width, height, mode in
                let hash = UInt64(frame.last ?? 0)
                return makeGroundingCacheKey(
                    targetText: target,
                    displayWidthPoints: width,
                    displayHeightPoints: height,
                    screenHash: hash,
                    gridHashes: [hash],
                    mode: mode
                )
            }
        )

        _ = await agent.groundedClick(["target": "Save"], frame: Data([1]))
        _ = await agent.groundedClick(["target": "Save"], frame: Data([2]))

        #expect(await counter.value() == 2)
    }

    @Test func persistentNegativeMissShortCircuitsGrounder() async throws {
        let cache = GroundingCache(negativeMissTTL: 30)
        let counter = GroundingCallCounter()
        let agent = ComputerUseAgent(
            grounder: StubGrounder(point: nil, counter: counter),
            groundingMode: .structural,
            groundingCache: cache,
            groundingCacheKeyProvider: { _, target, width, height, mode in
                makeGroundingCacheKey(targetText: target, displayWidthPoints: width, displayHeightPoints: height, mode: mode)
            }
        )

        #expect(await agent.groundedClick(["target": "Missing"], frame: dummyFrame) == nil)
        #expect(await agent.groundedClick(["target": "Missing"], frame: dummyFrame) == nil)

        #expect(await counter.value() == 1)
    }

    @Test func groundedClickBlocksRejectedResultWithPoint() async {
        let result = GroundingResult(
            candidates: [
                GroundingCandidate(
                    point: CGPoint(x: 11, y: 22),
                    confidence: 0.95,
                    source: .accessibility,
                    coordinateSpace: .displayLocalAppKitPoints,
                    candidateID: "ax-dead"
                )
            ],
            selectedIndex: 0,
            verifierVerdict: .reject,
            verifierFailureKind: .lowEvidence
        )
        let agent = ComputerUseAgent(grounder: ResultGrounder(result: result), groundingMode: .structural)

        #expect(await agent.groundedClick(["target": "Save"], frame: dummyFrame) == nil)
        #expect(agent.lastGroundMiss == "Save")
        #expect(agent.lastGroundCandidateID == "ax-dead")
    }

    // MARK: groundedScroll — scroll over a named area (or the screen center)

    @Test func scrollOverNamedTargetUsesGrounderPoint() async {
        let agent = ComputerUseAgent(grounder: StubGrounder(point: CGPoint(x: 100, y: 200)), groundingMode: .structural)
        let action = await agent.groundedScroll(["direction": "down", "amount": 5, "target": "the message list"], frame: dummyFrame)
        #expect(action == .scroll(x: 100, y: 200, direction: "down", amount: 5))
    }

    @Test func scrollWithoutTargetFallsToCenterAndDefaults() async {
        // displayW/displayH are 0 until begin() — center is (0,0), and a bare scroll
        // defaults to down / 3 clicks. Never nil: a scroll always has a fallback.
        let agent = ComputerUseAgent(grounder: StubGrounder(point: CGPoint(x: 9, y: 9)), groundingMode: .structural)
        #expect(await agent.groundedScroll(["direction": "up"], frame: dummyFrame) == .scroll(x: 0, y: 0, direction: "up", amount: 3))
        #expect(await agent.groundedScroll([:], frame: dummyFrame) == .scroll(x: 0, y: 0, direction: "down", amount: 3))
    }

    // MARK: tool definitions — the structural tool contract

    @Test func structuralToolNames() {
        #expect(ComputerUseAgent.clickTargetToolDefinition()["name"] as? String == "click_target")
        #expect(ComputerUseAgent.typeTextToolDefinition()["name"] as? String == "type_text")
        #expect(ComputerUseAgent.pressKeyToolDefinition()["name"] as? String == "press_key")
        #expect(ComputerUseAgent.scrollTargetToolDefinition()["name"] as? String == "scroll")
        #expect(ComputerUseAgent.waitToolDefinition()["name"] as? String == "wait")
        #expect(ComputerUseAgent.openAppToolDefinition()["name"] as? String == "open_app")
        #expect(ComputerUseAgent.openURLToolDefinition()["name"] as? String == "open_url")
    }

    @Test func everyStructuralToolDefIsValidJSON() {
        for def in [
            ComputerUseAgent.clickTargetToolDefinition(),
            ComputerUseAgent.typeTextToolDefinition(),
            ComputerUseAgent.pressKeyToolDefinition(),
            ComputerUseAgent.scrollTargetToolDefinition(),
            ComputerUseAgent.waitToolDefinition(),
        ] {
            #expect(JSONSerialization.isValidJSONObject(def))
        }
    }

    @Test func structuralPromptNamesTargetsNotCoordinates() {
        let p = ComputerUseAgent.structuralSystemPrompt
        #expect(p.contains("click_target"))
        #expect(p.contains("fill_target"))
        // The whole point: it must not instruct the model to use the computer tool,
        // and must forbid pixel coordinates.
        #expect(!p.contains("computer tool"))
        #expect(p.lowercased().contains("coordinate"))
    }
}

actor GroundingCallCounter {
    private var calls = 0

    func increment() {
        calls += 1
    }

    func value() -> Int {
        calls
    }
}

private func makeGroundingCacheKey(
    targetText: String = "Save",
    appName: String = "Mail",
    bundleIdentifier: String? = "com.apple.mail",
    windowTitle: String? = "Inbox",
    displayWidthPoints: Int = 0,
    displayHeightPoints: Int = 0,
    screenHash: UInt64 = 0xCAFE,
    gridHashes: [UInt64] = [0xCAFE],
    mode: GroundingCacheMode = .structural
) -> GroundingCacheKey? {
    GroundingCacheKey(
        targetText: targetText,
        appName: appName,
        bundleIdentifier: bundleIdentifier,
        windowTitle: windowTitle,
        displayWidthPoints: displayWidthPoints,
        displayHeightPoints: displayHeightPoints,
        screenHash: screenHash,
        gridHashes: gridHashes,
        mode: mode
    )
}
