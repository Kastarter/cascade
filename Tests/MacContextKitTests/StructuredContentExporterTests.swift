import CoreGraphics
import Foundation
@testable import MacContextKit
import Testing

private typealias ExportBox = ScreenTextRecognizer.TextBox

private func exportBox(_ text: String, _ x: CGFloat, _ y: CGFloat, w: CGFloat = 50, h: CGFloat = 14) -> ExportBox {
    ExportBox(text: text, boundingBox: CGRect(x: x, y: y, width: w, height: h))
}

@Test
func exportsReadingOrderLinesAsMarkdownParagraphs() {
    let structured = ScreenContentStructurer.structure([
        exportBox("Ready for manager review", 0, 24, w: 180),
        exportBox("Candidate summary", 0, 0, w: 160),
    ])

    let markdown = StructuredContentExporter.markdown(from: structured)

    #expect(markdown.hasPrefix("Candidate summary\n\nReady for manager review"))
}

@Test
func exportsKeyValuesAsCompactMarkdownList() {
    let structured = ScreenContentStructurer.structure([
        exportBox("Invoice Total: $403,050", 0, 0, w: 180),
        exportBox("Status: Paid", 0, 24, w: 100),
    ])

    let markdown = StructuredContentExporter.markdown(from: structured)

    #expect(markdown.contains("- **Invoice Total**: $403,050"))
    #expect(markdown.contains("- **Status**: Paid"))
}

@Test
func exportsAlignedTableAsMarkdownWithEscapedCells() {
    let structured = ScreenContentStructurer.structure([
        exportBox("Name", 0, 0), exportBox("Q1", 120, 0),
        exportBox("Acme | North", 0, 24, w: 90), exportBox("403,050", 120, 24),
        exportBox("Globex \"West\"", 0, 48, w: 100), exportBox("469100", 120, 48),
    ])

    let markdown = StructuredContentExporter.markdownTables(from: structured)[0]

    #expect(markdown == """
    | Name | Q1 |
    | --- | --- |
    | Acme \\| North | 403,050 |
    | Globex "West" | 469100 |
    """)
}

@Test
func exportsAlignedTableAsCSVWithEscapedCells() {
    let structured = ScreenContentStructurer.structure([
        exportBox("Name", 0, 0), exportBox("Q1", 120, 0),
        exportBox("Acme | North", 0, 24, w: 90), exportBox("403,050", 120, 24),
        exportBox("Globex \"West\"", 0, 48, w: 100), exportBox("469100", 120, 48),
    ])

    let csv = StructuredContentExporter.csvTables(from: structured)[0]

    #expect(csv == #"""
    Name,Q1
    Acme | North,"403,050"
    "Globex ""West""",469100
    """#)
}

@Test
func metadataCarriesBoundedBlocksAndLists() throws {
    let structured = ScreenContentStructurer.structure([
        exportBox("Invoice Summary", 0, 0, w: 180, h: 24),
        exportBox("- Subtotal reviewed", 20, 60, w: 180),
        exportBox("- Tax calculated", 20, 82, w: 160),
    ])

    let metadata = StructuredContentExporter.metadata(from: structured)
    let payload = try JSONEncoder().encode(metadata)
    let json = try #require(String(data: payload, encoding: .utf8))

    #expect(metadata.blocks.contains { $0.kind == "heading" && $0.text.contains("Invoice Summary") })
    #expect(metadata.lists.first?.items == ["Subtotal reviewed", "Tax calculated"])
    #expect(json.contains("\"blocks\""))
    #expect(json.contains("\"lists\""))
}

@Test
func sidecarPayloadEncodesVersionedFullStructure() throws {
    let structured = ScreenContentStructurer.structure([
        exportBox("Invoice Total: $403,050", 0, 0, w: 180),
    ])

    let payload = try #require(StructuredContentExporter.sidecarPayload(from: structured))

    #expect(payload.version == ScreenContentStructurer.currentVersion)
    #expect(payload.json.contains("\"fields\""))
    #expect(payload.searchableText.contains("Invoice Total"))
}

@Test
func sidecarPayloadRetainsManyTableRowsInSearchableText() throws {
    var boxes: [ExportBox] = [exportBox("Item", 0, 0), exportBox("Qty", 120, 0), exportBox("Amount", 220, 0)]
    for row in 1...20 {
        boxes.append(exportBox("Line \(row)", 0, CGFloat(row * 24), w: 70))
        boxes.append(exportBox("\(row)", 120, CGFloat(row * 24), w: 30))
        boxes.append(exportBox("$\(row * 10).00", 220, CGFloat(row * 24), w: 70))
    }
    let structured = ScreenContentStructurer.structure(boxes)

    let payload = try #require(StructuredContentExporter.sidecarPayload(from: structured))

    #expect(payload.searchableText.contains("Line 20"))
    #expect(payload.searchableText.contains("$200.00"))
}

@Test
func exportsCSVWithFormulaNeutralizedCells() {
    let table = ScreenContentStructurer.Table(rows: [
        ["A", "B", "C", "D", "E"],
        [#"=HYPERLINK("https://example.com")"#, "  =SUM(1)", "+cmd", "-10", "@name"],
    ])

    let csv = StructuredContentExporter.csv(table)

    #expect(csv == #"""
    A,B,C,D,E
    "'=HYPERLINK(""https://example.com"")",'  =SUM(1),'+cmd,'-10,'@name
    """#)
}

@Test
func truncatesMarkdownByLineBudget() {
    let structured = ScreenContentStructurer.structure([
        exportBox("Line one", 0, 0),
        exportBox("Line two", 0, 24),
        exportBox("Line three", 0, 48),
        exportBox("Line four", 0, 72),
    ])

    let markdown = StructuredContentExporter.markdown(
        from: structured,
        budget: .init(maxBytes: 200, maxLines: 3)
    )

    #expect(markdown.split(separator: "\n", omittingEmptySubsequences: false).count <= 3)
    #expect(markdown.contains("[truncated]"))
}

@Test
func truncatesMarkdownByByteBudget() {
    let structured = ScreenContentStructurer.structure([
        exportBox("This is a long paragraph that should be clipped to the configured byte budget.", 0, 0, w: 420),
        exportBox("Another line that should not fit.", 0, 24, w: 260),
    ])

    let markdown = StructuredContentExporter.markdown(
        from: structured,
        budget: .init(maxBytes: 64, maxLines: 10)
    )

    #expect(markdown.utf8.count <= 64)
    #expect(markdown.contains("[truncated]"))
}

@Test
func emptyStructureProducesExplicitSummary() {
    let structured = ScreenContentStructurer.structure([])

    #expect(StructuredContentExporter.summary(from: structured) == "No structured content detected.")
}
