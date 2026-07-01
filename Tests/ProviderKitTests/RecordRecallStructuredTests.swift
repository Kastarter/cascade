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

private let structuredSidecarJSON = #"""
{"version":2,"lines":[{"text":"TOTAL DUE $443,355"},{"text":"Item Qty Amount"}],"blocks":[{"kind":"form","text":"TOTAL DUE $443,355"}],"fields":[{"key":"TOTAL DUE","value":"$443,355","kind":"total"}],"lists":[],"tables":[{"rows":[["Item","Qty","Amount"],["Widgets","100","$250,000"],["Gadgets","50","$153,050"]]}],"code_blocks":[]}
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
func inspectMomentIncludesStructureFromSidecar() async throws {
    let store = try makeStructuredStore()
    let moment = try await store.insert(RecordedContext(
        source: .screen,
        appName: "Preview",
        ocrText: "flat frame text"
    ))
    try await store.insertOCRStructure(
        contextID: moment.id,
        version: 2,
        json: structuredSidecarJSON,
        searchableText: "TOTAL DUE $443,355 Item Qty Amount"
    )

    let out = await RecordRecall(store: store).perform(.inspect(id: moment.id))

    #expect(out.contains("STRUCTURE:"))
    #expect(out.contains("TOTAL DUE=$443,355"))
    #expect(out.contains("table 0: | Item | Qty | Amount |"))
}

@Test
func extractTableAndFieldsUseSidecar() async throws {
    let store = try makeStructuredStore()
    let moment = try await store.insert(RecordedContext(
        source: .screen,
        appName: "Preview",
        ocrText: "flat frame text"
    ))
    try await store.insertOCRStructure(
        contextID: moment.id,
        version: 2,
        json: structuredSidecarJSON,
        searchableText: "TOTAL DUE $443,355 Item Qty Amount"
    )

    let table = await RecordRecall(store: store).perform(.extractTable(id: moment.id, tableIndex: 0, format: "csv"))
    let fields = await RecordRecall(store: store).perform(.extractFields(id: moment.id, query: "total"))

    #expect(table.contains(#"\"table_index\":0"#))
    #expect(table.contains(#"Item,Qty,Amount\\nWidgets,100,\\\"$250,000\\\""#))
    #expect(fields.contains(#"\"key\":\"TOTAL DUE\""#))
    #expect(fields.contains(#"\"value\":\"$443,355\""#))
}

@Test
func inspectStructureParsesAndRoutesLikeOtherRecallTools() {
    #expect(RecordRecall.Call(name: "inspect_structure", input: ["id": 42]) == .inspectStructure(id: 42))
    #expect(RecordRecall.Call(name: "extract_table", input: ["id": 42, "table_index": 1, "format": "csv"]) == .extractTable(id: 42, tableIndex: 1, format: "csv"))
    #expect(RecordRecall.Call(name: "extract_fields", input: ["id": 42, "query": "total"]) == .extractFields(id: 42, query: "total"))
    #expect(RecordRecall.Call.inspectStructure(id: 12).auditDetail == "tool=inspect_structure id=12")
    #expect(!RecordRecall.isRecallTool("inspect_structure"))

    let defaultNames = RecordRecall.toolDefinitions().compactMap { $0["name"] as? String }
    #expect(!defaultNames.contains("inspect_structure"))
    #expect(RecordRecall.toolNames().contains("inspect_structure") == false)

    #expect(RecordRecall.isRecallTool("inspect_structure", includeStructuredContent: true))
    #expect(RecordRecall.isRecallTool("extract_table", includeStructuredContent: true))
    #expect(RecordRecall.isRecallTool("extract_fields", includeStructuredContent: true))
    let optInNames = RecordRecall.toolDefinitions(includeStructuredContent: true).compactMap { $0["name"] as? String }
    #expect(optInNames.contains("inspect_structure"))
    #expect(optInNames.contains("extract_table"))
    #expect(optInNames.contains("extract_fields"))
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
