import CascadeMemory
import CoreGraphics
import Foundation
import Testing

struct GroundingCorpusExporterTests {
    @Test func exportsPrivacyGatedClickRecordsAsJSONL() throws {
        let base = Date(timeIntervalSince1970: 1_720_000_000)
        let click = InputEvent(
            id: 42,
            capturedAt: base,
            kind: .click,
            x: 120,
            y: 240,
            text: "Approve",
            appName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            windowTitle: "Review queue",
            targetDescriptor: #"{"label":"Approve","role":"AXButton"}"#
        )
        let context = RecordedContext(
            id: 7,
            capturedAt: base.addingTimeInterval(0.5),
            source: .screen,
            appName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            windowTitle: "Review queue",
            ocrText: "Approve request",
            imagePath: "/local/frame.jpg",
            frameHash: 99,
            safeToShow: true
        )
        let recipe = AgentRecipe(steps: [
            RecipeStep(order: 0, kind: .click, appName: "Safari", ocrAnchor: "Approve request")
        ])

        let jsonl = try GroundingCorpusExporter().jsonl(
            clicks: [click],
            contexts: [context],
            recipe: recipe
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(GroundingCorpusRecord.self, from: Data(jsonl.utf8))

        #expect(record.eventID == 42)
        #expect(record.contextID == 7)
        #expect(record.point == CGPoint(x: 120, y: 240))
        #expect(record.imagePath == "/local/frame.jpg")
        #expect(record.frameHash == 99)
        #expect(record.windowTitleHash != nil)
        #expect(record.labelHash != nil)
        #expect(record.ocrAnchorHash != nil)
        #expect(record.ocrTextHash != nil)
        #expect(record.sourceEvidence.contains("descriptor"))
        #expect(record.sourceEvidence.contains("ocr_hash"))
        #expect(!jsonl.contains("Approve request"))
        #expect(!jsonl.contains("Review queue"))
    }

    @Test func skipsSensitiveOrUnmatchedClicks() {
        let base = Date(timeIntervalSince1970: 1_720_000_000)
        let click = InputEvent(
            id: 1,
            capturedAt: base,
            kind: .click,
            x: 10,
            y: 20,
            text: "Pay",
            appName: "Bank",
            windowTitle: "Checking"
        )
        let sensitiveContext = RecordedContext(
            id: 2,
            capturedAt: base,
            source: .screen,
            appName: "Bank",
            windowTitle: "Checking",
            ocrText: "balance",
            imagePath: "/local/bank.jpg",
            safeToShow: true
        )

        let records = GroundingCorpusExporter().records(
            clicks: [click],
            contexts: [sensitiveContext]
        )

        #expect(records.isEmpty)
    }
}
