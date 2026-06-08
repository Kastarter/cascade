import AgentOrchestrator
import CascadeMemory
import ComputerUseKit
import Foundation
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
