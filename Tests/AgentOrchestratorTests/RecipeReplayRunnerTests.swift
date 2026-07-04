import XCTest
import CoreGraphics
@testable import AgentOrchestrator
@testable import AppShell
import CascadeMemory
import ComputerUseKit

/// §4b (t11) exercised ON-path tests: the full RecipeReplayRunner ladder runs
/// against fake Hooks that record every call — fully headless, no TCC, no screen.
final class RecipeReplayRunnerTests: XCTestCase {

    // MARK: - Fake hook recorder

    /// Lock-guarded call log shared by the scripted hooks.
    private final class HookLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [String] = []
        private var _clickPoints: [CGPoint] = []
        private var _axPressPoints: [CGPoint] = []
        private var _performOtherOrders: [Int] = []
        private var _demoted: [ReplayAnchor] = []
        private var _promotedTiers: [String] = []
        private var _promotedScores: [Double?] = []
        private var _promotedSources: [AnchorDriftScorer.AnchorSource?] = []
        private var _verifications: [ReplayVerification]

        init(verifications: [ReplayVerification] = []) {
            _verifications = verifications
        }

        func call(_ name: String) {
            lock.lock(); defer { lock.unlock() }
            _calls.append(name)
        }

        func click(_ point: CGPoint) {
            lock.lock(); defer { lock.unlock() }
            _clickPoints.append(point)
        }

        func axPress(_ point: CGPoint) {
            lock.lock(); defer { lock.unlock() }
            _axPressPoints.append(point)
        }

        func performOther(_ order: Int) {
            lock.lock(); defer { lock.unlock() }
            _performOtherOrders.append(order)
        }

        func demote(_ anchor: ReplayAnchor) {
            lock.lock(); defer { lock.unlock() }
            _demoted.append(anchor)
        }

        func promote(_ tier: String, score: Double?, source: AnchorDriftScorer.AnchorSource?) {
            lock.lock(); defer { lock.unlock() }
            _promotedTiers.append(tier)
            _promotedScores.append(score)
            _promotedSources.append(source)
        }

        /// Next scripted verification; defaults to `.unchanged` when exhausted.
        func nextVerification() -> ReplayVerification {
            lock.lock(); defer { lock.unlock() }
            guard !_verifications.isEmpty else { return .unchanged }
            return _verifications.removeFirst()
        }

        var calls: [String] { lock.lock(); defer { lock.unlock() }; return _calls }
        var clickPoints: [CGPoint] { lock.lock(); defer { lock.unlock() }; return _clickPoints }
        var axPressPoints: [CGPoint] { lock.lock(); defer { lock.unlock() }; return _axPressPoints }
        var performOtherOrders: [Int] { lock.lock(); defer { lock.unlock() }; return _performOtherOrders }
        var demoted: [ReplayAnchor] { lock.lock(); defer { lock.unlock() }; return _demoted }
        var promotedTiers: [String] { lock.lock(); defer { lock.unlock() }; return _promotedTiers }
        var promotedScores: [Double?] { lock.lock(); defer { lock.unlock() }; return _promotedScores }
        var promotedSources: [AnchorDriftScorer.AnchorSource?] { lock.lock(); defer { lock.unlock() }; return _promotedSources }
    }

    private func makeHooks(
        log: HookLog,
        startStateMismatch: String? = nil,
        modalTitle: String? = nil,
        axUnreliableOrders: Set<Int> = [],
        anchors: [ReplayAnchor] = [],
        ensemble: [AXElementResolver.RankedCandidate] = [],
        ocrPoint: CGPoint? = nil,
        visionPoint: CGPoint? = nil
    ) -> RecipeReplayRunner.Hooks {
        RecipeReplayRunner.Hooks(
            isStopRequested: {
                log.call("isStopRequested")
                return false
            },
            activateApp: { _, _ in
                log.call("activateApp")
            },
            startStateMismatch: { _ in
                log.call("startStateMismatch")
                return startStateMismatch
            },
            unexpectedModalTitle: {
                log.call("unexpectedModalTitle")
                return modalTitle
            },
            uiFingerprint: {
                log.call("uiFingerprint")
                return 42
            },
            stepAXUnreliable: { step in
                log.call("stepAXUnreliable")
                return axUnreliableOrders.contains(step.order)
            },
            mergedAnchors: { _, _ in
                log.call("mergedAnchors")
                return anchors
            },
            ensembleCandidates: { _, _ in
                log.call("ensembleCandidates")
                return ensemble
            },
            axPress: { point in
                log.call("axPress")
                log.axPress(point)
                return false
            },
            click: { _, point in
                log.call("click")
                log.click(point)
            },
            performOther: { step in
                log.call("performOther")
                log.performOther(step.order)
            },
            ocrRegroundPoint: { _ in
                log.call("ocrRegroundPoint")
                return ocrPoint
            },
            visionRegroundPoint: { _, _ in
                log.call("visionRegroundPoint")
                return visionPoint
            },
            verifyChanged: { _ in
                log.call("verifyChanged")
                return log.nextVerification()
            },
            promoteVerified: { _, _, _, tier, score, source in
                log.call("promoteVerified")
                log.promote(tier, score: score, source: source)
            },
            demoteAnchor: { anchor, _ in
                log.call("demoteAnchor")
                log.demote(anchor)
            },
            audit: { _, _ in },
            progress: { _, _ in }
        )
    }

    private func clickStep(order: Int = 1, x: Double = 100, y: Double = 200) -> RecipeStep {
        RecipeStep(
            order: order,
            kind: .click,
            x: x,
            y: y,
            text: "Save",
            appName: "TestApp",
            bundleIdentifier: "com.test.app",
            ocrAnchor: "Save"
        )
    }

    private func candidate(id: String, x: Double, y: Double, confidence: Double) -> AXElementResolver.RankedCandidate {
        AXElementResolver.RankedCandidate(
            candidate: AXElementResolver.Candidate(
                id: id,
                descriptor: AXTargetDescriptorV2(label: "Save", role: "AXButton", identifier: id),
                center: CGPoint(x: x, y: y)
            ),
            score: confidence,
            confidence: confidence
        )
    }

    // MARK: - (1) Pre-flight state gate is a REPLAN, never a pause (ecc1b90)

    func testStateGateIsReplanNotPause() async {
        let log = HookLog()
        let hooks = makeHooks(log: log, startStateMismatch: "wrong app is frontmost")
        let outcome = await RecipeReplayRunner().run(steps: [clickStep()], hooks: hooks)
        XCTAssertEqual(
            outcome,
            .replan(.wrongStartState(expected: "TestApp", actual: "wrong app is frontmost"))
        )
        XCTAssertTrue(log.clickPoints.isEmpty, "state gate must fire before any click")
        XCTAssertTrue(log.axPressPoints.isEmpty, "state gate must fire before any AXPress")
        XCTAssertTrue(log.performOtherOrders.isEmpty)
    }

    // MARK: - (2) Unchanged verify retries the NEXT candidate — never the recorded pixel

    func testUnchangedVerifyRetriesNextCandidateNeverRecordedPoint() async {
        let recorded = CGPoint(x: 100, y: 200)
        let first = CGPoint(x: 10, y: 20)
        let second = CGPoint(x: 300, y: 400)
        let log = HookLog(verifications: [.unchanged, .changed])
        let hooks = makeHooks(
            log: log,
            ensemble: [
                candidate(id: "a", x: first.x, y: first.y, confidence: 0.95),
                candidate(id: "b", x: second.x, y: second.y, confidence: 0.80),
            ]
        )
        let outcome = await RecipeReplayRunner().run(
            steps: [clickStep(x: recorded.x, y: recorded.y)],
            hooks: hooks
        )
        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(log.clickPoints, [first, second], "second candidate is the retry target")
        XCTAssertFalse(log.clickPoints.contains(recorded), "the recorded pixel is NEVER clicked in V2")
        XCTAssertFalse(log.axPressPoints.contains(recorded), "the recorded pixel is NEVER pressed in V2")
    }

    // MARK: - (3) Ladder order: ensemble → OCR → vision → replan(.targetNotFound)

    func testLadderOrderEnsembleThenOCRThenVisionThenReplan() async {
        let log = HookLog()
        let hooks = makeHooks(log: log) // empty candidates, ocr nil, vision nil
        let outcome = await RecipeReplayRunner().run(steps: [clickStep()], hooks: hooks)
        XCTAssertEqual(outcome, .replan(.targetNotFound(stepOrder: 1)))
        let ladderCalls = log.calls.filter {
            ["ensembleCandidates", "ocrRegroundPoint", "visionRegroundPoint"].contains($0)
        }
        XCTAssertEqual(ladderCalls, ["ensembleCandidates", "ocrRegroundPoint", "visionRegroundPoint"])
        XCTAssertTrue(log.clickPoints.isEmpty, "exhaustion degrades to MISSED, never a stale click")
    }

    // MARK: - (4) B5's honest limit stays DECLARED: parameter steps never retype

    func testParameterStepIsDeclaredLimit() async {
        let step = RecipeStep(
            order: 3,
            kind: .type,
            text: "stale-order-8841",
            appName: "TestApp",
            isParameter: true
        )
        let log = HookLog()
        let hooks = makeHooks(log: log)
        let outcome = await RecipeReplayRunner().run(steps: [step], hooks: hooks)
        XCTAssertEqual(outcome, .replan(.parameterNeedsLiveValue(stepOrder: 3)))
        XCTAssertTrue(log.performOtherOrders.isEmpty, "B5: never retype the stale value")
        XCTAssertTrue(log.clickPoints.isEmpty)
    }

    // MARK: - (5) Healed anchor is tried before live ensemble and demoted on failure

    func testHealedAnchorTriedBeforeLiveEnsembleAndDemotedOnFailure() async {
        let healedPoint = CGPoint(x: 5, y: 6)
        let livePoint = CGPoint(x: 50, y: 60)
        let healed = ReplayAnchor(
            point: healedPoint,
            anchorHash: "healed-hash",
            verifiedScore: 0.9,
            source: "target_cache_ax",
            origin: .healed
        )
        let log = HookLog(verifications: [.unchanged, .changed])
        let hooks = makeHooks(
            log: log,
            anchors: [healed],
            ensemble: [candidate(id: "live", x: livePoint.x, y: livePoint.y, confidence: 0.9)]
        )
        let outcome = await RecipeReplayRunner().run(steps: [clickStep()], hooks: hooks)
        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(log.clickPoints, [healedPoint, livePoint], "healed anchor first, then live ensemble")
        XCTAssertEqual(log.demoted.count, 1)
        XCTAssertEqual(log.demoted.first?.origin, .healed)
        XCTAssertEqual(log.demoted.first?.point, healedPoint)
        XCTAssertEqual(log.promotedTiers, ["ax"], "the verified live candidate is what gets promoted")
    }

    // MARK: - (6) Cross-step unverified streak of two ⇒ replan(.driftNoEffect)

    func testDriftStreakOfTwoReplans() async {
        // Every verification reads .unchanged (scripted list empty ⇒ default).
        let log = HookLog()
        let hooks = makeHooks(
            log: log,
            ensemble: [candidate(id: "only", x: 10, y: 20, confidence: 0.9)]
        )
        let outcome = await RecipeReplayRunner().run(
            steps: [clickStep(order: 1), clickStep(order: 2)],
            hooks: hooks
        )
        XCTAssertEqual(outcome, .replan(.driftNoEffect(stepOrder: 2)), "two unverified steps in a row trip the drift replan")
        XCTAssertEqual(log.clickPoints.count, 2, "one candidate clicked per step")
    }

    // MARK: - (7) axUnreliable (canvas app): AX tiers + fingerprint verify skipped

    func testAXUnreliableStepSkipsAXTiersAndVerify() async {
        let ocr = CGPoint(x: 77, y: 88)
        let log = HookLog()
        let hooks = makeHooks(
            log: log,
            axUnreliableOrders: [1],
            // A live candidate that MUST NOT be ranked or pressed for a canvas app.
            ensemble: [candidate(id: "phantom", x: 1, y: 2, confidence: 0.99)],
            ocrPoint: ocr
        )
        let outcome = await RecipeReplayRunner().run(steps: [clickStep()], hooks: hooks)
        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(log.clickPoints, [ocr], "canvas step grounds by OCR, never the AX ensemble")
        XCTAssertFalse(log.calls.contains("ensembleCandidates"), "AX ranking is an invalid mechanism for axUnreliable apps")
        XCTAssertFalse(log.calls.contains("axPress"), "AXPress is an invalid mechanism for axUnreliable apps")
        XCTAssertFalse(log.calls.contains("verifyChanged"), "fingerprint verify is skipped so canvas apps don't false-pause")
        XCTAssertFalse(log.calls.contains("mergedAnchors"), "cache anchors are skipped for axUnreliable apps (V1 cache-skip parity)")
        XCTAssertTrue(log.promotedTiers.isEmpty, "no effect confirmation ⇒ no promote (SEQ-29)")
    }

    func testAXUnreliableStepLeavesUnverifiedStreakUntouched() async {
        // Normal unverified step (streak 1) → canvas step (streak UNTOUCHED) →
        // normal unverified step trips the drift replan at streak 2: the canvas
        // step neither resets nor advances the cross-step streak (V1 parity).
        let log = HookLog()
        let hooks = makeHooks(
            log: log,
            axUnreliableOrders: [2],
            ensemble: [candidate(id: "only", x: 10, y: 20, confidence: 0.9)],
            ocrPoint: CGPoint(x: 77, y: 88)
        )
        let outcome = await RecipeReplayRunner().run(
            steps: [clickStep(order: 1), clickStep(order: 2), clickStep(order: 3)],
            hooks: hooks
        )
        XCTAssertEqual(
            outcome,
            .replan(.driftNoEffect(stepOrder: 3)),
            "the canvas step must not reset the streak the two normal steps accumulate"
        )
    }

    func testAXUnreliableExhaustionIsMissedNeverRecordedPixel() async {
        let recorded = CGPoint(x: 100, y: 200)
        let log = HookLog()
        let hooks = makeHooks(log: log, axUnreliableOrders: [1]) // no OCR, no vision
        let outcome = await RecipeReplayRunner().run(
            steps: [clickStep(x: recorded.x, y: recorded.y)],
            hooks: hooks
        )
        XCTAssertEqual(outcome, .replan(.targetNotFound(stepOrder: 1)))
        XCTAssertTrue(log.clickPoints.isEmpty, "exhaustion degrades to MISSED, never the recorded pixel (LAW 7)")
    }

    // MARK: - (8) Promote carries the verified score + typed source (SEQ-29)

    func testPromoteCarriesVerifiedScoreAndSource() async {
        let log = HookLog(verifications: [.unchanged, .changed])
        let hooks = makeHooks(
            log: log,
            ensemble: [
                candidate(id: "a", x: 10, y: 20, confidence: 0.95),
                candidate(id: "b", x: 300, y: 400, confidence: 0.80),
            ]
        )
        let outcome = await RecipeReplayRunner().run(steps: [clickStep()], hooks: hooks)
        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(log.promotedTiers, ["ax"])
        XCTAssertEqual(log.promotedScores, [0.80], "the VERIFIED candidate's confidence is persisted, not dropped")
        XCTAssertEqual(log.promotedSources, [.accessibility])
    }

    // MARK: - (9) Flag ships OFF: absent key reads false

    func testReplayRunnerV2DefaultOff() {
        // Fresh suite — NEVER touch .standard here, or the test itself would
        // flip the live default (LAW 3).
        let suiteName = "cascade.tests.replayRunnerV2.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("could not create test defaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        XCTAssertFalse(CascadeAppModel.replayRunnerV2Enabled(defaults))
        XCTAssertEqual(CascadeAppModel.experimentalReplayRunnerV2Key, "cascade.replayRunnerV2")
    }
}
