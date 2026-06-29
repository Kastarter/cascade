@testable import MacContextKit
import CascadeMemory
import CoreGraphics
import Foundation
import Testing

private func makeContextWriteBufferStore() throws -> CascadeStore {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("ContextWriteBufferTests-\(UUID().uuidString).sqlite")
        .path
    return try CascadeStore(path: path)
}

@Test
func contextWriteBufferFlushesThresholdBatchAndSideEffects() async throws {
    let store = try makeContextWriteBufferStore()
    let signature = FrameSignature(
        dHash: 1,
        combinedGridHash: 2,
        gridDHash: [3, 4],
        blockHash: 5,
        changedCellsMask: 6,
        textDigest: 7
    )
    let buffer = ContextWriteBuffer(
        store: store,
        indexWorkGraph: false,
        maintenanceScheduler: nil,
        flushThreshold: 2,
        flushInterval: 60
    ) { _ in }

    await buffer.enqueue(ContextWriteBufferItem(
        context: RecordedContext(
            capturedAt: Date(timeIntervalSince1970: 1_900_000_000),
            source: .screen,
            appName: "Safari",
            ocrText: "alpha buffered text",
            imagePath: "/tmp/buffer-alpha.jpg"
        ),
        structuredPayload: StructuredContentExporter.SidecarPayload(
            version: 2,
            json: #"{"version":2,"lines":[]}"#,
            searchableText: "alpha sidecar"
        ),
        visionBoxes: [
            ScreenTextRecognizer.TextBox(
                text: "alpha",
                boundingBox: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
                confidence: 0.9
            )
        ],
        axText: "AX alpha",
        nativeVisionBoxes: [],
        signature: signature,
        semanticText: "alpha buffered text",
        auditDetail: "app=safari axChars=8 ocrChars=19"
    ))
    #expect(try await store.recentContexts(limit: 10).isEmpty)

    await buffer.enqueue(ContextWriteBufferItem(
        context: RecordedContext(
            capturedAt: Date(timeIntervalSince1970: 1_900_000_001),
            source: .screen,
            appName: "Xcode",
            ocrText: "beta buffered text"
        ),
        structuredPayload: nil,
        visionBoxes: [],
        axText: "AX beta",
        nativeVisionBoxes: [
            ScreenTextRecognizer.TextBox(
                text: "native beta",
                boundingBox: CGRect(x: 0.2, y: 0.3, width: 0.2, height: 0.1)
            )
        ],
        signature: signature,
        semanticText: nil,
        auditDetail: "app=xcode axChars=7 ocrChars=18"
    ))

    let rows = try await store.recentContexts(limit: 10)
    #expect(rows.map(\.appName) == ["Xcode", "Safari"])

    let safari = try #require(rows.first { $0.appName == "Safari" })
    let xcode = try #require(rows.first { $0.appName == "Xcode" })
    #expect(try await store.ocrStructure(contextID: safari.id)?.searchableText == "alpha sidecar")
    #expect(Set(try await store.ocrLines(contextID: safari.id).map(\.source)) == ["vision", "ax"])
    #expect(Set(try await store.ocrLines(contextID: xcode.id).map(\.source)) == ["ax", "vision_native_crop"])
    #expect(try await store.frameSignature(contextID: safari.id)?.combinedGridHash == 2)
    #expect(try await store.recentChainedAudit(limit: 10).map(\.action) == ["rewind.capture", "rewind.capture"])
}
