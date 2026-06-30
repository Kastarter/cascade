import CoreGraphics
import Foundation
@testable import MacContextKit
import Testing

private typealias StructuredBox = ScreenTextRecognizer.TextBox

private func visionBox(_ text: String, _ x: CGFloat, _ y: CGFloat, w: CGFloat = 0.12, h: CGFloat = 0.04) -> StructuredBox {
    StructuredBox(text: text, boundingBox: CGRect(x: x, y: y, width: w, height: h))
}

@Test
func structuredContentRecordingIsDefaultOn() {
    let options = ContextRecorder.Options()
    let metadata = RecorderMetadataJSON.rewind(width: 1920, height: 1080, axCount: 42, structured: nil)

    #expect(options.structuredContent)
    #expect(options.indexWorkGraph == true)
    #expect(metadata == "{\"rewind\":true,\"w\":1920,\"h\":1080,\"ax\":42}")
    #expect(!metadata.contains("structured"))
}

@Test
func optInSyntheticVisionBoxesProduceStructuredMetadata() throws {
    let structured = ScreenContentStructurer.structure([
        visionBox("Invoice Total: $403,050", 0.05, 0.90, w: 0.40),
        visionBox("Name", 0.05, 0.72), visionBox("Q1", 0.42, 0.72),
        visionBox("Acme", 0.05, 0.62), visionBox("=SUM(1)", 0.42, 0.62),
        visionBox("Globex", 0.05, 0.52), visionBox("469100", 0.42, 0.52),
    ], topLeftOrigin: false)

    let metadata = StructuredContentExporter.metadata(from: structured)
    let json = RecorderMetadataJSON.rewind(width: 1440, height: 900, axCount: 0, structured: metadata)
    let data = try #require(json.data(using: .utf8))
    let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let payload = try #require(root["structured"] as? [String: Any])
    let readingOrder = try #require(payload["reading_order"] as? String)
    let keyValues = try #require(payload["key_values"] as? [[String: Any]])
    let markdownTables = try #require(payload["markdown_tables"] as? [String])
    let csvTables = try #require(payload["csv_tables"] as? [String])

    #expect(readingOrder.hasPrefix("Invoice Total: $403,050\nName Q1"))
    #expect(keyValues.contains { $0["key"] as? String == "Invoice Total" && $0["value"] as? String == "$403,050" })
    #expect(markdownTables.first?.contains("| Name | Q1 |") == true)
    #expect(csvTables.first?.contains("Acme,'=SUM(1)") == true)
}

@Test
func rewindMetadataEncodesChangedRegionsAlongsideExistingFields() throws {
    let signature = FrameSignature(
        dHash: 1,
        combinedGridHash: 2,
        gridDHash: [3],
        blockHash: 4,
        changedCellsMask: 0b010
    )
    let json = RecorderMetadataJSON.rewind(
        width: 300,
        height: 210,
        axCount: 12,
        signature: signature,
        ocrMode: .changedRegion,
        ocrRegion: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
        ocrPixelsRequested: 25200,
        changedRegions: [CGRect(x: 100, y: 70, width: 100, height: 70)],
        structured: nil
    )
    let data = try #require(json.data(using: .utf8))
    let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let signaturePayload = try #require(root["signature"] as? [String: Any])
    let ocrRegion = try #require(root["ocr_region"] as? [String: Any])
    let changedRegions = try #require(root["changed_regions"] as? [[String: Any]])

    #expect(signaturePayload["changedCellsMask"] as? Int == 0b010)
    #expect(root["ocr_mode"] as? String == FrameOCRMode.changedRegion.rawValue)
    #expect(ocrRegion["width"] as? Double == 0.3)
    #expect(changedRegions.count == 1)
    #expect(changedRegions[0]["x"] as? Double == 100)
    #expect(changedRegions[0]["height"] as? Double == 70)
}
