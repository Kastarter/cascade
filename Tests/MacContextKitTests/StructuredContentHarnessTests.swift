import AppKit
import Foundation
import Testing

@testable import MacContextKit

// Diagnostic harness for the `experimentalStructuredContent` flag (SEQ-16).
//
// It renders a known invoice fixture, runs the REAL pipeline the recorder runs
// when the flag is on — Vision OCR (`recognizeBoxes`) → `ScreenContentStructurer`
// → `StructuredContentExporter` — and prints exactly what `inspect_structure`
// would return for that moment, plus per-stage latency. The fixture deliberately
// mixes colon-delimited totals ("Subtotal: …") with a no-colon footer total
// ("TOTAL DUE   $…") so the report shows which the geometry pass captures.
//
// Run it on its own to see the report:
//   swift test --filter structuredContentHarnessReportsWhatInspectStructureReturns
@Test
func structuredContentHarnessReportsWhatInspectStructureReturns() {
    let rows: [[(String, CGFloat)]] = [
        [("ACME Corporation — Invoice", 60)],
        [("Invoice Number: INV-2026-0042", 60)],
        [("Date: 2026-06-15", 60)],
        [("Due Date: 2026-07-15", 60)],
        [("Item", 60), ("Qty", 380), ("Amount", 560)],
        [("Widgets", 60), ("100", 380), ("$250,000", 560)],
        [("Gadgets", 60), ("50", 380), ("$153,050", 560)],
        [("Subtotal: $403,050", 60)],
        [("Tax: $40,305", 60)],
        [("TOTAL DUE", 60), ("$443,355", 560)],
    ]
    guard let png = renderFixture(rows: rows, width: 760, height: 520) else {
        Issue.record("Could not render the invoice fixture image.")
        return
    }

    let t0 = DispatchTime.now()
    let boxes = ScreenTextRecognizer.recognizeBoxes(inImageData: png, level: .accurate)
    let t1 = DispatchTime.now()
    // Vision OCR boxes are BOTTOM-left origin, matching the recorder's wiring.
    let structured = ScreenContentStructurer.structure(boxes, topLeftOrigin: false)
    let t2 = DispatchTime.now()
    let metadata = StructuredContentExporter.metadata(from: structured)
    let t3 = DispatchTime.now()

    func ms(_ a: DispatchTime, _ b: DispatchTime) -> String {
        String(format: "%.1f ms", Double(b.uptimeNanoseconds - a.uptimeNanoseconds) / 1_000_000)
    }

    var report = ["", "===== experimentalStructuredContent harness ====="]
    report.append("Latency:  OCR \(ms(t0, t1))  |  structure \(ms(t1, t2))  |  export \(ms(t2, t3))")
    report.append("OCR returned \(boxes.count) text boxes; structurer made \(structured.lines.count) lines, "
        + "\(structured.keyValues.count) key-values, \(structured.tables.count) tables.")

    report.append("\n--- OCR boxes (text) ---")
    for box in boxes { report.append("  • \(box.text)") }

    report.append("\n--- inspect_structure: SUMMARY ---")
    report.append(metadata.summary)

    report.append("\n--- inspect_structure: READING ORDER ---")
    report.append(metadata.readingOrder)

    report.append("\n--- inspect_structure: KEY-VALUES ---")
    if metadata.keyValues.isEmpty {
        report.append("  (none)")
    } else {
        for kv in metadata.keyValues { report.append("  • \(kv.key) = \(kv.value)") }
    }

    report.append("\n--- inspect_structure: MARKDOWN TABLES ---")
    if metadata.markdownTables.isEmpty {
        report.append("  (no table detected)")
    } else {
        for table in metadata.markdownTables { report.append(table) }
    }

    // Gap probe: which "totals" did the geometry pass actually expose?
    let kvBlob = metadata.keyValues.map { "\($0.key) \($0.value)" }.joined(separator: " ").lowercased()
    let footerTotalCaptured = kvBlob.contains("443,355")
    let colonTotalsCaptured = kvBlob.contains("403,050") && kvBlob.contains("40,305")
    report.append("\n--- GAP PROBE (invoice total) ---")
    report.append("  colon totals (Subtotal/Tax) captured as key-values: \(colonTotalsCaptured ? "YES" : "NO")")
    report.append("  no-colon footer 'TOTAL DUE $443,355' captured:      \(footerTotalCaptured ? "YES" : "NO")")
    report.append("  table detected from the 3-column rows:              \(structured.tables.isEmpty ? "NO" : "YES")")
    report.append("================================================\n")
    print(report.joined(separator: "\n"))

    // Only hard assertion: OCR must read the rendered text. Everything else is a
    // report of current behavior, not a contract.
    #expect(!boxes.isEmpty)
}

/// Renders the given rows (each a list of (text, x) at a row) onto a white
/// canvas and returns PNG bytes. AppKit's default context is bottom-left origin,
/// so rows are placed top-to-bottom by decreasing y.
private func renderFixture(rows: [[(String, CGFloat)]], width: CGFloat, height: CGFloat) -> Data? {
    let size = NSSize(width: width, height: height)
    let image = NSImage(size: size)
    image.lockFocus()
    NSColor.white.setFill()
    NSRect(origin: .zero, size: size).fill()
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 20),
        .foregroundColor: NSColor.black,
    ]
    let lineHeight: CGFloat = 40
    let topMargin: CGFloat = 36
    for (index, row) in rows.enumerated() {
        let y = height - topMargin - CGFloat(index) * lineHeight
        for (text, x) in row {
            (text as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
        }
    }
    image.unlockFocus()
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        return nil
    }
    return png
}
