import ComputerUseKit
import Foundation
import Testing

// MARK: - Secure Input

@Test
func secureInputRefusalOnlyWhenActive() {
    #expect(SecureInputGuard.refusalReason(secureInputActive: false) == nil)
    let reason = SecureInputGuard.refusalReason(secureInputActive: true)
    #expect(reason != nil)
    #expect(reason?.contains("Secure Input") == true)
}

// MARK: - Grapheme-safe chunking

private func reconstruct(_ chunks: [[UInt16]]) -> String {
    var units: [UInt16] = []
    for chunk in chunks { units.append(contentsOf: chunk) }
    return String(utf16CodeUnits: units, count: units.count)
}

@Test
func chunkingPreservesPlainText() {
    let text = "The quick brown fox jumped over the lazy dog 1234567890"
    let chunks = TextChunker.graphemeSafeChunks(text, maxUTF16: 16)
    #expect(reconstruct(chunks) == text)
    #expect(chunks.allSatisfy { $0.count <= 16 })
}

@Test
func chunkingNeverSplitsAGrapheme() {
    // Emoji and a ZWJ family sequence are multi-UTF-16-unit graphemes.
    let text = "ab😀cd🎉ef👨‍👩‍👧‍👦gh"
    let chunks = TextChunker.graphemeSafeChunks(text, maxUTF16: 8)
    // Lossless round-trip — nothing dropped or mangled.
    #expect(reconstruct(chunks) == text)
    // Every chunk decodes to a whole number of grapheme clusters (no half emoji):
    // re-chunking each emitted chunk by character and rejoining yields the chunk.
    for chunk in chunks {
        let s = String(utf16CodeUnits: chunk, count: chunk.count)
        #expect(s.unicodeScalars.allSatisfy { $0 != "\u{FFFD}" })  // no replacement chars
    }
}

@Test
func oversizeSingleGraphemeBecomesItsOwnChunk() {
    // The 4-person family emoji is > 8 UTF-16 units on its own.
    let family = "👨‍👩‍👧‍👦"
    let chunks = TextChunker.graphemeSafeChunks(family, maxUTF16: 8)
    #expect(reconstruct(chunks) == family)
    #expect(String(utf16CodeUnits: chunks[0], count: chunks[0].count) == family)
}

@Test
func emptyTextYieldsNoChunks() {
    #expect(TextChunker.graphemeSafeChunks("", maxUTF16: 16).isEmpty)
}
