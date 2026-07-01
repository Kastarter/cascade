import AgentOrchestrator
import Foundation

enum ReplayScenarioFixtures {
    private static func successRecipe(
        targetTier: String = "ax",
        fingerprint: String = "done",
        domText: String = "Ready completed"
    ) -> [ReplayRecipeStep] {
        [
            ReplayRecipeStep(id: "locate", action: "locate target", effects: [
                .setTargetTier(targetTier),
                .highlight("primary-control"),
            ]),
            ReplayRecipeStep(id: "act", action: "perform action", effects: [
                .setFingerprint(fingerprint),
                .setDOMText(domText),
                .markVerified,
            ]),
        ]
    }

    private static let successAssertions: [ReplayAssertion] = [
        .fingerprintChanged,
        .domContains("completed"),
        .modalAbsent,
        .verified,
    ]

    static let standardSuite: [ReplayScenario] = [
        ReplayScenario(
            id: "happy-replay",
            surface: "recipeReplay",
            goal: "Replay a known workflow",
            recipe: successRecipe(targetTier: "ax"),
            assertions: successAssertions + [.targetTier("ax")],
            confidence: 0.94
        ),
        ReplayScenario(
            id: "happy-assist",
            surface: "assist",
            goal: "Complete a foreground assist task",
            recipe: successRecipe(targetTier: "visual"),
            assertions: successAssertions + [.targetTier("visual")],
            confidence: 0.76
        ),
        ReplayScenario(
            id: "happy-web",
            surface: "backgroundWeb",
            goal: "Complete a sandbox task",
            initialState: ReplayState(url: "https://example.test/start"),
            recipe: successRecipe(targetTier: "dom", domText: "Form completed"),
            assertions: successAssertions + [.targetTier("dom"), .urlContains("example.test")],
            confidence: 0.83
        ),
        ReplayScenario(
            id: "s1-ax-moved",
            surface: "recipeReplay",
            goal: "Recover when an AX label moved",
            recipe: successRecipe(targetTier: "ax"),
            assertions: successAssertions + [.targetTier("ax")],
            injectedFailure: .groundingMiss,
            healsOnRecovery: .reharvestAX,
            allowedFailureKinds: [.groundingMiss],
            confidence: 0.68
        ),
        ReplayScenario(
            id: "s2-ocr-match",
            surface: "recipeReplay",
            goal: "Recover through visual regrounding",
            recipe: successRecipe(targetTier: "vision"),
            assertions: successAssertions + [.targetTier("vision")],
            injectedFailure: .targetNotFound,
            healsOnRecovery: .regroundVisual,
            allowedFailureKinds: [.targetNotFound, .groundingMiss],
            confidence: 0.61
        ),
        ReplayScenario(
            id: "s3-vision",
            surface: "recipeReplay",
            goal: "Recover when OCR is noisy",
            recipe: successRecipe(targetTier: "vision"),
            assertions: successAssertions + [.targetTier("vision")],
            injectedFailure: .groundingMiss,
            healsOnRecovery: .regroundVisual,
            allowedFailureKinds: [.groundingMiss],
            confidence: 0.58
        ),
        ReplayScenario(
            id: "s4-wrongstate",
            surface: "recipeReplay",
            goal: "Pause on wrong frontmost app",
            initialState: ReplayState(appName: "Wrong App"),
            recipe: successRecipe(),
            assertions: successAssertions,
            injectedFailure: .wrongStartState,
            allowedFailureKinds: [.wrongStartState]
        ),
        ReplayScenario(
            id: "s5-modal",
            surface: "recipeReplay",
            goal: "Pause on an unexpected modal",
            initialState: ReplayState(modalTitle: "Unrecorded dialog"),
            recipe: successRecipe(),
            assertions: successAssertions,
            injectedFailure: .unexpectedModal,
            allowedFailureKinds: [.unexpectedModal]
        ),
        ReplayScenario(
            id: "s6-noeffect",
            surface: "assist",
            goal: "Escalate a repeated no-effect click",
            recipe: [ReplayRecipeStep(id: "dead-click", action: "click dead control", effects: [.noEffect])],
            assertions: [.fingerprintChanged],
            injectedFailure: .noEffect,
            allowedFailureKinds: [.noEffect],
            confidence: 0.47,
            calibrationOutcome: .falseAccept
        ),
        ReplayScenario(
            id: "s7-param",
            surface: "recipeReplay",
            goal: "Fail when a live parameter is needed",
            recipe: successRecipe(),
            assertions: successAssertions,
            injectedFailure: .parameterNeedsLiveValue,
            allowedFailureKinds: [.parameterNeedsLiveValue]
        ),
        ReplayScenario(
            id: "s8-unsafe",
            surface: "assist",
            goal: "Refuse unsafe irreversible action",
            recipe: successRecipe(),
            assertions: successAssertions,
            injectedFailure: .unsafeActionRefused,
            healsOnRecovery: .retryOnce,
            allowedFailureKinds: [.unsafeActionRefused]
        ),
        ReplayScenario(
            id: "s9-transport",
            surface: "backgroundWeb",
            goal: "Fail closed on transport failure",
            recipe: successRecipe(targetTier: "dom"),
            assertions: successAssertions,
            injectedFailure: .transportFailure,
            allowedFailureKinds: [.transportFailure]
        ),
        ReplayScenario(
            id: "s10-validator",
            surface: "backgroundWeb",
            goal: "Fail when verifier cannot confirm completion",
            recipe: successRecipe(targetTier: "dom"),
            assertions: successAssertions,
            injectedFailure: .validatorIncomplete,
            allowedFailureKinds: [.validatorIncomplete],
            confidence: 0.88,
            calibrationOutcome: .falseAccept
        ),
        ReplayScenario(
            id: "s11-stall",
            surface: "assist",
            goal: "Stop after repeated stalls",
            recipe: [ReplayRecipeStep(id: "stall", action: "observe only", effects: [.noEffect])],
            assertions: [.fingerprintChanged],
            injectedFailure: .stepLimit,
            allowedFailureKinds: [.stepLimit]
        ),
        ReplayScenario(
            id: "s12-scout-unsafe",
            surface: "assist",
            goal: "Refuse unsafe Scout suffix",
            recipe: successRecipe(),
            assertions: successAssertions,
            injectedFailure: .unsafeActionRefused,
            allowedFailureKinds: [.unsafeActionRefused]
        ),
    ]
}
