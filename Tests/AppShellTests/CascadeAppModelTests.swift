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
    func at() -> Date { base.addingTimeInterval(Double(i) * 3) }
    for _ in 0..<3 {
        events.append(InputEvent(id: Int64(i), capturedAt: at(), kind: .click, x: 10, y: 10, text: "Compose", appName: "Safari", windowTitle: "Inbox - Gmail")); i += 1
        events.append(InputEvent(id: Int64(i), capturedAt: at(), kind: .key, key: "a", modifiers: ["command"], appName: "Safari", windowTitle: "Inbox - Gmail")); i += 1
        events.append(InputEvent(id: Int64(i), capturedAt: at(), kind: .type, text: "reply", appName: "Safari", windowTitle: "Inbox - Gmail")); i += 1
        events.append(InputEvent(id: Int64(i), capturedAt: at(), kind: .click, x: 30, y: 30, text: "Send", appName: "Safari", windowTitle: "Inbox - Gmail")); i += 1
        events.append(InputEvent(id: Int64(i), capturedAt: at(), kind: .key, key: "Return", modifiers: ["command"], appName: "Safari", windowTitle: "Inbox - Gmail")); i += 1
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
}

@MainActor @Test
func nativeWorkflowReachesTheReviewQueueAndDeploysOnScreen() async throws {
    // A repeated NATIVE-app workflow (Mail→Numbers) that clears the habit + real-time
    // bars now becomes a reviewable agent — app identity no longer gates it. Browser
    // workflows deploy to the background sandbox; native ones replay on-screen (and
    // escalate to the cursor-class runtime on drift).
    var events: [InputEvent] = []
    var i = 0
    func at() -> Date { base.addingTimeInterval(Double(i) * 4) } // clear the 30s floor
    for _ in 0..<3 {
        events.append(InputEvent(id: Int64(i), capturedAt: at(), kind: .click, x: 10, y: 10, text: "Inbox", appName: "Mail")); i += 1
        events.append(InputEvent(id: Int64(i), capturedAt: at(), kind: .key, key: "c", modifiers: ["command"], appName: "Mail")); i += 1
        events.append(InputEvent(id: Int64(i), capturedAt: at(), kind: .click, x: 20, y: 20, text: "A1", appName: "Numbers")); i += 1
        events.append(InputEvent(id: Int64(i), capturedAt: at(), kind: .key, key: "v", modifiers: ["command"], appName: "Numbers")); i += 1
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

private func waste(apps: [String], occurrences: Int, perRun: Int = 20) -> DetectedWaste {
    DetectedWaste(
        title: "t", apps: apps, occurrences: occurrences,
        estimatedSecondsPerRun: perRun, estimatedTotalSeconds: perRun * occurrences,
        recipe: AgentRecipe(steps: []), evidence: [], confidence: 0.7, signature: "sig"
    )
}

@Test
func repetitionBarNeedsThreeRepeats() {
    // The detector recalls anything seen twice; promoting to a reviewable agent
    // demands a genuine habit — three or more.
    #expect(!CascadeAppModel.meetsRepetitionBar(waste(apps: ["Safari"], occurrences: 2)))
    #expect(CascadeAppModel.meetsRepetitionBar(waste(apps: ["Safari"], occurrences: 3)))
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
