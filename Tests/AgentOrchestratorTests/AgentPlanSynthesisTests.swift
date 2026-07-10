import AgentOrchestrator
import CascadeMemory
import Testing

private func creationPlan(steps: [RecipeStep], occurrences: Int) -> AgentCreationPlan {
    AgentPlanSynthesizer().synthesize(
        goal: "Repeat the demonstrated workflow for the current case",
        signature: "plan-\(occurrences)-\(steps.count)",
        recipe: AgentRecipe(steps: steps),
        apps: Array(Set(steps.map(\.appName))).sorted(),
        occurrenceCount: occurrences,
        occurrenceIDs: (1...max(1, occurrences)).map(Int64.init)
    )
}

@Test
func agentPlanAcceptsSemanticReplayTargets() throws {
    let plan = creationPlan(
        steps: [
            RecipeStep(order: 0, kind: .click, x: 10, y: 10, text: "Send", appName: "Mail"),
            RecipeStep(order: 1, kind: .click, appName: "Mail", targetDescriptor: "role=AXButton id=reply"),
            RecipeStep(order: 2, kind: .click, appName: "Mail", ocrAnchor: "Archive"),
        ],
        occurrences: 1
    )

    try AgentPlanValidator().validate(plan)

    let textTarget = try #require(plan.targetChecks.first { $0.order == 0 })
    let descriptorTarget = try #require(plan.targetChecks.first { $0.order == 1 })
    let anchorTarget = try #require(plan.targetChecks.first { $0.order == 2 })
    #expect(textTarget.targetTextHash == AuditIdentity.hash("Send"))
    #expect(textTarget.hasSemanticReplayTarget)
    #expect(descriptorTarget.hasSemanticReplayTarget)
    #expect(anchorTarget.hasSemanticReplayTarget)
    #expect(plan.auditDetail().contains("anchoredTargetCount=3"))
}

@Test
func agentPlanTreatsParameterizedClicksAsLiveSlots() throws {
    let plan = creationPlan(
        steps: [
            RecipeStep(
                order: 0,
                kind: .click,
                x: 10,
                y: 10,
                text: "personName slot",
                appName: "CRM",
                isParameter: true,
                parameterKey: "customer",
                parameterKind: .personName,
                valueExamples: ["personName:Aaaa Aaaa"],
                valueHashes: ["abc123"]
            ),
        ],
        occurrences: 1
    )

    try AgentPlanValidator().validate(plan)
    #expect(plan.liveValueSlots.count == 1)
    #expect(plan.liveValueSlots.first?.kind == .personName)
    #expect(plan.auditDetail().contains("liveSlotCount=1"))
}

@Test
func agentPlanRejectsSingleDemoCoordinateOnlyClicks() {
    let plan = creationPlan(
        steps: [RecipeStep(order: 0, kind: .click, x: 10, y: 10, appName: "Mail")],
        occurrences: 1
    )

    do {
        try AgentPlanValidator().validate(plan)
        Issue.record("expected coordinate-only replay target rejection")
    } catch let error as AgentPlanValidationError {
        #expect(error.issueCodes == ["coordinate_only_replay_target"])
    } catch {
        Issue.record("expected AgentPlanValidationError, got \(error)")
    }
}

@Test
func agentPlanKeepsRepeatedCoordinateOnlyCompatibility() throws {
    let plan = creationPlan(
        steps: [RecipeStep(order: 0, kind: .click, x: 10, y: 10, appName: "Mail")],
        occurrences: 3
    )

    try AgentPlanValidator().validate(plan)
    #expect(plan.targetChecks.first?.hasReplayTarget == true)
    #expect(plan.targetChecks.first?.hasSemanticReplayTarget == false)
}
