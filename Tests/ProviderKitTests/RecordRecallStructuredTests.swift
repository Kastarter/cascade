import CascadeMemory
import Foundation
import ProviderKit
import Testing

private func makeStructuredStore() throws -> CascadeStore {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("CascadeRecallStructuredTests-\(UUID().uuidString).sqlite")
        .path
    return try CascadeStore(path: path)
}

private let structuredMetadataJSON = #"""
{"processIdentifier":123,"cursorScreen":true,"structured":{"summary":"Structured content: 4 lines, 1 key-value, 1 table; table 1: 2 rows x 2 cols.","reading_order":"Invoice Total: $403,050\nName Q1\nAcme =SUM(1)\nGlobex 469100","key_values":[{"key":"Invoice Total","value":"$403,050"}],"markdown_tables":["| Name | Q1 |\n| --- | --- |\n| Acme | =SUM(1) |"],"csv_tables":["Name,Q1\nAcme,'=SUM(1)"]}}
"""#

@Test
func inspectStructureReturnsBoundedStructuredContent() async throws {
    let store = try makeStructuredStore()
    let moment = try await store.insert(RecordedContext(
        source: .screen,
        appName: "Numbers",
        windowTitle: "Revenue",
        ocrText: "Invoice Total: $403,050",
        metadataJSON: structuredMetadataJSON
    ))

    let out = await RecordRecall(store: store).perform(.inspectStructure(id: moment.id))

    #expect(out.contains("[#\(moment.id)]"))
    #expect(out.contains("Summary: Structured content: 4 lines"))
    #expect(out.contains("- **Invoice Total**: $403,050"))
    #expect(out.contains("| Name | Q1 |"))
    #expect(out.contains("```csv"))
    #expect(out.contains("Acme,'=SUM(1)"))
}

@Test
func inspectStructureMissingMetadataDegradesClearly() async throws {
    let store = try makeStructuredStore()
    let moment = try await store.insert(RecordedContext(
        source: .screen,
        appName: "Preview",
        ocrText: "plain text only"
    ))

    let out = await RecordRecall(store: store).perform(.inspectStructure(id: moment.id))

    #expect(out == #"{"kind":"missing_structured_metadata","message":"No structured metadata recorded for moment #\#(moment.id). Capture structured content must be enabled first.","status":"no_result","tool":"inspect_structure"}"#)
}

@Test
func inspectStructureParsesAndRoutesLikeOtherRecallTools() {
    #expect(RecordRecall.Call(name: "inspect_structure", input: ["id": 42]) == .inspectStructure(id: 42))
    #expect(RecordRecall.Call.inspectStructure(id: 12).auditDetail == "tool=inspect_structure id=12")
    #expect(!RecordRecall.isRecallTool("inspect_structure"))

    let defaultNames = RecordRecall.toolDefinitions().compactMap { $0["name"] as? String }
    #expect(!defaultNames.contains("inspect_structure"))
    #expect(RecordRecall.toolNames().contains("inspect_structure") == false)

    #expect(RecordRecall.isRecallTool("inspect_structure", includeStructuredContent: true))
    let optInNames = RecordRecall.toolDefinitions(includeStructuredContent: true).compactMap { $0["name"] as? String }
    #expect(optInNames.contains("inspect_structure"))
    #expect(RecordRecall.toolNames(includeStructuredContent: true).contains("inspect_structure"))
}

@Test
func recordSearchAnswererToolDefinitionsRespectStructuredOptIn() throws {
    let store = try makeStructuredStore()

    let defaultNames = RecordSearchAnswerer(store: store)
        .configuredToolDefinitions()
        .compactMap { $0["name"] as? String }
    #expect(!defaultNames.contains("inspect_structure"))

    let optInNames = RecordSearchAnswerer(store: store, includeStructuredContent: true)
        .configuredToolDefinitions()
        .compactMap { $0["name"] as? String }
    #expect(optInNames.contains("inspect_structure"))
}
