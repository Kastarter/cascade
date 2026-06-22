import CoreGraphics
import Foundation
import MacContextKit
import Testing

@Test
func identicalFramesHashEqual() {
    let a = PerceptualHash.dHash(horizontalGradient())
    let b = PerceptualHash.dHash(horizontalGradient())
    #expect(PerceptualHash.hamming(a, b) == 0)
    #expect(PerceptualHash.isDuplicate(a, of: b))
}

@Test
func smallChangeStaysWithinThreshold() {
    let base = PerceptualHash.dHash(horizontalGradient())
    let patched = PerceptualHash.dHash(horizontalGradient(darkPatch: true))
    let reversed = PerceptualHash.dHash(horizontalGradient(reversed: true))
    // A small localized change perturbs only a few bits...
    #expect(PerceptualHash.hamming(base, patched) <= PerceptualHash.defaultSkipThreshold)
    #expect(PerceptualHash.isDuplicate(base, of: patched))
    // ...and stays well below a wholesale content change.
    #expect(PerceptualHash.hamming(base, patched) < PerceptualHash.hamming(base, reversed))
}

@Test
func veryDifferentFramesHashFarApart() {
    let base = PerceptualHash.dHash(horizontalGradient())
    let reversed = PerceptualHash.dHash(horizontalGradient(reversed: true))
    #expect(PerceptualHash.hamming(base, reversed) > PerceptualHash.defaultSkipThreshold)
    #expect(!PerceptualHash.isDuplicate(base, of: reversed))
}

// MARK: - Region grid (change-aware dedup)

@Test
func gridCatchesTheSmallChangeTheGlobalHashMisses() {
    let base = horizontalGradient()
    let patched = horizontalGradient(darkPatch: true)

    // The whole-frame hash calls these "the same screen" — that's exactly the
    // hole that loses a new message in a static layout...
    #expect(PerceptualHash.isDuplicate(PerceptualHash.dHash(patched), of: PerceptualHash.dHash(base)))

    // ...and the per-region grid catches it: the patched region differs.
    let baseGrid = PerceptualHash.gridHashes(base)
    let patchedGrid = PerceptualHash.gridHashes(patched)
    #expect(baseGrid.count == PerceptualHash.gridDimension * PerceptualHash.gridDimension)
    #expect(!PerceptualHash.isDuplicateGrid(patchedGrid, of: baseGrid))
}

@Test
func gridStillDedupesIdenticalFrames() {
    let a = PerceptualHash.gridHashes(horizontalGradient())
    let b = PerceptualHash.gridHashes(horizontalGradient())
    #expect(PerceptualHash.isDuplicateGrid(a, of: b))
}

@Test
func combinedHashIsStableAndMovesWithContent() {
    let same = PerceptualHash.gridHashes(horizontalGradient())
    let other = PerceptualHash.gridHashes(horizontalGradient(reversed: true))
    // Same frame → same folded signature (deterministic; replay-safe).
    #expect(PerceptualHash.combinedHash(same) == PerceptualHash.combinedHash(PerceptualHash.gridHashes(horizontalGradient())))
    // A wholesale content change moves the signature.
    #expect(PerceptualHash.combinedHash(same) != PerceptualHash.combinedHash(other))
}

@Test
func combinedHashDoesNotCollideOnRegionPosition() {
    // Two frames that differ only in WHICH region carries the change must fold
    // to different signatures — the per-index rotation is what stops a plain
    // XOR from cancelling them to the same value.
    let g1: [UInt64] = [1, 0, 0, 0, 0, 0, 0, 0, 0]
    let g2: [UInt64] = [0, 1, 0, 0, 0, 0, 0, 0, 0]
    #expect(PerceptualHash.combinedHash(g1) != PerceptualHash.combinedHash(g2))
}

// MARK: - AX/OCR text merge

@Test
func mergePrefersAXAndAppendsNovelOCRLines() {
    let ax = "Inbox\nReply All\nQuarterly numbers are ready"
    let ocr = "Inbox\nReply All\nLogo Banner Text"
    let merged = AXTextHarvester.merge(ax: ax, ocr: ocr)
    #expect(merged.hasPrefix(ax))                  // exact text leads
    #expect(merged.contains("Logo Banner Text"))   // OCR-only content kept
    let occurrences = merged.components(separatedBy: "Reply All").count - 1
    #expect(occurrences == 1)                      // overlap not duplicated
}

@Test
func mergeFallsBackToWhicheverChannelHasText() {
    #expect(AXTextHarvester.merge(ax: "", ocr: "only ocr") == "only ocr")
    #expect(AXTextHarvester.merge(ax: "only ax", ocr: "") == "only ax")
    #expect(AXTextHarvester.merge(ax: "", ocr: "") == "")
}

/// Renders a deterministic horizontal grayscale gradient so the dHash has real
/// horizontal structure (every pixel brighter than its left neighbor). Reversing
/// it flips every comparison bit; a small dark patch perturbs only a couple.
private func horizontalGradient(reversed: Bool = false, darkPatch: Bool = false) -> CGImage {
    let width = 288, height = 128
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    for x in 0..<width {
        let t = Double(x) / Double(width - 1)
        let v = reversed ? 1 - t : t
        context.setFillColor(CGColor(srgbRed: v, green: v, blue: v, alpha: 1))
        context.fill(CGRect(x: x, y: 0, width: 1, height: height))
    }
    if darkPatch {
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: width * 6 / 9, y: 0, width: width / 9, height: height / 8))
    }
    return context.makeImage()!
}
