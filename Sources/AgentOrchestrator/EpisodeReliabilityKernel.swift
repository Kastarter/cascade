import Foundation
import PerceptionCore

/// The assist loop's structural reliability scaffolding, extracted into one PURE,
/// deterministic per-episode state machine (§3.1/§4a): no captures, no sleeps, no
/// audit writes, no model calls. The caller feeds it one `TurnObservation` per turn
/// and gets back the verdict the inline scaffolding in `runAssistEpisode` would have
/// produced:
///
/// - tiered idle/stall guard (nudge at turn 2, bail at 3; acting resets),
/// - no-effect detection on grid-hash signatures (threshold-2 Hamming duplicate
///   check; suspicion is raised on the PRE-recheck frame and decided by the
///   336263d 400ms settle re-check),
/// - the no-effect stall bail at the AgentRecoveryPolicy-derived attempt limit,
/// - ground-miss nudges + the 4f62dab fail-fast bail (2 misses on a zero-control
///   view),
/// - the forced-completion validator predicate,
/// - KERNEL-EXTRA signals (8aaea59 signature-based repetition AND the
///   bfe89d6/6b98567 anti-oscillation shape, both implemented in
///   `updateExtraSignals`) surfaced via `extraSignals` for the kernel.shadow
///   summary row but NEVER part of any shadow divergence comparison — this
///   branch has no inline equivalent for them.
///
/// SHADOW-FIRST (b40ede8 discipline): behind `cascade.reliabilityKernel` (default
/// OFF) the kernel runs ALONGSIDE the inline logic; disagreements are audited as
/// `kernel.shadow.diverged` and nothing the kernel says is ever actuated.
/// Promotion to authoritative is a later, per-lane flip gated on live audit rows.
///
/// actionChunking interplay: when `cascade.experimentalActionChunking` is ON, the
/// chunk executor's per-group no-effect deferral fires BEFORE the turn-level check;
/// the kernel observes only the TURN-level decision — chunk-level shadowing is out
/// of scope, so a chunked turn must not be double-counted against the kernel.
public struct EpisodeReliabilityKernel: Sendable {

    /// Inline constants injected by the caller so the kernel never invents numbers.
    /// The caller passes `CascadeAppModel.noEffectThreshold` (2) and
    /// `recoveryAttemptLimit(for: .noEffect)` (the AgentRecoveryPolicy-derived
    /// value) — they are NOT re-hardcoded here.
    public struct Config: Sendable {
        /// Per-region Hamming threshold for the grid-signature duplicate check.
        public var noEffectSignatureThreshold: Int
        /// Idle/observation-only turn count that earns the act-now nudge.
        public var idleNudgeAtTurn: Int
        /// Idle/observation-only turn count that ends the episode.
        public var idleStallAtTurn: Int
        /// No-effect streak at which the inline loop runs its verifier probe
        /// (kernel-extra escalate-condition signal only; no verdict of its own).
        public var noEffectVerifierAtStreak: Int
        /// No-effect streak that ends the episode (AgentRecoveryPolicy-derived).
        public var noEffectStallLimit: Int
        /// Consecutive ground misses on a ZERO-control view that end the episode
        /// (4f62dab fail-fast; Scout-only inline — kernel-extra on the Opus lane).
        public var emptyViewMissBailLimit: Int
        /// Identical action+after-signature repetitions that raise the
        /// kernel-extra escalate-condition signal (8aaea59 lineage).
        public var repetitionSignalAtCount: Int
        /// A→B→A alternation hits that raise the kernel-extra
        /// escalate-condition signal (bfe89d6/6b98567 anti-oscillation shape);
        /// 2 hits = a full A→B→A→B ping-pong.
        public var oscillationSignalAtCount: Int

        public init(
            noEffectSignatureThreshold: Int,
            noEffectStallLimit: Int,
            idleNudgeAtTurn: Int = 2,
            idleStallAtTurn: Int = 3,
            noEffectVerifierAtStreak: Int = 2,
            emptyViewMissBailLimit: Int = 2,
            repetitionSignalAtCount: Int = 3,
            oscillationSignalAtCount: Int = 2
        ) {
            self.noEffectSignatureThreshold = noEffectSignatureThreshold
            self.noEffectStallLimit = noEffectStallLimit
            self.idleNudgeAtTurn = idleNudgeAtTurn
            self.idleStallAtTurn = idleStallAtTurn
            self.noEffectVerifierAtStreak = noEffectVerifierAtStreak
            self.emptyViewMissBailLimit = emptyViewMissBailLimit
            self.repetitionSignalAtCount = repetitionSignalAtCount
            self.oscillationSignalAtCount = oscillationSignalAtCount
        }
    }

    /// Mirrors the loop's observationOnly / actedThisTurn / expectsChange trio.
    public enum TurnClass: Sendable, Equatable {
        /// No actions at all this turn (the model only talked).
        case idle
        /// Screenshot/wait-only turn — staring, counted like idle by the guard.
        case observationOnly
        /// A real action ran; `expectsChange` is the structural predicted-effect
        /// gate (a copy-only/wait-only turn legitimately changes nothing).
        case acted(expectsChange: Bool)
    }

    /// A grounding miss the loop already surfaced (hashes/counts only — P7).
    public struct GroundMiss: Sendable {
        public let targetHash: String
        public let visibleControlCount: Int

        public init(targetHash: String, visibleControlCount: Int) {
            self.targetHash = targetHash
            self.visibleControlCount = visibleControlCount
        }
    }

    /// Everything the kernel needs to re-derive one turn's verdict — all values
    /// the inline loop ALREADY holds; the kernel adds zero captures.
    public struct TurnObservation: Sendable {
        public let turn: Int
        public let turnClass: TurnClass
        /// Signature of the frame the turn's step was generated from.
        public let before: StateSignature?
        /// Signature of the frame captured after the turn's actions (PRE-recheck).
        /// IGNORED when a `StateSignatureProvider` is injected — the kernel then
        /// reads the after-frame from `signatures.signature()` instead, so the
        /// seam is load-bearing, not decorative.
        public let after: StateSignature?
        /// The frame the inline loop captured on its 400ms settle re-check
        /// (336263d); nil when the loop did not re-check. IGNORED when a
        /// provider is injected — the settle decision then comes from
        /// `signatures.settleRecheck(after:)`.
        public let settled: StateSignature?
        public let groundMiss: GroundMiss?
        /// Stable hash of the turn's action list, for repetition/oscillation
        /// counting.
        public let actionSignatureHash: String?

        public init(
            turn: Int,
            turnClass: TurnClass,
            before: StateSignature? = nil,
            after: StateSignature? = nil,
            settled: StateSignature? = nil,
            groundMiss: GroundMiss? = nil,
            actionSignatureHash: String? = nil
        ) {
            self.turn = turn
            self.turnClass = turnClass
            self.before = before
            self.after = after
            self.settled = settled
            self.groundMiss = groundMiss
            self.actionSignatureHash = actionSignatureHash
        }
    }

    public enum Nudge: String, Sendable {
        case idleActNow
        case noEffect
        case groundMiss
    }

    public enum Bail: String, Sendable {
        case idleStall
        case noEffectStall
        case emptyViewMisses
    }

    public enum Verdict: Sendable, Equatable {
        case proceed
        /// The settle re-check proved the effect just rendered late (336263d) —
        /// the action DID work; the streak was reset.
        case recheckCleared
        case nudge(Nudge)
        case bail(Bail)
    }

    /// KERNEL-EXTRA signals with no inline equivalent on this branch (8aaea59
    /// repetition; bfe89d6/6b98567 anti-oscillation, whose inline form lives on
    /// feat/two-tier-planner). Surfaced for the kernel.shadow summary row but
    /// NEVER part of the divergence comparison — counting them would manufacture
    /// permanent divergence and block promotion forever.
    public struct ExtraSignals: Sendable, Equatable {
        /// Consecutive acting turns with the same action-signature hash AND the
        /// same after-signature (the screen keeps landing in the same place).
        public var repetitionCount: Int
        /// A→B→A alternation hits between two distinct action-signature hashes
        /// (the ping-pong that same-action repetition counting is blind to —
        /// each alternation resets `repetitionCount` to 1).
        public var oscillationCount: Int
        /// The kernel saw a condition the inline loop escalates/verifies on.
        public var sawEscalateCondition: Bool

        public init(
            repetitionCount: Int = 0,
            oscillationCount: Int = 0,
            sawEscalateCondition: Bool = false
        ) {
            self.repetitionCount = repetitionCount
            self.oscillationCount = oscillationCount
            self.sawEscalateCondition = sawEscalateCondition
        }
    }

    public let config: Config
    /// The signature seam (PerceptionCore.StateSignatureProvider). LOAD-BEARING
    /// when injected: `observe` reads the turn's after-frame from
    /// `signature()` and the 336263d settle decision from
    /// `settleRecheck(after:)` — the observation's `after`/`settled` fields are
    /// then ignored. In shadow mode the caller feeds a
    /// `FedStateSignatureProvider` with the loop's OWN observations (zero extra
    /// captures); the authoritative flip replaces it with a recorder-backed
    /// implementation that captures for itself.
    public let signatures: StateSignatureProvider?

    public private(set) var extraSignals = ExtraSignals()

    private var idleCounter = 0
    private var noEffectStreak = 0
    private var emptyViewMissCounter = 0
    private var previousActionSignatureHash: String?
    private var penultimateActionSignatureHash: String?
    private var previousAfterSignature: StateSignature?

    public init(config: Config, signatures: StateSignatureProvider? = nil) {
        self.config = config
        self.signatures = signatures
    }

    /// One call per turn, implementing EXACTLY the inline order of
    /// `runAssistEpisode` (idle tiering first — its bail returns before miss and
    /// no-effect handling run — then no-effect suspicion on the pre-recheck
    /// after-frame vs `before`, decided by the settle re-check, then ground-miss
    /// accounting). Verdict precedence when several fire: bail > nudge, and
    /// noEffect > groundMiss > idle (matching inline, where the no-effect nudge
    /// text OVERWRITES and the miss note is appended).
    ///
    /// Async because the after-frame and settle decision come THROUGH the
    /// `StateSignatureProvider` seam when one is injected; provider-less
    /// (pure-test) callers supply `after`/`settled` on the observation instead.
    public mutating func observe(_ o: TurnObservation) async -> Verdict {
        // Resolve the after-frame. With a provider, `signature()` is the source
        // of truth (a "none"-kind signature is the no-decodable-frame sentinel a
        // FedStateSignatureProvider emits when the loop's recapture failed).
        let after: StateSignature?
        if let signatures {
            let provided = await signatures.signature()
            after = provided.kind == FedStateSignatureProvider.noFrame.kind ? nil : provided
        } else {
            after = o.after
        }
        updateExtraSignals(o, after: after)

        // Idle tiering: idle/observation-only turns increment the counter; the
        // inline stall RETURNS the episode before miss/no-effect handling runs,
        // so the bail short-circuits here too. Acting resets.
        var idleNudgePending = false
        switch o.turnClass {
        case .idle, .observationOnly:
            idleCounter += 1
            if idleCounter >= config.idleStallAtTurn { return .bail(.idleStall) }
            if idleCounter == config.idleNudgeAtTurn { idleNudgePending = true }
        case .acted:
            idleCounter = 0
        }

        // Ground miss: any miss earns the re-describe nudge (inline appends the
        // miss note regardless of control count); a miss on a ZERO-control view
        // additionally counts toward the 4f62dab fail-fast bail, and a miss on a
        // controls-present view resets that counter.
        var groundMissNudgePending = false
        var emptyViewBail = false
        if let miss = o.groundMiss {
            groundMissNudgePending = true
            if miss.visibleControlCount == 0 {
                emptyViewMissCounter += 1
                if emptyViewMissCounter >= config.emptyViewMissBailLimit { emptyViewBail = true }
            } else {
                emptyViewMissCounter = 0
            }
        }

        // No-effect: only acting turns that EXPECT a visible change, with both
        // frames present. Exactly the 336263d inline shape: suspicion is raised
        // on the PRE-recheck after-frame vs `before`, then confirmed or cleared
        // by the settle re-check — through the provider seam when injected, else
        // from the observation's settled frame. A copy/wait-exempt acting turn
        // leaves the streak untouched.
        var noEffectOutcome: Verdict?
        if case .acted(expectsChange: true) = o.turnClass {
            if let before = o.before, let after,
               Self.isDuplicate(after, of: before, threshold: config.noEffectSignatureThreshold) {
                let renderedLate: Bool
                if let signatures {
                    renderedLate = await signatures.settleRecheck(after: .milliseconds(400))
                } else if let settled = o.settled {
                    renderedLate = !Self.isDuplicate(settled, of: before, threshold: config.noEffectSignatureThreshold)
                } else {
                    // No re-check available — the suspicion stands, exactly as the
                    // inline loop concludes when its recapture fails.
                    renderedLate = false
                }
                if renderedLate {
                    // The settle re-check cleared the suspicion — late render.
                    noEffectStreak = 0
                    noEffectOutcome = .recheckCleared
                } else {
                    noEffectStreak += 1
                    if noEffectStreak >= config.noEffectVerifierAtStreak {
                        extraSignals.sawEscalateCondition = true
                    }
                    noEffectOutcome = noEffectStreak >= config.noEffectStallLimit
                        ? .bail(.noEffectStall)
                        : .nudge(.noEffect)
                }
            } else {
                // A visibly-changed frame, or undecodable/missing frames: the
                // inline reset arm gates only on acted/expectsChange, not on
                // hash availability — reset.
                noEffectStreak = 0
            }
        }

        // Precedence: bail > nudge; noEffect > groundMiss > idle. recheckCleared
        // sits in the no-effect slot (the inline recheck-cleared arm runs after —
        // and therefore overrides — the appended miss note).
        if case .some(.bail) = noEffectOutcome { return noEffectOutcome! }
        if emptyViewBail { return .bail(.emptyViewMisses) }
        if let noEffectOutcome { return noEffectOutcome }
        if groundMissNudgePending { return .nudge(.groundMiss) }
        if idleNudgePending { return .nudge(.idleActNow) }
        return .proceed
    }

    private mutating func updateExtraSignals(_ o: TurnObservation, after: StateSignature?) {
        guard case .acted = o.turnClass, let hash = o.actionSignatureHash else { return }
        if hash == previousActionSignatureHash, let after, after == previousAfterSignature {
            extraSignals.repetitionCount += 1
        } else {
            extraSignals.repetitionCount = 1
        }
        // bfe89d6/6b98567 anti-oscillation shape: the model PING-PONGS between
        // two distinct actions (A→B→A→B…) — invisible to same-action repetition,
        // which resets to 1 on every alternation. Counted on action-signature
        // hashes alone; kernel-extra signal only, never a verdict.
        if let penultimate = penultimateActionSignatureHash,
           hash == penultimate, hash != previousActionSignatureHash {
            extraSignals.oscillationCount += 1
        } else {
            extraSignals.oscillationCount = 0
        }
        penultimateActionSignatureHash = previousActionSignatureHash
        previousActionSignatureHash = hash
        previousAfterSignature = after
        if extraSignals.repetitionCount >= config.repetitionSignalAtCount {
            extraSignals.sawEscalateCondition = true
        }
        if extraSignals.oscillationCount >= config.oscillationSignalAtCount {
            extraSignals.sawEscalateCondition = true
        }
    }

    // MARK: - Signature math

    /// Encodes the recorder's 3×3 grid hashes as a comparable `StateSignature`
    /// (kind "gridHashes", value = comma-joined lowercase hex).
    public static func gridSignature(_ hashes: [UInt64]) -> StateSignature {
        StateSignature(kind: "gridHashes", value: hashes.map { String($0, radix: 16) }.joined(separator: ","))
    }

    /// Byte-for-byte reimplementation of `PerceptualHash.isDuplicateGrid`
    /// semantics (AgentOrchestrator cannot import MacContextKit; a unit test pins
    /// parity): count mismatch or empty → false; otherwise every region's
    /// XOR popcount must be within `threshold`. Non-gridHashes kinds compare by
    /// exact equality (the future WebStateSignature seam).
    public static func isDuplicate(_ a: StateSignature, of b: StateSignature, threshold: Int) -> Bool {
        guard a.kind == "gridHashes", b.kind == "gridHashes" else { return a == b }
        guard let candidate = decodeGrid(a), let previous = decodeGrid(b) else { return false }
        guard candidate.count == previous.count, !candidate.isEmpty else { return false }
        return zip(candidate, previous).allSatisfy { ($0 ^ $1).nonzeroBitCount <= threshold }
    }

    private static func decodeGrid(_ signature: StateSignature) -> [UInt64]? {
        guard !signature.value.isEmpty else { return [] }
        var hashes: [UInt64] = []
        for part in signature.value.split(separator: ",", omittingEmptySubsequences: false) {
            guard let hash = UInt64(part, radix: 16) else { return nil }
            hashes.append(hash)
        }
        return hashes
    }

    // MARK: - Forced-completion validator

    /// Mirrors the inline forced-validator predicate at the assist subgoal
    /// verification callsite: multi-part plans, high-risk subtasks, and the Scout
    /// backend always run the completion validator.
    public static func requiresForcedValidator(partCount: Int, highRisk: Bool, scoutBackend: Bool) -> Bool {
        partCount > 1 || highRisk || scoutBackend
    }

    // MARK: - Fed provider (shadow-mode StateSignatureProvider)

    /// A `StateSignatureProvider` the shadow hook FEEDS with the loop's own
    /// observations, so the kernel consumes the PerceptionCore protocol with
    /// zero extra captures — and consumes it FUNCTIONALLY: `observe` reads the
    /// after-frame from `signature()` and the settle decision from
    /// `settleRecheck(after:)`, so a stale or missing feed changes the verdict.
    /// The authoritative flip replaces this with a recorder-backed
    /// implementation that captures for itself. An actor: the protocol is
    /// Sendable and the seam crosses async boundaries.
    public actor FedStateSignatureProvider: StateSignatureProvider {
        /// The sentinel `signature()` returns when the loop had no decodable
        /// frame this turn (`push(nil)`); `observe` maps it back to a missing
        /// after-frame so the inline reset arm's behavior is preserved.
        public static let noFrame = StateSignature(kind: "none", value: "")

        private var lastSignature: StateSignature?
        private var lastSettleChanged = false

        public init() {}

        /// Feed the frame signature the loop observed this turn — nil when the
        /// loop's recapture produced no decodable hashes.
        public func push(_ s: StateSignature?) {
            lastSignature = s
        }

        /// Feed the outcome of the loop's own 400ms settle re-check
        /// (`true` = the settled frame differed, i.e. the effect rendered late).
        public func pushSettleResult(_ changed: Bool) {
            lastSettleChanged = changed
        }

        public func signature() -> StateSignature {
            lastSignature ?? Self.noFrame
        }

        public func settleRecheck(after: Duration) -> Bool {
            lastSettleChanged
        }
    }
}
