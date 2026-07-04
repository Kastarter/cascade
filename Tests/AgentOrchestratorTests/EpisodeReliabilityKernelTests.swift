import Foundation
import PerceptionCore
import Testing

@testable import AgentOrchestrator

// Exercises the real ON-path computation of the EpisodeReliabilityKernel shadow
// (cascade.reliabilityKernel): signature math parity, the no-effect nudge→bail
// ladder, the 336263d settle re-check, exemptions, idle tiering, the 4f62dab
// fail-fast, kernel-extra repetition + anti-oscillation, the forced-validator
// predicate, and the LOAD-BEARING StateSignatureProvider seam (the kernel's
// verdict math reads the provider, so a decorative feed cannot pass).
// Run focused: swift test --filter EpisodeReliabilityKernelTests

private func makeKernel(
    threshold: Int = 2,
    stallLimit: Int = 3,
    signatures: StateSignatureProvider? = nil
) -> EpisodeReliabilityKernel {
    EpisodeReliabilityKernel(
        config: .init(noEffectSignatureThreshold: threshold, noEffectStallLimit: stallLimit),
        signatures: signatures
    )
}

private func sig(_ hashes: [UInt64]) -> StateSignature {
    EpisodeReliabilityKernel.gridSignature(hashes)
}

private func actedTurn(
    _ turn: Int,
    before: StateSignature?,
    after: StateSignature?,
    settled: StateSignature? = nil,
    expectsChange: Bool = true,
    groundMiss: EpisodeReliabilityKernel.GroundMiss? = nil,
    actionSignatureHash: String? = "action-hash"
) -> EpisodeReliabilityKernel.TurnObservation {
    EpisodeReliabilityKernel.TurnObservation(
        turn: turn,
        turnClass: .acted(expectsChange: expectsChange),
        before: before,
        after: after,
        settled: settled,
        groundMiss: groundMiss,
        actionSignatureHash: actionSignatureHash
    )
}

// MARK: - (1) Hamming parity pin with PerceptualHash.isDuplicateGrid semantics

@Test func kernelHammingParityDistanceTwoIsDuplicate() {
    // Per-region XOR popcount == 2 in one region, 0 in the other → duplicate at
    // threshold 2 (isDuplicateGrid requires EVERY region within threshold).
    let a = sig([0b11, 0x0, 0xdeadbeef])
    let b = sig([0b00, 0x0, 0xdeadbeef])
    #expect(EpisodeReliabilityKernel.isDuplicate(a, of: b, threshold: 2))
}

@Test func kernelHammingParityDistanceThreeIsChanged() {
    let a = sig([0b111, 0x0])
    let b = sig([0b000, 0x0])
    #expect(!EpisodeReliabilityKernel.isDuplicate(a, of: b, threshold: 2))
}

@Test func kernelHammingParityHighBitsAndMixedRegions() {
    // Distance spread over high bits, every region within threshold.
    let a = sig([0x8000000000000001, 0xffffffffffffffff])
    let b = sig([0x0000000000000001, 0xfffffffffffffffe])
    // Region 0 popcount 1, region 1 popcount 1 → duplicate at threshold 2.
    #expect(EpisodeReliabilityKernel.isDuplicate(a, of: b, threshold: 2))
    // Threshold 0 rejects it.
    #expect(!EpisodeReliabilityKernel.isDuplicate(a, of: b, threshold: 0))
}

@Test func kernelHammingParityCountMismatchAndEmptyAreFalse() {
    #expect(!EpisodeReliabilityKernel.isDuplicate(sig([1]), of: sig([1, 2]), threshold: 64))
    #expect(!EpisodeReliabilityKernel.isDuplicate(sig([]), of: sig([]), threshold: 64))
}

@Test func kernelNonGridKindsCompareByExactEquality() {
    // The future WebStateSignature seam: non-gridHashes kinds are equal-or-changed.
    let a = StateSignature(kind: "web", value: "https://example.com|Title")
    let b = StateSignature(kind: "web", value: "https://example.com|Title")
    let c = StateSignature(kind: "web", value: "https://example.com|Other")
    #expect(EpisodeReliabilityKernel.isDuplicate(a, of: b, threshold: 2))
    #expect(!EpisodeReliabilityKernel.isDuplicate(a, of: c, threshold: 2))
}

@Test func kernelGridSignatureRoundTripsThroughIsDuplicate() {
    let hashes: [UInt64] = [0, UInt64.max, 0x123456789abcdef0]
    let encoded = sig(hashes)
    #expect(encoded.kind == "gridHashes")
    // Identical grids are duplicates even at threshold 0.
    #expect(EpisodeReliabilityKernel.isDuplicate(encoded, of: sig(hashes), threshold: 0))
}

// MARK: - (2) No-effect ladder: nudge at streak 1..limit-1, bail at the limit

@Test func kernelNoEffectLadderNudgesThenBailsAtInjectedLimit() async {
    var kernel = makeKernel(stallLimit: 3)
    let frame = sig([7, 7, 7])
    #expect(await kernel.observe(actedTurn(1, before: frame, after: frame)) == .nudge(.noEffect))
    #expect(await kernel.observe(actedTurn(2, before: frame, after: frame)) == .nudge(.noEffect))
    #expect(await kernel.observe(actedTurn(3, before: frame, after: frame)) == .bail(.noEffectStall))
}

@Test func kernelNoEffectStreakResetsOnRealChange() async {
    var kernel = makeKernel(stallLimit: 2)
    let frame = sig([7, 7, 7])
    let changed = sig([0xffff, 7, 7])
    #expect(await kernel.observe(actedTurn(1, before: frame, after: frame)) == .nudge(.noEffect))
    // A visibly-changed acting turn resets the streak…
    #expect(await kernel.observe(actedTurn(2, before: frame, after: changed)) == .proceed)
    // …so the next duplicate is streak 1 again (nudge, not bail).
    #expect(await kernel.observe(actedTurn(3, before: changed, after: changed)) == .nudge(.noEffect))
}

// MARK: - (3) Settle re-check (336263d): settled frame differs → cleared + reset

@Test func kernelSettleRecheckClearsAndResetsStreak() async {
    var kernel = makeKernel(stallLimit: 2)
    let frame = sig([7, 7, 7])
    let settled = sig([0xffff, 7, 7])
    // Suspicious after-frame, but the settled frame differs beyond threshold —
    // the effect rendered late; verdict is recheckCleared and the streak resets.
    #expect(await kernel.observe(actedTurn(1, before: frame, after: frame, settled: settled)) == .recheckCleared)
    // Streak was reset: a following duplicate is a nudge, not the limit-2 bail.
    #expect(await kernel.observe(actedTurn(2, before: settled, after: settled)) == .nudge(.noEffect))
}

@Test func kernelSettleRecheckConfirmedDuplicateStillCounts() async {
    var kernel = makeKernel(stallLimit: 3)
    let frame = sig([7, 7, 7])
    // The settled frame is ALSO a duplicate — the suspicion is confirmed on the
    // settled signature, exactly as the inline 400ms re-check decides.
    #expect(await kernel.observe(actedTurn(1, before: frame, after: frame, settled: frame)) == .nudge(.noEffect))
}

// MARK: - (4) Predicted-effect exemption: expectsChange:false leaves streak untouched

@Test func kernelCopyWaitExemptTurnLeavesStreakUntouched() async {
    var kernel = makeKernel(stallLimit: 2)
    let frame = sig([7, 7, 7])
    #expect(await kernel.observe(actedTurn(1, before: frame, after: frame)) == .nudge(.noEffect))
    // A copy/wait-exempt acting turn with identical frames: proceed, streak KEPT.
    #expect(await kernel.observe(actedTurn(2, before: frame, after: frame, expectsChange: false)) == .proceed)
    // Streak was untouched (still 1), so the next duplicate hits the limit-2 bail.
    #expect(await kernel.observe(actedTurn(3, before: frame, after: frame)) == .bail(.noEffectStall))
}

// MARK: - (5) Idle tiering: nudge at 2, bail at 3, acted resets

@Test func kernelIdleTieringNudgesAtTwoBailsAtThree() async {
    var kernel = makeKernel()
    let idle = EpisodeReliabilityKernel.TurnObservation(turn: 1, turnClass: .idle)
    #expect(await kernel.observe(idle) == .proceed)
    #expect(await kernel.observe(EpisodeReliabilityKernel.TurnObservation(turn: 2, turnClass: .observationOnly)) == .nudge(.idleActNow))
    #expect(await kernel.observe(EpisodeReliabilityKernel.TurnObservation(turn: 3, turnClass: .idle)) == .bail(.idleStall))
}

@Test func kernelIdleCounterResetsOnActedTurn() async {
    var kernel = makeKernel()
    let before = sig([1, 2, 3])
    let after = sig([0xffff, 2, 3])
    #expect(await kernel.observe(EpisodeReliabilityKernel.TurnObservation(turn: 1, turnClass: .idle)) == .proceed)
    #expect(await kernel.observe(EpisodeReliabilityKernel.TurnObservation(turn: 2, turnClass: .idle)) == .nudge(.idleActNow))
    // Acting resets the counter…
    #expect(await kernel.observe(actedTurn(3, before: before, after: after)) == .proceed)
    // …so the next idle turn is the FIRST of a new run (proceed, not bail).
    #expect(await kernel.observe(EpisodeReliabilityKernel.TurnObservation(turn: 4, turnClass: .idle)) == .proceed)
    #expect(await kernel.observe(EpisodeReliabilityKernel.TurnObservation(turn: 5, turnClass: .idle)) == .nudge(.idleActNow))
}

// MARK: - (6) Fail-fast (4f62dab): two zero-control misses bail; controls reset

@Test func kernelTwoZeroControlMissesBail() async {
    var kernel = makeKernel()
    let before = sig([1, 2, 3])
    let after = sig([0xffff, 2, 3])
    let emptyMiss = EpisodeReliabilityKernel.GroundMiss(targetHash: "h1", visibleControlCount: 0)
    #expect(await kernel.observe(actedTurn(1, before: before, after: after, groundMiss: emptyMiss)) == .nudge(.groundMiss))
    #expect(await kernel.observe(actedTurn(2, before: after, after: before, groundMiss: emptyMiss)) == .bail(.emptyViewMisses))
}

@Test func kernelControlsPresentMissResetsEmptyViewCounter() async {
    var kernel = makeKernel()
    let before = sig([1, 2, 3])
    let after = sig([0xffff, 2, 3])
    let emptyMiss = EpisodeReliabilityKernel.GroundMiss(targetHash: "h1", visibleControlCount: 0)
    let presentMiss = EpisodeReliabilityKernel.GroundMiss(targetHash: "h2", visibleControlCount: 9)
    #expect(await kernel.observe(actedTurn(1, before: before, after: after, groundMiss: emptyMiss)) == .nudge(.groundMiss))
    // A miss on a controls-present view still nudges, but RESETS the fail-fast counter.
    #expect(await kernel.observe(actedTurn(2, before: after, after: before, groundMiss: presentMiss)) == .nudge(.groundMiss))
    // The next zero-control miss is #1 of a fresh run — nudge, not bail.
    #expect(await kernel.observe(actedTurn(3, before: before, after: after, groundMiss: emptyMiss)) == .nudge(.groundMiss))
    #expect(await kernel.observe(actedTurn(4, before: after, after: before, groundMiss: emptyMiss)) == .bail(.emptyViewMisses))
}

@Test func kernelNoEffectOutranksGroundMissNudge() async {
    // Verdict precedence: noEffect > groundMiss (inline: the no-effect nudge
    // text OVERWRITES, the miss note is appended).
    var kernel = makeKernel(stallLimit: 3)
    let frame = sig([7, 7, 7])
    let presentMiss = EpisodeReliabilityKernel.GroundMiss(targetHash: "h", visibleControlCount: 4)
    #expect(await kernel.observe(actedTurn(1, before: frame, after: frame, groundMiss: presentMiss)) == .nudge(.noEffect))
}

// MARK: - (7) Repetition extra-signal (8aaea59 lineage) — never a verdict

@Test func kernelRepetitionExtraSignalCountsWithoutChangingVerdict() async {
    var kernel = makeKernel()
    let after = sig([42, 42, 42])
    // Three acting turns, SAME action-signature hash, UNCHANGED after-signature,
    // before differing from after so the no-effect path never fires.
    for turn in 1...3 {
        let before = sig([UInt64(turn) &* 0xffff, 1, 2])
        let verdict = await kernel.observe(actedTurn(turn, before: before, after: after, actionSignatureHash: "same-hash"))
        #expect(verdict == .proceed)
    }
    #expect(kernel.extraSignals.repetitionCount == 3)
    #expect(kernel.extraSignals.sawEscalateCondition)
}

@Test func kernelRepetitionResetsOnDifferentAction() async {
    var kernel = makeKernel()
    let after = sig([42, 42, 42])
    let before = sig([0xffff, 1, 2])
    _ = await kernel.observe(actedTurn(1, before: before, after: after, actionSignatureHash: "a"))
    _ = await kernel.observe(actedTurn(2, before: before, after: after, actionSignatureHash: "a"))
    #expect(kernel.extraSignals.repetitionCount == 2)
    _ = await kernel.observe(actedTurn(3, before: before, after: after, actionSignatureHash: "b"))
    #expect(kernel.extraSignals.repetitionCount == 1)
    #expect(!kernel.extraSignals.sawEscalateCondition)
}

// MARK: - (8) Anti-oscillation extra-signal (bfe89d6/6b98567 shape) — never a verdict

@Test func kernelOscillationCountsAlternationAndRaisesEscalateSignal() async {
    var kernel = makeKernel()
    let after = sig([42, 42, 42])
    let before = sig([0xffff, 1, 2])
    // A → B: no alternation yet.
    #expect(await kernel.observe(actedTurn(1, before: before, after: after, actionSignatureHash: "a")) == .proceed)
    #expect(await kernel.observe(actedTurn(2, before: before, after: after, actionSignatureHash: "b")) == .proceed)
    #expect(kernel.extraSignals.oscillationCount == 0)
    // A → B → A: first alternation hit. Repetition is BLIND to this (resets to
    // 1 every turn) — exactly the gap the oscillation counter closes.
    #expect(await kernel.observe(actedTurn(3, before: before, after: after, actionSignatureHash: "a")) == .proceed)
    #expect(kernel.extraSignals.oscillationCount == 1)
    #expect(kernel.extraSignals.repetitionCount == 1)
    #expect(!kernel.extraSignals.sawEscalateCondition)
    // A → B → A → B: full ping-pong — the kernel-extra escalate signal fires,
    // the verdict stays proceed (extra signals are never a verdict).
    #expect(await kernel.observe(actedTurn(4, before: before, after: after, actionSignatureHash: "b")) == .proceed)
    #expect(kernel.extraSignals.oscillationCount == 2)
    #expect(kernel.extraSignals.sawEscalateCondition)
}

@Test func kernelOscillationResetsOnThirdDistinctOrRepeatedAction() async {
    var kernel = makeKernel()
    let after = sig([42, 42, 42])
    let before = sig([0xffff, 1, 2])
    _ = await kernel.observe(actedTurn(1, before: before, after: after, actionSignatureHash: "a"))
    _ = await kernel.observe(actedTurn(2, before: before, after: after, actionSignatureHash: "b"))
    _ = await kernel.observe(actedTurn(3, before: before, after: after, actionSignatureHash: "a"))
    #expect(kernel.extraSignals.oscillationCount == 1)
    // A third distinct action breaks the ping-pong.
    _ = await kernel.observe(actedTurn(4, before: before, after: after, actionSignatureHash: "c"))
    #expect(kernel.extraSignals.oscillationCount == 0)
    // Same-action repetition is NOT oscillation: A A A keeps the counter at 0.
    var repeating = makeKernel()
    for turn in 1...3 {
        _ = await repeating.observe(actedTurn(turn, before: before, after: after, actionSignatureHash: "a"))
    }
    #expect(repeating.extraSignals.oscillationCount == 0)
}

// MARK: - (9) requiresForcedValidator truth table (inline callsite parity)

@Test func kernelRequiresForcedValidatorTruthTable() {
    // partCount > 1 || highRisk || scoutBackend
    #expect(!EpisodeReliabilityKernel.requiresForcedValidator(partCount: 1, highRisk: false, scoutBackend: false))
    #expect(EpisodeReliabilityKernel.requiresForcedValidator(partCount: 2, highRisk: false, scoutBackend: false))
    #expect(EpisodeReliabilityKernel.requiresForcedValidator(partCount: 1, highRisk: true, scoutBackend: false))
    #expect(EpisodeReliabilityKernel.requiresForcedValidator(partCount: 1, highRisk: false, scoutBackend: true))
    #expect(EpisodeReliabilityKernel.requiresForcedValidator(partCount: 3, highRisk: true, scoutBackend: true))
    #expect(!EpisodeReliabilityKernel.requiresForcedValidator(partCount: 0, highRisk: false, scoutBackend: false))
}

// MARK: - (10) StateSignatureProvider seam is LOAD-BEARING, not decorative

@Test func kernelReadsAfterFrameAndSettleDecisionFromProvider() async {
    let provider = EpisodeReliabilityKernel.FedStateSignatureProvider()
    var kernel = makeKernel(stallLimit: 3, signatures: provider)
    let frame = sig([7, 7, 7])
    // The observation carries NO after/settled — everything the verdict needs
    // flows through the provider. settleRecheck=true → the effect rendered late.
    await provider.push(frame)
    await provider.pushSettleResult(true)
    #expect(await kernel.observe(actedTurn(1, before: frame, after: nil)) == .recheckCleared)
    // Same duplicate frame, settle re-check confirms → the no-effect ladder.
    await provider.pushSettleResult(false)
    #expect(await kernel.observe(actedTurn(2, before: frame, after: nil)) == .nudge(.noEffect))
    #expect(await kernel.observe(actedTurn(3, before: frame, after: nil)) == .nudge(.noEffect))
    #expect(await kernel.observe(actedTurn(4, before: frame, after: nil)) == .bail(.noEffectStall))
}

@Test func kernelProviderChangedFrameResetsStreak() async {
    let provider = EpisodeReliabilityKernel.FedStateSignatureProvider()
    var kernel = makeKernel(stallLimit: 2, signatures: provider)
    let frame = sig([7, 7, 7])
    await provider.push(frame)
    await provider.pushSettleResult(false)
    #expect(await kernel.observe(actedTurn(1, before: frame, after: nil)) == .nudge(.noEffect))
    // A visibly-changed frame from the provider resets the streak — the seam,
    // not the observation, decides.
    await provider.push(sig([0xffff, 7, 7]))
    #expect(await kernel.observe(actedTurn(2, before: frame, after: nil)) == .proceed)
    await provider.push(frame)
    #expect(await kernel.observe(actedTurn(3, before: frame, after: nil)) == .nudge(.noEffect))
}

@Test func kernelProviderNoFrameSentinelMeansMissingFrame() async {
    let provider = EpisodeReliabilityKernel.FedStateSignatureProvider()
    var kernel = makeKernel(signatures: provider)
    let frame = sig([7, 7, 7])
    // push(nil): the loop's recapture produced no decodable hashes — the inline
    // reset arm, not a no-effect count.
    await provider.push(nil)
    await provider.pushSettleResult(false)
    #expect(await kernel.observe(actedTurn(1, before: frame, after: nil)) == .proceed)
    #expect(await provider.signature() == EpisodeReliabilityKernel.FedStateSignatureProvider.noFrame)
}

@Test func kernelFedProviderRoundTripsSignaturesAndSettleResults() async {
    let provider = EpisodeReliabilityKernel.FedStateSignatureProvider()
    let kernel = makeKernel(signatures: provider)
    // The kernel stores the injected provider — StateSignatureProvider, not a fake seam.
    #expect(kernel.signatures != nil)

    let first = sig([1, 2, 3])
    await provider.push(first)
    #expect(await provider.signature() == first)

    let second = sig([9, 9, 9])
    await provider.push(second)
    #expect(await provider.signature() == second)

    await provider.pushSettleResult(true)
    #expect(await provider.settleRecheck(after: .milliseconds(400)))
    await provider.pushSettleResult(false)
    #expect(!(await provider.settleRecheck(after: .milliseconds(400))))
}
