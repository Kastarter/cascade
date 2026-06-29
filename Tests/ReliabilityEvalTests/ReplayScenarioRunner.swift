import AgentOrchestrator
import Foundation

enum ReplayScenarioRunner {
    static func run(_ scenario: ReplayScenario) -> ScenarioOutcome {
        var state = scenario.initialState
        let initialFingerprint = state.fingerprint
        var retries = 0
        var modalCount = state.modalTitle == nil ? 0 : 1
        var noEffectCount = 0
        var validatorIncompleteCount = 0
        var redundantStepCount = scenario.redundantStepCount
        var wrongStartStateCount = scenario.wrongStartStateCount

        func makeOutcome(status: ScenarioStatus, failureKind: AgentFailureKind?) -> ScenarioOutcome {
            let subgoalTotal = scenario.subgoalCount
            let defaultSubgoalsSucceeded = status == .success ? subgoalTotal : max(0, subgoalTotal - 1)
            return ScenarioOutcome(
                id: scenario.id,
                surface: scenario.surface,
                status: status,
                failureKind: failureKind,
                stepsAttempted: scenario.recipe.count,
                retries: retries,
                targetTier: state.targetTier,
                modalCount: modalCount,
                noEffectCount: noEffectCount,
                validatorIncompleteCount: validatorIncompleteCount,
                verificationFailureCount: state.verificationFailures,
                subgoalCount: subgoalTotal,
                subgoalsSucceeded: scenario.subgoalsSucceeded ?? defaultSubgoalsSucceeded,
                redundantStepCount: redundantStepCount,
                wrongStartStateCount: wrongStartStateCount,
                confidence: scenario.confidence,
                actualSuccess: scenario.confidence == nil ? nil : status == .success,
                calibrationOutcome: scenario.calibrationOutcome
            )
        }

        func applyRecipe() {
            for step in scenario.recipe {
                for effect in step.effects {
                    apply(effect, to: &state, modalCount: &modalCount)
                }
            }
        }

        if let failure = scenario.injectedFailure {
            if failure == .unexpectedModal, state.modalTitle == nil {
                apply(.showModal("Unexpected dialog"), to: &state, modalCount: &modalCount)
            }
            if failure == .noEffect {
                noEffectCount += 1
                redundantStepCount += 1
            }
            if failure == .wrongStartState {
                wrongStartStateCount += 1
            }
            if failure == .validatorIncomplete {
                validatorIncompleteCount += 1
                apply(.markVerificationFailure, to: &state, modalCount: &modalCount)
            }

            let plan = AgentRecoveryPolicy.plan(for: failure)
            for (offset, action) in plan.retryRungs.enumerated() {
                retries = offset + 1
                applyRecovery(action, to: &state, modalCount: &modalCount)
                if action == scenario.healsOnRecovery {
                    applyRecipe()
                    let failedAssertions = failures(for: scenario.assertions, state: state, initialFingerprint: initialFingerprint)
                    return makeOutcome(status: failedAssertions.isEmpty ? .success : .failed, failureKind: failure)
                }
            }
            return makeOutcome(status: terminalStatus(plan.terminal), failureKind: failure)
        }

        applyRecipe()
        let failedAssertions = failures(for: scenario.assertions, state: state, initialFingerprint: initialFingerprint)
        return makeOutcome(status: failedAssertions.isEmpty ? .success : .failed, failureKind: failedAssertions.isEmpty ? nil : .validatorIncomplete)
    }

    private static func apply(_ effect: ReplayEffect, to state: inout ReplayState, modalCount: inout Int) {
        switch effect {
        case .setApp(let appName):
            state.appName = appName
        case .setURL(let url):
            state.url = url
        case .setDOMText(let text):
            state.domText = text
        case .appendDOMText(let text):
            state.domText += " " + text
        case .setFingerprint(let fingerprint):
            state.fingerprint = fingerprint
        case .showModal(let title):
            if state.modalTitle == nil { modalCount += 1 }
            state.modalTitle = title
        case .dismissModal:
            state.modalTitle = nil
        case .highlight(let target):
            state.highlightedTarget = target
        case .setTargetTier(let tier):
            state.targetTier = tier
        case .markVerified:
            state.verified = true
        case .markVerificationFailure:
            state.verificationFailures += 1
            state.verified = false
        case .wrongStartState:
            state.fingerprint = "wrong-start"
        case .noEffect:
            break
        }
    }

    private static func applyRecovery(
        _ action: RecoveryAction,
        to state: inout ReplayState,
        modalCount: inout Int
    ) {
        switch action {
        case .reharvestAX:
            apply(.setTargetTier("ax"), to: &state, modalCount: &modalCount)
            apply(.highlight("reharvested-control"), to: &state, modalCount: &modalCount)
        case .regroundVisual:
            apply(.setTargetTier("vision"), to: &state, modalCount: &modalCount)
            apply(.highlight("visual-control"), to: &state, modalCount: &modalCount)
        case .recapture:
            apply(.setFingerprint("recaptured"), to: &state, modalCount: &modalCount)
        case .alternateTarget:
            apply(.highlight("alternate-control"), to: &state, modalCount: &modalCount)
        case .safeDismiss:
            apply(.dismissModal, to: &state, modalCount: &modalCount)
        case .diagnosticProbe, .rerunVerifier:
            apply(.markVerificationFailure, to: &state, modalCount: &modalCount)
        case .backoffRetry, .retryOnce:
            apply(.appendDOMText("retry"), to: &state, modalCount: &modalCount)
        case .escalate, .pauseForUser, .failWithReason, .refuse, .stop, .none:
            break
        }
    }

    private static func failures(
        for assertions: [ReplayAssertion],
        state: ReplayState,
        initialFingerprint: String
    ) -> [String] {
        assertions.compactMap { assertion in
            switch assertion {
            case .domContains(let text):
                return state.domText.contains(text) ? nil : "dom missing \(text)"
            case .urlContains(let text):
                return state.url.contains(text) ? nil : "url missing \(text)"
            case .fingerprintChanged:
                return state.fingerprint != initialFingerprint ? nil : "fingerprint unchanged"
            case .modalAbsent:
                return state.modalTitle == nil ? nil : "modal still present"
            case .highlighted(let target):
                return state.highlightedTarget == target ? nil : "highlight mismatch"
            case .targetTier(let tier):
                return state.targetTier == tier ? nil : "target tier mismatch"
            case .verified:
                return state.verified ? nil : "not verified"
            }
        }
    }

    private static func terminalStatus(_ action: RecoveryAction) -> ScenarioStatus {
        switch action {
        case .refuse:
            return .refused
        case .stop:
            return .userStop
        case .pauseForUser:
            return .paused
        case .escalate:
            return .escalated
        case .failWithReason, .none:
            return .failed
        default:
            return .failed
        }
    }
}
