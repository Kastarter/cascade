import Foundation
import ProviderKit
import SandboxKit
import Testing

@testable import AppShell

@Test
func speedRouterFlagIsDefaultOff() throws {
    let suite = "AssistSpeedRouterTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    #expect(!CascadeAppModel.experimentalSpeedRouterEnabled(defaults: defaults))
    defaults.set(true, forKey: CascadeAppModel.experimentalSpeedRouterKey)
    #expect(CascadeAppModel.experimentalSpeedRouterEnabled(defaults: defaults))
}

@Test
func assistSpeedRouterChoosesLocalEvidenceForRecordedMemory() {
    let route = SourcePlan(
        routingIntent: .answerRecord,
        candidateSources: [.recordedMemory, .web],
        cleanQuery: "invoice yesterday"
    )

    let decision = AssistSpeedRouter().decide(
        goal: "Find the invoice from yesterday",
        subtask: AgentSubtask(task: "Find the invoice from yesterday"),
        routeHint: route
    )

    #expect(decision.lane == .localEvidence)
    #expect(!decision.usesExistingComputerUseLoop)
}

@Test
func assistSpeedRouterChoosesBackgroundWebForWebRoute() {
    let route = SourcePlan(
        routingIntent: .webFact,
        candidateSources: [.web],
        cleanQuery: "latest exchange rate"
    )

    let decision = AssistSpeedRouter().decide(
        goal: "look up the latest exchange rate",
        subtask: AgentSubtask(task: "look up the latest exchange rate"),
        routeHint: route
    )

    #expect(decision.lane == .backgroundWeb)
    #expect(decision.shouldRunBackgroundWeb)
}

@Test
func assistSpeedRouterStillAttemptsRequiredWebWhenBackgroundWebUnavailable() {
    let route = SourcePlan(
        routingIntent: .webFact,
        candidateSources: [.web],
        cleanQuery: "latest exchange rate",
        requiredSource: .web,
        stopPolicy: .requireRequiredSource
    )

    let decision = AssistSpeedRouter().decide(
        goal: "look up the latest exchange rate",
        subtask: AgentSubtask(task: "look up the latest exchange rate"),
        routeHint: route,
        context: AssistRouteContext(backgroundWebAvailable: false)
    )

    #expect(decision.lane == .fallbackComputerUse("no faster available lane"))
    #expect(!decision.shouldRunBackgroundWeb)
    #expect(decision.shouldAttemptBackgroundWeb)
}

@Test
func assistSpeedRouterUsesPlannedAppAndURLBeforeModelLoop() {
    let openApp = AssistSpeedRouter().decide(
        goal: "Open Notes",
        subtask: AgentSubtask(task: "Open Notes", app: "Notes"),
        routeHint: SourcePlan(routingIntent: .action, candidateSources: [.action], cleanQuery: "Open Notes")
    )
    let openURL = AssistSpeedRouter().decide(
        goal: "Open the docs",
        subtask: AgentSubtask(task: "Open the docs", startURL: "https://example.com"),
        routeHint: SourcePlan(routingIntent: .action, candidateSources: [.action], cleanQuery: "Open the docs")
    )

    #expect(openApp.lane == .deterministicOpenApp("Notes"))
    #expect(openURL.lane == .deterministicOpenURL("https://example.com"))
    #expect(!openApp.usesExistingComputerUseLoop)
    #expect(!openURL.usesExistingComputerUseLoop)
}

@Test
func assistSpeedRouterFallsThroughToExistingLoopForScreenSemanticWork() {
    let route = SourcePlan(
        routingIntent: .locateVisible,
        candidateSources: [.onScreen],
        cleanQuery: "send"
    )

    let decision = AssistSpeedRouter().decide(
        goal: "where is the send button",
        subtask: AgentSubtask(task: "where is the send button"),
        routeHint: route
    )

    #expect(decision.lane == .onScreenSemantic)
    #expect(decision.usesExistingComputerUseLoop)
}
