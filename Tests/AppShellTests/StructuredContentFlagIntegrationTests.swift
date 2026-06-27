import CascadeMemory
import Foundation
import ProviderKit
import Testing

@testable import AppShell
@testable import MacContextKit

private func makeStructuredFlagStore() throws -> CascadeStore {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("CascadeStructuredFlagIT-\(UUID().uuidString).sqlite")
        .path
    return try CascadeStore(path: path)
}

private let appShellStructuredMetadataJSON = #"""
{"processIdentifier":123,"cursorScreen":true,"structured":{"summary":"Structured content: 2 lines, 1 key-value, 0 tables.","reading_order":"Invoice Total: $403,050\nStatus: Ready","key_values":[{"key":"Invoice Total","value":"$403,050"}],"markdown_tables":[],"csv_tables":[]}}
"""#

@MainActor @Test
func structuredContentFlagDefaultsOffAndLeavesStructuredMetadataAbsent() throws {
    let defaults = UserDefaults(suiteName: "CascadeStructuredFlagOff-\(UUID().uuidString)")!
    let store = try makeStructuredFlagStore()
    let model = try CascadeAppModel(store: store, defaults: defaults, startsSubsystems: false)

    #expect(!CascadeAppModel.experimentalStructuredContentEnabled(defaults: defaults))
    #expect(model.recorder.configuration.structuredContent == false)

    let metadata = RecorderMetadataJSON.capture(processIdentifier: 123, cursorScreen: true, structured: nil)
    #expect(!metadata.contains("structured"))

    let agent = ComputerUseAgent(
        harnessProvider: { _, _ in "unused" },
        recallEnabled: true,
        includeStructuredRecallContent: CascadeAppModel.experimentalStructuredContentEnabled(defaults: defaults)
    )
    let names = agent.configuredRecallToolDefinitions().compactMap { $0["name"] as? String }
    #expect(!names.contains("inspect_structure"))
}

@MainActor @Test
func structuredContentFlagEnablesRecorderAndComputerUseStructuredRecall() async throws {
    let defaults = UserDefaults(suiteName: "CascadeStructuredFlagOn-\(UUID().uuidString)")!
    defaults.set(true, forKey: CascadeAppModel.experimentalStructuredContentKey)
    let store = try makeStructuredFlagStore()
    let model = try CascadeAppModel(store: store, defaults: defaults, startsSubsystems: false)

    #expect(CascadeAppModel.experimentalStructuredContentEnabled(defaults: defaults))
    #expect(model.recorder.configuration.structuredContent)

    let agent = ComputerUseAgent(
        harnessProvider: { _, _ in "unused" },
        recallEnabled: true,
        includeStructuredRecallContent: CascadeAppModel.experimentalStructuredContentEnabled(defaults: defaults)
    )
    let names = agent.configuredRecallToolDefinitions().compactMap { $0["name"] as? String }
    #expect(names.contains("inspect_structure"))

    let moment = try await store.insert(RecordedContext(
        source: .screen,
        appName: "Numbers",
        windowTitle: "Invoice",
        ocrText: "Invoice Total: $403,050",
        metadataJSON: appShellStructuredMetadataJSON
    ))
    let stored = try #require(try await store.context(id: moment.id))
    #expect(stored.metadataJSON?.contains("\"structured\"") == true)

    let out = await RecordRecall(store: store).perform(RecordRecall.Call(name: "inspect_structure", input: ["id": moment.id]))
    #expect(out.contains("[#\(moment.id)]"))
    #expect(out.contains("Summary: Structured content: 2 lines"))
    #expect(out.contains("- **Invoice Total**: $403,050"))
}
