import AgentOrchestrator
import CascadeMemory
import Foundation
import ProviderKit
import Testing
import WasteDetection

@testable import AppShell

private struct ParameterizedMiningFakeCompleter: MessageCompleting {
    func complete(system: String?, user: String, model: String, maxTokens: Int) async throws -> String {
        #"{"agents":[]}"#
    }
}

private let parameterizedAppShellBase = Date(timeIntervalSince1970: 1_792_000_000)

@MainActor
private func makeParameterizedMiningModel() throws -> (model: CascadeAppModel, store: CascadeStore, defaults: UserDefaults) {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("CascadeParameterizedMining-\(UUID().uuidString).sqlite").path
    let store = try CascadeStore(path: path)
    let orchestrator = CascadeOrchestrator(
        store: store,
        curator: WorkflowCurator(client: ParameterizedMiningFakeCompleter())
    )
    let defaults = UserDefaults(suiteName: "CascadeParameterizedMining-\(UUID().uuidString)")!
    let model = try CascadeAppModel(store: store, orchestrator: orchestrator, defaults: defaults, startsSubsystems: false)
    return (model, store, defaults)
}

private func parameterizedAppShellEvent(
    _ id: Int,
    at seconds: TimeInterval,
    kind: InputEventKind,
    text: String? = nil,
    key: String? = nil,
    modifiers: [String] = [],
    window: String
) -> InputEvent {
    InputEvent(
        id: Int64(id),
        capturedAt: parameterizedAppShellBase.addingTimeInterval(seconds),
        kind: kind,
        x: kind == .click ? 20 : nil,
        y: kind == .click ? 20 : nil,
        text: text,
        key: key,
        modifiers: modifiers,
        appName: "Safari",
        bundleIdentifier: "com.apple.Safari",
        windowTitle: window
    )
}

private func parameterizedAppShellFixture() -> [InputEvent] {
    var events: [InputEvent] = []
    var id = 0
    let noiseCounts = [301, 301, 301, 304]

    for (run, coin) in ["ETH", "SOL", "BTC", "LTC"].enumerated() {
        let start = TimeInterval(run * 2_000)
        let googleWindow = "\(coin) price - Google - Safari"
        let notionWindow = "\(coin) tracker - Notion - Safari"
        events.append(parameterizedAppShellEvent(id, at: start, kind: .click, text: "Search", window: googleWindow)); id += 1
        events.append(parameterizedAppShellEvent(id, at: start + 1, kind: .type, text: coin, window: googleWindow)); id += 1
        events.append(parameterizedAppShellEvent(id, at: start + 2, kind: .key, key: "Return", window: googleWindow)); id += 1
        events.append(parameterizedAppShellEvent(id, at: start + 3, kind: .click, text: "Price result", window: googleWindow)); id += 1
        events.append(parameterizedAppShellEvent(id, at: start + 4, kind: .key, key: "c", modifiers: ["command"], window: googleWindow)); id += 1
        events.append(parameterizedAppShellEvent(id, at: start + 5, kind: .click, text: "\(coin) tracker row", window: notionWindow)); id += 1
        events.append(parameterizedAppShellEvent(id, at: start + 6, kind: .key, key: "v", modifiers: ["command"], window: notionWindow)); id += 1

        let noiseStart = start + 220
        for offset in 0..<noiseCounts[run] {
            events.append(parameterizedAppShellEvent(
                id,
                at: noiseStart + TimeInterval(offset * 4),
                kind: .scroll,
                window: "Research noise \(run)"
            ))
            id += 1
        }
    }

    return events
}

@MainActor @Test
func refreshAllKeepsParameterizedMiningDefaultOff() async throws {
    let events = parameterizedAppShellFixture()
    let expected = WasteDetector().detect(
        contexts: [],
        inputEvents: events,
        webAppIdentity: CascadeAppModel.webAppIdentity(for:),
        useEpisodeMining: true,
        useParameterizedMining: false
    ).map(\.signature)
    let (model, store, _) = try makeParameterizedMiningModel()
    try await store.insertInputEvents(events)

    await model.refreshAll()

    // Parity with the detector's own default-off path. The literal miner's
    // text-agnostic tokens DO find the shared search->copy->paste spine (the
    // per-coin click is dropped), so the default path yields the routine WITHOUT
    // parameter slots rather than nothing.
    #expect(model.detectedWaste.map(\.signature) == expected)
    #expect(!model.detectedWaste.isEmpty)
    #expect(model.detectedWaste.allSatisfy { !$0.signature.hasPrefix("routine:v2:") })
}

@MainActor @Test
func refreshAllUsesParameterizedMiningAndAuditsSafeSummaryWhenFlagIsEnabled() async throws {
    let events = parameterizedAppShellFixture()
    let (model, store, defaults) = try makeParameterizedMiningModel()
    defaults.set(true, forKey: CascadeAppModel.experimentalParameterizedMiningKey)
    try await store.insertInputEvents(events)

	    await model.refreshAll()

	    // Two variants surface: the literal 6-step spine plus the parameterized
	    // 7-step routine that recovers the per-coin click as a ticker slot.
	    #expect(model.detectedWaste.count == 2)
	    let parameterized = try #require(model.detectedWaste.first { waste in
	        waste.recipe.steps.contains { $0.isParameter && $0.parameterKind == .ticker }
	    })
        // The PARAMETERIZED recipe must scrub run-varying values from its window
        // hints; the literal variant keeps raw recorder window titles by design.
        let windowHints = parameterized.recipe.steps.compactMap(\.windowTitleHint).joined(separator: "|")
	    let audit = try await store.recentAudit(limit: 20)
	    let miningAudit = try #require(audit.first { $0.action == "workflow.parameterized_mining" })
    #expect(miningAudit.detail.contains("enabled=true"))
    #expect(miningAudit.detail.contains("candidateCount=2"))
    #expect(miningAudit.detail.contains("slotCount=2"))
	    for raw in ["ETH", "SOL", "BTC", "LTC"] {
	        #expect(!miningAudit.detail.localizedCaseInsensitiveContains(raw))
            #expect(!windowHints.localizedCaseInsensitiveContains(raw))
	    }
	}
