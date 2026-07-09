import AgentOrchestrator
import CascadeMemory
import ComputerUseKit
import Foundation
import ProviderKit
import Testing
import WasteDetection

private struct StubActuator: ComputerUseActuator {
    func health() async -> ComputerUseHealth {
        ComputerUseHealth(
            ready: true,
            permissions: .init(screenRecording: true, accessibility: true, inputMonitoring: true),
            message: "ready"
        )
    }

    func perform(_ action: ComputerUseAction) async throws {}
}

private struct RefusingSecureInputActuator: ComputerUseActuator {
    func health() async -> ComputerUseHealth {
        ComputerUseHealth(
            ready: true,
            permissions: .init(screenRecording: true, accessibility: true, inputMonitoring: true),
            secureInputEnabled: true,
            message: "secure"
        )
    }

    func execute(_ action: ComputerUseAction) async -> ComputerUseActionResult {
        action.result(status: .refused, failureKind: .secureInput)
    }

    func perform(_ action: ComputerUseAction) async throws {
        throw ComputerUseError.secureInput("secure")
    }
}

@Test
func localMacDriverVerifiesAgainstContext() async throws {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("AgentOrchestratorTests-\(UUID().uuidString).sqlite")
        .path
    let store = try CascadeStore(path: path)
    _ = try await store.insert(RecordedContext(source: .app, appName: "Safari", windowTitle: "Docs"))
    let driver = LocalMacDriver(store: store, actuator: StubActuator())

    let observation = try await driver.observe()
    let verification = try await driver.verify(goal: "Summarize docs")

    #expect(observation.contexts.count == 1)
    #expect(verification.passed)
}

@Test
func localMacDriverAuditDetailsHashComputerActionsAndArtifacts() async throws {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("AgentOrchestratorTests-\(UUID().uuidString).sqlite")
        .path
    let store = try CascadeStore(path: path)
    let driver = LocalMacDriver(store: store, actuator: StubActuator())
    let rawToken = "ApertureDeltaDriverAuditSeed"
    let typedText = "\(rawToken)-typed"
    let artifactTitle = "\(rawToken)-artifact-title"

    try await driver.act(.computerUse(.typeText(typedText)))
    try await driver.act(.writeLocalArtifact(title: artifactTitle, body: "local artifact body"))

    let rows = try await store.recentAudit(limit: 10)
    let computer = try #require(rows.first { $0.action == "computer.act" })
    #expect(computer.detail.contains("kind=typeText"))
    #expect(computer.detail.contains("textHash=\(AuditIdentity.hash(typedText))"))
    #expect(!computer.detail.lowercased().contains(rawToken.lowercased()))
    #expect(!computer.detail.contains(typedText))

    let artifact = try #require(rows.first { $0.action == "artifact.write" })
    #expect(artifact.detail.contains("titleHash=\(AuditIdentity.hash(artifactTitle))"))
    #expect(artifact.detail.contains("pathHash="))
    #expect(artifact.detail.contains("bodyChars=19"))
    #expect(!artifact.detail.lowercased().contains(rawToken.lowercased()))
    #expect(!artifact.detail.contains(artifactTitle))
}

@Test
func localMacDriverAuditsAndRethrowsSecureInputRefusal() async throws {
    let store = try makeStore()
    let driver = LocalMacDriver(store: store, actuator: RefusingSecureInputActuator())

    do {
        try await driver.act(.computerUse(.typeText("secret")))
        Issue.record("expected secure input refusal")
    } catch ComputerUseError.secureInput {
    } catch {
        Issue.record("expected secure input, got \(error)")
    }

    let rows = try await store.recentAudit(limit: 10)
    let audit = try #require(rows.first { $0.action == "computer.act" })
    #expect(audit.detail.contains("status=refused"))
    #expect(audit.detail.contains("failureKind=secure_input"))
    #expect(audit.detail.contains("textHash="))
    #expect(!audit.detail.contains("secret"))
}

private struct CountingAnswerer: ContextQuestionAnswering {
    func answer(question: String, grounding: ChatGrounding) async throws -> String {
        "\(grounding.timeline.count)"
    }
}

private struct RelevantEchoAnswerer: ContextQuestionAnswering {
    func answer(question: String, grounding: ChatGrounding) async throws -> String {
        grounding.relevant.compactMap(\.ocrText).joined(separator: " | ")
    }
}

private struct ThrowingAnswerer: ContextQuestionAnswering {
    func answer(question: String, grounding: ChatGrounding) async throws -> String {
        throw CocoaError(.featureUnsupported)
    }
}

/// Keeps `ask` tests deterministic on machines that have a real key in the
/// keychain — the agentic record path must never hit the network in tests.
private struct ThrowingRecordAnswerer: RecordAnswering {
    func answer(question: String, conversation: [(user: String, assistant: String)]) async throws -> RecordAnswer {
        throw CocoaError(.featureUnsupported)
    }
}

private func makeStore() throws -> CascadeStore {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("AgentOrchestratorTests-\(UUID().uuidString).sqlite")
        .path
    return try CascadeStore(path: path)
}

private let contextWasteLinkBase = Date(timeIntervalSince1970: 1_700_300_000)

private func invoiceContextSessions() -> [RecordedContext] {
    var contexts: [RecordedContext] = []
    var id: Int64 = 10_000
    for run in 0..<3 {
        let start = TimeInterval(run * 3_600)
        for elapsed in stride(from: 0.0, through: 1_200.0, by: 300.0) {
            contexts.append(RecordedContext(
                id: id,
                capturedAt: contextWasteLinkBase.addingTimeInterval(start + elapsed),
                source: .screen,
                appName: "QuickBooks",
                bundleIdentifier: "com.intuit.quickbooks",
                windowTitle: run == 0 ? "Acme invoice queue" : "Beta invoice queue",
                ocrText: "Review vendor invoice queue, reconcile invoice totals, and mark vendor batch paid.",
                metadataJSON: #"{"project":"Vendor invoices"}"#
            ))
            id += 1
        }
    }
    return contexts
}

private func actionWaste(
    title: String,
    signature: String,
    steps: [RecipeStep],
    lastSeenAt: Date = contextWasteLinkBase.addingTimeInterval(7_500)
) -> DetectedWaste {
    DetectedWaste(
        title: title,
        apps: ["QuickBooks"],
        occurrences: 3,
        estimatedSecondsPerRun: 60,
        estimatedTotalSeconds: 180,
        recipe: AgentRecipe(steps: steps),
        evidence: [1, 2, 3],
        confidence: 0.8,
        signature: signature,
        lastSeenAt: lastSeenAt
    )
}

@Test
func askGroundsInTheWholeDayNotJustTheFreshestMoments() async throws {
    let store = try makeStore()
    // 40 moments spread over the last ~6 h — more than the 24-row detail window.
    for index in 0..<40 {
        _ = try await store.insert(RecordedContext(
            capturedAt: Date(timeIntervalSinceNow: TimeInterval(-index * 9 * 60)),
            source: .screen,
            appName: "App\(index)"
        ))
    }
    // The Claude answerer throws so the test is deterministic whether or not a
    // real key is in the keychain; the local answerer reports what it received.
    let orchestrator = CascadeOrchestrator(
        store: store,
        localAnswerer: CountingAnswerer(),
        claudeAnswerer: ThrowingAnswerer(),
        recordAnswerer: ThrowingRecordAnswerer()
    )

    let answer = try await orchestrator.ask("what did I do today?")

    #expect(Int(answer) == 40)
}

@Test
func askRecallsQuestionRelevantMomentsFromEarlierInTheDay() async throws {
    let store = try makeStore()
    // Hours of unrelated activity, plus one old moment holding the answer.
    for index in 0..<30 {
        _ = try await store.insert(RecordedContext(
            capturedAt: Date(timeIntervalSinceNow: TimeInterval(-index * 5 * 60)),
            source: .screen,
            appName: "Chrome",
            ocrText: "browsing tab \(index)"
        ))
    }
    // NB: keep this OCR clear of PrivacyRules keywords — sensitive moments are
    // (correctly) invisible to the chat.
    _ = try await store.insert(RecordedContext(
        capturedAt: Date(timeIntervalSinceNow: -6 * 3600),
        source: .screen,
        appName: "Chrome",
        windowTitle: "LEARN",
        ocrText: "Final Project Migration Plan due Jul 30 at 11:59 PM"
    ))
    let orchestrator = CascadeOrchestrator(
        store: store,
        localAnswerer: RelevantEchoAnswerer(),
        claudeAnswerer: ThrowingAnswerer(),
        recordAnswerer: ThrowingRecordAnswerer()
    )

    let answer = try await orchestrator.ask("when is the final project due?")

    #expect(answer.contains("Jul 30"))
}

@Test
func contextWasteReportLinksCompatibleActionRecipe() async throws {
    let store = try makeStore()
    _ = try await store.insertContexts(invoiceContextSessions())
    let orchestrator = CascadeOrchestrator(store: store)
    let compatible = actionWaste(
        title: "Review invoice queue",
        signature: "invoice-action",
        steps: [
            RecipeStep(order: 0, kind: .click, x: 10, y: 10, appName: "QuickBooks", ocrAnchor: "Invoice queue"),
            RecipeStep(
                order: 1,
                kind: .type,
                text: "INV-001",
                appName: "QuickBooks",
                ocrAnchor: "Invoice number",
                isParameter: true,
                parameterKey: "invoice_number",
                parameterKind: .number,
                valueExamples: ["id:AAA-000"],
                valueHashes: ["abc123"]
            ),
        ]
    )

    let report = try await orchestrator.contextWasteReport(linkingTo: [compatible])
    let waste = try #require(report.results.first)

    #expect(waste.linkedActionSignature == "invoice-action")
    #expect(waste.linkedActionWaste?.recipe == compatible.recipe)
    #expect(waste.feasibility == .linkedRecipe)
}

@Test
func linkedContextWasteApprovalPersistsLinkedActionRecipe() async throws {
    let store = try makeStore()
    _ = try await store.insertContexts(invoiceContextSessions())
    let orchestrator = CascadeOrchestrator(store: store)
    let compatible = actionWaste(
        title: "Review invoice queue",
        signature: "invoice-action",
        steps: [
            RecipeStep(order: 0, kind: .click, x: 10, y: 10, appName: "QuickBooks", ocrAnchor: "Invoice queue"),
            RecipeStep(order: 1, kind: .key, key: "v", modifiers: ["command"], appName: "QuickBooks", ocrAnchor: "Invoice number"),
        ]
    )
    let report = try await orchestrator.contextWasteReport(linkingTo: [compatible])
    let waste = try #require(report.results.first)
    let curated = CuratedContextWaste(
        source: waste,
        name: "Reconcile vendor invoices",
        why: "The record shows repeated invoice queue work.",
        goal: "Reconcile the vendor invoice queue in QuickBooks.",
        value: 0.9,
        feasibility: .linkedRecipe
    )

    let agent = try await orchestrator.createAgent(from: curated)

    #expect(agent.signature == "invoice-action")
    #expect(agent.recipe == compatible.recipe)
    #expect(!agent.recipe.steps.isEmpty)
}

@Test
func contextWasteReportDoesNotLinkUnrelatedSameAppActionRecipe() async throws {
    let store = try makeStore()
    _ = try await store.insertContexts(invoiceContextSessions())
    let orchestrator = CascadeOrchestrator(store: store)
    let unrelated = actionWaste(
        title: "Export payroll report",
        signature: "payroll-action",
        steps: [
            RecipeStep(order: 0, kind: .click, x: 10, y: 10, appName: "QuickBooks", ocrAnchor: "Payroll"),
            RecipeStep(order: 1, kind: .click, x: 20, y: 20, appName: "QuickBooks", ocrAnchor: "Export report"),
        ]
    )

    let report = try await orchestrator.contextWasteReport(linkingTo: [unrelated])
    let waste = try #require(report.results.first)

    #expect(waste.linkedActionSignature == nil)
    #expect(waste.feasibility == .goalOnlyCandidate)
}
