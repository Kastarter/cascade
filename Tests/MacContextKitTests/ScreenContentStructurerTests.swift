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
