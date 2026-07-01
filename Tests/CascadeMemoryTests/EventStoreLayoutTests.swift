import CascadeMemory
import Foundation
import Testing

@Test
func capturedMillisecondsAndUTCPartitionKeysAreStable() {
    let dayTwo = Date(timeIntervalSince1970: 86_400 + 1.234)
    let dayOneEnd = Date(timeIntervalSince1970: 86_399.999)

    #expect(EventStoreLayout.capturedMilliseconds(for: dayTwo) == 86_401_234)
    #expect(EventStoreLayout.date(fromCapturedMilliseconds: 86_401_234) == Date(timeIntervalSince1970: 86_401.234))
    #expect(EventStoreLayout.utcDayKey(for: dayTwo) == "1970-01-02")
    #expect(EventStoreLayout.utcDayKey(for: dayOneEnd) == "1970-01-01")
    #expect(EventStoreLayout.utcDayKey(capturedMilliseconds: 172_799_999) == "1970-01-02")
}

@Test
func capturedMillisecondsHandlesNaNDate() {
    #expect(EventStoreLayout.capturedMilliseconds(for: Date(timeIntervalSince1970: .nan)) == 0)
}

@Test
func dayPartitionManifestAggregatesRowsBytesAndEndpoints() {
    var manifest = DayPartitionManifest(dayKey: "1970-01-02")
    manifest.include(rowID: 20, capturedMilliseconds: 2_000, byteCount: 100)
    manifest.include(rowID: 10, capturedMilliseconds: 1_000, byteCount: 40)
    manifest.include(rowID: 30, capturedMilliseconds: 2_000, byteCount: -8)

    var tail = DayPartitionManifest(dayKey: "1970-01-02")
    tail.include(rowID: 40, capturedMilliseconds: 4_000, byteCount: 12)

    let merged = manifest.merged(with: tail)

    #expect(merged.rowCount == 4)
    #expect(merged.byteCount == 152)
    #expect(merged.firstCapturedMilliseconds == 1_000)
    #expect(merged.lastCapturedMilliseconds == 4_000)
    #expect(merged.firstID == 10)
    #expect(merged.lastID == 40)
}

@Test
func retentionChunksAreBoundedAndOrdered() {
    let chunks = EventStoreLayout.retentionChunks(from: 1_000, upTo: 6_500, maxChunkMilliseconds: 2_000)

    #expect(chunks == [
        CapturedMillisecondsRange(lowerBound: 1_000, upperBound: 3_000),
        CapturedMillisecondsRange(lowerBound: 3_000, upperBound: 5_000),
        CapturedMillisecondsRange(lowerBound: 5_000, upperBound: 6_500),
    ])
    #expect(chunks.allSatisfy { $0.spanMilliseconds <= 2_000 })
    #expect(chunks.map(\.lowerBound) == chunks.map(\.lowerBound).sorted())
    #expect(EventStoreLayout.retentionChunks(from: 9, upTo: 9, maxChunkMilliseconds: 1).isEmpty)
    #expect(EventStoreLayout.retentionChunks(from: 1, upTo: 9, maxChunkMilliseconds: 0).isEmpty)
}

@Test
func contextTextCompressionRoundTripsAndFallbackIsDeterministic() throws {
    let text = String(repeating: "Cascade context row contains repeated review evidence. ", count: 200)
    let compressed = ContextTextBlob.encode(text, excerptCharacterLimit: 24)
    let fallback = ContextTextBlob.encode(text, excerptCharacterLimit: 24, preferCompression: false)

    #expect(compressed.codec == .lzfse)
    #expect(try compressed.decodeText() == text)
    #expect(compressed.payloadByteCount < Data(text.utf8).count)
    #expect(fallback.codec == .plainUTF8)
    #expect(fallback.payload == Data(text.utf8))
    #expect(try fallback.decodeText() == text)
}

@Test
func contextTextExcerptUsesSideTextWithoutInflatingPayload() throws {
    let text = String(repeating: "Needle context sentence. ", count: 100)
    let blob = ContextTextBlob.encode(text, excerptCharacterLimit: 32)
    let corrupted = ContextTextBlob(
        codec: blob.codec,
        originalByteCount: blob.originalByteCount,
        excerptUTF8: blob.excerptUTF8,
        payload: Data([0xff])
    )

    #expect(corrupted.excerpt(maxCharacters: 18) == String(text.prefix(18)))

    do {
        _ = try corrupted.decodeText()
        Issue.record("expected corrupted payload to fail full decode")
    } catch {
        #expect(corrupted.excerpt(maxCharacters: 18) == String(text.prefix(18)))
    }
}
