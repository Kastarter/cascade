import AgentOrchestrator
import CascadeMemory
import ComputerUseKit
import Foundation
import ProviderKit
import Testing

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
    func answer(
        question: String,
        conversation: [(user: String, assistant: String)],
        focus: RecordAnswerFocus?
    ) async throws -> RecordAnswer {
        throw CocoaError(.featureUnsupported)
    }
}

private final class CapturingRecordAnswerer: RecordAnswering, @unchecked Sendable {
    private let lock = NSLock()
    private var _focus: RecordAnswerFocus?
    var focus: RecordAnswerFocus? { lock.withLock { _focus } }

    func answer(
        question: String,
        conversation: [(user: String, assistant: String)],
        focus: RecordAnswerFocus?
    ) async throws -> RecordAnswer {
        lock.withLock { _focus = focus }
        return RecordAnswer(text: "focused", citedMomentIDs: focus.map { [$0.momentID] } ?? [])
    }
}

private func makeStore() throws -> CascadeStore {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("AgentOrchestratorTests-\(UUID().uuidString).sqlite")
        .path
    return try CascadeStore(path: path)
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
func askRecordPassesFocusToInjectedRecordAnswerer() async throws {
    let store = try makeStore()
    let selected = try await store.insert(RecordedContext(source: .screen, appName: "Numbers", ocrText: "TOTAL DUE $443,355"))
    let answerer = CapturingRecordAnswerer()
    let orchestrator = CascadeOrchestrator(
        store: store,
        localAnswerer: ThrowingAnswerer(),
        claudeAnswerer: ThrowingAnswerer(),
        recordAnswerer: answerer
    )

    let answer = try await orchestrator.askRecord("what is on this screen?", focus: RecordAnswerFocus(moment: selected))

    #expect(answer.text == "focused")
    #expect(answerer.focus?.momentID == selected.id)
    #expect(answer.citedMomentIDs == [selected.id])
}

private struct FocusedEchoAnswerer: ContextQuestionAnswering {
    func answer(question: String, grounding: ChatGrounding) async throws -> String {
        grounding.focused.compactMap(\.ocrText).joined(separator: " | ")
    }
}

@Test
func focusedFallbackGroundingAndCitationsPreferSelectedOldMoment() async throws {
    let store = try makeStore()
    let selected = try await store.insert(RecordedContext(
        capturedAt: Date(timeIntervalSinceNow: -6 * 3600),
        source: .screen,
        appName: "Numbers",
        ocrText: "Selected old invoice TOTAL DUE $443,355"
    ))
    _ = try await store.insert(RecordedContext(
        capturedAt: Date(),
        source: .screen,
        appName: "Safari",
        ocrText: "new unrelated live context"
    ))
    let orchestrator = CascadeOrchestrator(
        store: store,
        localAnswerer: FocusedEchoAnswerer(),
        claudeAnswerer: ThrowingAnswerer(),
        recordAnswerer: ThrowingRecordAnswerer()
    )

    let answer = try await orchestrator.askRecord("what is on this screen?", focus: RecordAnswerFocus(moment: selected))

    #expect(answer.text.contains("TOTAL DUE $443,355"))
    #expect(answer.citedMomentIDs.first == selected.id)
}
