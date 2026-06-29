import AgentOrchestrator
import CascadeMemory
import Foundation
import ProviderKit
import SandboxKit
import WasteDetection
import Testing

@testable import AppShell

private struct FakeCompleter: MessageCompleting {
    let canned: String
    func complete(system: String?, user: String, model: String, maxTokens: Int) async throws -> String {
        canned
    }
}

private let base = Date(timeIntervalSince1970: 1_700_000_000)

/// Builds the model in HEADLESS mode — injected temp store + orchestrator, no taps,
/// no capture, no audio, no scheduler — so the orchestration wiring can be exercised.
@MainActor
private func makeModel(curatorReply: String = #"{"agents":[]}"#) throws -> (model: CascadeAppModel, store: CascadeStore) {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("CascadeAppShellIT-\(UUID().uuidString).sqlite").path
    let store = try CascadeStore(path: path)
    let orchestrator = CascadeOrchestrator(store: store, curator: WorkflowCurator(client: FakeCompleter(canned: curatorReply)))
    // An ephemeral defaults suite per model — tests never read stale declines from,
    // or pollute, the real .standard defaults (and so don't contaminate each other).
    let defaults = UserDefaults(suiteName: "CascadeTest-\(UUID().uuidString)")!
    let model = try CascadeAppModel(store: store, orchestrator: orchestrator, defaults: defaults, startsSubsystems: false)
    return (model, store)
}

/// A repeated in-browser workflow the detector catches AND the automatable bar
/// keeps: a real five-action email reply in Safari (compose → select → type →
/// send), three times, spaced ~3s/action so each run represents ~12s — clearing
/// both the `minRepeatsToAutomate` and `minSecondsToReview` bars. Safari is always
/// registered to open https on macOS, so it passes `runsInBackground`
/// deterministically on any test Mac.
private func webWorkflowEvents() -> [InputEvent] {
    var events: [InputEvent] = []
    var i = 0
    for run in 0..<3 {
        let start = TimeInterval(run * 300)
        events.append(InputEvent(id: Int64(i), capturedAt: base.addingTimeInterval(start), kind: .click, x: 10, y: 10, text: "Compose", appName: "Safari", windowTitle: "Inbox - Gmail")); i += 1
        events.append(InputEvent(id: Int64(i), capturedAt: base.addingTimeInterval(start + 8), kind: .key, key: "a", modifiers: ["command"], appName: "Safari", windowTitle: "Inbox - Gmail")); i += 1
        events.append(InputEvent(id: Int64(i), capturedAt: base.addingTimeInterval(start + 16), kind: .type, text: "reply", appName: "Safari", windowTitle: "Inbox - Gmail")); i += 1
        events.append(InputEvent(id: Int64(i), capturedAt: base.addingTimeInterval(start + 24), kind: .click, x: 30, y: 30, text: "Send", appName: "Safari", windowTitle: "Inbox - Gmail")); i += 1
        events.append(InputEvent(id: Int64(i), capturedAt: base.addingTimeInterval(start + 32), kind: .key, key: "Return", modifiers: ["command"], appName: "Safari", windowTitle: "Inbox - Gmail")); i += 1
    }
    return events
}

/// Polls a MainActor condition until true or it times out (~5s), yielding so the
/// model's fire-and-forget Tasks can run.
@MainActor
private func waitUntil(_ condition: () -> Bool, maxTries: Int = 500) async throws {
    var tries = 0
    while !condition(), tries < maxTries {
        try await Task.sleep(for: .milliseconds(10))
        tries += 1
    }
}

private func waitForAudit(
    _ store: CascadeStore,
    action: String,
    maxTries: Int = 500
) async throws -> AuditEvent {
    var tries = 0
    while tries < maxTries {
        if let row = try await store.recentAudit(limit: 80).first(where: { $0.action == action }) {
            return row
        }
        try await Task.sleep(for: .milliseconds(10))
        tries += 1
    }
    throw CocoaError(.fileReadNoSuchFile)
}

private func waitForAudit(
    _ store: CascadeStore,
    action: String,
    detailContains needle: String,
    maxTries: Int = 500
) async throws -> AuditEvent {
    var tries = 0
    while tries < maxTries {
        if let row = try await store.recentAudit(limit: 80).first(where: { $0.action == action && $0.detail.contains(needle) }) {
            return row
        }
        try await Task.sleep(for: .milliseconds(10))
        tries += 1
    }
    throw CocoaError(.fileReadNoSuchFile)
}

private func expectAuditDetail(_ detail: String, excludesRawIdentityContaining token: String) {
    #expect(!detail.lowercased().contains(token.lowercased()))
}

private let curatorKeepsOne = """
{"agents":[{"index":0,"name":"Reply to refund emails with the policy link","why":"You do it by hand several times a day.","goal":"In Gmail, reply to each new refund request with the standard policy link.","value":0.9}]}
"""

@MainActor @Test
func modelBuildsHeadlessWithoutStartingHardware() throws {
    let (model, _) = try makeModel()
    // The point of C7: a real CascadeAppModel exists in a test, no hardware started.
    #expect(model.curatedWaste.isEmpty)
    #expect(model.agents.isEmpty)
    #expect(model.pendingCuratedAgents.isEmpty)
    #expect(!model.agentRunning)
}

@MainActor @Test
func refreshAllCuratesDetectedWorkflows() async throws {
    let (model, store) = try makeModel(curatorReply: curatorKeepsOne)
    try await store.insertInputEvents(webWorkflowEvents())

    await model.refreshAll()

    // The whole review surface wiring: detector caught it → the automatable bar
    // (≥3×, real time) kept it → curator judged + named it → it's what the
    // manager's review queue shows.
    #expect(model.detectedWaste.count == 1)
	    #expect(model.curatedWaste.count == 1)
	    #expect(model.curatedWaste.first?.name == "Reply to refund emails with the policy link")
	    #expect(model.pendingCuratedAgents.count == 1) // nothing approved or declined yet
	    #expect(model.learningOpportunities.contains { $0.kind == .repeatedWorkflow })

	    let opportunity = try #require(model.learningOpportunities.first { $0.kind == .repeatedWorkflow })
	    model.focusLearningOpportunity(opportunity)
	    #expect(model.selectedTab == .manager)
	    model.dismissLearningOpportunity(opportunity)
	    #expect(!model.learningOpportunities.contains { $0.id == opportunity.id })
	}

@MainActor @Test
func nativeWorkflowReachesTheReviewQueueAndDeploysOnScreen() async throws {
    // A repeated NATIVE-app workflow (Mail→Numbers) that clears the habit + real-time
    // bars now becomes a reviewable agent — app identity no longer gates it. Browser
    // workflows deploy to the background sandbox; native ones replay on-screen (and
    // escalate to the cursor-class runtime on drift).
    var events: [InputEvent] = []
    var i = 0
    for run in 0..<3 {
        let start = TimeInterval(run * 300)
        events.append(InputEvent(id: Int64(i), capturedAt: base.addingTimeInterval(start), kind: .click, x: 10, y: 10, text: "Inbox", appName: "Mail")); i += 1
        events.append(InputEvent(id: Int64(i), capturedAt: base.addingTimeInterval(start + 8), kind: .key, key: "c", modifiers: ["command"], appName: "Mail")); i += 1
        events.append(InputEvent(id: Int64(i), capturedAt: base.addingTimeInterval(start + 16), kind: .click, x: 20, y: 20, text: "A1", appName: "Numbers")); i += 1
        events.append(InputEvent(id: Int64(i), capturedAt: base.addingTimeInterval(start + 24), kind: .key, key: "v", modifiers: ["command"], appName: "Numbers")); i += 1
    }
    let (model, store) = try makeModel(curatorReply: curatorKeepsOne)
    try await store.insertInputEvents(events)

    await model.refreshAll()

    #expect(model.detectedWaste.count == 1)
    #expect(model.curatedWaste.count == 1)        // native now reaches curation…
    let curated = try #require(model.pendingCuratedAgents.first) // …and the review queue
    // A native workflow deploys ON-SCREEN, not in the background sandbox.
    #expect(!CascadeAppModel.runsInBackground(apps: curated.source.apps))
}

@MainActor @Test
func decliningHidesFromPendingImmediately() async throws {
    let (model, store) = try makeModel(curatorReply: curatorKeepsOne)
    try await store.insertInputEvents(webWorkflowEvents())
    await model.refreshAll()
    let curated = try #require(model.pendingCuratedAgents.first)

    model.declineCurated(curated)

    #expect(model.pendingCuratedAgents.isEmpty) // filtered out at once
    #expect(model.curatedWaste.count == 1)      // still curated, just hidden
}

@MainActor @Test
func approvingCreatesAgentWithCuratedNameAndGoalThenLeavesPending() async throws {
    let (model, store) = try makeModel(curatorReply: curatorKeepsOne)
    try await store.insertInputEvents(webWorkflowEvents())
    await model.refreshAll()
    let curated = try #require(model.pendingCuratedAgents.first)

    model.approveCurated(curated) // fire-and-forget: createAgent → refreshAll
    try await waitUntil { model.agents.contains { $0.signature == curated.signature } }

    let agent = try #require(model.agents.first { $0.signature == curated.signature })
    #expect(agent.name == "Reply to refund emails with the policy link")
    #expect(agent.goal == "In Gmail, reply to each new refund request with the standard policy link.")
    // The agent is web-only, so it deploys in the background.
    #expect(CascadeAppModel.runsInBackground(apps: agent.apps))
    // Approved → it drops out of the review queue.
    #expect(!model.pendingCuratedAgents.contains { $0.signature == curated.signature })
}

@MainActor @Test
func approveFlashesAManagerReviewNote() async throws {
    // The regression this fixes: approve happens on the Manager tab, so it must
    // give feedback THERE — the new agent landing in Cascades is out of sight.
    let (model, store) = try makeModel(curatorReply: curatorKeepsOne)
    try await store.insertInputEvents(webWorkflowEvents())
    await model.refreshAll()
    let curated = try #require(model.pendingCuratedAgents.first)
    #expect(model.managerReviewNote == nil)

    model.approveCurated(curated) // fire-and-forget: createAgent → note → refreshAll
    try await waitUntil { model.managerReviewNote != nil }

    #expect(model.managerReviewNote?.contains(curated.name) == true)
}

@MainActor @Test
func declineFlashesAManagerReviewNote() async throws {
    let (model, store) = try makeModel(curatorReply: curatorKeepsOne)
    try await store.insertInputEvents(webWorkflowEvents())
    await model.refreshAll()
    let curated = try #require(model.pendingCuratedAgents.first)

    model.declineCurated(curated) // sets the note synchronously

    #expect(model.managerReviewNote?.contains(curated.name) == true)
}

// MARK: - C1: honest math (only genuine completions count as reclaimed runs)

private func completedUpdate(_ result: String) -> BackgroundWebAgent.Update {
    BackgroundWebAgent.Update(status: result, snapshotPNG: nil, url: "", done: true, result: result, completed: true)
}
private func stoppedUpdate() -> BackgroundWebAgent.Update {
    BackgroundWebAgent.Update(status: "Stopped.", snapshotPNG: nil, url: "", done: true, result: nil)
}
private func failedUpdate(_ reason: String) -> BackgroundWebAgent.Update {
    BackgroundWebAgent.Update(status: reason, snapshotPNG: nil, url: "", done: true, result: nil)
}
private func stepLimitUpdate(_ summary: String) -> BackgroundWebAgent.Update {
    BackgroundWebAgent.Update(status: summary, snapshotPNG: nil, url: "", done: true, result: summary)
}

@MainActor
private func deployedAgent(in store: CascadeStore) async throws -> CascadeAgent {
    try await store.upsertAgent(CascadeAgent(
        name: "Daily web report", source: .detected, signature: "web-sig",
        recipe: AgentRecipe(steps: []), estimatedSecondsPerRun: 45
    ))
}

@MainActor @Test
func genuineCompletionCountsAsOneReclaimedRun() async throws {
    let (model, store) = try makeModel()
    let agent = try await deployedAgent(in: store)
    #expect(agent.runCount == 0)

    await model.recordSandboxCompletion(deployedAgentID: agent.id, update: completedUpdate("Found $420 on Delta"), task: "find the fare")

    #expect(try await store.agent(id: agent.id)?.runCount == 1)
}

@MainActor @Test
func stoppedFailedAndStepLimitRunsNeverCount() async throws {
    let (model, store) = try makeModel()
    let agent = try await deployedAgent(in: store)

    await model.recordSandboxCompletion(deployedAgentID: agent.id, update: stoppedUpdate(), task: "t")
    await model.recordSandboxCompletion(deployedAgentID: agent.id, update: failedUpdate("Couldn't open the sandbox browser."), task: "t")
    await model.recordSandboxCompletion(deployedAgentID: agent.id, update: stepLimitUpdate("Ran out of steps — ask again."), task: "t")

    // None of these finished the task, so "Reclaimed" must stay at zero.
    #expect(try await store.agent(id: agent.id)?.runCount == 0)
}

@MainActor @Test
func managedPolicyBlocksRecordingBackgroundRunsAndSchedules() async throws {
    let (model, store) = try makeModel()
    model.capturePrivacyPolicy = CapturePrivacyPolicy(
        recordingAvailable: false,
        backgroundWebRunsAvailable: false,
        scheduledRunsAvailable: false
    )

    model.startRecording()
    let recordingRow = try await waitForAudit(store, action: "policy.enforced", detailContains: "capability=recording")
    #expect(recordingRow.detail.contains("capability=recording"))

    #expect(!model.createSandboxAgent(task: "open https://example.com and summarize it"))
    let backgroundRow = try await waitForAudit(store, action: "policy.enforced", detailContains: "capability=background_web_run")
    #expect(backgroundRow.detail.contains("capability=background_web_run"))

    let agent = try await deployedAgent(in: store)
    model.setAgentSchedule(agent, schedule: "daily@09:05")
    let scheduleRow = try await waitForAudit(store, action: "policy.enforced", detailContains: "capability=agent_schedule")
    #expect(scheduleRow.detail.contains("capability=agent_schedule"))
}

@MainActor @Test
func managedPolicyBlocksDeniedBackgroundSites() async throws {
    let (model, store) = try makeModel()
    model.capturePrivacyPolicy = CapturePrivacyPolicy(deniedURLHosts: ["example.com"])

    #expect(!model.createSandboxAgent(task: "visit https://secure.example.com/report"))
    let row = try await waitForAudit(store, action: "policy.enforced")
    #expect(row.detail.contains("capability=background_web_run"))
    #expect(row.detail.contains("reasonChars="))
}

@MainActor @Test
func appShellAuditDetailsKeepStableIdentityReferencesNotRawText() async throws {
    let (model, store) = try makeModel()
    let rawToken = "ApertureDeltaAuditSeed"
    let task = "\(rawToken)-task"
    let scheduleName = "\(rawToken)-schedule-agent"
    let intent = "\(rawToken)-teach-intent"
    let pointedLabel = "\(rawToken)-pointed-label"
    let approvedName = "\(rawToken)-approved-agent"
    let steerMessage = "\(rawToken)-sandbox-steer"
    let recipeLabel = "\(rawToken)-recipe-label"
    let assistGoal = "\(rawToken)-assist-goal"
    let skillName = "\(rawToken)-skill-name"
    let validationMessage = "\(rawToken)-validation-missing"
    let stalledText = "\(rawToken)-stalled-reason"
    let groundLog = "hit \"\(rawToken)-ground-target\" @ (120,240)"
    let watchedApp = "\(rawToken)-watched-app"
    let pointQuestion = "\(rawToken)-where-is-the-private-button"
    let plannerFailure = "\(rawToken)-planner-failed-with-private-text"

    let scheduledAgent = try await store.upsertAgent(CascadeAgent(
        name: scheduleName,
        source: .detected,
        signature: "\(rawToken)-schedule-signature",
        recipe: AgentRecipe(steps: []),
        apps: ["Numbers"],
        estimatedSecondsPerRun: 30
    ))

    await model.recordSandboxCompletion(deployedAgentID: scheduledAgent.id, update: completedUpdate("done"), task: task)
    model.setAgentSchedule(scheduledAgent, schedule: "daily@09:05")
    model.beginTeaching()
    model.teach(question: intent)
    _ = try await store.appendAudit(AuditEvent(
        actor: "agent",
        action: "teach.clickPointed",
        detail: CascadeAppModel.teachPointedAuditDetail(utterance: "click that", label: pointedLabel)
    ))
    _ = try await store.appendAudit(AuditEvent(
        actor: "employee",
        action: "sandbox.steer",
        detail: CascadeAppModel.sandboxSteerAuditDetail(runID: UUID(), message: steerMessage)
    ))
    _ = try await store.appendAudit(AuditEvent(
        actor: "agent",
        action: "assist.task",
        detail: CascadeAppModel.textAuditDetail("goal", assistGoal)
    ))
    _ = try await store.appendAudit(AuditEvent(
        actor: "agent",
        action: "recipe.step",
        detail: CascadeAppModel.recipeAuditDetail(RecipeStep(
            order: 1,
            kind: .click,
            x: 10,
            y: 20,
            appName: "\(rawToken)-app",
            ocrAnchor: recipeLabel
        ))
    ))
    _ = try await store.appendAudit(AuditEvent(
        actor: "agent",
        action: "agent.skill",
        detail: CascadeAppModel.textAuditDetail("skill", skillName)
    ))
    _ = try await store.appendAudit(AuditEvent(
        actor: "agent",
        action: "agent.skill.denied",
        detail: CascadeAppModel.textAuditDetail("skill", skillName)
    ))
    _ = try await store.appendAudit(AuditEvent(
        actor: "agent",
        action: "computer.type.keys",
        detail: "chars=7 \(CascadeAppModel.textAuditDetail("skill", skillName))"
    ))
    _ = try await store.appendAudit(AuditEvent(
        actor: "agent",
        action: "reel.point",
        detail: CascadeAppModel.textAuditDetail("question", pointQuestion)
    ))
    _ = try await store.appendAudit(AuditEvent(
        actor: "system",
        action: "voice.fragment.ignored",
        detail: CascadeAppModel.textAuditDetail("utterance", intent)
    ))
    _ = try await store.appendAudit(AuditEvent(
        actor: "system",
        action: "voice.duplicate.ignored",
        detail: CascadeAppModel.textAuditDetail("utterance", assistGoal)
    ))
    _ = try await store.appendAudit(AuditEvent(
        actor: "agent",
        action: "assist.validate",
        detail: CascadeAppModel.assistValidationAuditDetail(validationMessage)
    ))
    _ = try await store.appendAudit(AuditEvent(
        actor: "agent",
        action: "assist.stalled",
        detail: CascadeAppModel.assistStalledAuditDetail(engine: "scout", text: stalledText)
    ))
    _ = try await store.appendAudit(AuditEvent(
        actor: "agent",
        action: "agent.ground",
        detail: CascadeAppModel.groundAuditDetail(groundLog)
    ))
    _ = try await store.appendAudit(AuditEvent(
        actor: "agent",
        action: "harness.denied.watched-app",
        detail: CascadeAppModel.harnessDeniedWatchedAppAuditDetail(toolName: "run_applescript", watchedApp: watchedApp)
    ))
    _ = try await store.appendAudit(AuditEvent(
        actor: "agent",
        action: "assist.timing",
        detail: "\(CascadeAppModel.assistPlannerFailedTimingReason(plannerFailure)) · scout · 1 turns"
    ))

    let approved = taughtCurated(signature: "\(rawToken)-approval-signature", name: approvedName)
    model.approveCurated(approved)

    let sandboxTask = try await waitForAudit(store, action: "sandbox.task")
    #expect(sandboxTask.detail.contains("taskHash=\(AuditIdentity.hash(task))"))
    expectAuditDetail(sandboxTask.detail, excludesRawIdentityContaining: rawToken)

    let completed = try await waitForAudit(store, action: "agent.run.completed")
    #expect(completed.detail.contains("agentID=\(scheduledAgent.id)"))
    #expect(completed.detail.contains("labelHash=\(AuditIdentity.hash(task))"))
    expectAuditDetail(completed.detail, excludesRawIdentityContaining: rawToken)

    let schedule = try await waitForAudit(store, action: "agent.schedule.set")
    #expect(schedule.detail.contains("agentID=\(scheduledAgent.id)"))
    #expect(schedule.detail.contains("nameHash=\(AuditIdentity.hash(scheduleName))"))
    expectAuditDetail(schedule.detail, excludesRawIdentityContaining: rawToken)

    let teachIntent = try await waitForAudit(store, action: "teach.intent")
    #expect(teachIntent.detail.contains("intentHash=\(AuditIdentity.hash(intent))"))
    expectAuditDetail(teachIntent.detail, excludesRawIdentityContaining: rawToken)

    let pointed = try await waitForAudit(store, action: "teach.clickPointed")
    #expect(pointed.detail.contains("pointedLabelHash=\(AuditIdentity.hash(pointedLabel))"))
    expectAuditDetail(pointed.detail, excludesRawIdentityContaining: rawToken)

    let steer = try await waitForAudit(store, action: "sandbox.steer")
    #expect(steer.detail.contains("messageHash=\(AuditIdentity.hash(steerMessage))"))
    expectAuditDetail(steer.detail, excludesRawIdentityContaining: rawToken)

    let assist = try await waitForAudit(store, action: "assist.task")
    #expect(assist.detail.contains("goalHash=\(AuditIdentity.hash(assistGoal))"))
    expectAuditDetail(assist.detail, excludesRawIdentityContaining: rawToken)

    let recipe = try await waitForAudit(store, action: "recipe.step")
    #expect(recipe.detail.contains("anchorHash=\(AuditIdentity.hash(recipeLabel))"))
    expectAuditDetail(recipe.detail, excludesRawIdentityContaining: rawToken)

    let approvedRow = try await waitForAudit(store, action: "agent.approved")
    #expect(approvedRow.detail.contains("nameHash=\(AuditIdentity.hash(approvedName))"))
    expectAuditDetail(approvedRow.detail, excludesRawIdentityContaining: rawToken)

    let skill = try await waitForAudit(store, action: "agent.skill")
    #expect(skill.detail.contains("skillHash=\(AuditIdentity.hash(skillName))"))
    expectAuditDetail(skill.detail, excludesRawIdentityContaining: rawToken)

    let deniedSkill = try await waitForAudit(store, action: "agent.skill.denied")
    #expect(deniedSkill.detail.contains("skillHash=\(AuditIdentity.hash(skillName))"))
    expectAuditDetail(deniedSkill.detail, excludesRawIdentityContaining: rawToken)

    let typedKeys = try await waitForAudit(store, action: "computer.type.keys")
    #expect(typedKeys.detail.contains("chars=7"))
    #expect(typedKeys.detail.contains("skillHash=\(AuditIdentity.hash(skillName))"))
    expectAuditDetail(typedKeys.detail, excludesRawIdentityContaining: rawToken)

    let point = try await waitForAudit(store, action: "reel.point")
    #expect(point.detail.contains("questionHash=\(AuditIdentity.hash(pointQuestion))"))
    #expect(point.detail.contains("questionChars=\(pointQuestion.count)"))
    expectAuditDetail(point.detail, excludesRawIdentityContaining: rawToken)

    let fragment = try await waitForAudit(store, action: "voice.fragment.ignored")
    #expect(fragment.detail.contains("utteranceHash=\(AuditIdentity.hash(intent))"))
    #expect(fragment.detail.contains("utteranceChars=\(intent.count)"))
    expectAuditDetail(fragment.detail, excludesRawIdentityContaining: rawToken)

    let duplicate = try await waitForAudit(store, action: "voice.duplicate.ignored")
    #expect(duplicate.detail.contains("utteranceHash=\(AuditIdentity.hash(assistGoal))"))
    #expect(duplicate.detail.contains("utteranceChars=\(assistGoal.count)"))
    expectAuditDetail(duplicate.detail, excludesRawIdentityContaining: rawToken)

    let validation = try await waitForAudit(store, action: "assist.validate")
    #expect(validation.detail.contains("status=incomplete"))
    #expect(validation.detail.contains("missingHash=\(AuditIdentity.hash(validationMessage))"))
    #expect(validation.detail.contains("missingChars=\(validationMessage.count)"))
    expectAuditDetail(validation.detail, excludesRawIdentityContaining: rawToken)

    let stalled = try await waitForAudit(store, action: "assist.stalled")
    #expect(stalled.detail.contains("status=stalled"))
    #expect(stalled.detail.contains("engine=scout"))
    #expect(stalled.detail.contains("textHash=\(AuditIdentity.hash(stalledText))"))
    #expect(stalled.detail.contains("textChars=\(stalledText.count)"))
    expectAuditDetail(stalled.detail, excludesRawIdentityContaining: rawToken)

    let ground = try await waitForAudit(store, action: "agent.ground")
    #expect(ground.detail.contains("groundHash=\(AuditIdentity.hash(groundLog))"))
    #expect(ground.detail.contains("groundChars=\(groundLog.count)"))
    expectAuditDetail(ground.detail, excludesRawIdentityContaining: rawToken)

    let watched = try await waitForAudit(store, action: "harness.denied.watched-app")
    #expect(watched.detail.contains("tool=run_applescript"))
    #expect(watched.detail.contains("appHash=\(AuditIdentity.hash(watchedApp))"))
    #expect(watched.detail.contains("appChars=\(watchedApp.count)"))
    expectAuditDetail(watched.detail, excludesRawIdentityContaining: rawToken)

    let timing = try await waitForAudit(store, action: "assist.timing")
    #expect(timing.detail.contains("status=planner-failed"))
    #expect(timing.detail.contains("textHash=\(AuditIdentity.hash(plannerFailure))"))
    #expect(timing.detail.contains("textChars=\(plannerFailure.count)"))
    expectAuditDetail(timing.detail, excludesRawIdentityContaining: rawToken)
}

@MainActor @Test
func watchedAppHarnessDenialPersistsHashedAppIdentity() async throws {
    let (model, store) = try makeModel()
    let watchedApp = "P9SentinelWatchedApp"

    let denial = await model.watchedAppHarnessDenialMessageIfNeeded(
        toolName: "run_applescript",
        input: ["script": #"tell application "\#(watchedApp)" to activate"#],
        goal: "Update the visible document",
        watchedAppActionCounts: [watchedApp: 3]
    )

    #expect(denial != nil)
    let watched = try await waitForAudit(store, action: "harness.denied.watched-app")
    #expect(watched.detail.contains("tool=run_applescript"))
    #expect(watched.detail.contains("appHash=\(AuditIdentity.hash(watchedApp))"))
    #expect(watched.detail.contains("appChars=\(watchedApp.count)"))
    #expect(!watched.detail.contains(watchedApp))
}

@Test
func flightDelayMillisecondsRejectsNonFiniteAndClampsLargeValues() {
    #expect(CascadeAppModel.safeFlightDelayMilliseconds(.nan) == 0)
    #expect(CascadeAppModel.safeFlightDelayMilliseconds(.infinity) == 0)
    #expect(CascadeAppModel.safeFlightDelayMilliseconds(-.infinity) == 0)
    #expect(CascadeAppModel.safeFlightDelayMilliseconds(-1) == 0)
    #expect(CascadeAppModel.safeFlightDelayMilliseconds(0.245) == 245)
    #expect(CascadeAppModel.safeFlightDelayMilliseconds(2.5) == 2_500)
    #expect(CascadeAppModel.safeFlightDelayMilliseconds(60) == 5_000)
    #expect(CascadeAppModel.safeFlightDelayMilliseconds(.greatestFiniteMagnitude) == 5_000)
}

private func waste(apps: [String], occurrences: Int, perRun: Int = 20, sig: String = "sig") -> DetectedWaste {
    DetectedWaste(
        title: "t", apps: apps, occurrences: occurrences,
        estimatedSecondsPerRun: perRun, estimatedTotalSeconds: perRun * occurrences,
        recipe: AgentRecipe(steps: []), evidence: [], confidence: 0.7, signature: sig
    )
}

@Test
func parameterTypeStepEscalatesInsteadOfReplayingStaleValue() {
    // Phase 1 parameterized replay: a .type step whose value varied across the
    // recorded runs (an order #, a date) is a parameter — replay can't supply the
    // current value, so its precondition fails and it hands off to the assist
    // runtime. Fixed steps and non-type steps replay normally.
    #expect(CascadeAppModel.recipeStepNeedsLiveValue(
        RecipeStep(order: 2, kind: .type, text: "order #4471", appName: "Mail", isParameter: true)))
    // A fixed .type step (same content every run) replays its recorded text.
    #expect(!CascadeAppModel.recipeStepNeedsLiveValue(
        RecipeStep(order: 2, kind: .type, text: "Best regards", appName: "Mail", isParameter: false)))
    // Old recipes predate isParameter (defaults false) → replay unchanged.
    #expect(!CascadeAppModel.recipeStepNeedsLiveValue(
        RecipeStep(order: 2, kind: .type, text: "anything", appName: "Mail")))
    // Only .type carries a typed value; a click never needs a live value.
    #expect(!CascadeAppModel.recipeStepNeedsLiveValue(
        RecipeStep(order: 1, kind: .click, x: 1, y: 1, appName: "Mail", isParameter: true)))
}

@Test
func assistValidatorAcceptsUnlessClearlyIncomplete() {
    // Phase 1 validator stage: judge by fresh evidence, lean accept. VERIFIED,
    // unclear, and empty all accept (nil); only a clear INCOMPLETE downgrades the
    // run and carries the "what's missing" reason.
    #expect(CascadeAppModel.parseAssistVerdict("VERIFIED") == nil)
    #expect(CascadeAppModel.parseAssistVerdict("  verified — the slide has a title and subtitle ") == nil)
    #expect(CascadeAppModel.parseAssistVerdict("I'm not sure, looks done-ish") == nil)  // doubt → accept
    #expect(CascadeAppModel.parseAssistVerdict("") == nil)
    #expect(CascadeAppModel.parseAssistVerdict("INCOMPLETE: the subtitle placeholder is still empty")
        == "the subtitle placeholder is still empty")
    // Bare INCOMPLETE with no reason still downgrades, with a default reason.
    #expect(CascadeAppModel.parseAssistVerdict("INCOMPLETE") == "the screen doesn't show the task was completed")
}

@Test
func startStateGateMatchesAppByBundleOrNameContainment() {
    // B3 pre-replay state gate. Bundle id match wins outright.
    #expect(CascadeAppModel.appMatches(frontmostName: "Anything", frontmostBundle: "com.apple.Keynote",
                                        expectedName: "Keynote", expectedBundle: "com.apple.Keynote"))
    // Display-name containment EITHER direction — recorded "Keynote" matches a live
    // "Keynote Creator Studio" (the equality blind spot activateAndConfirm has).
    #expect(CascadeAppModel.appMatches(frontmostName: "Keynote Creator Studio", frontmostBundle: nil,
                                        expectedName: "Keynote", expectedBundle: nil))
    #expect(CascadeAppModel.appMatches(frontmostName: "Word", frontmostBundle: nil,
                                        expectedName: "Microsoft Word", expectedBundle: nil))
    // A genuinely different app in front is a mismatch → the gate escalates.
    #expect(!CascadeAppModel.appMatches(frontmostName: "Finder", frontmostBundle: "com.apple.finder",
                                        expectedName: "Keynote", expectedBundle: "com.apple.Keynote"))
    // No app in front (nil) is never a match.
    #expect(!CascadeAppModel.appMatches(frontmostName: nil, frontmostBundle: nil,
                                        expectedName: "Keynote", expectedBundle: nil))
}

@Test
func repetitionBarNeedsThreeRepeats() {
    // The detector recalls anything seen twice; promoting to a reviewable agent
    // demands a genuine habit — three or more.
    #expect(!CascadeAppModel.meetsRepetitionBar(waste(apps: ["Safari"], occurrences: 2)))
    #expect(CascadeAppModel.meetsRepetitionBar(waste(apps: ["Safari"], occurrences: 3)))
}

@Test
func repetitionBarUsesAcceptedAndDeclinedPreferenceThresholds() {
    var model = PreferenceModel()
    for _ in 0..<12 { model.record("accepted", accepted: true) }
    for _ in 0..<12 { model.record("declined", accepted: false) }

    #expect(CascadeAppModel.meetsRepetitionBar(waste(apps: ["Safari"], occurrences: 2, sig: "accepted"), using: model))
    #expect(!CascadeAppModel.meetsRepetitionBar(waste(apps: ["Safari"], occurrences: 3, sig: "declined"), using: model))
}

@Test
func realTimeBarKeepsTrivialHabitsOut() {
    // "Really save time": ~60s clears the floor, 6s doesn't — independent of how
    // many times it repeated.
    #expect(CascadeAppModel.representsRealTime(waste(apps: ["Safari"], occurrences: 3)))             // 60s
    #expect(!CascadeAppModel.representsRealTime(waste(apps: ["Safari"], occurrences: 3, perRun: 2))) // 6s
}

@Test
func automatableBarRequiresHabitAndTime() {
    // A real, time-saving habit is reviewable regardless of which app it runs in:
    // browser workflows deploy to the background sandbox, native ones replay
    // on-screen (escalating to the cursor-class runtime on drift). App identity no
    // longer gates automatability.
    #expect(CascadeAppModel.isAutomatable(waste(apps: ["Safari"], occurrences: 3)))
    // A native-app habit is now automatable too — it runs on-screen.
    #expect(CascadeAppModel.isAutomatable(waste(apps: ["Numbers"], occurrences: 5)))
    // Not yet a habit → not reviewable.
    #expect(!CascadeAppModel.isAutomatable(waste(apps: ["Safari"], occurrences: 2)))
    // A habit but trivially quick → kept out of the queue ("really save time").
    #expect(!CascadeAppModel.isAutomatable(waste(apps: ["Safari"], occurrences: 3, perRun: 2)))
}

@Test
func displayAppNeverReinterpretsNativeApps() {
    // The Reel's web-app display must gate on "is a browser" — a native app whose
    // window title happens to have a separator must NOT be mistaken for a web app.
    // (The browser → web-app path is covered by WebAppIdentityTests.)
    #expect(CascadeAppModel.displayApp(appName: "Numbers", windowTitle: "Budget — Numbers") == "Numbers")
    #expect(CascadeAppModel.displayApp(appName: "Xcode", windowTitle: "Foo.swift — Xcode") == "Xcode")
    #expect(CascadeAppModel.displayApp(appName: "Blender", windowTitle: nil) == "Blender")
}

@MainActor @Test
func deployGoalLeadsWithCuratedGoalThenRecordedSteps() {
    // On-screen deploy escalates to the cursor runtime with THIS goal: the curated
    // intent up front, the user's recorded steps as guidance (typing/scroll filtered).
    let recipe = AgentRecipe(steps: [
        RecipeStep(order: 0, kind: .activateApp, appName: "Mail"),
        RecipeStep(order: 1, kind: .click, x: 1, y: 1, appName: "Mail", ocrAnchor: "Reply"),
        RecipeStep(order: 2, kind: .type, text: "hello", appName: "Mail"),
        RecipeStep(order: 3, kind: .key, key: "v", modifiers: ["command"], appName: "Numbers"),
    ])
    let withGoal = CascadeAgent(name: "Mail thing", source: .detected, signature: "s", recipe: recipe, goal: "Reply to the latest support email")
    let g1 = CascadeAppModel.deployGoal(for: withGoal)
    #expect(g1.hasPrefix("Reply to the latest support email")) // curated intent leads
    #expect(g1.contains("click “Reply”"))                       // recorded steps as guidance
    #expect(!g1.contains("hello"))                              // never the typed text

    let noGoal = CascadeAgent(name: "Mail thing", source: .detected, signature: "s2", recipe: recipe)
    #expect(CascadeAppModel.deployGoal(for: noGoal).hasPrefix("Mail thing")) // falls back to the name
}

@MainActor @Test
func completionMessageIsHonestAboutTheOutcome() {
    // Genuine completion announces done; everything else shows its own status —
    // never the old fake "Background agent done — Finished in the background."
    #expect(CascadeAppModel.sandboxCompletionMessage(for: completedUpdate("Booked, conf #A1")) == "Background agent done — Booked, conf #A1")
    #expect(CascadeAppModel.sandboxCompletionMessage(for: failedUpdate("Couldn't open the sandbox browser.")) == "Couldn't open the sandbox browser.")
    #expect(CascadeAppModel.sandboxCompletionMessage(for: stoppedUpdate()) == "Stopped.")
    #expect(CascadeAppModel.sandboxCompletionMessage(for: stepLimitUpdate("Ran out of steps — ask again.")) == "Ran out of steps — ask again.")
}

@Test
func sandboxFailureMemoryContextRequiresExternalSignalAndKnownFailure() {
    let rawSelfReport = BackgroundWebAgent.Update(
        status: "INCOMPLETE: I could not finish",
        snapshotPNG: nil,
        url: "https://example.test/private",
        done: true,
        result: nil
    )
    #expect(CascadeAppModel.sandboxFailureMemoryContext(for: rawSelfReport, failureKind: .verifierRejected) == nil)
    #expect(CascadeAppModel.sandboxFailureMemoryContext(for: rawSelfReport, failureKind: .unknown) == nil)

    let verifierSignal = BackgroundWebAgent.Update(
        status: "Couldn't finish — verify check found the form still blank for jane@example.com",
        snapshotPNG: nil,
        url: "https://example.test/form",
        done: true,
        result: nil
    )
    let context = CascadeAppModel.sandboxFailureMemoryContext(for: verifierSignal, failureKind: .verifierRejected)
    #expect(context != nil)
    #expect(context?.stateSummary.contains("<EMAIL>") == true)
    #expect(context?.stateSummary.contains("jane@example.com") == false)
    #expect(context?.recoveryEvidenceHash.isEmpty == false)
}

@Test
func failureMemoryScoreBoostsSameFailureKindAndCategory() {
    let memory = AgentFailureMemory(
        appName: "Safari",
        normalizedGoalTokens: ["submit", "invoice"],
        failureKind: .noEffect,
        repairHint: "Use a different button."
    )
    let queryTokens: Set<String> = ["submit", "invoice"]

    let base = CascadeAppModel.failureMemoryScore(memory, queryTokens: queryTokens, frontmostApp: "Safari")
    let exact = CascadeAppModel.failureMemoryScore(memory, queryTokens: queryTokens, frontmostApp: "Safari", expectedFailureKind: .noEffect)
    let category = CascadeAppModel.failureMemoryScore(memory, queryTokens: queryTokens, frontmostApp: "Safari", expectedFailureKind: .staleFrameBatch)

    #expect(exact > category)
    #expect(category > base)
}

@Test
func groundingBucketReliabilityRequiresEnoughAccurateSamples() {
    let goodReport = VerifierCalibration.report(samples: Array(repeating: VerifierCalibrationSample(
        confidence: 0.9,
        outcome: .acceptedCorrect
    ), count: 8), bucketCount: 5)
    let sparseReport = VerifierCalibration.report(samples: [
        VerifierCalibrationSample(confidence: 0.9, outcome: .acceptedCorrect)
    ], bucketCount: 5)

    #expect(CascadeAppModel.groundingBucketIsReliable(confidence: 0.91, report: goodReport))
    #expect(!CascadeAppModel.groundingBucketIsReliable(confidence: 0.91, report: sparseReport))
    #expect(!CascadeAppModel.groundingBucketIsReliable(confidence: 0.91, report: nil))
}

// MARK: - Teach-once (demonstrate a task → agent, over the shared spine)

/// A single cross-app copy/paste demonstration timestamped INSIDE the bracket
/// `[now, now+offsets]`, increasing 1ms apart so the recipe order is deterministic.
private func taughtCopyPasteEvents(at now: Date) -> [InputEvent] {
    [
        InputEvent(id: 0, capturedAt: now.addingTimeInterval(0.000), kind: .click, x: 10, y: 10, text: "Inbox", appName: "Mail"),
        InputEvent(id: 1, capturedAt: now.addingTimeInterval(0.001), kind: .key, key: "c", modifiers: ["command"], appName: "Mail"),
        InputEvent(id: 2, capturedAt: now.addingTimeInterval(0.002), kind: .click, x: 20, y: 20, text: "A1", appName: "Numbers"),
        InputEvent(id: 3, capturedAt: now.addingTimeInterval(0.003), kind: .key, key: "v", modifiers: ["command"], appName: "Numbers"),
    ]
}

/// A taught proposal built directly, so the create/review paths can be tested without
/// driving a live demonstration.
private func taughtCurated(signature: String = "sig-taught", name: String = "My taught task") -> CuratedAgent {
    let waste = DetectedWaste(
        title: "Mail → Numbers: copy", apps: ["Mail", "Numbers"], occurrences: 1,
        estimatedSecondsPerRun: 20, estimatedTotalSeconds: 20,
        recipe: AgentRecipe(steps: [
            RecipeStep(order: 0, kind: .activateApp, appName: "Mail"),
            RecipeStep(order: 1, kind: .key, key: "c", modifiers: ["command"], appName: "Mail"),
        ]),
        evidence: [1], confidence: 0.7, signature: signature
    )
    return CuratedAgent(source: waste, name: name, why: "You showed me once.", goal: "Do the taught task.", value: 0.8)
}

@MainActor @Test
func teachOnceBracketsTheDemonstrationIntoAPreview() async throws {
    let (model, store) = try makeModel(curatorReply: curatorKeepsOne)
    model.beginTeaching()
    #expect(model.teachingMode)

    let now = Date()
    try await store.insertInputEvents(taughtCopyPasteEvents(at: now))
    // endTeaching insets the bracket end by ~0.3s (to drop the finishing hotkey), so
    // the demonstration events must sit comfortably before that inset window.
    try await Task.sleep(for: .milliseconds(450))
    model.endTeaching()
    #expect(!model.teachingMode)

    // buildTaughtAgent settles ~1.5s (drain + AX labels) then curates → preview.
    try await waitUntil({ model.teachPreview != nil }, maxTries: 500)
    #expect(model.teachPreview?.name == "Reply to refund emails with the policy link")
    #expect(model.teachPreview?.apps == ["Mail", "Numbers"])
}

@MainActor @Test
func teachingGatesNarrationIntoIntentNotAnAssistRun() throws {
    let (model, _) = try makeModel()
    model.beginTeaching()
    // A spoken phrase during a demonstration is INTENT, not a command — it must not
    // launch an assist run (which, with no key, would force open Settings).
    model.teach(question: "pulling the weekly numbers into the Monday report")
    #expect(model.teachingMode)             // still demonstrating
    #expect(!model.showSettings)            // the no-key assist path never ran
    #expect(model.teachStatus?.contains("heard") == true)
}

@MainActor @Test
func createTaughtAgentLandsInYourAgents() async throws {
    let (model, _) = try makeModel()
    model.teachPreview = taughtCurated()

    model.createTaughtAgent(taughtCurated())

    try await waitUntil({ !model.agents.isEmpty }, maxTries: 500)
    #expect(model.agents.first?.name == "My taught task")
    #expect(model.selectedTab == .cascades)
    #expect(model.teachPreview == nil)
}

@MainActor @Test
func sendTaughtAgentToManagerSurfacesInTheReviewQueue() throws {
    let (model, _) = try makeModel()
    let curated = taughtCurated()
    model.sendTaughtAgentToManager(curated)

    // It joins the manager's review queue (no auto-create) and clears the sheet.
    #expect(model.pendingCuratedAgents.contains { $0.signature == "sig-taught" })
    #expect(model.teachPreview == nil)

    // Declining drops it back out of the queue immediately.
    model.declineCurated(curated)
    #expect(!model.pendingCuratedAgents.contains { $0.signature == "sig-taught" })
}

@Test
func isSameGoalDetectsReFiresButNotDifferentCommands() {
    let g = "Open Keynote and design a market entry readout for Cascade."
    // Identical or minor transcription variance = a voice re-fire → same.
    #expect(CascadeAppModel.isSameGoal(g, g))
    #expect(CascadeAppModel.isSameGoal(g, "Open Keynote and design a market entry readout"))
    // A genuinely different command (new step / steer) → NOT same, still supersedes.
    #expect(!CascadeAppModel.isSameGoal(g, "make the title bigger"))
    #expect(!CascadeAppModel.isSameGoal(g, "now add a chart to the slide"))
    // Short utterances never match (need ≥3 words).
    #expect(!CascadeAppModel.isSameGoal("open it", "open it"))
}
