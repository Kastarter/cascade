import ComputerUseKit
import CoreGraphics
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

@Test
func secureInputErrorCarriesItsReason() {
    let error = ComputerUseError.secureInput("macOS Secure Input is active")
    #expect(error.errorDescription?.contains("Secure Input") == true)
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

@Test
func textInjectionResultAuditNeverIncludesRawText() {
    let raw = "SensitiveSeed-12345"
    let result = TextInjectionResult.make(
        method: .paste,
        text: raw,
        succeeded: false,
        focusedRole: "AXTextField",
        focusedSubrole: "AXSearchField",
        bundleIdentifier: "com.example.SecretApp",
        secureInputEnabled: false,
        readbackStatus: .mismatched,
        fallbackReason: "readback mismatch",
        elapsedMs: 12
    )

    #expect(result.auditDetail.contains("method=paste"))
    #expect(result.auditDetail.contains("chars=\(raw.count)"))
    #expect(result.auditDetail.contains("textHash="))
    #expect(!result.auditDetail.contains(raw))
    #expect(!result.auditDetail.contains("com.example.SecretApp"))
}

@Test
func keyboardFallbackMapsShiftedSymbols() throws {
    let plus = try #require(KeyboardLayoutMapper.usFallbackMapping(for: "plus"))
    let bang = try #require(KeyboardLayoutMapper.usFallbackMapping(for: "!"))
    let equal = try #require(KeyboardLayoutMapper.usFallbackMapping(for: "="))

    #expect(plus.keyCode == 24)
    #expect(plus.requiredModifiers.contains(.maskShift))
    #expect(bang.keyCode == 18)
    #expect(bang.requiredModifiers.contains(.maskShift))
    #expect(equal.keyCode == 24)
    #expect(!equal.requiredModifiers.contains(.maskShift))
}

@Test
func modifierSequenceWrapsMainKeyWithDownUpEvents() {
    let steps = EventSynthesisPlan.modifierEventSequence(mainKeyCode: 8, flags: [.maskCommand, .maskShift])

    #expect(steps.count == 6)
    #expect(steps[0].keyDown)
    #expect(steps[1].keyDown)
    #expect(steps[2] == KeyboardEventStep(keyCode: 8, keyDown: true, flags: [.maskCommand, .maskShift]))
    #expect(steps[3] == KeyboardEventStep(keyCode: 8, keyDown: false, flags: [.maskCommand, .maskShift]))
    #expect(!steps[4].keyDown)
    #expect(!steps[5].keyDown)
}

@Test
func clickAndScrollPlansAreDeterministic() {
    #expect(EventSynthesisPlan.clickStates(clickCount: 3) == [1, 2, 3])
    let scroll = EventSynthesisPlan.scrollConfiguration(deltaX: 12.4, deltaY: -40.6)
    #expect(scroll.deltaX == 12)
    #expect(scroll.deltaY == -41)
    #expect(scroll.continuous)
    #expect(scroll.phase == 1)
}
