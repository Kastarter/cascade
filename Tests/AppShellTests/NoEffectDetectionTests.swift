import AppKit
import CoreGraphics
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import AppShell
@testable import MacContextKit

/// Pins the "no state change after an action" engine — the cheapest universal
/// failure signal in the GUI-agent literature (WILBUR / VeriGUI / AgentRR), used
/// to stop the agent re-clicking a dead spot (the audited 657,675 ×2 loop). The
/// runtime decision is: an acting turn whose every screen region is unchanged had
/// no effect. Here we pin the primitive it rests on — `gridHashes(ofJPEG:)` over
/// the recorder's grid hash — so frame-diffing stays reliable.
struct NoEffectDetectionTests {
    /// Encodes a drawn pattern to JPEG, the same shape the assist loop hashes.
    private func jpeg(_ draw: (CGContext, CGRect) -> Void, size: Int = 240) -> Data {
        let ctx = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        ctx.setFillColor(.white)
        ctx.fill(rect)
        draw(ctx, rect)
        let image = ctx.makeImage()!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    /// Two independent JPEG encodes of the SAME picture must read as "no change" —
    /// re-observing after a dead click should look identical despite JPEG noise.
    @Test func identicalFrameReadsAsNoChange() {
        let draw: (CGContext, CGRect) -> Void = { ctx, rect in
            ctx.setFillColor(.black)
            ctx.fill(CGRect(x: 0, y: 0, width: rect.width / 2, height: rect.height))
        }
        let a = CascadeAppModel.gridHashes(ofJPEG: jpeg(draw))
        let b = CascadeAppModel.gridHashes(ofJPEG: jpeg(draw))
        #expect(a != nil)
        #expect(b != nil)
        #expect(PerceptualHash.isDuplicateGrid(a!, of: b!))
    }

    /// A genuinely different screen must NOT read as a duplicate — a real effect
    /// (content moved/appeared) has to reset the no-effect counter.
    @Test func differentFrameReadsAsChanged() {
        let vertical = jpeg { ctx, rect in
            ctx.setFillColor(.black)
            ctx.fill(CGRect(x: 0, y: 0, width: rect.width / 2, height: rect.height))
        }
        let blocks = jpeg { ctx, rect in
            ctx.setFillColor(.black)
            ctx.fill(CGRect(x: rect.width * 0.2, y: rect.height * 0.2, width: rect.width * 0.3, height: rect.height * 0.3))
            ctx.fill(CGRect(x: rect.width * 0.6, y: rect.height * 0.55, width: rect.width * 0.25, height: rect.height * 0.25))
        }
        let a = CascadeAppModel.gridHashes(ofJPEG: vertical)
        let b = CascadeAppModel.gridHashes(ofJPEG: blocks)
        #expect(a != nil && b != nil)
        #expect(!PerceptualHash.isDuplicateGrid(a!, of: b!))
    }

    /// Undecodable data yields nil — no-effect detection then safely skips.
    @Test func garbageDataYieldsNil() {
        #expect(CascadeAppModel.gridHashes(ofJPEG: Data([0x01, 0x02, 0x03])) == nil)
    }
}
