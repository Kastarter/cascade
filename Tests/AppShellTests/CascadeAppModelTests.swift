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

private actor SequenceCompleter: MessageCompleting {
    private let replies: [String]
    private let holdFirst: Bool
    private var users: [String] = []
    private var firstWaiter: CheckedContinuation<Void, Never>?

    init(replies: [String], holdFirst: Bool = false) {
        self.replies = replies
        self.holdFirst = holdFirst
    }

    func complete(system: String?, user: String, model: String, maxTokens: Int) async throws -> String {
        let index = users.count
        users.append(user)
        if holdFirst, index == 0 {
            await withCheckedContinuation { firstWaiter = $0 }
        }
        return replies[min(index, max(0, replies.count - 1))]
    }

    func releaseFirst() {
        firstWaiter?.resume()
        firstWaiter = nil
    }

    func prompts() -> [String] { users }
    func callCount() -> Int { users.count }
}

private final class TestTeachClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) { self.value = value }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(_ interval: TimeInterval) {
        lock.lock()
        value = value.addingTimeInterval(interval)
        lock.unlock()
    }
}

private actor TeachDrainGate {
    private var waiter: CheckedContinuation<RealtimeVoice.TranscriptionDrainResult, Never>?
    private var releasedResult: RealtimeVoice.TranscriptionDrainResult?
    private var waiting = false

    func wait() async -> RealtimeVoice.TranscriptionDrainResult {
        if let releasedResult { return releasedResult }
        waiting = true
        return await withCheckedContinuation { waiter = $0 }
    }

    func isWaiting() -> Bool { waiting && releasedResult == nil }

    func release(_ result: RealtimeVoice.TranscriptionDrainResult) {
        releasedResult = result
        waiter?.resume(returning: result)
        waiter = nil
    }
}

private final class TestTeachSessionIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [UUID]

    init(_ ids: [UUID]) { self.ids = ids }

    func next() -> UUID {
        lock.lock()
        defer { lock.unlock() }
        return ids.isEmpty ? UUID() : ids.removeFirst()
    }
}

private actor AssistLifecycleGate {
    private var started = false
    private var releaseRequested = false
    private var waiter: CheckedContinuation<Void, Never>?

    func hold() async {
        started = true
        if releaseRequested { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func hasStarted() -> Bool { started }

    func release() {
        releaseRequested = true
        waiter?.resume()
        waiter = nil
    }
}

private enum IntentionalCuratorFailure: Error {
    case failed
}

private actor SucceedThenThrowTeachCuration {
    private let firstResult: CuratedAgent
    private var intents: [String?] = []

    init(firstResult: CuratedAgent) { self.firstResult = firstResult }

    func curate(from: Date, to: Date, statedIntent: String?) async throws -> CuratedAgent? {
        intents.append(statedIntent)
        if intents.count == 1 { return firstResult }
        throw IntentionalCuratorFailure.failed
    }

    func callCount() -> Int { intents.count }
}

private final class DetectionSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func record() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private let base = Date(timeIntervalSinceNow: -24 * 60 * 60)

/// Builds the model in HEADLESS mode — injected temp store + orchestrator, no taps,
/// no capture, no audio, no scheduler — so the orchestration wiring can be exercised.
@MainActor
private func makeModel(
    curatorReply: String = #"{"agents":[]}"#,
    contextWasteDetectionEnabled: Bool? = nil,
    legacyActionWasteMode: CascadeAppModel.LegacyActionWasteMode? = nil,
    detectedWasteReportObserver: (@Sendable () -> Void)? = nil,
    curatorClient: (any MessageCompleting)? = nil,
    teachClock: @escaping @Sendable () -> Date = { Date() },
    teachSessionIDFactory: @escaping @Sendable () -> UUID = { UUID() },
    teachRecorderSettleOperation: @escaping @Sendable () async -> Void = {
        try? await Task.sleep(for: .milliseconds(1800))
    },
    teachNarrationDrain: (@Sendable (UUID, Duration) async -> RealtimeVoice.TranscriptionDrainResult)? = nil,
    teachCurationOverride: (@Sendable (Date, Date, String?) async throws -> CuratedAgent?)? = nil,
    assistTaskLifecycleOverride: (@Sendable () async -> Void)? = nil
) throws -> (model: CascadeAppModel, store: CascadeStore) {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("CascadeAppShellIT-\(UUID().uuidString).sqlite").path
    let store = try CascadeStore(path: path)
    let curator = curatorClient.map { WorkflowCurator(client: $0) }
        ?? WorkflowCurator(client: FakeCompleter(canned: curatorReply))
    let orchestrator = CascadeOrchestrator(
        store: store,
        curator: curator,
        detectedWasteReportObserver: detectedWasteReportObserver
    )
    // An ephemeral defaults suite per model — tests never read stale declines from,
    // or pollute, the real .standard defaults (and so don't contaminate each other).
    let defaults = UserDefaults(suiteName: "CascadeTest-\(UUID().uuidString)")!
    if let contextWasteDetectionEnabled {
        defaults.set(contextWasteDetectionEnabled, forKey: CascadeAppModel.experimentalContextWasteDetectionKey)
    }
    if let legacyActionWasteMode {
        defaults.set(legacyActionWasteMode.rawValue, forKey: CascadeAppModel.legacyActionWasteModeKey)
    }
    let model = try CascadeAppModel(
        store: store,
        orchestrator: orchestrator,
        defaults: defaults,
        startsSubsystems: false,
        teachClock: teachClock,
        teachSessionIDFactory: teachSessionIDFactory,
        teachRecorderSettleOperation: teachRecorderSettleOperation,
        teachNarrationDrain: teachNarrationDrain,
        teachCurationOverride: teachCurationOverride,
        assistTaskLifecycleOverride: assistTaskLifecycleOverride
    )
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

private func contextSession(
    idStart: Int64,
    start: TimeInterval,
    title: String,
    ocr: String,
    metadataJSON: String
) -> [RecordedContext] {
    stride(from: 0.0, through: 1_200.0, by: 300.0).enumerated().map { offset, elapsed in
        RecordedContext(
            id: idStart + Int64(offset),
            capturedAt: base.addingTimeInterval(start + elapsed),
            source: .screen,
            appName: "QuickBooks",
            bundleIdentifier: "com.intuit.quickbooks",
            windowTitle: title,
            ocrText: ocr,
            metadataJSON: metadataJSON,
            safeToShow: true,
            safeToSummarize: true
        )
    }
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

@MainActor
private func waitForAudit(
    _ store: CascadeStore,
    action: String,
    maxTries: Int = 2_000
) async throws -> AuditEvent {
    await Task.yield()
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

@MainActor
private func waitForAudit(
    _ store: CascadeStore,
    action: String,
    detailContains needle: String,
    maxTries: Int = 2_000
) async throws -> AuditEvent {
    await Task.yield()
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

private let contextCuratorKeepsOne = """
{"agents":[{"index":0,"name":"Reconcile vendor invoices","why":"The record shows repeated invoice queue work.","goal":"Reconcile the vendor invoice queue in QuickBooks.","value":0.9,"feasibility":"goalOnlyCandidate"}]}
"""

private func teachCuratorReply(name: String, goal: String) -> String {
    """
    {"agents":[{"index":0,"name":"\(name)","why":"shown once","goal":"\(goal)","value":0.9}]}
    """
}

private func waitForCompleterCalls(_ completer: SequenceCompleter, count: Int) async throws {
    for _ in 0..<500 {
        if await completer.callCount() >= count { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw CocoaError(.coderValueNotFound)
}

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
    let (model, store) = try makeModel(curatorReply: curatorKeepsOne, contextWasteDetectionEnabled: false)
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
func refreshAllCuratesContextWasteByDefault() async throws {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("CascadeAppShellContextWaste-\(UUID().uuidString).sqlite").path
    let store = try CascadeStore(path: path)
    let contexts =
        contextSession(
            idStart: 1,
            start: 0,
            title: "Acme invoice queue",
            ocr: "Review vendor invoice queue, reconcile invoice totals, and mark vendor batch paid.",
            metadataJSON: #"{"project":"Acme invoices"}"#
        )
        + contextSession(
            idStart: 100,
            start: 3_600,
            title: "Beta invoice queue",
            ocr: "Review vendor invoice queue, reconcile invoice totals, and mark vendor batch paid.",
            metadataJSON: #"{"project":"Beta invoices"}"#
        )
        + contextSession(
            idStart: 200,
            start: 7_200,
            title: "Contoso invoice queue",
            ocr: "Review vendor invoice queue, reconcile invoice totals, and mark vendor batch paid.",
            metadataJSON: #"{"project":"Contoso invoices"}"#
        )
    _ = try await store.insertContexts(contexts)
    let orchestrator = CascadeOrchestrator(store: store, curator: WorkflowCurator(client: FakeCompleter(canned: contextCuratorKeepsOne)))
    let defaults = UserDefaults(suiteName: "CascadeContextWasteTest-\(UUID().uuidString)")!
    let model = try CascadeAppModel(store: store, orchestrator: orchestrator, defaults: defaults, startsSubsystems: false)

    await model.refreshAll()

    let waste = try #require(model.contextWaste.first)
    #expect(model.contextWaste.count == 1)
    #expect(waste.occurrences == 3)
    #expect(waste.feasibility == .goalOnlyCandidate)
    #expect(waste.title.lowercased().contains("invoice"))
    #expect(waste.signature.contains("context-process:v3"))
    #expect(model.curatedWaste.isEmpty)
    #expect(model.curatedContextWaste.count == 1)
    #expect(model.pendingCuratedContextWaste.first?.name == "Reconcile vendor invoices")
}

@MainActor @Test
func defaultRefreshSurfacesContextWasteNotLegacyActionCards() async throws {
    let spy = DetectionSpy()
    let (model, store) = try makeModel(curatorReply: contextCuratorKeepsOne, detectedWasteReportObserver: spy.record)
    let contexts =
        contextSession(
            idStart: 1,
            start: 0,
            title: "Acme invoice queue",
            ocr: "Review vendor invoice queue, reconcile invoice totals, and mark vendor batch paid.",
            metadataJSON: #"{"project":"Acme invoices"}"#
        )
        + contextSession(
            idStart: 100,
            start: 3_600,
            title: "Beta invoice queue",
            ocr: "Review vendor invoice queue, reconcile invoice totals, and mark vendor batch paid.",
            metadataJSON: #"{"project":"Beta invoices"}"#
        )
        + contextSession(
            idStart: 200,
            start: 7_200,
            title: "Contoso invoice queue",
            ocr: "Review vendor invoice queue, reconcile invoice totals, and mark vendor batch paid.",
            metadataJSON: #"{"project":"Contoso invoices"}"#
        )
    try await store.insertInputEvents(webWorkflowEvents())
    _ = try await store.insertContexts(contexts)

    await model.refreshAll()

    #expect(spy.count == 0)
    #expect(model.contextWaste.count == 1)
    #expect(model.detectedWaste.isEmpty)
    #expect(model.curatedWaste.isEmpty)
    #expect(model.pendingCuratedAgents.isEmpty)
    #expect(model.pendingCuratedContextWaste.first?.name == "Reconcile vendor invoices")
}

@MainActor @Test
func defaultRefreshDoesNotFallbackToClickOnlyRepeatsWhenContextMiningFindsNothing() async throws {
    let spy = DetectionSpy()
    let (model, store) = try makeModel(curatorReply: curatorKeepsOne, detectedWasteReportObserver: spy.record)
    try await store.insertInputEvents(webWorkflowEvents())

    await model.refreshAll()

    #expect(spy.count == 0)
    #expect(model.contextWaste.isEmpty)
    #expect(model.detectedWaste.isEmpty)
    #expect(model.curatedWaste.isEmpty)
    #expect(model.pendingCuratedAgents.isEmpty)
    #expect(!model.learningOpportunities.contains { $0.kind == .repeatedWorkflow })
}

@MainActor @Test
func fallbackReviewQueueSurfacesClickOnlyRepeatsOnlyWhenExplicitlyEnabled() async throws {
    let spy = DetectionSpy()
    let (model, store) = try makeModel(
        curatorReply: curatorKeepsOne,
        legacyActionWasteMode: .fallbackReviewQueue,
        detectedWasteReportObserver: spy.record
    )
    try await store.insertInputEvents(webWorkflowEvents())

    await model.refreshAll()

    #expect(spy.count == 1)
    #expect(model.contextWaste.isEmpty)
    #expect(model.detectedWaste.count == 1)
    #expect(model.curatedWaste.count == 1)
    #expect(model.pendingCuratedAgents.first?.name == "Reply to refund emails with the policy link")
}

@MainActor @Test
func legacyActionModesAreTheOnlyDefaultContextPathThatRunActionMining() async throws {
    for mode in [
        CascadeAppModel.LegacyActionWasteMode.diagnosticsOnly,
        .linkRecipes,
        .fallbackReviewQueue,
    ] {
        let spy = DetectionSpy()
        let (model, store) = try makeModel(
            curatorReply: contextCuratorKeepsOne,
            legacyActionWasteMode: mode,
            detectedWasteReportObserver: spy.record
        )
        try await store.insertInputEvents(webWorkflowEvents())

        await model.refreshAll()

        #expect(spy.count == 1)
        #expect(model.detectedWaste.count == 1)
    }
}

@MainActor @Test
func contextWasteThumbnailOnlyUsesSafeVettedEvidenceFrames() {
    let waste = ContextWasteCandidate(
        title: "Repeated invoice work",
        apps: ["QuickBooks"],
        occurrences: 3,
        estimatedSecondsPerRun: 60,
        estimatedTotalSeconds: 180,
        evidenceContextIDs: [1, 3],
        sessionIDs: [1, 2, 3],
        signature: "context-sig",
        startedAt: base,
        endedAt: base.addingTimeInterval(180),
        lastSeenAt: base.addingTimeInterval(180),
        snippets: [],
        entities: [],
        quality: ContextWasteQuality(
            supportScore: 0.8,
            durationScore: 0.5,
            semanticStabilityScore: 0.9,
            actionabilityScore: 0.8,
            privacyPenalty: 0,
            noisePenalty: 0
        ),
        suggestedGoal: "Teach Cascade invoice work."
    )
    let contexts = [
        RecordedContext(id: 1, capturedAt: base.addingTimeInterval(10), source: .screen, appName: "QuickBooks", ocrText: "invoice queue", imagePath: "/frames/safe.png"),
        RecordedContext(id: 2, capturedAt: base.addingTimeInterval(179), source: .screen, appName: "QuickBooks", ocrText: "nearby same app", imagePath: "/frames/same-app.png"),
        RecordedContext(id: 3, capturedAt: base.addingTimeInterval(178), source: .screen, appName: "QuickBooks", ocrText: "unsafe evidence", imagePath: "/frames/unsafe.png", safeToShow: false),
    ]

    #expect(ContextWasteEvidenceImagePicker.safeImagePath(for: waste, contexts: contexts) == "/frames/safe.png")

    let unsafeEvidenceOnly = ContextWasteCandidate(
        title: waste.title,
        apps: waste.apps,
        occurrences: waste.occurrences,
        estimatedSecondsPerRun: waste.estimatedSecondsPerRun,
        estimatedTotalSeconds: waste.estimatedTotalSeconds,
        evidenceContextIDs: [3],
        sessionIDs: waste.sessionIDs,
        signature: waste.signature,
        startedAt: waste.startedAt,
        endedAt: waste.endedAt,
        lastSeenAt: waste.lastSeenAt,
        snippets: waste.snippets,
        entities: waste.entities,
        processTerms: waste.processTerms,
        parameters: waste.parameters,
        quality: waste.quality,
        suggestedGoal: waste.suggestedGoal
    )
    #expect(ContextWasteEvidenceImagePicker.safeImagePath(for: unsafeEvidenceOnly, contexts: contexts) == nil)
}

@MainActor @Test
func approvingContextWasteCreatesGoalDrivenAgentWithoutReplayRecipe() async throws {
    let (model, store) = try makeModel(curatorReply: contextCuratorKeepsOne)
    let contexts =
        contextSession(
            idStart: 1,
            start: 0,
            title: "Acme invoice queue",
            ocr: "Review vendor invoice queue, reconcile invoice totals, and mark vendor batch paid.",
            metadataJSON: #"{"project":"Acme invoices"}"#
        )
        + contextSession(
            idStart: 100,
            start: 3_600,
            title: "Beta invoice queue",
            ocr: "Review vendor invoice queue, reconcile invoice totals, and mark vendor batch paid.",
            metadataJSON: #"{"project":"Beta invoices"}"#
        )
        + contextSession(
            idStart: 200,
            start: 7_200,
            title: "Contoso invoice queue",
            ocr: "Review vendor invoice queue, reconcile invoice totals, and mark vendor batch paid.",
            metadataJSON: #"{"project":"Contoso invoices"}"#
        )
    _ = try await store.insertContexts(contexts)

    await model.refreshAll()
    let curated = try #require(model.pendingCuratedContextWaste.first)

    model.approveContextWaste(curated)
    try await waitUntil { model.agents.contains { $0.signature == curated.signature } }

    let agent = try #require(model.agents.first { $0.signature == curated.signature })
    #expect(agent.name == "Reconcile vendor invoices")
    #expect(agent.goal == "Reconcile the vendor invoice queue in QuickBooks.")
    #expect(agent.recipe.steps.isEmpty)
    #expect(agent.evidenceIDs == curated.evidence)
    #expect(!model.pendingCuratedContextWaste.contains { $0.signature == curated.signature })
}

@MainActor @Test
func contextWasteApprovalAuditAndPreferencePayloadsDoNotExposeRawOCR() async throws {
    let rawOCRToken = "ApertureDeltaContextOCRSecret"
    let (model, store) = try makeModel(curatorReply: contextCuratorKeepsOne)
    let contexts =
        contextSession(
            idStart: 1,
            start: 0,
            title: "Acme invoice queue",
            ocr: "Review \(rawOCRToken) vendor invoice queue, reconcile invoice totals, and mark vendor batch paid.",
            metadataJSON: #"{"project":"\#(rawOCRToken) invoices"}"#
        )
        + contextSession(
            idStart: 100,
            start: 3_600,
            title: "Beta invoice queue",
            ocr: "Review \(rawOCRToken) vendor invoice queue, reconcile invoice totals, and mark vendor batch paid.",
            metadataJSON: #"{"project":"\#(rawOCRToken) invoices"}"#
        )
        + contextSession(
            idStart: 200,
            start: 7_200,
            title: "Contoso invoice queue",
            ocr: "Review \(rawOCRToken) vendor invoice queue, reconcile invoice totals, and mark vendor batch paid.",
            metadataJSON: #"{"project":"\#(rawOCRToken) invoices"}"#
        )
    _ = try await store.insertContexts(contexts)

    await model.refreshAll()
    let waste = try #require(model.contextWaste.first)
    let curated = try #require(model.pendingCuratedContextWaste.first)
    #expect(!waste.snippets.joined(separator: " ").localizedCaseInsensitiveContains(rawOCRToken))

    model.approveContextWaste(curated)

    let approved = try await waitForAudit(store, action: "agent.approved")
    #expect(approved.detail.contains("source=context"))
    #expect(approved.detail.contains("nameHash="))
    #expect(approved.detail.contains("goalHash="))
    expectAuditDetail(approved.detail, excludesRawIdentityContaining: rawOCRToken)

    let preferencePayloads = try await store.recentPreferenceEvents(limit: 20)
        .map { event in
            [
                event.appName,
                event.workflowSignature,
                event.featureJSON,
                event.evidenceJSON
            ].compactMap { $0 }.joined(separator: " ")
        }
        .joined(separator: "\n")
    #expect(!preferencePayloads.localizedCaseInsensitiveContains(rawOCRToken))
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
    let (model, store) = try makeModel(curatorReply: curatorKeepsOne, contextWasteDetectionEnabled: false)
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
    let (model, store) = try makeModel(curatorReply: curatorKeepsOne, contextWasteDetectionEnabled: false)
    try await store.insertInputEvents(webWorkflowEvents())
    await model.refreshAll()
    let curated = try #require(model.pendingCuratedAgents.first)

    model.declineCurated(curated)

    #expect(model.pendingCuratedAgents.isEmpty) // filtered out at once
    #expect(model.curatedWaste.count == 1)      // still curated, just hidden
}

@MainActor @Test
func approvingCreatesAgentWithCuratedNameAndGoalThenLeavesPending() async throws {
    let (model, store) = try makeModel(curatorReply: curatorKeepsOne, contextWasteDetectionEnabled: false)
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
    let (model, store) = try makeModel(curatorReply: curatorKeepsOne, contextWasteDetectionEnabled: false)
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
    let (model, store) = try makeModel(curatorReply: curatorKeepsOne, contextWasteDetectionEnabled: false)
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
    // Parameterized clicks represent run-specific target labels and need the current target.
    #expect(CascadeAppModel.recipeStepNeedsLiveValue(
        RecipeStep(order: 1, kind: .click, x: 1, y: 1, text: "personName slot", appName: "Mail", isParameter: true)))
    #expect(!CascadeAppModel.recipeStepNeedsLiveValue(
        RecipeStep(order: 1, kind: .click, x: 1, y: 1, text: "Send", appName: "Mail", isParameter: false)))
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
func recipeReplayTargetClassifiersSeparateSemanticFromCoordinateOnly() {
    let textClick = RecipeStep(order: 0, kind: .click, x: 1, y: 1, text: "Send", appName: "Mail")
    let descriptorClick = RecipeStep(order: 1, kind: .click, x: 1, y: 1, appName: "Mail", targetDescriptor: "role=AXButton id=send")
    let anchorClick = RecipeStep(order: 2, kind: .click, x: 1, y: 1, appName: "Mail", ocrAnchor: "Archive")
    let coordinateOnly = RecipeStep(order: 3, kind: .click, x: 1, y: 1, appName: "Mail")

    #expect(CascadeAppModel.recipeStepHasSemanticReplayTarget(textClick))
    #expect(CascadeAppModel.recipeStepHasSemanticReplayTarget(descriptorClick))
    #expect(CascadeAppModel.recipeStepHasSemanticReplayTarget(anchorClick))
    #expect(!CascadeAppModel.recipeStepHasSemanticReplayTarget(coordinateOnly))
    #expect(CascadeAppModel.recipeStepIsCoordinateOnlyReplayTarget(coordinateOnly))
    #expect(CascadeAppModel.recipeStepBlocksOneShotCoordinateReplay(coordinateOnly, evidenceCount: 1))
    #expect(!CascadeAppModel.recipeStepBlocksOneShotCoordinateReplay(coordinateOnly, evidenceCount: 2))
    #expect(!CascadeAppModel.recipeStepIsCoordinateOnlyReplayTarget(textClick))
}

@MainActor @Test
func assistContinuationGoalCarriesCurrentSlotAndDemoContextWithoutLiteralReplay() {
    let demoLiteral = "ACME-DEMO-SECRET-420"
    let recipe = AgentRecipe(steps: [
        RecipeStep(order: 0, kind: .click, x: 10, y: 10, appName: "Mail", ocrAnchor: "Invoice total"),
        RecipeStep(order: 1, kind: .key, key: "c", modifiers: ["command"], appName: "Mail"),
        RecipeStep(order: 2, kind: .click, x: 20, y: 20, appName: "Numbers", ocrAnchor: "Amount"),
        RecipeStep(
            order: 3,
            kind: .type,
            text: demoLiteral,
            appName: "Numbers",
            isParameter: true,
            parameterKey: "invoice_total",
            parameterKind: .currency,
            valueHashes: [AuditIdentity.hash(demoLiteral)],
            sourceStepIDs: [0]
        ),
    ])
    let agent = CascadeAgent(
        name: "Copy invoice total",
        source: .detected,
        signature: "copy-total",
        recipe: recipe,
        apps: ["Mail", "Numbers"],
        evidenceCount: 1,
        goal: "Copy the current invoice total from Mail into Numbers",
        demoSketches: [
            AgentDemoSketch(
                id: "demo",
                appName: "Mail",
                normalizedGoalTokens: ["copy", "invoice", "total"],
                promptText: "TRAJECTORY SKETCH\napp: Mail\nfirst_actions:\n1. click \"Invoice total\"",
                actionCount: 1,
                anchorCount: 1,
                checkCount: 0
            )
        ]
    )

    let goal = CascadeAppModel.assistContinuationGoal(
        for: agent,
        reason: "this step needs the current value",
        sortedSteps: recipe.steps.sorted { $0.order < $1.order },
        currentIndex: 3,
        triggeringStep: recipe.steps[3]
    )

    #expect(goal.contains("Recorded steps before step 4 already ran"))
    #expect(goal.contains("Current live slot:"))
    #expect(goal.contains("invoice_total"))
    #expect(goal.contains("<invoice_total>"))
    #expect(goal.contains("Source steps: click “Invoice total”"))
    #expect(goal.contains("Remaining recorded process: type"))
    #expect(goal.contains("TRAJECTORY SKETCH"))
    #expect(!goal.contains(demoLiteral))
}

@MainActor @Test
func deployGoalAndSandboxTaskCarryStructuralBatchContract() {
    let recipe = AgentRecipe(steps: [
        RecipeStep(order: 0, kind: .click, appName: "Safari", surface: "Source catalog", ocrAnchor: "Alpha Record"),
        RecipeStep(order: 1, kind: .click, appName: "Safari", surface: "Source catalog", ocrAnchor: "Amount"),
        RecipeStep(
            order: 2,
            kind: .type,
            text: "Sample record",
            appName: "Safari",
            surface: "Destination tracker",
            isParameter: true,
            parameterKey: "record_name",
            parameterKind: .freeText,
            sourceStepIDs: [0]
        ),
        RecipeStep(
            order: 3,
            kind: .type,
            text: "$12",
            appName: "Safari",
            surface: "Destination tracker",
            isParameter: true,
            parameterKey: "amount",
            parameterKind: .currency,
            sourceStepIDs: [1]
        ),
    ])
    let agent = CascadeAgent(
        name: "Catalog import",
        source: .detected,
        signature: "catalog-import",
        recipe: recipe,
        apps: ["Safari"],
        goal: "Finish all remaining records from the source catalog in the destination tracker"
    )

    let onScreenGoal = CascadeAppModel.deployGoal(for: agent)
    let sandboxTask = CascadeAppModel.sandboxTask(for: agent)

    #expect(onScreenGoal.contains("structural batch/list control loop"))
    #expect(onScreenGoal.contains("measure destination identities"))
    #expect(onScreenGoal.contains("report count-only totals"))
    #expect(sandboxTask.contains("structural batch/list control loop"))
    #expect(sandboxTask.contains("Do not split this into per-record/item subtasks"))
    #expect(onScreenGoal.contains("source catalog"))
    #expect(sandboxTask.contains("destination tracker"))
    #expect(onScreenGoal.contains("Destination procedure template"))
    #expect(sandboxTask.contains("actively switch to the destination surface"))
    #expect(!onScreenGoal.contains("Sample record"))
    #expect(!sandboxTask.contains("Sample record"))
    #expect(!onScreenGoal.contains("Alpha Record"))
    #expect(!sandboxTask.contains("Alpha Record"))
}

@MainActor @Test
func deployAgentRoutesBatchAgentThroughAssistControlLoop() async throws {
    let (model, store) = try makeModel()
    let recipe = AgentRecipe(steps: [
        RecipeStep(order: 0, kind: .click, appName: "Numbers", surface: "Source catalog", ocrAnchor: "Alpha Record"),
        RecipeStep(
            order: 1,
            kind: .type,
            text: "Alpha Record",
            appName: "Numbers",
            surface: "Destination tracker",
            isParameter: true,
            parameterKey: "record_name",
            parameterKind: .freeText,
            sourceStepIDs: [0]
        ),
    ])
    let agent = CascadeAgent(
        name: "Catalog import",
        source: .detected,
        signature: "batch-route",
        recipe: recipe,
        apps: ["Numbers"],
        goal: "Import all remaining records from the source catalog into the destination tracker"
    )

    model.deployAgent(agent)
    try await waitUntil { !model.agentRunning }
    let audit = try await store.recentAudit(limit: 40)

    #expect(!audit.contains { $0.action == "agent.batch.run.started" })
    #expect(!audit.contains { $0.action == "agent.batch.run.ended" })
    #expect(!audit.contains { $0.action == "recipe.run.started" })
    #expect(!audit.contains { $0.action == "recipe.parameter" })
    #expect(!model.agentMessage.contains("Alpha Record"))
    #expect(!model.agentRunning)
}

@MainActor @Test
func deployAgentKeepsNonBatchParameterizedAgentOnExistingAssistEscalationPath() async throws {
    let (model, store) = try makeModel()
    let recipe = AgentRecipe(steps: [
        RecipeStep(
            order: 0,
            kind: .type,
            text: "$420",
            appName: "Numbers",
            surface: "Numbers",
            isParameter: true,
            parameterKey: "invoice_total",
            parameterKind: .currency,
            sourceStepIDs: [0]
        ),
    ])
    let agent = CascadeAgent(
        name: "Invoice total",
        source: .detected,
        signature: "non-batch-parameter",
        recipe: recipe,
        apps: ["Numbers"],
        goal: "Copy the latest invoice total into Numbers"
    )

    model.deployAgent(agent)
    let parameter = try await waitForAudit(store, action: "recipe.parameter")
    let audit = try await store.recentAudit(limit: 40)

    #expect(parameter.detail.contains("recoveryAction="))
    #expect(audit.contains { $0.action == "recipe.run.started" })
    #expect(!audit.contains { $0.action == "agent.batch.run.started" })
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

private func taughtSingleAppTypeEvents(at now: Date) -> [InputEvent] {
    [
        InputEvent(id: 10, capturedAt: now.addingTimeInterval(0.000), kind: .click, x: 10, y: 10, text: "Message", appName: "Notes"),
        InputEvent(id: 11, capturedAt: now.addingTimeInterval(0.001), kind: .type, text: "typed 13 chars", appName: "Notes"),
        InputEvent(id: 12, capturedAt: now.addingTimeInterval(0.002), kind: .key, key: "Return", appName: "Notes"),
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
func teachOnceNoCandidateDoesNotAskForRepeatability() async throws {
    let (model, _) = try makeModel()
    model.beginTeaching()
    try await Task.sleep(for: .milliseconds(450))
    model.endTeaching()

    try await waitUntil({ model.teachStatus?.contains("concrete actions") == true }, maxTries: 500)
    let status = try #require(model.teachStatus)
    #expect(model.teachPreview == nil)
    #expect(!status.localizedCaseInsensitiveContains("repeatable"))
    #expect(!status.localizedCaseInsensitiveContains("try the task again"))
    #expect(status.contains("short, clear sequence"))
    #expect(status.contains("click, shortcut, typed value, or copy/paste step"))
}

@MainActor @Test
func teachOnceSingleAppDemoBuildsPreview() async throws {
    let reply = #"{"agents":[{"index":0,"name":"Draft the Notes message","why":"shown once","goal":"Draft the current message in Notes and submit it.","value":0.8}]}"#
    let (model, store) = try makeModel(curatorReply: reply)
    model.beginTeaching()

    let now = Date()
    try await store.insertInputEvents(taughtSingleAppTypeEvents(at: now))
    try await Task.sleep(for: .milliseconds(450))
    model.endTeaching()

    try await waitUntil({ model.teachPreview != nil }, maxTries: 500)
    let preview = try #require(model.teachPreview)
    let type = try #require(preview.source.recipe.steps.first { $0.kind == .type })
    #expect(preview.name == "Draft the Notes message")
    #expect(preview.apps == ["Notes"])
    #expect(type.isParameter)
    #expect(type.text == "freeText:typed 13 chars")
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
func teachFinishWaitsForDrainAndCuratesFinalCallbackIntent() async throws {
    let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = TestTeachClock(startedAt)
    let sessionID = UUID()
    let drainGate = TeachDrainGate()
    let completer = SequenceCompleter(replies: [teachCuratorReply(
        name: "Check course seats and report them",
        goal: "Check the requested course seats and send the report."
    )])
    let (model, store) = try makeModel(
        curatorClient: completer,
        teachClock: { clock.now() },
        teachSessionIDFactory: { sessionID },
        teachRecorderSettleOperation: {},
        teachNarrationDrain: { _, _ in await drainGate.wait() }
    )
    model.beginTeaching()
    try await store.insertInputEvents(taughtCopyPasteEvents(at: startedAt))
    clock.advance(1)

    model.endTeaching()

    #expect(model.teachStatus == "Finishing your narration…")
    #expect(model.teachPreview == nil)
    try? await Task.sleep(for: .milliseconds(20))
    #expect(await completer.callCount() == 0)

    let finalNarration = "check empty seats for four courses and send the report"
    model.voice.onUtterance?(RealtimeVoice.CompletedUtterance(
        text: finalNarration,
        itemID: "final-teach-item",
        purpose: .teachAmbient(sessionID: sessionID, automaticEndpointing: true)
    ))
    #expect(model.teachPreview == nil)
    await drainGate.release(.drained)

    try await waitUntil({ model.teachPreview != nil })
    let prompts = await completer.prompts()
    #expect(prompts.count == 1)
    #expect(prompts[0].contains(finalNarration))
    let stopped = try await waitForAudit(store, action: "teach.stopped")
    #expect(stopped.detail.contains("drain=drained"))
    #expect(!stopped.detail.contains(finalNarration))
    #expect(!stopped.detail.contains("status=silent"))
}

@MainActor @Test
func fortySecondFinalTeachTranscriptStaysInDrainAndNeverRoutesAsCommand() async throws {
    let startedAt = Date(timeIntervalSince1970: 1_800_000_500)
    let clock = TestTeachClock(startedAt)
    let sessionID = UUID()
    let drainGate = TeachDrainGate()
    let completer = SequenceCompleter(replies: [teachCuratorReply(
        name: "Registration seat report",
        goal: "Check the requested course seats and send the report."
    )])
    let (model, store) = try makeModel(
        curatorClient: completer,
        teachClock: { clock.now() },
        teachSessionIDFactory: { sessionID },
        teachRecorderSettleOperation: {},
        teachNarrationDrain: { _, _ in await drainGate.wait() }
    )
    model.beginTeaching()
    try await store.insertInputEvents(taughtCopyPasteEvents(at: startedAt))
    clock.advance(1)
    let generationBeforeFinish = model.currentAssistGeneration
    model.endTeaching()

    for _ in 0..<100 {
        if await drainGate.isWaiting() { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await drainGate.isWaiting())
    clock.advance(40)

    let fullNarration = "enter registration, check empty seats for four courses, and send a report to the specified Instagram profile"
    model.voice.onUtterance?(RealtimeVoice.CompletedUtterance(
        text: fullNarration,
        itemID: "forty-second-final-item",
        purpose: .teachAmbient(sessionID: sessionID, automaticEndpointing: true)
    ))
    #expect(model.teachPreview == nil)
    #expect(!model.showSettings)
    #expect(model.currentAssistGeneration == generationBeforeFinish)

    await drainGate.release(.drained)
    try await waitUntil({ model.teachPreview?.name == "Registration seat report" })

    let prompts = await completer.prompts()
    #expect(prompts.count == 1)
    #expect(prompts[0].contains(fullNarration))
    let audits = try await store.recentAudit(limit: 100)
    #expect(!audits.contains { $0.action == "assist.task" })
    #expect(!audits.contains { $0.action == "teach.reveal" })
    #expect(!model.showSettings)
    #expect(model.currentAssistGeneration == generationBeforeFinish)
}

@MainActor @Test
func teachFinishTimeoutCuratesWhateverNarrationAlreadyArrived() async throws {
    let startedAt = Date(timeIntervalSince1970: 1_800_001_000)
    let clock = TestTeachClock(startedAt)
    let sessionID = UUID()
    let completer = SequenceCompleter(replies: [teachCuratorReply(
        name: "Prepare the weekly report",
        goal: "Prepare the weekly report from the demonstrated sources."
    )])
    let (model, store) = try makeModel(
        curatorClient: completer,
        teachClock: { clock.now() },
        teachSessionIDFactory: { sessionID },
        teachRecorderSettleOperation: {},
        teachNarrationDrain: { _, _ in .timedOut }
    )
    model.beginTeaching()
    model.teach(question: "pull the weekly numbers into the Monday report")
    try await store.insertInputEvents(taughtCopyPasteEvents(at: startedAt))
    clock.advance(1)

    model.endTeaching()

    try await waitUntil({ model.teachPreview != nil })
    let prompts = await completer.prompts()
    #expect(prompts.first?.contains("pull the weekly numbers into the Monday report") == true)
    let stopped = try await waitForAudit(store, action: "teach.stopped")
    #expect(stopped.detail.contains("drain=timed_out"))
    #expect(!stopped.detail.contains("status=silent"))
}

@MainActor @Test
func fortySecondTranscriptAfterDrainTimeoutReconcilesWithoutCommandRouting() async throws {
    let startedAt = Date(timeIntervalSince1970: 1_800_001_500)
    let clock = TestTeachClock(startedAt)
    let sessionID = UUID()
    let completer = SequenceCompleter(replies: [
        teachCuratorReply(name: "Initial silent demonstration", goal: "Copy the demonstrated values."),
        teachCuratorReply(name: "Recovered registration report", goal: "Check the requested course seats and send the report."),
    ])
    let (model, store) = try makeModel(
        curatorClient: completer,
        teachClock: { clock.now() },
        teachSessionIDFactory: { sessionID },
        teachRecorderSettleOperation: {},
        teachNarrationDrain: { _, _ in .timedOut }
    )
    model.beginTeaching()
    try await store.insertInputEvents(taughtCopyPasteEvents(at: startedAt))
    clock.advance(1)
    model.endTeaching()
    try await waitUntil({ model.teachPreview?.name == "Initial silent demonstration" })
    let generationBeforeLateCallback = model.currentAssistGeneration
    clock.advance(40)

    let fullNarration = "enter registration, check empty seats for four courses, and send a report to the specified Instagram profile"
    model.voice.onUtterance?(RealtimeVoice.CompletedUtterance(
        text: fullNarration,
        itemID: "forty-second-timeout-item",
        purpose: .teachAmbient(sessionID: sessionID, automaticEndpointing: true)
    ))

    try await waitUntil({ model.teachPreview?.name == "Recovered registration report" })
    let prompts = await completer.prompts()
    #expect(prompts.count == 2)
    #expect(!prompts[0].contains(fullNarration))
    #expect(prompts[1].contains(fullNarration))
    #expect(!model.showSettings)
    #expect(model.currentAssistGeneration == generationBeforeLateCallback)
    let audits = try await store.recentAudit(limit: 100)
    #expect(!audits.contains { $0.action == "assist.task" })
    #expect(!audits.contains { $0.action == "teach.reveal" })
}

@MainActor @Test
func lateTeachTranscriptWithinWindowRecuratesVisiblePreviewWithoutTouchingAssistState() async throws {
    let startedAt = Date(timeIntervalSince1970: 1_800_002_000)
    let clock = TestTeachClock(startedAt)
    let sessionID = UUID()
    let completer = SequenceCompleter(replies: [
        teachCuratorReply(name: "Initial taught agent", goal: "Copy the demonstrated values."),
        teachCuratorReply(name: "Course seat report", goal: "Check course seats and send the report."),
    ])
    let (model, store) = try makeModel(
        curatorClient: completer,
        teachClock: { clock.now() },
        teachSessionIDFactory: { sessionID },
        teachRecorderSettleOperation: {},
        teachNarrationDrain: { _, _ in .timedOut }
    )
    model.beginTeaching()
    model.teach(question: "copy the demonstrated values")
    try await store.insertInputEvents(taughtCopyPasteEvents(at: startedAt))
    clock.advance(1)
    model.endTeaching()
    try await waitUntil({ model.teachPreview?.name == "Initial taught agent" })

    let generation = model.currentAssistGeneration
    let stoppedBefore = model.driver.runState.isStopRequested
    let lateNarration = "also check empty seats for four courses and send a report"
    model.voice.onUtterance?(RealtimeVoice.CompletedUtterance(
        text: lateNarration,
        itemID: "late-teach-item",
        purpose: .teachAmbient(sessionID: sessionID, automaticEndpointing: true)
    ))

    try await waitUntil({ model.teachPreview?.name == "Course seat report" })
    let prompts = await completer.prompts()
    #expect(prompts.count == 2)
    #expect(prompts[1].contains("copy the demonstrated values"))
    #expect(prompts[1].contains(lateNarration))
    #expect(model.currentAssistGeneration == generation)
    #expect(model.driver.runState.isStopRequested == stoppedBefore)
    #expect(!model.showSettings)
    let lateAudit = try await waitForAudit(store, action: "teach.intent.late")
    #expect(!lateAudit.detail.contains(lateNarration))
    #expect(!(try await store.recentAudit(limit: 80)).contains { $0.action == "assist.task" })
}

@MainActor @Test
func lateTeachFailurePreservesPreviewAndDoesNotTouchRunningAssist() async throws {
    let startedAt = Date(timeIntervalSince1970: 1_800_002_250)
    let clock = TestTeachClock(startedAt)
    let sessionID = UUID()
    let assistGate = AssistLifecycleGate()
    let curation = SucceedThenThrowTeachCuration(firstResult: taughtCurated(
        signature: "visible-teach-signature",
        name: "Visible taught agent"
    ))
    let (model, store) = try makeModel(
        teachClock: { clock.now() },
        teachSessionIDFactory: { sessionID },
        teachRecorderSettleOperation: {},
        teachNarrationDrain: { _, _ in .timedOut },
        teachCurationOverride: { from, to, statedIntent in
            try await curation.curate(from: from, to: to, statedIntent: statedIntent)
        },
        assistTaskLifecycleOverride: { await assistGate.hold() }
    )
    model.beginTeaching()
    model.teach(question: "copy the demonstrated values")
    try await store.insertInputEvents(taughtCopyPasteEvents(at: startedAt))
    clock.advance(1)
    model.endTeaching()
    try await waitUntil({ model.teachPreview?.name == "Visible taught agent" })
    let visiblePreview = try #require(model.teachPreview)

    let assistTask = Task {
        await model.runInjectedAssistTaskForTesting(goal: "prepare the quarterly deck")
    }
    for _ in 0..<100 {
        if await assistGate.hasStarted() { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await assistGate.hasStarted())
    #expect(model.assistTaskRunningForTesting)
    let generation = model.currentAssistGeneration
    let stoppedBefore = model.driver.runState.isStopRequested

    model.voice.onUtterance?(RealtimeVoice.CompletedUtterance(
        text: "okay",
        itemID: "ptt-ack-during-assist",
        purpose: .pushToTalk
    ))
    let lateNarration = "also check the requested course seats before sending the report"
    model.voice.onUtterance?(RealtimeVoice.CompletedUtterance(
        text: lateNarration,
        itemID: "late-teach-during-assist",
        purpose: .teachAmbient(sessionID: sessionID, automaticEndpointing: true)
    ))

    for _ in 0..<500 {
        if await curation.callCount() >= 2,
           model.teachStatus?.contains("couldn't update") == true {
            break
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await curation.callCount() == 2)
    #expect(model.teachStatus?.contains("couldn't update") == true)
    #expect(model.teachPreview == visiblePreview)
    #expect(model.assistTaskRunningForTesting)
    #expect(model.currentAssistGeneration == generation)
    #expect(model.driver.runState.isStopRequested == stoppedBefore)
    #expect(!model.showSettings)
    let audits = try await store.recentAudit(limit: 120)
    #expect(audits.filter { $0.action == "assist.task" }.count == 1)
    #expect(audits.filter { $0.action == "teach.intent.late" }.count == 1)
    #expect(!audits.contains { $0.action == "teach.reveal" })

    await assistGate.release()
    await assistTask.value
    #expect(!model.assistTaskRunningForTesting)
}

@MainActor @Test(arguments: [false, true])
func consecutiveTeachCallbacksReconcileToTheirOwnBracketsInEitherOrder(
    deliverSecondFirst: Bool
) async throws {
    let startedAt = Date(timeIntervalSince1970: 1_800_002_500)
    let clock = TestTeachClock(startedAt)
    let firstSessionID = UUID()
    let secondSessionID = UUID()
    let sessionIDs = TestTeachSessionIDs([firstSessionID, secondSessionID])
    let completer = SequenceCompleter(replies: [
        teachCuratorReply(name: "First initial teach", goal: "Copy values from Mail to Numbers."),
        teachCuratorReply(name: "Second initial teach", goal: "Draft the current Notes message."),
        teachCuratorReply(name: "First late result", goal: "Use the recovered narration."),
        teachCuratorReply(name: "Second late result", goal: "Use the recovered narration."),
    ])
    let (model, store) = try makeModel(
        curatorClient: completer,
        teachClock: { clock.now() },
        teachSessionIDFactory: { sessionIDs.next() },
        teachRecorderSettleOperation: {},
        teachNarrationDrain: { _, _ in .timedOut }
    )

    model.beginTeaching()
    try await store.insertInputEvents(taughtCopyPasteEvents(at: clock.now()))
    clock.advance(1)
    model.endTeaching()
    try await waitUntil({ model.teachPreview?.name == "First initial teach" })

    model.beginTeaching()
    try await store.insertInputEvents(taughtSingleAppTypeEvents(at: clock.now()))
    clock.advance(1)
    model.endTeaching()
    try await waitUntil({ model.teachPreview?.name == "Second initial teach" })

    let firstNarration = "the first demo copies the selected inbox value into the Numbers sheet"
    let secondNarration = "the second demo drafts the current message in Notes"
    let firstCallback = RealtimeVoice.CompletedUtterance(
        text: firstNarration,
        itemID: "late-first-teach",
        purpose: .teachAmbient(sessionID: firstSessionID, automaticEndpointing: true)
    )
    let secondCallback = RealtimeVoice.CompletedUtterance(
        text: secondNarration,
        itemID: "late-second-teach",
        purpose: .teachAmbient(sessionID: secondSessionID, automaticEndpointing: true)
    )
    let callbacks = deliverSecondFirst
        ? [secondCallback, firstCallback]
        : [firstCallback, secondCallback]
    let generationBeforeCallbacks = model.currentAssistGeneration

    for (offset, callback) in callbacks.enumerated() {
        model.voice.onUtterance?(callback)
        try await waitForCompleterCalls(completer, count: 3 + offset)
    }

    let prompts = await completer.prompts()
    #expect(prompts.count == 4)
    let firstLatePrompt = try #require(prompts.first { $0.contains(firstNarration) })
    let secondLatePrompt = try #require(prompts.first { $0.contains(secondNarration) })
    #expect(firstLatePrompt.contains("apps: Mail → Numbers"))
    #expect(!firstLatePrompt.contains("apps: Notes"))
    #expect(secondLatePrompt.contains("apps: Notes"))
    #expect(!secondLatePrompt.contains("apps: Mail"))
    #expect(!model.showSettings)
    #expect(model.currentAssistGeneration == generationBeforeCallbacks)
    let audits = try await store.recentAudit(limit: 120)
    #expect(audits.filter { $0.action == "teach.intent.late" }.count == 2)
    #expect(!audits.contains { $0.action == "assist.task" || $0.action == "teach.reveal" })
}

@MainActor @Test
func pushToTalkTranscriptInsideLateWindowRoutesNormally() async throws {
    let startedAt = Date(timeIntervalSince1970: 1_800_003_000)
    let clock = TestTeachClock(startedAt)
    let sessionID = UUID()
    let completer = SequenceCompleter(replies: [teachCuratorReply(
        name: "Initial taught agent",
        goal: "Copy the demonstrated values."
    )])
    let (model, store) = try makeModel(
        curatorClient: completer,
        teachClock: { clock.now() },
        teachSessionIDFactory: { sessionID },
        teachRecorderSettleOperation: {},
        teachNarrationDrain: { _, _ in .drained }
    )
    model.beginTeaching()
    try await store.insertInputEvents(taughtCopyPasteEvents(at: startedAt))
    clock.advance(1)
    model.endTeaching()
    try await waitUntil({ model.teachPreview != nil })

    model.voice.onUtterance?(RealtimeVoice.CompletedUtterance(
        text: "open Notes and write hello",
        itemID: "fresh-ptt",
        purpose: .pushToTalk
    ))

    #expect(model.showSettings)
    #expect(await completer.callCount() == 1)
    #expect((try await store.recentAudit(limit: 80)).allSatisfy { $0.action != "teach.intent.late" })
}

@MainActor @Test
func expiredTeachTranscriptReturnsToNormalRouting() async throws {
    let startedAt = Date(timeIntervalSince1970: 1_800_004_000)
    let clock = TestTeachClock(startedAt)
    let sessionID = UUID()
    let completer = SequenceCompleter(replies: [teachCuratorReply(
        name: "Initial taught agent",
        goal: "Copy the demonstrated values."
    )])
    let (model, store) = try makeModel(
        curatorClient: completer,
        teachClock: { clock.now() },
        teachSessionIDFactory: { sessionID },
        teachRecorderSettleOperation: {},
        teachNarrationDrain: { _, _ in .drained }
    )
    model.beginTeaching()
    try await store.insertInputEvents(taughtCopyPasteEvents(at: startedAt))
    clock.advance(1)
    model.endTeaching()
    try await waitUntil({ model.teachPreview != nil })
    clock.advance(91)

    model.voice.onUtterance?(RealtimeVoice.CompletedUtterance(
        text: "open Notes and write hello",
        itemID: "expired-teach-item",
        purpose: .teachAmbient(sessionID: sessionID, automaticEndpointing: true)
    ))

    #expect(model.showSettings)
    #expect(await completer.callCount() == 1)
}

@MainActor @Test
func newerLateRevisionWinsOverInFlightInitialCuration() async throws {
    let startedAt = Date(timeIntervalSince1970: 1_800_005_000)
    let clock = TestTeachClock(startedAt)
    let sessionID = UUID()
    let completer = SequenceCompleter(
        replies: [
            teachCuratorReply(name: "Stale initial result", goal: "Copy the demonstrated values."),
            teachCuratorReply(name: "Newest narrated result", goal: "Build the full narrated report."),
        ],
        holdFirst: true
    )
    let (model, store) = try makeModel(
        curatorClient: completer,
        teachClock: { clock.now() },
        teachSessionIDFactory: { sessionID },
        teachRecorderSettleOperation: {},
        teachNarrationDrain: { _, _ in .timedOut }
    )
    model.beginTeaching()
    model.teach(question: "copy the demonstrated values")
    try await store.insertInputEvents(taughtCopyPasteEvents(at: startedAt))
    clock.advance(1)
    model.endTeaching()
    try await waitForCompleterCalls(completer, count: 1)

    model.voice.onUtterance?(RealtimeVoice.CompletedUtterance(
        text: "then build and send the full report",
        itemID: "revision-two",
        purpose: .teachAmbient(sessionID: sessionID, automaticEndpointing: true)
    ))
    try await waitUntil({ model.teachPreview?.name == "Newest narrated result" })
    await completer.releaseFirst()
    try? await Task.sleep(for: .milliseconds(50))

    #expect(model.teachPreview?.name == "Newest narrated result")
    #expect(await completer.callCount() == 2)
}

@MainActor @Test
func teachingRunsTheDemoCaptureBurst() throws {
    // While demonstrating, the recorder captures every 0.5s (instead of the normal
    // 1s changed-frame cadence) so the whole concept of the demo lands on record;
    // ending the demonstration restores the normal cadence.
    let (model, _) = try makeModel()
    #expect(!model.recorder.demoBurstEnabled)
    model.beginTeaching()
    #expect(model.recorder.demoBurstEnabled)
    model.endTeaching()
    #expect(!model.recorder.demoBurstEnabled)
}

@MainActor @Test
func voicePartialUtteranceUpdatesStatusWithoutTeaching() throws {
    let (model, _) = try makeModel()
    let initialTeachMessage = model.teachMessage

    model.voice.onPartialUtterance?("  ok  ")

    #expect(model.voicePartialUtterance == "ok")
    #expect(model.teachStatus?.contains("ok") == true)
    #expect(model.teachMessage == initialTeachMessage)
    #expect(!model.showSettings)
    #expect(!model.agentRunning)

    model.teach(question: "ok")

    #expect(model.teachMessage == "ok")
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

@Test
func routeIntentHeuristicCoversCommonLookupForms() {
    #expect(CascadeAppModel.routeIntentHeuristic("Find the invoice from yesterday").routingIntent == .answerRecord)
    #expect(CascadeAppModel.routeIntentHeuristic("look up the latest exchange rate").routingIntent == .webFact)
    #expect(CascadeAppModel.routeIntentHeuristic("ابحث عن ملف العقد").routingIntent == .mixed)
    #expect(CascadeAppModel.routeIntentHeuristic("Open Notes and write hello").routingIntent == .action)
}

@Test
func searchUngatedAuditDetailKeepsGoalAndQueryHashOnly() {
    let rawToken = "ApertureDeltaSearchSeed"
    let route = SearchRouteHint(
        routingIntent: .web,
        candidateSources: [.web],
        cleanQuery: rawToken
    )

    let detail = CascadeAppModel.assistSearchUngatedAuditDetail(
        goal: rawToken,
        routeHint: route,
        status: "blocked"
    )

    #expect(detail.contains("status=blocked"))
    #expect(detail.contains("intent=web"))
    #expect(detail.contains("sources=web"))
    #expect(detail.contains("goalHash=\(AuditIdentity.hash(rawToken))"))
    #expect(detail.contains("cleanQueryHash=\(AuditIdentity.hash(rawToken))"))
    #expect(!detail.contains(rawToken))
}

@Test
func searchToolClassifiersCoverReadOnlyAndRecallTools() {
    #expect(AgentHarness.isReadOnlyTool("search_files"))
    #expect(AgentHarness.isReadOnlyTool("list_folder"))
    #expect(AgentHarness.isReadOnlyTool("read_file"))
    #expect(!AgentHarness.isReadOnlyTool("run_command"))

    #expect(RecordRecall.isRecallTool("search_record"))
    #expect(RecordRecall.isRecallTool("inspect_moment"))
    #expect(!RecordRecall.isRecallTool("search_files"))
}

@Test
func searchEvidenceVerdictParserUsesStrictLeadingToken() {
    #expect(CascadeAppModel.SearchEvidenceVerdict.parse("SUFFICIENT") == .sufficient)
    #expect(CascadeAppModel.SearchEvidenceVerdict.parse("SUFFICIENT: local files answer it") == .sufficient)
    #expect(CascadeAppModel.SearchEvidenceVerdict.parse("INSUFFICIENT - no matching record") == .insufficient)
    #expect(CascadeAppModel.SearchEvidenceVerdict.parse("ABSTAIN") == .abstain)
    #expect(CascadeAppModel.SearchEvidenceVerdict.parse("SUFFICIENTLY likely") == .abstain)
    #expect(CascadeAppModel.SearchEvidenceVerdict.parse("maybe") == .abstain)
}

@Test
func firstConcreteLocalPathSkipsStatusAndCountLines() {
    let output = """
    status=ok
    No files matched the first pattern.
    /Users/mohanadbahammam/Documents/report.pdf
    /Users/mohanadbahammam/Documents/old.pdf 3 more.
    """

    #expect(CascadeAppModel.firstConcreteLocalPath(from: output) == "/Users/mohanadbahammam/Documents/report.pdf")
    #expect(CascadeAppModel.firstConcreteLocalPath(from: "status=ok\nNo files matched") == nil)
}

@Test
func searchEscalationAndBackgroundPreferenceArePureRouteDecisions() {
    let web = SearchRouteHint(routingIntent: .web, candidateSources: [.web], cleanQuery: "rate")
    let localThenWeb = SearchRouteHint(routingIntent: .multi, candidateSources: [.recordedMemory, .web], cleanQuery: "rate")
    let localOnly = SearchRouteHint(routingIntent: .localFiles, candidateSources: [.localFiles], cleanQuery: "invoice")

    #expect(CascadeAppModel.shouldPreferBackgroundWeb(routeHint: web))
    #expect(!CascadeAppModel.shouldPreferBackgroundWeb(routeHint: localThenWeb))
    #expect(CascadeAppModel.shouldEscalateSearchToWeb(routeHint: localThenWeb, verdict: .insufficient))
    #expect(CascadeAppModel.shouldEscalateSearchToWeb(routeHint: localThenWeb, verdict: .abstain))
    #expect(!CascadeAppModel.shouldEscalateSearchToWeb(routeHint: localThenWeb, verdict: .sufficient))
    #expect(!CascadeAppModel.shouldEscalateSearchToWeb(routeHint: localOnly, verdict: .insufficient))
}

@Test
func assistBackgroundWebResultClassificationIsPure() {
    let task = "look up the filing deadline"

    switch CascadeAppModel.classifyAssistBackgroundWebUpdate(task: task, update: completedUpdate("Due April 30")) {
    case .finding(let finding):
        #expect(finding == AgentTaskFinding(task: task, result: "Due April 30"))
    default:
        #expect(Bool(false))
    }

    let login = BackgroundWebAgent.Update(
        status: "Sign in required",
        snapshotPNG: nil,
        url: "https://example.com",
        done: true,
        result: "Please sign in",
        needsLogin: true
    )
    switch CascadeAppModel.classifyAssistBackgroundWebUpdate(task: task, update: login) {
    case .pause(let reason):
        #expect(reason == "Please sign in")
    default:
        #expect(Bool(false))
    }

    switch CascadeAppModel.classifyAssistBackgroundWebUpdate(task: task, update: failedUpdate("Could not load")) {
    case .pause(let reason):
        #expect(reason == "Could not load")
    default:
        #expect(Bool(false))
    }
}
