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
    #expect(openApp.terminalAction == .openApp("Notes"))
    #expect(openURL.terminalAction == .openURL("https://example.com"))
}

@Test
func assistSpeedRouterUsesDirectHintsForSinglePartOpenCommands() {
    let openApp = AssistSpeedRouter().decide(
        goal: "Open Notes",
        subtask: AgentSubtask(task: "Open Notes"),
        routeHint: SourcePlan(routingIntent: .action, candidateSources: [.action], cleanQuery: "Open Notes"),
        context: AssistRouteContext(directAppHint: "Notes")
    )
    let openURL = AssistSpeedRouter().decide(
        goal: "Open https://example.com",
        subtask: AgentSubtask(task: "Open https://example.com"),
        routeHint: SourcePlan(routingIntent: .action, candidateSources: [.action], cleanQuery: "Open https://example.com"),
        context: AssistRouteContext(directURLHint: "https://example.com")
    )

    #expect(openApp.lane == .deterministicOpenApp("Notes"))
    #expect(openURL.lane == .deterministicOpenURL("https://example.com"))
    #expect(openApp.terminalAction == .openApp("Notes"))
    #expect(openURL.terminalAction == .openURL("https://example.com"))
}

@Test
func assistSpeedRouterDoesNotTerminalOpenWhenMoreWorkFollows() {
    let write = AssistSpeedRouter().decide(
        goal: "Open Notes and write hello",
        subtask: AgentSubtask(task: "Open Notes and write hello", app: "Notes"),
        routeHint: SourcePlan(routingIntent: .action, candidateSources: [.action], cleanQuery: "Open Notes and write hello")
    )
    let search = AssistSpeedRouter().decide(
        goal: "Go to https://example.com and search pricing",
        subtask: AgentSubtask(task: "Go to https://example.com and search pricing", startURL: "https://example.com"),
        routeHint: SourcePlan(routingIntent: .action, candidateSources: [.action], cleanQuery: "Go to https://example.com and search pricing")
    )

    #expect(write.terminalAction == nil)
    #expect(search.terminalAction == nil)
    #expect(!write.usesExistingComputerUseLoop)
    #expect(!search.usesExistingComputerUseLoop)
}

@Test
func terminalOpenOnlyHeuristicRejectsFollowupWork() {
    #expect(AssistSpeedRouter.isTerminalOpenOnly("Open Notes"))
    #expect(AssistSpeedRouter.isTerminalOpenOnly("visit https://example.com"))
    #expect(!AssistSpeedRouter.isTerminalOpenOnly("Open Notes and write hello"))
    #expect(!AssistSpeedRouter.isTerminalOpenOnly("Go to example.com then search pricing"))
    #expect(!AssistSpeedRouter.isTerminalOpenOnly("Find the invoice"))
}

@Test
func firstSafeWebURLOnlyAcceptsHTTPFamilyURLs() {
    #expect(AssistSpeedRouter.firstSafeWebURL(in: "Open https://example.com.") == "https://example.com")
    #expect(AssistSpeedRouter.firstSafeWebURL(in: "Open http://example.com/path?q=1") == "http://example.com/path?q=1")
    #expect(AssistSpeedRouter.firstSafeWebURL(in: "Open file:///etc/passwd") == nil)
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
