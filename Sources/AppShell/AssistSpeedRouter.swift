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
    let terminalAction: CUAction?

    init(lane: AssistRouteLane, speedPlan: AgentSpeedRoutePlan, terminalAction: CUAction? = nil) {
        self.lane = lane
        self.speedPlan = speedPlan
        self.terminalAction = terminalAction
    }

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
    var directAppHint: String?
    var directURLHint: String?

    init(
        backgroundWebAvailable: Bool = true,
        recallEnabled: Bool = true,
        harnessTier: HarnessTier = .readOnly,
        accessibilityAvailable: Bool = true,
        localOCRAvailable: Bool = true,
        directAppHint: String? = nil,
        directURLHint: String? = nil
    ) {
        self.backgroundWebAvailable = backgroundWebAvailable
        self.recallEnabled = recallEnabled
        self.harnessTier = harnessTier
        self.accessibilityAvailable = accessibilityAvailable
        self.localOCRAvailable = localOCRAvailable
        self.directAppHint = Self.cleanHint(directAppHint)
        self.directURLHint = Self.cleanHint(directURLHint)
    }

    private static func cleanHint(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
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

        let urlHint = subtask.startURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = urlHint.isEmpty ? context.directURLHint : urlHint
        if let url, !url.isEmpty {
            return AssistRouteDecision(
                lane: .deterministicOpenURL(url),
                speedPlan: speedPlan,
                terminalAction: Self.isTerminalOpenOnly(goal) && Self.isSafeWebURL(url) ? .openURL(url) : nil
            )
        }
        let appHint = subtask.app.trimmingCharacters(in: .whitespacesAndNewlines)
        let app = appHint.isEmpty ? context.directAppHint : appHint
        if let app, !app.isEmpty {
            return AssistRouteDecision(
                lane: .deterministicOpenApp(app),
                speedPlan: speedPlan,
                terminalAction: Self.isTerminalOpenOnly(goal) ? .openApp(app) : nil
            )
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

    static func isTerminalOpenOnly(_ goal: String) -> Bool {
        let normalized = " " + goal.lowercased()
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,"))) + " "
        let startsOpen = [
            " open ", " launch ", " go to ", " visit ",
        ].contains { normalized.hasPrefix($0) }
        guard startsOpen else { return false }
        let followupMarkers = [
            " and ", " then ", " after ", " write ", " type ", " send ", " fill ",
            " submit ", " create ", " make ", " edit ", " change ", " update ",
            " search ", " find ", " look up ", " read ", " summarize ", " compare ",
            " book ", " buy ", " log in ", " sign in ", " upload ", " download ",
        ]
        return !followupMarkers.contains { normalized.contains($0) }
    }

    static func isSafeWebURL(_ value: String) -> Bool {
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    static func firstSafeWebURL(in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"https?://[^\s<>"']+"#, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let matchRange = Range(match.range, in: text) else {
            return nil
        }
        let value = String(text[matchRange])
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,);]")))
        return isSafeWebURL(value) ? value : nil
    }
}
