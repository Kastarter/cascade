import CascadeMemory
import Foundation
import Testing
import WasteDetection

@testable import AgentOrchestrator

private let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

private func step(
    _ order: Int,
    _ kind: RecipeStepKind,
    app: String = "Mail",
    window: String? = "Inbox",
    text: String? = nil,
    key: String? = nil,
    modifiers: [String] = [],
    anchor: String? = nil,
    isParameter: Bool = false
) -> RecipeStep {
    RecipeStep(
        order: order,
        kind: kind,
        text: text,
        key: key,
        modifiers: modifiers,
        appName: app,
        windowTitleHint: window,
        ocrAnchor: anchor,
        isParameter: isParameter
    )
}

@Test
func sketchOmitsPrivateTypedTextAndScrubsLabels() {
    let recipe = AgentRecipe(steps: [
        step(0, .activateApp),
        step(1, .click, anchor: "Reply to candidate"),
        step(2, .type, text: "SSN 123-45-6789 secret offer", isParameter: true),
        step(3, .click, anchor: "Order 123456789"),
    ])

    let sketch = TrajectorySketchBuilder().build(goal: "Reply to the candidate with the current offer", recipe: recipe)

    #expect(sketch.firstActions.map(\.label) == [
        "switch to Mail",
        "click \"Reply to candidate\"",
        "type current value",
        "click \"Order <NUMBER>\"",
    ])
    #expect(sketch.safeAnchors.contains("Order <NUMBER>"))
    #expect(!sketch.promptText.contains("123-45-6789"))
    #expect(!sketch.promptText.contains("secret offer"))
    #expect(!sketch.promptText.contains("123456789"))
}

@Test
func sketchPreservesActionOrderChecksAndCollapsesEquivalentSteps() {
    let recipe = AgentRecipe(steps: [
        step(0, .activateApp),
        step(1, .click, anchor: "Send"),
        step(2, .click, anchor: "Send"),
        step(3, .key, key: "return", modifiers: ["command"]),
    ])
    let checks = [
        AuditEvent(id: 1, createdAt: baseDate, actor: "agent", action: "assist.verify", detail: "verified: message sent"),
        AuditEvent(id: 2, createdAt: baseDate.addingTimeInterval(1), actor: "agent", action: "audit.complete", detail: "completed: audit row saved"),
    ]

    let sketch = TrajectorySketchBuilder().build(goal: "Send the prepared reply", recipe: recipe, auditEvents: checks)

    #expect(sketch.firstActions.map(\.label) == ["switch to Mail", "click \"Send\"", "Command+Return"])
    #expect(sketch.firstActions[1].repeatCount == 2)
    #expect(sketch.firstActions[1].sourceOrders == [1, 2])
    #expect(sketch.expectedChecks.count == 2)
    #expect(sketch.expectedChecks[0].label.contains("message sent"))
    #expect(sketch.expectedChecks[1].label.contains("audit row saved"))
    #expect(sketch.expectedChecks[0].matches(audit: checks[0]))
}

@Test
func sketchIncludesOnlyVerifiedRecoveries() {
    let recipe = AgentRecipe(steps: [
        step(0, .activateApp),
        step(1, .click, anchor: "Retry"),
    ])
    let auditEvents = [
        AuditEvent(
            id: 10,
            createdAt: baseDate,
            actor: "agent",
            action: "agent.recovery",
            detail: "failure=target_not_found correction=recapture, verified=true"
        ),
        AuditEvent(
            id: 11,
            createdAt: baseDate.addingTimeInterval(1),
            actor: "agent",
            action: "agent.recovery",
            detail: "failure=timeout correction=retry, unverified"
        ),
    ]
    let trace = AgentTrace(
        traceID: "trace",
        goal: "Retry failed send",
        surface: "screen",
        spans: [
            TraceSpan(
                id: "unverified-span",
                parentID: nil,
                kind: .tool,
                name: "recovery retry",
                startMs: 1,
                durationMs: 1,
                status: .ok,
                attributes: ["recovery.action": "retry", "recovery.verified": "false", "failure.kind": "timeout"]
            ),
        ]
    )

    let sketch = TrajectorySketchBuilder().build(
        goal: "Retry failed send",
        recipe: recipe,
        auditEvents: auditEvents,
        traces: [trace]
    )

    #expect(sketch.failureCorrections == [
        TrajectoryCorrection(source: .auditEvent, failureKind: "target_not_found", correction: "recapture", evidenceID: "10")
    ])
    #expect(!sketch.promptText.contains("timeout"))
}

@Test
func structuredChecksMatchAuditTraceAndExperienceEvidence() throws {
    let recipe = AgentRecipe(steps: [step(0, .activateApp)])
    let audit = AuditEvent(
        id: 20,
        createdAt: baseDate,
        actor: "agent",
        action: "assist.verify",
        detail: "verified: reply sent"
    )
    let traceSpan = TraceSpan(
        id: "eval-1",
        parentID: nil,
        kind: .eval,
        name: "reply verifier",
        startMs: 2,
        durationMs: 3,
        status: .ok,
        attributes: ["expected": "reply sent"]
    )
    let trace = AgentTrace(traceID: "trace-1", goal: "Send reply", surface: "screen", spans: [traceSpan])
    let experience = AgentExperienceCase(
        id: 30,
        appName: "Mail",
        goalPattern: "send reply",
        recipeSignature: "mail-send",
        outcome: .success,
        verificationSignal: .verified,
        actionCount: 3
    )

    let sketch = TrajectorySketchBuilder().build(
        goal: "Send reply",
        recipe: recipe,
        auditEvents: [audit],
        experiences: [experience],
        traces: [trace]
    )

    let auditCheck = try #require(sketch.expectedChecks.first { $0.source == .auditEvent })
    let traceCheck = try #require(sketch.expectedChecks.first { $0.source == .traceSpan })
    let experienceCheck = try #require(sketch.expectedChecks.first { $0.source == .agentExperience })
    #expect(auditCheck.matches(audit: audit))
    #expect(traceCheck.matches(traceSpan: traceSpan))
    #expect(experienceCheck.matches(experience: experience))
}

@Test
func rankPrefersCloserAppAndGoalSketches() {
    let builder = TrajectorySketchBuilder()
    let mail = builder.build(
        goal: "Copy invoice totals from Mail into Numbers",
        recipe: AgentRecipe(steps: [
            step(0, .activateApp, app: "Mail"),
            step(1, .click, app: "Mail", anchor: "Invoice"),
        ])
    )
    let safari = builder.build(
        goal: "Open news article in Safari",
        recipe: AgentRecipe(steps: [
            step(0, .activateApp, app: "Safari", window: "News"),
            step(1, .click, app: "Safari", window: "News", anchor: "Top Stories"),
        ])
    )

    let ranked = builder.rank(
        [safari, mail],
        appName: "Mail",
        goal: "copy invoice amount from mail into spreadsheet"
    )

    #expect(ranked.first?.id == mail.id)
}

@Test
func createAgentPersistsPromptSafeDemoSketch() async throws {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("TrajectorySketchAgent-\(UUID().uuidString).sqlite")
        .path
    let store = try CascadeStore(path: path)
    let orchestrator = CascadeOrchestrator(store: store)
    let recipe = AgentRecipe(steps: [
        step(0, .activateApp, app: "Mail"),
        step(1, .click, app: "Mail", anchor: "Reply to candidate"),
        step(2, .type, app: "Mail", text: "SSN 123-45-6789 secret offer", isParameter: true),
    ])
    let waste = DetectedWaste(
        title: "Mail: reply",
        apps: ["Mail"],
        occurrences: 2,
        estimatedSecondsPerRun: 15,
        estimatedTotalSeconds: 30,
        recipe: recipe,
        evidence: [1, 2],
        confidence: 0.8,
        signature: "mail-reply"
    )
    let curated = CuratedAgent(
        source: waste,
        name: "Reply to candidate",
        why: "Repeated reply workflow",
        goal: "Reply to the candidate with the current offer",
        value: 30
    )

    let agent = try await orchestrator.createAgent(from: curated)

    let demo = try #require(agent.demoSketches.first)
    #expect(demo.appName == "Mail")
    #expect(demo.normalizedGoalTokens.contains("candidate"))
    #expect(!demo.promptText.contains("123-45-6789"))
    #expect(!demo.promptText.contains("secret offer"))
    #expect(try await store.agent(id: agent.id)?.demoSketches == agent.demoSketches)
}

@Test
func persistedDemoSketchRelevancePrefersMatchingAppAndGoal() {
    let mail = AgentDemoSketch(
        id: "mail-invoice",
        appName: "Mail",
        windowTitle: nil,
        normalizedGoalTokens: ["copy", "invoice", "totals"],
        promptText: "TRAJECTORY SKETCH\napp: Mail",
        actionCount: 2,
        anchorCount: 1,
        checkCount: 0
    )
    let safari = AgentDemoSketch(
        id: "safari-news",
        appName: "Safari",
        windowTitle: nil,
        normalizedGoalTokens: ["open", "article"],
        promptText: "TRAJECTORY SKETCH\napp: Safari",
        actionCount: 2,
        anchorCount: 1,
        checkCount: 0
    )
    let queryTokens = Set(TrajectorySketch.normalizedGoalTokens(from: "copy invoice total from mail into spreadsheet"))

    #expect(mail.relevanceScore(appName: "Mail", goalTokens: queryTokens) > safari.relevanceScore(appName: "Mail", goalTokens: queryTokens))
}
