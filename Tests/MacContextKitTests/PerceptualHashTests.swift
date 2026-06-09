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
