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
        claudeAnswerer: ThrowingAnswerer()
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
        claudeAnswerer: ThrowingAnswerer()
    )

    let answer = try await orchestrator.ask("when is the final project due?")

    #expect(answer.contains("Jul 30"))
}
