import CascadeMemory
import ComputerUseKit
import CoreGraphics
import Foundation

// §4b recipe replay extracted into a headless-testable runner (t11). The runner
// owns ALL replay policy — pre-flight state gate, the V2 ensemble ladder, the
// unverified-streak drift guard, promote/demote routing — as pure logic over
// injected `Hooks`, so the ladder is exercisable in tests with zero TCC/screen.
// Behind `cascade.replayRunnerV2` (default OFF): with the flag absent the shipped
// `runAgentRecipe` path in CascadeAppModel executes byte-identically (LAW 6).
//
// LAW 1 (structural, not advisory): a wrong start state / unexpected modal /
// parameter step / ambiguous target is a TYPED `.replan(...)` return the caller
// can't ignore — never a prompt rule or a bare pause.
// LAW 7 (degrade to MISSED, never FALSE): the recorded pixel is NEVER a retry
// target in V2 — it survives only as the `near:` ranking hint and the vision
// re-ground input. Candidate exhaustion degrades to `.replan`, never a stale click.

/// One replayable click anchor merged from the healed in-memory RecipeTargetCache
/// entry and/or the historical persistent ActionTrajectoryCache row.
public struct ReplayAnchor: Sendable, Equatable {
    public enum Origin: String, Sendable, Equatable {
        /// Healed, effect-confirmed RecipeTargetCache entry from this process.
        case healed
        /// Historical persistent ActionTrajectoryCache row from earlier runs.
        case historical
    }

    public let point: CGPoint
    public let descriptor: AXTargetDescriptorV2?
    public let anchorHash: String?
    public let verifiedScore: Double?
    /// The typed anchor source the entry was last verified with (SEQ-29) — fed
    /// back into `promoteVerified` on success so healed-anchor quality metadata
    /// round-trips instead of being dropped.
    public let verifiedSource: AnchorDriftScorer.AnchorSource?
    public let source: String
    public let origin: Origin

    public init(
        point: CGPoint,
        descriptor: AXTargetDescriptorV2? = nil,
        anchorHash: String? = nil,
        verifiedScore: Double? = nil,
        verifiedSource: AnchorDriftScorer.AnchorSource? = nil,
        source: String,
        origin: Origin
    ) {
        self.point = point
        self.descriptor = descriptor
        self.anchorHash = anchorHash
        self.verifiedScore = verifiedScore
        self.verifiedSource = verifiedSource
        self.source = source
        self.origin = origin
    }
}

/// Post-click effect verdict (wraps the AX fingerprint diff on the live path).
public enum ReplayVerification: Sendable, Equatable {
    case changed
    case unchanged
    case unavailable
}

/// The typed REPLAN contract (LAW 1): every way deterministic replay can stop
/// needing intelligence is a case the caller must map to an escalation — the
/// runner can never silently plow on or merely "pause".
public enum RecipeReplanReason: Sendable, Equatable {
    /// Pre-flight state gate (ecc1b90): wrong app/window is a REPLAN input,
    /// not just a pause.
    case wrongStartState(expected: String, actual: String?)
    case unexpectedModal(title: String)
    /// B5's honest limit stays DECLARED here: literal replay would retype the
    /// stale recorded value, so a parameter step is unreachable by type until
    /// slot induction lands.
    case parameterNeedsLiveValue(stepOrder: Int)
    /// Close top-2 live candidates — preserves today's `recipe.drift` semantics.
    /// `frames` carries the candidates' screen rects so the escalation can
    /// highlight them, exactly as V1's `ambiguityFrames` does.
    case ambiguousTarget(stepOrder: Int, choices: String, frames: [CGRect])
    case targetNotFound(stepOrder: Int)
    /// Two clicks in a row whose effect could not be confirmed (today's threshold).
    case driftNoEffect(stepOrder: Int)
}

public enum RecipeReplayOutcome: Sendable, Equatable {
    case completed
    case stopped
    case replan(RecipeReplanReason)
    case failed(String)
}

public struct RecipeReplayRunner: Sendable {
    /// The headless seam: every effectful/observing operation the ladder needs,
    /// as injectable async closures. Live hooks (CascadeAppModel) wrap the same
    /// private helpers the shipped path uses; test hooks script them.
    public struct Hooks: Sendable {
        public var isStopRequested: @Sendable () async -> Bool
        public var activateApp: @Sendable (_ name: String, _ bundle: String?) async -> Void
        public var startStateMismatch: @Sendable (RecipeStep) async -> String?
        public var unexpectedModalTitle: @Sendable () async -> String?
        public var uiFingerprint: @Sendable () async -> Int?
        /// Whether the step's app declares its AX tree unreliable (skill
        /// `axUnreliable` — Blender/Figma/Photoshop canvas apps). V1 parity:
        /// these steps skip the AX tiers AND fingerprint verification, "so
        /// canvas apps don't false-pause" (LAW 8 — never verify by a mechanism
        /// the skill layer declares invalid for the app).
        public var stepAXUnreliable: @Sendable (RecipeStep) async -> Bool
        /// Healed RecipeTargetCache entry + historical ActionTrajectoryCache row,
        /// verified-score order, deduped by anchorHash.
        public var mergedAnchors: @Sendable (RecipeStep, _ stateFingerprint: String?) async -> [ReplayAnchor]
        /// Wraps `AXElementResolver.rank(recorded:near:limit: 5)` off-main,
        /// exactly as `resolveByAX` does today.
        public var ensembleCandidates: @Sendable (AXTargetDescriptorV2, _ near: CGPoint?) async -> [AXElementResolver.RankedCandidate]
        /// Wraps `axActivate(atCG:)` — AXPress before any CGEvent click.
        public var axPress: @Sendable (CGPoint) async -> Bool
        public var click: @Sendable (RecipeStep, _ at: CGPoint) async throws -> Void
        /// type/key/scroll via the existing `AgentAction(recipeStep:)` mapping.
        public var performOther: @Sendable (RecipeStep) async throws -> Void
        /// Wraps `regroundedByOCR` (on-device Vision OCR, no model round-trip).
        public var ocrRegroundPoint: @Sendable (String?) async -> CGPoint?
        /// Wraps `regroundedTarget` (Claude vision) — the SAME full-screen
        /// ElementLocator call the shipped path makes (no crop path exists on
        /// the live tier today). Returns nil when vision could not improve on
        /// the recorded point.
        public var visionRegroundPoint: @Sendable (_ anchor: String?, _ recorded: CGPoint) async -> CGPoint?
        /// Wraps `verifyUIChange` against the fingerprint taken pre-click.
        public var verifyChanged: @Sendable (_ afterFingerprint: Int?) async -> ReplayVerification
        /// Effect-confirmed promote (SEQ-29): feeds `recipeTargetCache.promote`
        /// + `promoteActionTrajectoryRecipeCache` on the live path, carrying the
        /// winning candidate's verified score + typed anchor source so healed
        /// entries keep the confidence metadata V2 itself consumes (merged-anchor
        /// ordering, AnchorDriftScorer previous-score comparison).
        public var promoteVerified: @Sendable (
            RecipeStep, CGPoint, AXTargetDescriptorV2?,
            _ tier: String, _ verifiedScore: Double?, _ source: AnchorDriftScorer.AnchorSource?
        ) async -> Void
        public var demoteAnchor: @Sendable (ReplayAnchor, _ reason: String) async -> Void
        public var audit: @Sendable (_ action: String, _ detail: String) async -> Void
        public var progress: @Sendable (_ title: String, _ detail: String) -> Void

        public init(
            isStopRequested: @escaping @Sendable () async -> Bool,
            activateApp: @escaping @Sendable (String, String?) async -> Void,
            startStateMismatch: @escaping @Sendable (RecipeStep) async -> String?,
            unexpectedModalTitle: @escaping @Sendable () async -> String?,
            uiFingerprint: @escaping @Sendable () async -> Int?,
            stepAXUnreliable: @escaping @Sendable (RecipeStep) async -> Bool,
            mergedAnchors: @escaping @Sendable (RecipeStep, String?) async -> [ReplayAnchor],
            ensembleCandidates: @escaping @Sendable (AXTargetDescriptorV2, CGPoint?) async -> [AXElementResolver.RankedCandidate],
            axPress: @escaping @Sendable (CGPoint) async -> Bool,
            click: @escaping @Sendable (RecipeStep, CGPoint) async throws -> Void,
            performOther: @escaping @Sendable (RecipeStep) async throws -> Void,
            ocrRegroundPoint: @escaping @Sendable (String?) async -> CGPoint?,
            visionRegroundPoint: @escaping @Sendable (String?, CGPoint) async -> CGPoint?,
            verifyChanged: @escaping @Sendable (Int?) async -> ReplayVerification,
            promoteVerified: @escaping @Sendable (
                RecipeStep, CGPoint, AXTargetDescriptorV2?,
                String, Double?, AnchorDriftScorer.AnchorSource?
            ) async -> Void,
            demoteAnchor: @escaping @Sendable (ReplayAnchor, String) async -> Void,
            audit: @escaping @Sendable (String, String) async -> Void,
            progress: @escaping @Sendable (String, String) -> Void
        ) {
            self.isStopRequested = isStopRequested
            self.activateApp = activateApp
            self.startStateMismatch = startStateMismatch
            self.unexpectedModalTitle = unexpectedModalTitle
            self.uiFingerprint = uiFingerprint
            self.stepAXUnreliable = stepAXUnreliable
            self.mergedAnchors = mergedAnchors
            self.ensembleCandidates = ensembleCandidates
            self.axPress = axPress
            self.click = click
            self.performOther = performOther
            self.ocrRegroundPoint = ocrRegroundPoint
            self.visionRegroundPoint = visionRegroundPoint
            self.verifyChanged = verifyChanged
            self.promoteVerified = promoteVerified
            self.demoteAnchor = demoteAnchor
            self.audit = audit
            self.progress = progress
        }
    }

    /// First attempt + 2 retries at the NEXT candidate — never the recorded pixel.
    public static let maxCandidateAttempts = 3
    /// Cross-step unverified streak that trips the drift replan (today's threshold).
    public static let driftReplanStreak = 2

    public init() {}

    /// B5's parameterized-replay precondition: a per-run-varying value can't be
    /// replayed from the recording. This is the ONE shared symbol for the gate —
    /// `CascadeAppModel.recipeStepNeedsLiveValue` delegates here so the V1 and
    /// V2 parameter gates can never silently diverge.
    public static func stepNeedsLiveValue(_ step: RecipeStep) -> Bool {
        step.isParameter && (step.kind == .type || isPasteShortcut(step) || !step.sourceStepIDs.isEmpty)
    }

    public static func isPasteShortcut(_ step: RecipeStep) -> Bool {
        guard step.kind == .key, step.key?.lowercased() == "v" else { return false }
        let modifiers = step.modifiers.map { $0.lowercased() }
        return modifiers.contains("command") || modifiers.contains("control")
    }

    /// Same descriptor construction as `resolveByAX` today: decode the recorded
    /// V2 descriptor (fallback label from step text/anchor), else rebuild a thin
    /// descriptor from the legacy role/identifier/container encoding.
    static func targetDescriptor(for step: RecipeStep) -> AXTargetDescriptorV2 {
        let label = (step.text ?? step.ocrAnchor) ?? ""
        if let decoded = AXTargetDescriptorV2.decode(step.targetDescriptor, fallbackLabel: label) {
            return decoded
        }
        let (role, identifier, container) = AXTargetDescriptor.decode(step.targetDescriptor)
        return AXTargetDescriptorV2(
            label: label,
            role: role,
            identifier: identifier,
            container: container,
            ancestorPath: container.map { [$0] } ?? []
        )
    }

    static func anchorHash(for descriptor: AXTargetDescriptorV2?) -> String? {
        guard let descriptor else { return nil }
        return descriptor.identifier
            ?? descriptor.pathHash
            ?? descriptor.subtreeHash
            ?? descriptor.semanticTextHash
            ?? descriptor.semanticHash
    }

    /// Privacy-lean ambiguity summary for the escalation goal (labels truncated).
    static func candidateChoices(_ candidates: [AXElementResolver.RankedCandidate], limit: Int = 2) -> String {
        candidates.prefix(limit).enumerated().map { index, ranked in
            let descriptor = ranked.candidate.descriptor
            let label = descriptor.label.isEmpty ? "unlabeled" : String(descriptor.label.prefix(36))
            let role = (descriptor.role ?? "AXElement").replacingOccurrences(of: "AX", with: "")
            return "\(index + 1). \(label) \(role.lowercased()) score \(String(format: "%.2f", ranked.confidence))"
        }.joined(separator: "; ")
    }

    private struct Attempt {
        let point: CGPoint
        let descriptor: AXTargetDescriptorV2?
        let tier: String
        /// Candidate confidence (ensemble) / stored verified score (anchors) —
        /// carried through `promoteVerified` on success (SEQ-29).
        let score: Double?
        /// Typed anchor source for the promote, mirroring V1's `targetSource`.
        let source: AnchorDriftScorer.AnchorSource?
        /// Non-nil only for merged healed/historical anchors — the only attempts
        /// with a persistent entry to demote on failure.
        let anchor: ReplayAnchor?
    }

    public func run(steps: [RecipeStep], hooks: Hooks) async -> RecipeReplayOutcome {
        let ordered = steps.sorted { $0.order < $1.order }
        var startStateChecked = false
        var unverifiedStreak = 0
        // V1 parity: the axUnreliable verify skip is audited once per run.
        var skillVerifySkipLogged = false

        for (index, step) in ordered.enumerated() {
            if await hooks.isStopRequested() { return .stopped }
            hooks.progress("Step \(index + 1) of \(ordered.count)", "kind=\(step.kind.rawValue)")

            if step.kind == .activateApp {
                await hooks.activateApp(step.appName, step.bundleIdentifier)
                await hooks.audit("recipe.step", "step=\(step.order) kind=activateApp")
                continue
            }

            // B5's honest limit, DECLARED: literal replay would retype the stale
            // value — a parameter step is a typed replan, unreachable by retype.
            if Self.stepNeedsLiveValue(step) {
                await hooks.audit("recipe.parameter", "step=\(step.order) reason=needs_live_value")
                return .replan(.parameterNeedsLiveValue(stepOrder: step.order))
            }

            let isClickKind = step.kind == .click || step.kind == .doubleClick || step.kind == .rightClick
            guard isClickKind else {
                do {
                    try await hooks.performOther(step)
                } catch {
                    return .failed(error.localizedDescription)
                }
                unverifiedStreak = 0
                await hooks.audit("recipe.step", "step=\(step.order) kind=\(step.kind.rawValue)")
                continue
            }

            // Pre-flight STATE GATE before the first structural action (ecc1b90):
            // wrong app is a REPLAN input, never just a pause.
            if !startStateChecked {
                startStateChecked = true
                if let reason = await hooks.startStateMismatch(step) {
                    await hooks.audit("recipe.pause.wrongstate", "step=\(step.order) gate=start_state")
                    return .replan(.wrongStartState(expected: step.appName, actual: reason))
                }
            }
            if let modalTitle = await hooks.unexpectedModalTitle() {
                await hooks.audit("recipe.pause.modal", "step=\(step.order) gate=modal")
                return .replan(.unexpectedModal(title: modalTitle))
            }

            switch await runClickStep(
                step,
                hooks: hooks,
                unverifiedStreak: &unverifiedStreak,
                skillVerifySkipLogged: &skillVerifySkipLogged
            ) {
            case .proceed:
                continue
            case .outcome(let outcome):
                return outcome
            }
        }
        return .completed
    }

    private enum StepResolution {
        case proceed
        case outcome(RecipeReplayOutcome)
    }

    private func runClickStep(
        _ step: RecipeStep,
        hooks: Hooks,
        unverifiedStreak: inout Int,
        skillVerifySkipLogged: inout Bool
    ) async -> StepResolution {
        let recorded: CGPoint? = {
            guard let x = step.x, let y = step.y else { return nil }
            return CGPoint(x: x, y: y)
        }()

        // Canvas apps (skill `axUnreliable`, V1 parity): the AX tree does not
        // reflect the visible UI, so BOTH the AX tiers (ranking/AXPressing a
        // wrong element = FALSE action, LAW 7) and the fingerprint verify (a
        // static tree reads `.unchanged` for every real effect = false-pause)
        // are invalid mechanisms for these steps (LAW 8).
        if await hooks.stepAXUnreliable(step) {
            return await runCanvasClickStep(
                step,
                recorded: recorded,
                hooks: hooks,
                skillVerifySkipLogged: &skillVerifySkipLogged
            )
        }

        let before = await hooks.uiFingerprint()
        let descriptor = Self.targetDescriptor(for: step)

        // Candidate queue: merged healed/historical anchors first (verified-score
        // order, hook's contract), then the live V2 ensemble — deduped by anchorHash.
        let anchors = await hooks.mergedAnchors(step, before.map(String.init))
        let ensemble = await hooks.ensembleCandidates(descriptor, recorded)

        // Close top-2 live candidates ⇒ ambiguous replan, preserving today's
        // recipe.drift semantics. A healed/historical anchor (already effect-
        // confirmed once) short-circuits ambiguity exactly as the cache hit
        // short-circuits resolveByAX today.
        if anchors.isEmpty, ensemble.count >= 2 {
            let top = ensemble[0]
            let second = ensemble[1]
            if top.confidence >= AXElementResolver.rerankMinimumConfidence,
               top.confidence - second.confidence <= AnchorDriftScorer.Configuration.default.ambiguousTopMargin {
                await hooks.audit("recipe.drift", "step=\(step.order) outcome=ambiguous candidates=\(ensemble.count)")
                return .outcome(.replan(.ambiguousTarget(
                    stepOrder: step.order,
                    choices: Self.candidateChoices(ensemble),
                    frames: ensemble.compactMap { $0.candidate.frame }
                )))
            }
        }

        var attempts: [Attempt] = []
        var seenHashes = Set<String>()
        for anchor in anchors {
            if let hash = anchor.anchorHash, !seenHashes.insert(hash).inserted { continue }
            attempts.append(Attempt(
                point: anchor.point,
                descriptor: anchor.descriptor,
                tier: anchor.origin.rawValue,
                score: anchor.verifiedScore,
                source: anchor.verifiedSource,
                anchor: anchor
            ))
        }
        for ranked in ensemble {
            // High-agreement only: below the automatic-heal floor a live candidate
            // is never clicked — it degrades to OCR/vision/replan (LAW 7).
            guard ranked.confidence >= AXElementResolver.automaticHealMinimumConfidence,
                  let center = ranked.candidate.center else { continue }
            if let hash = Self.anchorHash(for: ranked.candidate.descriptor),
               !seenHashes.insert(hash).inserted { continue }
            attempts.append(Attempt(
                point: center,
                descriptor: ranked.candidate.descriptor,
                tier: "ax",
                score: ranked.confidence,
                source: .accessibility,
                anchor: nil
            ))
        }

        var clickedAny = false
        var verifiedPoint: CGPoint?
        var verifiedDescriptor: AXTargetDescriptorV2?
        var verifiedTier: String?
        var verifiedScore: Double?
        var verifiedSource: AnchorDriftScorer.AnchorSource?
        var verifyUnavailable = false

        candidateLoop: for attempt in attempts.prefix(Self.maxCandidateAttempts) {
            if await hooks.isStopRequested() { return .outcome(.stopped) }
            clickedAny = true
            // High-agreement AXPress first (free, exact); CGEvent click fallback.
            // Only a plain click maps to a single AXPress — double/right clicks
            // go straight to the CGEvent path.
            var pressed = false
            if step.kind == .click {
                pressed = await hooks.axPress(attempt.point)
            }
            if !pressed {
                do {
                    try await hooks.click(step, attempt.point)
                } catch {
                    return .outcome(.failed(error.localizedDescription))
                }
            }
            await hooks.audit("recipe.target", "step=\(step.order) tier=\(attempt.tier) axPress=\(pressed)")
            switch await hooks.verifyChanged(before) {
            case .changed:
                verifiedPoint = attempt.point
                verifiedDescriptor = attempt.descriptor
                verifiedTier = attempt.tier
                verifiedScore = attempt.score
                verifiedSource = attempt.source
                break candidateLoop
            case .unavailable:
                verifyUnavailable = true
                break candidateLoop
            case .unchanged:
                // Retry the NEXT candidate — the recorded pixel is NEVER a retry
                // target in V2 (it survives only as the near: ranking hint).
                if let anchor = attempt.anchor {
                    await hooks.demoteAnchor(anchor, "unchanged")
                }
                await hooks.audit("recipe.unverified", "step=\(step.order) tier=\(attempt.tier)")
                continue candidateLoop
            }
        }

        // OCR re-ground (on-device, sees canvas/Electron text AX is blind to).
        if verifiedPoint == nil, !verifyUnavailable {
            if let ocrPoint = await hooks.ocrRegroundPoint(step.ocrAnchor ?? step.text) {
                if await hooks.isStopRequested() { return .outcome(.stopped) }
                clickedAny = true
                do {
                    try await hooks.click(step, ocrPoint)
                } catch {
                    return .outcome(.failed(error.localizedDescription))
                }
                await hooks.audit("recipe.target", "step=\(step.order) tier=ocr")
                switch await hooks.verifyChanged(before) {
                case .changed:
                    verifiedPoint = ocrPoint
                    verifiedTier = "ocr"
                    // V1 parity: OCR is a vision-class source with no ranked score.
                    verifiedScore = nil
                    verifiedSource = .vision
                case .unavailable:
                    verifyUnavailable = true
                case .unchanged:
                    await hooks.audit("recipe.unverified", "step=\(step.order) tier=ocr")
                }
            }
        }

        // Vision re-ground (the audited exception, LAW 2): the SAME full-screen
        // `regroundedTarget` → ElementLocator call the shipped path makes — no
        // crop path exists on the live tier, so none is pretended here.
        if verifiedPoint == nil, !verifyUnavailable {
            let visionRecorded = recorded ?? attempts.first?.point ?? .zero
            if let visionPoint = await hooks.visionRegroundPoint(step.ocrAnchor, visionRecorded) {
                if await hooks.isStopRequested() { return .outcome(.stopped) }
                clickedAny = true
                do {
                    try await hooks.click(step, visionPoint)
                } catch {
                    return .outcome(.failed(error.localizedDescription))
                }
                await hooks.audit("recipe.target", "step=\(step.order) tier=vision")
                switch await hooks.verifyChanged(before) {
                case .changed:
                    verifiedPoint = visionPoint
                    verifiedTier = "vision"
                    verifiedScore = nil
                    verifiedSource = .vision
                case .unavailable:
                    verifyUnavailable = true
                case .unchanged:
                    await hooks.audit("recipe.unverified", "step=\(step.order) tier=vision")
                }
            }
        }

        if let verifiedPoint {
            unverifiedStreak = 0
            // Effect-confirmed promote only (SEQ-29), carrying score + source.
            await hooks.promoteVerified(
                step, verifiedPoint, verifiedDescriptor,
                verifiedTier ?? "ax", verifiedScore, verifiedSource
            )
            await hooks.audit("recipe.step", "step=\(step.order) tier=\(verifiedTier ?? "ax") status=verified")
            return .proceed
        }
        if verifyUnavailable {
            // Missing AX stays a skip-open condition: proceed unverified rather
            // than count the step as a no-effect failure (today's behavior).
            unverifiedStreak = 0
            await hooks.audit("recipe.verify.unavailable", "step=\(step.order)")
            await hooks.audit("recipe.step", "step=\(step.order) status=unverified")
            return .proceed
        }
        if !clickedAny {
            // Ladder exhausted with nothing clickable: MISSED, never a stale
            // false click (LAW 7).
            await hooks.audit("recipe.target", "step=\(step.order) tier=none outcome=missed")
            return .outcome(.replan(.targetNotFound(stepOrder: step.order)))
        }
        unverifiedStreak += 1
        await hooks.audit("recipe.unverified", "step=\(step.order) streak=\(unverifiedStreak)")
        if unverifiedStreak >= Self.driftReplanStreak {
            return .outcome(.replan(.driftNoEffect(stepOrder: step.order)))
        }
        await hooks.audit("recipe.step", "step=\(step.order) status=unverified")
        return .proceed
    }

    /// The `axUnreliable` (canvas-app) ladder, V1 parity (`recipe.verify.skipped-skill`,
    /// "so canvas apps don't false-pause"): OCR re-ground → vision re-ground →
    /// replan. No AX ensemble, no AXPress, no fingerprint verify, no promote or
    /// demote, and `unverifiedStreak` is deliberately UNTOUCHED — a streak from
    /// normal apps should still pause; these steps just don't count. Exhaustion
    /// degrades to MISSED (`.targetNotFound`), never the recorded pixel (LAW 7).
    private func runCanvasClickStep(
        _ step: RecipeStep,
        recorded: CGPoint?,
        hooks: Hooks,
        skillVerifySkipLogged: inout Bool
    ) async -> StepResolution {
        if !skillVerifySkipLogged {
            skillVerifySkipLogged = true
            await hooks.audit("recipe.verify.skipped-skill", "step=\(step.order) reason=ax_unreliable")
        }
        if let ocrPoint = await hooks.ocrRegroundPoint(step.ocrAnchor ?? step.text) {
            if await hooks.isStopRequested() { return .outcome(.stopped) }
            do {
                try await hooks.click(step, ocrPoint)
            } catch {
                return .outcome(.failed(error.localizedDescription))
            }
            await hooks.audit("recipe.target", "step=\(step.order) tier=ocr")
            await hooks.audit("recipe.step", "step=\(step.order) tier=ocr status=verify-skipped-skill")
            return .proceed
        }
        if let visionPoint = await hooks.visionRegroundPoint(step.ocrAnchor, recorded ?? .zero) {
            if await hooks.isStopRequested() { return .outcome(.stopped) }
            do {
                try await hooks.click(step, visionPoint)
            } catch {
                return .outcome(.failed(error.localizedDescription))
            }
            await hooks.audit("recipe.target", "step=\(step.order) tier=vision")
            await hooks.audit("recipe.step", "step=\(step.order) tier=vision status=verify-skipped-skill")
            return .proceed
        }
        await hooks.audit("recipe.target", "step=\(step.order) tier=none outcome=missed")
        return .outcome(.replan(.targetNotFound(stepOrder: step.order)))
    }
}
