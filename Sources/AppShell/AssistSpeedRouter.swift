import Foundation
import ProviderKit
import SandboxKit

enum AssistRouteLane: Sendable, Equatable {
    case localEvidence
    case backgroundWeb
    case deterministicOpenApp(String)
    case deterministicOpenURL(String)
    case onScreenSemantic
    case fallbackComputerUse(String)
}

struct AssistRouteDecision: Sendable, Equatable {
    let lane: AssistRouteLane
    let speedPlan: AgentSpeedRoutePlan

    var shouldRunBackgroundWeb: Bool {
        lane == .backgroundWeb
    }

    var shouldAttemptBackgroundWeb: Bool {
        shouldRunBackgroundWeb
            || speedPlan.sourcePlan.requiredSource == .web
            || speedPlan.sourcePlan.routingIntent == .webFact
            || (
                speedPlan.sourcePlan.candidateSources.first == .web
                && speedPlan.sourcePlan.stopPolicy == .requireRequiredSource
            )
    }

    var usesExistingComputerUseLoop: Bool {
        switch lane {
        case .onScreenSemantic, .fallbackComputerUse:
            true
        case .localEvidence, .backgroundWeb, .deterministicOpenApp, .deterministicOpenURL:
            false
        }
    }
}

struct AssistRouteContext: Sendable, Equatable {
    var backgroundWebAvailable: Bool
    var recallEnabled: Bool
    var harnessTier: HarnessTier
    var accessibilityAvailable: Bool
    var localOCRAvailable: Bool

    init(
        backgroundWebAvailable: Bool = true,
        recallEnabled: Bool = true,
        harnessTier: HarnessTier = .readOnly,
        accessibilityAvailable: Bool = true,
        localOCRAvailable: Bool = true
    ) {
        self.backgroundWebAvailable = backgroundWebAvailable
        self.recallEnabled = recallEnabled
        self.harnessTier = harnessTier
        self.accessibilityAvailable = accessibilityAvailable
        self.localOCRAvailable = localOCRAvailable
    }
}

struct AssistSpeedRouter: Sendable {
    func decide(
        goal: String,
        subtask: AgentSubtask,
        routeHint: SourcePlan?,
        context: AssistRouteContext = AssistRouteContext()
    ) -> AssistRouteDecision {
        let sourcePlan = routeHint ?? SourceRouter().route(goal, environment: .onScreen)
        let speedPlan = AgentSpeedRouter.plan(
            goal: goal,
            sourcePlan: sourcePlan,
            capabilities: AgentSpeedCapabilities(
                harnessTier: context.harnessTier,
                recallEnabled: context.recallEnabled,
                backgroundWebAvailable: context.backgroundWebAvailable,
                accessibilityAvailable: context.accessibilityAvailable,
                localOCRAvailable: context.localOCRAvailable,
                directAppLaunchAvailable: true
            )
        )

        if !subtask.app.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return AssistRouteDecision(lane: .deterministicOpenApp(subtask.app), speedPlan: speedPlan)
        }
        if !subtask.startURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return AssistRouteDecision(lane: .deterministicOpenURL(subtask.startURL), speedPlan: speedPlan)
        }

        switch speedPlan.primary?.lane {
        case .recordRecall, .localHarness:
            return AssistRouteDecision(lane: .localEvidence, speedPlan: speedPlan)
        case .backgroundWeb:
            return AssistRouteDecision(lane: .backgroundWeb, speedPlan: speedPlan)
        case .directAppLaunch:
            return AssistRouteDecision(lane: .fallbackComputerUse("direct open needs a concrete app or URL from the task plan"), speedPlan: speedPlan)
        case .accessibilitySnapshot, .localOCR:
            return AssistRouteDecision(lane: .onScreenSemantic, speedPlan: speedPlan)
        case .visualComputerUse, nil:
            return AssistRouteDecision(lane: .fallbackComputerUse("no faster available lane"), speedPlan: speedPlan)
        }
    }
}
