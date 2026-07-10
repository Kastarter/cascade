import ProviderKit
import Testing

@Test
func speedRouterPrefersRecordRecallBeforeVisualFallback() {
    let source = SourcePlan(
        routingIntent: .answerRecord,
        candidateSources: [.recordedMemory, .web],
        cleanQuery: "invoice from yesterday"
    )

    let plan = AgentSpeedRouter.plan(goal: "Find the invoice from yesterday", sourcePlan: source)

    #expect(plan.primary?.lane == .recordRecall)
    #expect(plan.fallbackVisual?.lane == .visualComputerUse)
    #expect(plan.avoidsVisualComputerUseFirst)
}

@Test
func speedRouterPrefersBackgroundWebForWebOnlyRoute() {
    let source = SourcePlan(
        routingIntent: .webFact,
        candidateSources: [.web],
        cleanQuery: "latest exchange rate"
    )

    let plan = AgentSpeedRouter.plan(goal: "look up the latest exchange rate", sourcePlan: source)

    #expect(plan.primary?.lane == .backgroundWeb)
    #expect(plan.primary?.requiresModelVision == false)
    #expect(plan.primary?.requiresScreenCapture == false)
}

@Test
func speedRouterRequiredWebOutranksOptionalCheapSources() {
    let source = SourcePlan(
        routingIntent: .mixed,
        candidateSources: [.recordedMemory, .web],
        cleanQuery: "current filing deadline",
        requiredSource: .web,
        stopPolicy: .requireRequiredSource
    )

    let plan = AgentSpeedRouter.plan(goal: "look up the current filing deadline", sourcePlan: source)

    #expect(plan.primary?.lane == .backgroundWeb)
}

@Test
func speedRouterFallsBackWhenFastLaneUnavailable() {
    let source = SourcePlan(
        routingIntent: .webFact,
        candidateSources: [.web],
        cleanQuery: "latest exchange rate"
    )
    let capabilities = AgentSpeedCapabilities(backgroundWebAvailable: false)

    let plan = AgentSpeedRouter.plan(
        goal: "look up the latest exchange rate",
        sourcePlan: source,
        capabilities: capabilities
    )

    #expect(plan.primary?.lane == .visualComputerUse)
    #expect(plan.primary?.requiresModelVision == true)
}

@Test
func speedRouterUsesAccessibilityThenOCRForVisibleScreenQueries() {
    let source = SourcePlan(
        routingIntent: .locateVisible,
        candidateSources: [.onScreen],
        cleanQuery: "send button"
    )

    let plan = AgentSpeedRouter.plan(goal: "where is the send button on screen", sourcePlan: source)
    let lanes = plan.options.map(\.lane)

    #expect(plan.primary?.lane == .accessibilitySnapshot)
    #expect(lanes.contains(.localOCR))
    #expect(lanes.last == .visualComputerUse)
}

@Test
func speedRouterDirectOpenSkipsVisualComputerUse() {
    let source = SourcePlan(
        routingIntent: .action,
        candidateSources: [.action],
        cleanQuery: "Open Notes"
    )

    let plan = AgentSpeedRouter.plan(goal: "Open Notes", sourcePlan: source)

    #expect(plan.primary?.lane == .directAppLaunch)
    #expect(plan.primary?.estimatedLatencyMilliseconds ?? 999 < 200)
}

@Test
func speedRouteAuditDescriptorDoesNotLeakGoalText() {
    let raw = "SecretNeedleExchangeRate"
    let source = SourcePlan(routingIntent: .webFact, candidateSources: [.web], cleanQuery: raw)

    let detail = AgentSpeedRouter.plan(goal: raw, sourcePlan: source).auditDescriptor(goal: raw)

    #expect(detail.contains("primary=background_web"))
    #expect(detail.contains("goalHash="))
    #expect(!detail.contains(raw))
}
