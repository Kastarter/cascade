import CascadeMemory
import Foundation
import ProviderKit
import WasteDetection
import Testing

@testable import AgentOrchestrator

private struct FakeCompleter: MessageCompleting {
    let canned: String
    func complete(system: String?, user: String, model: String, maxTokens: Int) async throws -> String {
        canned
    }
}

/// Counts how many times the model was asked — to prove the orchestrator caches.
private actor CallCounter {
    private(set) var calls = 0
    func bump() { calls += 1 }
}

private struct CountingCompleter: MessageCompleting {
    let canned: String
    let counter: CallCounter
    func complete(system: String?, user: String, model: String, maxTokens: Int) async throws -> String {
        await counter.bump()
        return canned
    }
}

private let base = Date(timeIntervalSince1970: 1_700_000_000)

private func makeStore() throws -> CascadeStore {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("CascadeCuratorIT-\(UUID().uuidString).sqlite").path
    return try CascadeStore(path: path)
}

/// A repeated Mail→Numbers copy/paste — the detector catches it as one workflow.
private func copyPasteEvents() -> [InputEvent] {
    var events: [InputEvent] = []
    var i = 0
    for run in 0..<3 {
        let start = TimeInterval(run * 300)
        events.append(InputEvent(id: Int64(i), capturedAt: base.addingTimeInterval(start), kind: .click, x: 10, y: 10, text: "Inbox", appName: "Mail")); i += 1
        events.append(InputEvent(id: Int64(i), capturedAt: base.addingTimeInterval(start + 8), kind: .key, key: "c", modifiers: ["command"], appName: "Mail")); i += 1
        events.append(InputEvent(id: Int64(i), capturedAt: base.addingTimeInterval(start + 16), kind: .click, x: 20, y: 20, text: "A1", appName: "Numbers")); i += 1
        events.append(InputEvent(id: Int64(i), capturedAt: base.addingTimeInterval(start + 24), kind: .key, key: "v", modifiers: ["command"], appName: "Numbers")); i += 1
    }
    return events
}

private struct FailingCompleter: MessageCompleting {
    func complete(system: String?, user: String, model: String, maxTokens: Int) async throws -> String {
        throw AnthropicError.missingKey
    }
}

/// Captures the user prompt the curator sent — to prove the spoken intent reaches it.
private actor PromptCapture {
    private(set) var lastUser = ""
    func record(_ user: String) { lastUser = user }
}

private struct CapturingCompleter: MessageCompleting {
    let canned: String
    let capture: PromptCapture
    func complete(system: String?, user: String, model: String, maxTokens: Int) async throws -> String {
        await capture.record(user)
        return canned
    }
}

private func waste(
    _ title: String, apps: [String], signature: String,
    occurrences: Int = 3, perRun: Int = 30, confidence: Double = 0.7
) -> DetectedWaste {
    DetectedWaste(
        title: title,
        apps: apps,
        occurrences: occurrences,
        estimatedSecondsPerRun: perRun,
        estimatedTotalSeconds: perRun * occurrences,
        recipe: AgentRecipe(steps: [
            RecipeStep(order: 0, kind: .activateApp, appName: apps.first ?? "App"),
            RecipeStep(order: 1, kind: .key, key: "c", modifiers: ["command"], appName: apps.first ?? "App"),
        ]),
        evidence: [1, 2],
        confidence: confidence,
        signature: signature
    )
}

private func contextWaste(
    _ title: String = "Repeated vendor invoice work",
    linkedActionSignature: String? = nil
) -> ContextWasteCandidate {
    ContextWasteCandidate(
        title: title,
        apps: ["QuickBooks"],
        occurrences: 3,
        estimatedSecondsPerRun: 3_600,
        estimatedTotalSeconds: 10_800,
        evidenceContextIDs: [1, 2, 3],
        sessionIDs: [1, 100, 200],
        signature: "context-sig",
        startedAt: base,
        endedAt: base.addingTimeInterval(10_800),
        lastSeenAt: base.addingTimeInterval(10_800),
        snippets: ["Review vendor invoice queue and mark batch paid."],
        entities: [ContextWasteEntity(kind: .project, canonicalValue: "vendor invoices", displayName: "Vendor invoices")],
        quality: ContextWasteQuality(
            supportScore: 0.8,
            durationScore: 1.0,
            semanticStabilityScore: 0.9,
            actionabilityScore: 0.8,
            privacyPenalty: 0,
            noisePenalty: 0
        ),
        suggestedGoal: "Teach Cascade to handle vendor invoice review in QuickBooks.",
        linkedActionSignature: linkedActionSignature
    )
}

@Test
func curatorKeepsRenamesAndDropsNoise() async {
    let candidates = [
        waste("Repeated steps in Mail", apps: ["Mail", "Numbers"], signature: "sig-a"),
        waste("Repeated steps in Safari", apps: ["Safari"], signature: "sig-b"),
    ]
    let canned = """
    {"agents":[
      {"index":0,"name":"Copy invoice totals from Mail into Numbers","why":"You do this every morning by hand.","goal":"Copy the latest invoice totals out of Mail and paste them into the Numbers tracker.","value":0.85}
    ]}
    """
    let result = await WorkflowCurator(client: FakeCompleter(canned: canned)).curate(candidates)
    #expect(result.count == 1) // the Safari "reading" candidate was dropped as noise
    #expect(result[0].name == "Copy invoice totals from Mail into Numbers")
    #expect(result[0].goal.contains("Numbers"))
    #expect(result[0].value == 0.85)
    // Carries the source workflow so approving still builds the real recipe.
    #expect(result[0].signature == "sig-a")
    #expect(result[0].source.apps == ["Mail", "Numbers"])
    #expect(result[0].evidence == [1, 2])
}

@Test
func contextWasteCuratorKeepsFeasibilityAndEvidence() async {
    let candidates = [contextWaste(linkedActionSignature: "action-sig")]
    let canned = """
    {"agents":[
      {"index":0,"name":"Reconcile vendor invoices","why":"About three hours repeat in QuickBooks.","goal":"Reconcile the vendor invoice queue in QuickBooks.","value":0.9,"feasibility":"linkedRecipe"}
    ]}
    """

    let result = await WorkflowCurator(client: FakeCompleter(canned: canned)).curateContextWaste(candidates)

    #expect(result.count == 1)
    #expect(result[0].name == "Reconcile vendor invoices")
    #expect(result[0].feasibility == .linkedRecipe)
    #expect(result[0].linkedActionSignature == "action-sig")
    #expect(result[0].evidence == [1, 2, 3])
}

@Test
func contextWasteCuratorFallsBackToGoalOnlyWhenModelFails() async {
    let candidates = [contextWaste()]

    let result = await WorkflowCurator(client: FailingCompleter()).curateContextWaste(candidates)

    #expect(result.count == 1)
    #expect(result[0].name == "Repeated vendor invoice work")
    #expect(result[0].feasibility == .goalOnlyCandidate)
    #expect(result[0].goal.contains("vendor invoice"))
}

@Test
func contextWastePromptUsesParameterSummariesInsteadOfRawEntityValues() {
    let candidate = ContextWasteCandidate(
        title: "Repeated invoice queue work",
        apps: ["QuickBooks"],
        occurrences: 3,
        estimatedSecondsPerRun: 1_200,
        estimatedTotalSeconds: 3_600,
        evidenceContextIDs: [1, 2, 3],
        sessionIDs: [1, 100, 200],
        signature: "context-process:v2|surface=quickbooks|verbs=review|objects=invoice|fields=invoice_id|entities=parameter:business_object",
        startedAt: base,
        endedAt: base.addingTimeInterval(3_600),
        lastSeenAt: base.addingTimeInterval(3_600),
        snippets: ["Review invoice INV-001 for Acme Corp at https://pay.example/invoices/INV-001 and mark $120.00 paid."],
        entities: [ContextWasteEntity(kind: .organization, canonicalValue: "acme", displayName: "Acme Corp")],
        processTerms: ["review", "invoice", "queue", "paid"],
        parameters: [
            ContextWasteParameter(
                role: "business_object",
                sourceKind: "field",
                count: 3,
                valueShapes: ["words:2"],
                valueHashes: ["abc123"]
            ),
        ],
        quality: ContextWasteQuality(
            supportScore: 0.8,
            durationScore: 0.5,
            semanticStabilityScore: 0.9,
            actionabilityScore: 0.8,
            privacyPenalty: 0,
            noisePenalty: 0
        ),
        suggestedGoal: "Teach Cascade to handle repeated invoice queue work in QuickBooks."
    )

    let prompt = WorkflowCurator.userPromptContextWaste([candidate])

    #expect(prompt.contains("parameter role=business_object"))
    #expect(prompt.contains("valueHashCount=1"))
    #expect(prompt.contains("entity roles: organization=1"))
    #expect(prompt.contains("evidenceHash="))
    #expect(!prompt.lowercased().contains("acme"))
    #expect(!prompt.lowercased().contains("inv-001"))
    #expect(!prompt.lowercased().contains("https://pay.example"))
    #expect(!prompt.contains("$120.00"))
    #expect(!prompt.contains("on screen:"))
}

@Test
func contextWasteCuratorScrubsUnsafeProperNounsFromModelOutput() {
    let candidate = ContextWasteCandidate(
        title: "Repeated receipt review work",
        apps: ["QuickBooks"],
        occurrences: 3,
        estimatedSecondsPerRun: 1_200,
        estimatedTotalSeconds: 3_600,
        evidenceContextIDs: [1, 2, 3],
        sessionIDs: [1, 100, 200],
        signature: "context-process:v3|terms=review,receipt",
        startedAt: base,
        endedAt: base.addingTimeInterval(3_600),
        lastSeenAt: base.addingTimeInterval(3_600),
        snippets: [],
        entities: [],
        processTerms: ["review", "receipt", "status"],
        parameters: [],
        quality: ContextWasteQuality(
            supportScore: 0.8,
            durationScore: 0.5,
            semanticStabilityScore: 0.9,
            actionabilityScore: 0.8,
            privacyPenalty: 0,
            noisePenalty: 0
        ),
        suggestedGoal: "Teach Cascade to handle repeated receipt review work in QuickBooks."
    )
    let raw = #"{"agents":[{"index":0,"name":"Review PhoenixLabs receipts","why":"x","goal":"Review PhoenixLabs receipt status in QuickBooks.","value":0.8,"feasibility":"goalOnlyCandidate"}]}"#

    let result = WorkflowCurator.parseContextWaste(raw, candidates: [candidate])

    #expect(result?.first?.name.lowercased().contains("phoenixlabs") == false)
    #expect(result?.first?.goal.lowercased().contains("phoenixlabs") == false)
    #expect(result?.first?.name.contains("[value]") == true)
}

@Test
func curatorMayKeepNone() async {
    // The whole point of R1: if nothing is worth automating, show nothing — an
    // intentional empty answer must NOT be papered over by the raw-list fallback.
    let candidates = [waste("Repeated steps in Safari", apps: ["Safari"], signature: "sig-b")]
    let result = await WorkflowCurator(client: FakeCompleter(canned: #"{"agents":[]}"#)).curate(candidates)
    #expect(result.isEmpty)
}

@Test
func curatorFallsBackToRawListOnFailure() async {
    // Never worse than today: a missing key / dead network still shows every
    // detected workflow, in the curated shape, in the detector's order.
    let candidates = [
        waste("Copy from Mail into Numbers", apps: ["Mail", "Numbers"], signature: "sig-a", occurrences: 4),
        waste("Save the report in TextEdit", apps: ["TextEdit"], signature: "sig-b"),
    ]
    let result = await WorkflowCurator(client: FailingCompleter()).curate(candidates)
    #expect(result.count == 2)
    #expect(result.map(\.name) == ["Copy from Mail into Numbers", "Save the report in TextEdit"])
    #expect(result.allSatisfy { $0.goal == $0.name }) // mechanical goal == title
    #expect(result[0].signature == "sig-a")
}

@Test
func curatorIgnoresOutOfRangeAndEmptyPicks() async {
    let candidates = [waste("Copy from Mail into Numbers", apps: ["Mail", "Numbers"], signature: "sig-a")]
    let canned = """
    {"agents":[
      {"index":99,"name":"Bogus","why":"x","goal":"y","value":0.9},
      {"index":0,"name":"","why":"x","goal":"y","value":0.9},
      {"index":0,"name":"Copy invoice totals into Numbers","why":"tedious","goal":"Copy invoice totals into the Numbers tracker.","value":0.8}
    ]}
    """
    let result = await WorkflowCurator(client: FakeCompleter(canned: canned)).curate(candidates)
    #expect(result.count == 1) // out-of-range dropped, empty-name dropped, index not double-kept
    #expect(result[0].name == "Copy invoice totals into Numbers")
}

@Test
func curatorClampsValueAndOrdersStrongestFirst() async {
    let candidates = [
        waste("A", apps: ["Mail"], signature: "sig-a"),
        waste("B", apps: ["Numbers"], signature: "sig-b"),
        waste("C", apps: ["Safari"], signature: "sig-c"),
    ]
    let canned = """
    {"agents":[
      {"index":0,"name":"Low","why":"x","goal":"g","value":-0.5},
      {"index":1,"name":"High","why":"x","goal":"g","value":1.7},
      {"index":2,"name":"Mid","why":"x","goal":"g","value":0.5}
    ]}
    """
    let result = await WorkflowCurator(client: FakeCompleter(canned: canned)).curate(candidates)
    #expect(result.map(\.name) == ["High", "Mid", "Low"])
    #expect(result.first?.value == 1.0) // 1.7 clamped
    #expect(result.last?.value == 0.0)  // -0.5 clamped
}

@Test
func curatorToleratesFencedJSON() async {
    let candidates = [waste("Copy from Mail into Numbers", apps: ["Mail", "Numbers"], signature: "sig-a")]
    let canned = """
    Sure — here's what's worth automating:
    ```json
    {"agents":[{"index":0,"name":"Copy totals into Numbers","why":"tedious","goal":"Copy the totals into Numbers.","value":0.8}]}
    ```
    """
    let result = await WorkflowCurator(client: FakeCompleter(canned: canned)).curate(candidates)
    #expect(result.count == 1)
    #expect(result[0].name == "Copy totals into Numbers")
}

@Test
func curatorReturnsEmptyForNoCandidates() async {
    let result = await WorkflowCurator(client: FailingCompleter()).curate([])
    #expect(result.isEmpty)
}

// MARK: - On-screen content reaches the curator (change (a): OCR-grounded curation)

@Test
func curatorPromptCarriesOnScreenContentPerCandidate() async {
    // The text visible while each workflow happened, keyed by signature, must land in
    // the prompt as an "on screen" sub-line so the goal can name the real subject.
    let capture = PromptCapture()
    let candidates = [
        waste("Repeated in Mail", apps: ["Mail"], signature: "sig-a"),
        waste("Repeated in Numbers", apps: ["Numbers"], signature: "sig-b"),
    ]
    let canned = #"{"agents":[{"index":0,"name":"X","why":"y","goal":"z","value":0.5}]}"#
    _ = await WorkflowCurator(client: CapturingCompleter(canned: canned, capture: capture))
        .curate(candidates, onScreen: ["sig-a": "Refund request for order #4821"])
    let prompt = await capture.lastUser
    #expect(prompt.contains("on screen"))
    #expect(prompt.contains("Refund request for order #4821"))
    // Only the candidate with content gets the sub-line; the other is untouched.
    #expect(prompt.components(separatedBy: "on screen").count == 2)
}

@Test
func curatorPromptFlagsParametersThatChangeEachRun() async {
    // B5: a recipe with a varying typed value must tell the curator so the goal is
    // written to supply the CURRENT value, not bake in the recorded one.
    let capture = PromptCapture()
    let parameterized = DetectedWaste(
        title: "Save the report", apps: ["TextEdit"], occurrences: 3,
        estimatedSecondsPerRun: 20, estimatedTotalSeconds: 60,
        recipe: AgentRecipe(steps: [
            RecipeStep(order: 0, kind: .click, x: 1, y: 1, appName: "TextEdit"),
            RecipeStep(order: 1, kind: .type, text: "report-q1", appName: "TextEdit", isParameter: true),
        ]),
        evidence: [1], confidence: 0.7, signature: "param-sig"
    )
    let canned = #"{"agents":[{"index":0,"name":"X","why":"y","goal":"z","value":0.5}]}"#
    _ = await WorkflowCurator(client: CapturingCompleter(canned: canned, capture: capture)).curate([parameterized])
    let prompt = await capture.lastUser
    #expect(prompt.contains("live slot"))
    #expect(prompt.contains("kind=freeText"))
    #expect(prompt.contains("shapeCount=0"))
    #expect(!prompt.contains("report-q1"))
}

@Test
func curatorPromptUsesPrivacySafeFieldAwareParameterMetadata() async {
    let capture = PromptCapture()
    let parameterized = DetectedWaste(
        title: "Update invoice", apps: ["Books"], occurrences: 3,
        estimatedSecondsPerRun: 20, estimatedTotalSeconds: 60,
        recipe: AgentRecipe(steps: [
            RecipeStep(order: 0, kind: .click, x: 1, y: 1, appName: "Books", ocrAnchor: "Invoice number"),
            RecipeStep(
                order: 1,
                kind: .type,
                text: "INV-001",
                appName: "Books",
                isParameter: true,
                parameterKey: "invoice_number",
                parameterKind: .number,
                valueExamples: ["number:AAA-000"],
                valueHashes: ["abc123"],
                sourceStepIDs: [0]
            ),
        ]),
        evidence: [1], confidence: 0.7, signature: "param-sig"
    )
    let canned = #"{"agents":[{"index":0,"name":"X","why":"y","goal":"z","value":0.5}]}"#
    _ = await WorkflowCurator(client: CapturingCompleter(canned: canned, capture: capture)).curate([parameterized])
    let prompt = await capture.lastUser
    #expect(prompt.contains("live slot"))
    #expect(prompt.contains("kind=number"))
    #expect(prompt.contains("shapeCount=1"))
    #expect(prompt.contains("valueHashCount=1"))
    #expect(prompt.contains("sourceStepCount=1"))
    #expect(prompt.contains("dataflow edge"))
    #expect(!prompt.contains("INV-001"))
}

@Test
func curatorPromptFlagsCrossAppDataTransfer() async {
    // H6: a copy-in-one-app / paste-in-another routine is the canonical high-value
    // automatable task — the curator must be told so it favours and names it.
    let capture = PromptCapture()
    let transfer = DetectedWaste(
        title: "Copy from Mail into Numbers", apps: ["Mail", "Numbers"], occurrences: 3,
        estimatedSecondsPerRun: 30, estimatedTotalSeconds: 90,
        recipe: AgentRecipe(steps: [
            RecipeStep(order: 0, kind: .key, key: "c", modifiers: ["command"], appName: "Mail"),
            RecipeStep(order: 1, kind: .key, key: "v", modifiers: ["command"], appName: "Numbers"),
        ]),
        evidence: [1], confidence: 0.7, signature: "x-app-sig"
    )
    let canned = #"{"agents":[{"index":0,"name":"X","why":"y","goal":"z","value":0.5}]}"#
    _ = await WorkflowCurator(client: CapturingCompleter(canned: canned, capture: capture)).curate([transfer])
    let prompt = await capture.lastUser
    #expect(prompt.contains("moves data between apps"))
}

@Test
func curateOnePassesOnScreenContentToThePrompt() async {
    let capture = PromptCapture()
    let canned = #"{"agents":[{"index":0,"name":"X","why":"y","goal":"z","value":0.5}]}"#
    _ = await WorkflowCurator(client: CapturingCompleter(canned: canned, capture: capture))
        .curateOne(taughtWaste(), onScreen: "Q2 pipeline sheet — total 469,100")
    let prompt = await capture.lastUser
    #expect(prompt.contains("on screen"))
    #expect(prompt.contains("Q2 pipeline sheet — total 469,100"))
}

@Test
func curatorOmitsOnScreenLineWhenNoneGiven() async {
    // Default behaviour (no OCR) must be byte-for-byte the old prompt — no stray line.
    let candidates = [waste("Repeated in Mail", apps: ["Mail"], signature: "sig-a")]
    let prompt = WorkflowCurator.userPrompt(candidates)
    #expect(!prompt.contains("on screen"))
}

// MARK: - End-to-end through the orchestrator (detect → curate → approve)

// MARK: - curateOne (Teach-once: a single demonstrated recipe)

private func taughtWaste() -> DetectedWaste {
    waste("Mail → Numbers: copy", apps: ["Mail", "Numbers"], signature: "taught-sig", occurrences: 1, perRun: 20)
}

@Test
func curateOneNamesASingleRecipeFromTheModel() async {
    let canned = #"{"agents":[{"index":0,"name":"Copy invoice totals into Numbers","why":"You just showed me.","goal":"Copy the latest invoice totals from Mail into the Numbers tracker.","value":0.9}]}"#
    let result = await WorkflowCurator(client: FakeCompleter(canned: canned)).curateOne(taughtWaste())
    #expect(result.name == "Copy invoice totals into Numbers")
    #expect(result.goal.contains("Numbers"))
    #expect(result.signature == "taught-sig") // carries the recorded recipe through
}

@Test
func curateOnePassesSpokenIntentToThePrompt() async {
    // The user narrated while demonstrating — that text must reach the curator as the
    // strongest naming signal.
    let capture = PromptCapture()
    let canned = #"{"agents":[{"index":0,"name":"X","why":"y","goal":"z","value":0.5}]}"#
    _ = await WorkflowCurator(client: CapturingCompleter(canned: canned, capture: capture))
        .curateOne(taughtWaste(), statedIntent: "pulling the weekly numbers into the Monday report")
    let prompt = await capture.lastUser
    #expect(prompt.contains("pulling the weekly numbers into the Monday report"))
}

@Test
func curateOneAlwaysReturnsAnAgentEvenWhenTheModelFails() async {
    // A deliberate demonstration is something the user WANTS — on a dead key/network
    // it degrades to the detector's own naming, never to nothing.
    let result = await WorkflowCurator(client: FailingCompleter()).curateOne(taughtWaste())
    #expect(result.name == "Mail → Numbers: copy") // fallback uses the detector title
    #expect(!result.goal.isEmpty)
    #expect(result.signature == "taught-sig")
}

@Test
func curateOneFallsBackWhenTheModelKeepsNone() async {
    // Unlike the batch curator, a single demonstration must not vanish on an empty
    // "keep none" reply — it falls back to detector naming.
    let result = await WorkflowCurator(client: FakeCompleter(canned: #"{"agents":[]}"#)).curateOne(taughtWaste())
    #expect(result.name == "Mail → Numbers: copy")
}

// MARK: - curateRange (the shared spine: a time range → one curated agent)

@Test
func curateRangeTurnsABracketedRangeIntoACuratedAgent() async throws {
    let store = try makeStore()
    try await store.insertInputEvents(copyPasteEvents())
    let canned = #"{"agents":[{"index":0,"name":"Copy totals into Numbers","why":"shown once","goal":"Copy the totals from Mail into Numbers.","value":0.8}]}"#
    let orchestrator = CascadeOrchestrator(store: store, curator: WorkflowCurator(client: FakeCompleter(canned: canned)))

    // The whole intentional spine: a [start, end] range → DetectedWaste → curateOne.
    let curated = try await orchestrator.curateRange(from: base, to: base.addingTimeInterval(100))
    let agent = try #require(curated)
    #expect(agent.name == "Copy totals into Numbers")
    #expect(agent.apps == ["Mail", "Numbers"])

    // …and approving it runs the SAME createAgent the automatic pipeline uses.
    _ = try await orchestrator.createAgent(from: agent)
    let agents = try await orchestrator.agents()
    #expect(agents.count == 1)
    #expect(agents[0].name == "Copy totals into Numbers")
    #expect(!agents[0].recipe.steps.isEmpty)
}

@Test
func curateRangeFeedsRecordedOCRToTheCurator() async throws {
    // The whole point of change (a): real recorded on-screen text from the moments
    // around the workflow reaches the curator so the goal is content-aware. The
    // recipe span is base…base+7, so a moment at base+2 sits inside the resolved window.
    let store = try makeStore()
    try await store.insertInputEvents(copyPasteEvents())
    _ = try await store.insert(RecordedContext(
        capturedAt: base.addingTimeInterval(2),
        source: .screen,
        appName: "Mail",
        ocrText: "Refund request for order #4821 — see policy link below"
    ))
    let capture = PromptCapture()
    let canned = #"{"agents":[{"index":0,"name":"X","why":"y","goal":"z","value":0.7}]}"#
    let orchestrator = CascadeOrchestrator(
        store: store,
        curator: WorkflowCurator(client: CapturingCompleter(canned: canned, capture: capture))
    )
    _ = try await orchestrator.curateRange(from: base, to: base.addingTimeInterval(100))
    let prompt = await capture.lastUser
    #expect(prompt.contains("on screen"))
    #expect(prompt.contains("Refund request for order #4821"))
}

@Test
func curateRangeReturnsNilForAJunkRange() async throws {
    // A range of only scrolling/typing has nothing automatable — the spine refuses it.
    let store = try makeStore()
    var events: [InputEvent] = []
    for i in 0..<8 {
        events.append(InputEvent(id: Int64(i), capturedAt: base.addingTimeInterval(Double(i)), kind: .scroll, appName: "Safari"))
    }
    try await store.insertInputEvents(events)
    let orchestrator = CascadeOrchestrator(store: store, curator: WorkflowCurator(client: FailingCompleter()))
    let curated = try await orchestrator.curateRange(from: base, to: base.addingTimeInterval(100))
    #expect(curated == nil)
}

@Test
func curateRangeSamplesOCRAcrossTheWholeDemonstration() async throws {
    // A Teach-once demo records densely (0.5s burst), so reading the first N moments
    // would show the curator only the opening seconds. Evidence must be sampled
    // EVENLY across the bracket: a screen seen only near the END of the demo still
    // reaches the prompt.
    let store = try makeStore()
    try await store.insertInputEvents(copyPasteEvents())
    for i in 0..<20 {
        _ = try await store.insert(RecordedContext(
            capturedAt: base.addingTimeInterval(Double(i) * 2),
            source: .screen,
            appName: "Mail",
            ocrText: "Inbox — three refund requests waiting for a reply"
        ))
    }
    for i in 0..<10 {
        _ = try await store.insert(RecordedContext(
            capturedAt: base.addingTimeInterval(60 + Double(i) * 2),
            source: .screen,
            appName: "Numbers",
            ocrText: "Q2 tracker sheet — totals column updated to 469,100"
        ))
    }
    let capture = PromptCapture()
    let canned = #"{"agents":[{"index":0,"name":"X","why":"y","goal":"z","value":0.7}]}"#
    let orchestrator = CascadeOrchestrator(
        store: store,
        curator: WorkflowCurator(client: CapturingCompleter(canned: canned, capture: capture))
    )
    _ = try await orchestrator.curateRange(from: base, to: base.addingTimeInterval(100))
    let prompt = await capture.lastUser
    #expect(prompt.contains("Inbox — three refund requests"))
    #expect(prompt.contains("469,100")) // the demo's ENDING made it in
}

@Test
func evenSamplingSpreadsAcrossTheListEndpointsIncluded() {
    let picked = CascadeOrchestrator.sampleEvenly(Array(0..<30), limit: 12)
    #expect(picked.count == 12)
    #expect(picked.first! == 0)                     // the demo's starting state…
    #expect(picked.last! == 29)                     // …and its OUTCOME always survive
    #expect(picked == picked.sorted())              // order preserved
    #expect(Set(picked).count == picked.count)      // no duplicates at this ratio
    // Short lists pass through untouched; degenerate budgets stay sane.
    #expect(CascadeOrchestrator.sampleEvenly([1, 2, 3], limit: 12) == [1, 2, 3])
    #expect(CascadeOrchestrator.sampleEvenly(Array(0..<30), limit: 0).isEmpty)
    #expect(CascadeOrchestrator.sampleEvenly(Array(0..<30), limit: 1) == [15])
}

@Test
func bracketFetchCoversTheWholeDemonstrationNotJustItsOpening() async throws {
    // The store's range query is oldest-first with a LIMIT, so one fetch of a demo
    // longer than the budget would drop its ENDING. The sliced fetch must return
    // moments from every quarter of the bracket even under a tiny budget.
    let store = try makeStore()
    for i in 0..<40 {
        _ = try await store.insert(RecordedContext(
            capturedAt: base.addingTimeInterval(Double(i) * 2.5),
            source: .screen,
            appName: "Mail",
            ocrText: "moment \(i)"
        ))
    }
    let orchestrator = CascadeOrchestrator(store: store, curator: WorkflowCurator(client: FailingCompleter()))
    let moments = try await orchestrator.bracketContexts(
        from: base, to: base.addingTimeInterval(100), slices: 4, budget: 8
    )
    #expect(moments.count == 8)
    #expect(moments.map(\.id) == moments.map(\.id).sorted()) // chronological, no dupes
    // Every quarter contributed — including the final one a flat fetch would lose.
    #expect(moments.first!.capturedAt < base.addingTimeInterval(25))
    #expect(moments.last!.capturedAt >= base.addingTimeInterval(75))
}

@Test
func curateOnePromptTeachesRunVaryingParameters() {
    // A demonstration shows ONE example of fields that change every run (a date, an
    // invoice number) — the single-demo prompt must tell the curator to write the
    // goal around the CURRENT value, exactly like the batch prompt does.
    #expect(WorkflowCurator.curateOneSystemPrompt.contains("live slots or parameters"))
    #expect(WorkflowCurator.curateOneSystemPrompt.contains("CURRENT/appropriate value at run time"))
    // Prompt changed → the model-call cache key must roll over.
    #expect(WorkflowCurator.curateOnePromptVersion == "workflow-curator.curate-one.prompt.v2")
}

@Test
func curateThenApprovePersistsCuratedNameAndGoal() async throws {
    let store = try makeStore()
    try await store.insertInputEvents(copyPasteEvents())

    let canned = """
    {"agents":[{"index":0,"name":"Copy invoice totals into Numbers","why":"You do it by hand daily.","goal":"Copy the latest invoice totals out of Mail into the Numbers tracker.","value":0.9}]}
    """
    let orchestrator = CascadeOrchestrator(store: store, curator: WorkflowCurator(client: FakeCompleter(canned: canned)))

    // Detector caught the real repeated workflow…
    let candidates = try await orchestrator.detectedWaste()
    #expect(candidates.count == 1)

    // …the curator judged + renamed it…
    let curated = await orchestrator.curate(candidates)
    #expect(curated.count == 1)
    #expect(curated[0].name == "Copy invoice totals into Numbers")

    // …and approving persists the curated NAME and GOAL on an agent built from the
    // real recorded recipe (signature carries through). This is the whole chain.
    _ = try await orchestrator.createAgent(from: curated[0])
    let agents = try await orchestrator.agents()
    #expect(agents.count == 1)
    #expect(agents[0].name == "Copy invoice totals into Numbers")
    #expect(agents[0].goal == "Copy the latest invoice totals out of Mail into the Numbers tracker.")
    #expect(agents[0].signature == candidates[0].signature)
    #expect(!agents[0].recipe.steps.isEmpty)
}

@Test
func curateCacheRefreshesSourceCountsOnHit() async throws {
    // Same workflow, more occurrences later: the signature (token shape) is unchanged
    // so the cache hits — but the card's counts must still update, not freeze at first
    // curation. A signature excludes counts, so the cache key alone can't see growth.
    let v1 = [waste("Repeated in Mail", apps: ["Mail", "Numbers"], signature: "sig", occurrences: 2, perRun: 30)]
    let v2 = [waste("Repeated in Mail", apps: ["Mail", "Numbers"], signature: "sig", occurrences: 5, perRun: 30)]
    let canned = #"{"agents":[{"index":0,"name":"Copy into Numbers","why":"x","goal":"Copy into Numbers.","value":0.8}]}"#
    let store = try makeStore()
    let orchestrator = CascadeOrchestrator(store: store, curator: WorkflowCurator(client: FakeCompleter(canned: canned)))

    let first = await orchestrator.curate(v1)
    #expect(first.first?.source.occurrences == 2)

    let second = await orchestrator.curate(v2) // cache hit (same signature set)
    #expect(second.first?.source.occurrences == 5)              // refreshed, not frozen
    #expect(second.first?.source.estimatedTotalSeconds == 150)  // 30 × 5
    #expect(second.first?.name == "Copy into Numbers")          // curated fields preserved
}

@Test
func contextCurateCachePreservesNeedsDemoOnNoRecipeRefresh() async throws {
    let candidate = contextWaste()
    let canned = #"{"agents":[{"index":0,"name":"Reconcile invoices","why":"x","goal":"Teach one invoice reconciliation demo.","value":0.8,"feasibility":"needsDemo"}]}"#
    let store = try makeStore()
    let orchestrator = CascadeOrchestrator(store: store, curator: WorkflowCurator(client: FakeCompleter(canned: canned)))

    let first = await orchestrator.curateContextWaste([candidate])
    #expect(first.first?.feasibility == .needsDemo)

    let refreshed = await orchestrator.curateContextWaste([contextWaste()])
    #expect(refreshed.first?.source.feasibility == .goalOnlyCandidate)
    #expect(refreshed.first?.feasibility == .needsDemo)

    let linked = await orchestrator.curateContextWaste([candidate.linked(to: "action-sig")])
    #expect(linked.first?.feasibility == .linkedRecipe)
}

@Test
func curateCachesByCandidateSet() async throws {
    let store = try makeStore()
    try await store.insertInputEvents(copyPasteEvents())
    let counter = CallCounter()
    let orchestrator = CascadeOrchestrator(
        store: store,
        curator: WorkflowCurator(client: CountingCompleter(canned: #"{"agents":[]}"#, counter: counter))
    )

    let candidates = try await orchestrator.detectedWaste()
    _ = await orchestrator.curate(candidates)
    _ = await orchestrator.curate(candidates)
    // Same candidate set → the model is asked once, not on every refresh.
    #expect(await counter.calls == 1)
}
