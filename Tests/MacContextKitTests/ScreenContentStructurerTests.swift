import CoreGraphics
import Foundation
@testable import MacContextKit
import Testing

private typealias Box = ScreenTextRecognizer.TextBox

/// Top-left-origin box: y increases downward, like screen coordinates.
private func box(_ text: String, _ x: CGFloat, _ y: CGFloat, w: CGFloat = 40, h: CGFloat = 14) -> Box {
    Box(text: text, boundingBox: CGRect(x: x, y: y, width: w, height: h))
}

@Test
func groupsBoxesIntoReadingOrderLines() {
    // Deliberately shuffled; should come out top-to-bottom, left-to-right.
    let boxes = [
        box("world", 60, 0),
        box("Hello", 0, 0),
        box("second", 0, 30),
        box("line", 60, 30),
    ]
    let structured = ScreenContentStructurer.structure(boxes)
    #expect(structured.lines.count == 2)
    #expect(structured.lines[0].text == "Hello world")
    #expect(structured.lines[1].text == "second line")
    #expect(structured.readingOrderText == "Hello world\nsecond line")
}

@Test
func extractsKeyValuePairs() {
    let boxes = [
        box("Invoice Total: $403,050", 0, 0, w: 200),
        box("Status: Paid", 0, 30, w: 120),
        box("Visit https://example.com", 0, 60, w: 220),   // must NOT become a KV
        box("Meeting at 9:30 AM", 0, 90, w: 160),           // numeric key must be skipped
    ]
    let kvs = ScreenContentStructurer.structure(boxes).keyValues
    #expect(kvs.contains(ScreenContentStructurer.KeyValue(key: "Invoice Total", value: "$403,050")))
    #expect(kvs.contains(ScreenContentStructurer.KeyValue(key: "Status", value: "Paid")))
    #expect(!kvs.contains { $0.value.hasPrefix("//") })
    #expect(!kvs.contains { $0.key == "9" || $0.key == "Meeting at 9" })
}

@Test
func reconstructsASimpleTable() {
    // 3 rows × 2 columns, columns clearly separated in x.
    let boxes = [
        box("Name", 0, 0),   box("Q1", 100, 0),
        box("Acme", 0, 20),  box("403050", 100, 20),
        box("Globex", 0, 40), box("469100", 100, 40),
    ]
    let tables = ScreenContentStructurer.structure(boxes).tables
    #expect(tables.count == 1)
    let table = tables[0]
    #expect(table.columnCount == 2)
    #expect(table.rows == [
        ["Name", "Q1"],
        ["Acme", "403050"],
        ["Globex", "469100"],
    ])
}

@Test
func rejectsTwoRowTableFalsePositive() {
    let boxes = [
        box("Name", 0, 0), box("Q1", 100, 0),
        box("Acme", 0, 20), box("403050", 100, 20),
    ]

    #expect(ScreenContentStructurer.structure(boxes).tables.isEmpty)
}

@Test
func detectsHeadingAndBulletListBlocks() {
    let boxes = [
        box("Invoice Summary", 0, 0, w: 180, h: 24),
        box("- Subtotal reviewed", 20, 60, w: 180),
        box("- Tax calculated", 20, 82, w: 160),
    ]

    let structured = ScreenContentStructurer.structure(boxes)

    #expect(structured.blocks.contains { $0.kind == .heading && $0.text == "Invoice Summary" })
    #expect(structured.lists.count == 1)
    #expect(structured.lists.first?.items.map(\.text) == ["Subtotal reviewed", "Tax calculated"])
}

@Test
func extractsSpatialAndTypedFields() {
    let boxes = [
        box("Due Date", 0, 0, w: 80), box("2026-07-15", 140, 0, w: 110),
        box("TOTAL DUE", 0, 28, w: 90), box("$443,355", 140, 28, w: 90),
    ]

    let fields = ScreenContentStructurer.structure(boxes).fields

    #expect(fields.contains { $0.key == "Due Date" && $0.value == "2026-07-15" && $0.kind == .date })
    #expect(fields.contains { $0.key == "TOTAL DUE" && $0.value == "$443,355" && $0.kind == .total })
}

@Test
func extractsAXControlFieldsWithoutOCRBoxes() {
    let structured = ScreenContentStructurer.structure(
        [],
        axControls: [
            .init(kind: .checkbox, label: "Approved", value: "1", rect: CGRect(x: 10, y: 10, width: 20, height: 20)),
        ]
    )

    #expect(structured.lines.isEmpty)
    #expect(structured.fields.contains { $0.key == "Approved" && $0.value == "1" && $0.kind == .formControl })
}

@Test
func emptyInputIsHandled() {
    let structured = ScreenContentStructurer.structure([])
    #expect(structured.lines.isEmpty)
    #expect(structured.tables.isEmpty)
    #expect(structured.keyValues.isEmpty)
    #expect(structured.readingOrderText.isEmpty)
}

@Test
func proseWithoutAGridProducesNoTable() {
    let boxes = [
        box("This is a paragraph of ordinary text.", 0, 0, w: 300),
        box("It continues on a second line here.", 0, 20, w: 300),
    ]
    // Single box per line → not table candidates.
    #expect(ScreenContentStructurer.structure(boxes).tables.isEmpty)
}
