import AgentOrchestrator
import CascadeMemory
import Foundation
import ProviderKit
import Testing

@testable import AppShell

private struct AutoRecallFakeCompleter: MessageCompleting {
    func complete(system: String?, user: String, model: String, maxTokens: Int) async throws -> String {
        #"{"agents":[]}"#
    }
}

@MainActor
private func makeAutoRecallModel() throws -> (model: CascadeAppModel, store: CascadeStore, defaults: UserDefaults) {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("CascadeAutoRecallIT-\(UUID().uuidString).sqlite")
        .path
    let store = try CascadeStore(path: path)
    let orchestrator = CascadeOrchestrator(
        store: store,
        curator: WorkflowCurator(client: AutoRecallFakeCompleter())
    )
    let defaults = UserDefaults(suiteName: "CascadeAutoRecall-\(UUID().uuidString)")!
    let model = try CascadeAppModel(
        store: store,
        orchestrator: orchestrator,
        defaults: defaults,
        startsSubsystems: false
    )
    return (model, store, defaults)
}

@MainActor @Test
func autoRecallFlagDefaultsOff() throws {
    let suite = "CascadeAutoRecallDefault-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    #expect(!CascadeAppModel.experimentalAutoRecallEnabled(defaults: defaults))
    defaults.set(true, forKey: CascadeAppModel.experimentalAutoRecallKey)
    #expect(CascadeAppModel.experimentalAutoRecallEnabled(defaults: defaults))
}

@MainActor @Test
func autoRecallFlagOffLeavesInitialAssistNoteByteIdentical() async throws {
    let (model, store, defaults) = try makeAutoRecallModel()
    _ = try await store.insert(RecordedContext(
        source: .screen,
        appName: "Notes",
        windowTitle: "Project Lumina",
        ocrText: "project lumina launch checklist"
    ))

    let unset = await model.initialAssistNote(goal: "prepare project lumina")
    defaults.set(false, forKey: CascadeAppModel.experimentalAutoRecallKey)
    let explicitOff = await model.initialAssistNote(goal: "prepare project lumina")

    #expect(unset == explicitOff)
    #expect(unset?.contains("auto_recall") != true)
    let audits = try await store.recentAudit(limit: 10)
    #expect(!audits.contains { $0.action == "recall.inject" })
}

@MainActor @Test
func autoRecallFlagOnAppendsOneUntrustedBlockAndAuditsHashesOnly() async throws {
    let (model, store, defaults) = try makeAutoRecallModel()
    defaults.set(true, forKey: CascadeAppModel.experimentalAutoRecallKey)
    _ = try await store.insert(RecordedContext(
        source: .screen,
        appName: "Notes",
        bundleIdentifier: "com.example.notes",
        windowTitle: "Project Lumina",
        ocrText: "project lumina launch checklist"
    ))

    let note = try #require(await model.initialAssistNote(goal: "prepare project lumina"))
    let blockCount = note.components(separatedBy: "UNTRUSTED RECORDED CONTEXT (auto_recall)").count - 1
    #expect(blockCount == 1)
    #expect(note.contains(#""acquiredByTool":"auto_recall""#))
    #expect(note.contains(#""trust":"untrustedRecord""#))

    let audit = try #require(try await store.recentAudit(limit: 10).first { $0.action == "recall.inject" })
    #expect(audit.detail.contains("enabled=true"))
    #expect(audit.detail.contains("status=injected"))
    #expect(audit.detail.contains("count=1"))
    #expect(audit.detail.contains("queryHash="))
    #expect(audit.detail.contains("selectedContextHash="))
    for raw in ["prepare project lumina", "Notes", "Project Lumina", "project lumina launch checklist", "com.example.notes"] {
        #expect(!audit.detail.localizedCaseInsensitiveContains(raw))
    }
}

@MainActor @Test
func autoRecallPolicyUnavailableSuppressesInjectionAndAuditsBlockedZero() async throws {
    let (model, store, defaults) = try makeAutoRecallModel()
    defaults.set(true, forKey: CascadeAppModel.experimentalAutoRecallKey)
    model.capturePrivacyPolicy = CapturePrivacyPolicy(recordRecallAvailable: false)
    _ = try await store.insert(RecordedContext(
        source: .screen,
        appName: "Notes",
        windowTitle: "Project Lumina",
        ocrText: "project lumina launch checklist"
    ))

    let note = await model.initialAssistNote(goal: "prepare project lumina")

    #expect(note?.contains("auto_recall") != true)
    let audit = try #require(try await store.recentAudit(limit: 10).first { $0.action == "recall.inject" })
    #expect(audit.detail.contains("status=record_recall_unavailable"))
    #expect(audit.detail.contains("count=0"))
    #expect(audit.detail.contains("chars=0"))
    for raw in ["prepare project lumina", "Notes", "Project Lumina", "project lumina launch checklist"] {
        #expect(!audit.detail.localizedCaseInsensitiveContains(raw))
    }
}
