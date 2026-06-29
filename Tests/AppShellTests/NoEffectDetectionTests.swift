import AppKit
import CoreGraphics
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import AppShell
@testable import ComputerUseKit
@testable import MacContextKit
@testable import ProviderKit

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

    // MARK: predicted-effect gate (VeriGUI) — a copy/wait-only turn isn't a failure

    @Test func clipboardAndWaitDoNotExpectChange() {
        #expect(!CascadeAppModel.expectsVisibleChange(.wait))
        #expect(!CascadeAppModel.expectsVisibleChange(.key("cmd+c")))
        #expect(!CascadeAppModel.expectsVisibleChange(.key("cmd+x")))
        #expect(!CascadeAppModel.expectsVisibleChange(.screenshot))
        #expect(!CascadeAppModel.expectsVisibleChange(.zoom(nx: 0, ny: 0, nw: 1, nh: 1)))
    }

    @Test func actingKeysAndClicksExpectChange() {
        #expect(CascadeAppModel.expectsVisibleChange(.click(x: 1, y: 1)))
        #expect(CascadeAppModel.expectsVisibleChange(.type("hi")))
        #expect(CascadeAppModel.expectsVisibleChange(.key("return")))
        #expect(CascadeAppModel.expectsVisibleChange(.key("cmd+a")))   // select-all changes the selection
        #expect(CascadeAppModel.expectsVisibleChange(.key("cmd+v")))   // paste changes content
    }

    @Test func turnExemptOnlyWhenEveryActionIsInvisible() {
        // A copy-only turn is exempt; a copy followed by a real click is NOT.
        #expect(!CascadeAppModel.turnExpectsVisibleChange([.key("cmd+c"), .wait]))
        #expect(CascadeAppModel.turnExpectsVisibleChange([.key("cmd+c"), .click(x: 5, y: 5)]))
        #expect(!CascadeAppModel.turnExpectsVisibleChange([]))   // nothing acted → no charge
    }

    // Coordinate-level grounding push: AX CG-global center -> model pixel space.
    // A wrong number here clicks empty space, so pin the mapping exactly.
    @Test func modelPixelMapsDisplayCenter() {
        let display = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let p = CascadeAppModel.modelPixel(forCGGlobal: CGPoint(x: 720, y: 450), in: display, resW: 1280, resH: 800)
        #expect(p?.x == 640)   // 0.5 * 1280
        #expect(p?.y == 400)   // 0.5 * 800
    }

    @Test func modelPixelMapsCornersAndOffsetDisplay() {
        let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)
        #expect(CascadeAppModel.modelPixel(forCGGlobal: .zero, in: primary, resW: 1280, resH: 800) == CGPoint(x: 0, y: 0))
        // A second display offset to the right: a point local to it maps by the
        // SAME subtract-and-scale once you pass that display's bounds.
        let secondary = CGRect(x: 1440, y: 0, width: 1280, height: 800)
        let p = CascadeAppModel.modelPixel(forCGGlobal: CGPoint(x: 1440 + 640, y: 400), in: secondary, resW: 1280, resH: 800)
        #expect(p?.x == 640)
        #expect(p?.y == 400)
    }

    @Test func modelPixelRejectsOffDisplayPoints() {
        let display = CGRect(x: 0, y: 0, width: 1440, height: 900)
        // A control on another monitor must NOT be pushed — its coordinate isn't
        // in this screenshot.
        #expect(CascadeAppModel.modelPixel(forCGGlobal: CGPoint(x: 2000, y: 450), in: display, resW: 1280, resH: 800) == nil)
        #expect(CascadeAppModel.modelPixel(forCGGlobal: CGPoint(x: 720, y: -50), in: display, resW: 1280, resH: 800) == nil)
    }

    @Test func groundingControlsFormatsLabelRoleAndCoordinate() {
        let display = CGRect(x: 0, y: 0, width: 1280, height: 800)
        let controls = [
            AXElementResolver.Match(center: CGPoint(x: 640, y: 400), role: "AXButton", title: "Save", score: 0),
        ]
        let summary = CascadeAppModel.groundingControls(controls, display: display, resW: 1280, resH: 800)
        #expect(summary == "“Save” (button) at 640,400")
    }

    @Test func groundingControlsDropsOffDisplayAndReturnsNilWhenEmpty() {
        let display = CGRect(x: 0, y: 0, width: 1280, height: 800)
        let offscreen = [AXElementResolver.Match(center: CGPoint(x: 5000, y: 5000), role: "AXButton", title: "Ghost", score: 0)]
        #expect(CascadeAppModel.groundingControls(offscreen, display: display, resW: 1280, resH: 800) == nil)
    }

    @Test func noEffectAuditDetailHashesControlsButModelNotesKeepLabels() {
        let phrase = "Aperture-Delta payroll seed"
        let display = CGRect(x: 0, y: 0, width: 1280, height: 800)
        let controls = [
            AXElementResolver.Match(center: CGPoint(x: 640, y: 400), role: "AXButton", title: phrase, score: 0),
        ]
        let labels = AXElementResolver.interactableSummary(controls)!
        let coords = CascadeAppModel.groundingControls(controls, display: display, resW: 1280, resH: 800)!

        #expect(labels.contains(phrase))
        #expect(coords.contains(phrase))

        let labelDetail = CascadeAppModel.assistNoEffectAuditDetail(
            turn: 7,
            status: "pushed-labels",
            noEffectStreak: 1,
            controlCount: controls.count,
            labels: labels
        )
        #expect(labelDetail.contains("turn=7"))
        #expect(labelDetail.contains("controlCount=1"))
        #expect(labelDetail.contains("recoveryAction=recapture"))
        #expect(labelDetail.contains("labelsHash=\(CascadeAppModel.auditHash(labels))"))
        #expect(!labelDetail.contains(phrase))
        #expect(!labelDetail.contains(labels))

        let coordDetail = CascadeAppModel.assistNoEffectAuditDetail(
            turn: 8,
            status: "pushed-coords",
            noEffectStreak: 2,
            controlCount: controls.count,
            coords: coords
        )
        #expect(coordDetail.contains("coordsHash=\(CascadeAppModel.auditHash(coords))"))
        #expect(!coordDetail.contains(phrase))
        #expect(!coordDetail.contains(coords))
    }

    @Test func groundMissAuditDetailHashesMissedTargetAndControlLabels() {
        let phrase = "Aperture-Delta payroll seed"
        let controls = [
            AXElementResolver.Match(center: .zero, role: "AXTextField", title: phrase, score: 0),
        ]
        let labels = AXElementResolver.interactableSummary(controls)!

        let detail = CascadeAppModel.groundMissAuditDetail(
            turn: 4,
            missedTarget: phrase,
            controlCount: controls.count,
            labels: labels
        )

        #expect(labels.contains(phrase))
        #expect(detail.contains("turn=4"))
        #expect(detail.contains("controlCount=1"))
        #expect(detail.contains("missedTargetHash=\(CascadeAppModel.auditHash(phrase))"))
        #expect(detail.contains("labelsHash=\(CascadeAppModel.auditHash(labels))"))
        #expect(!detail.contains(phrase))
        #expect(!detail.contains(labels))
    }

    @Test func ocrMarksAuditDetailHashesMarksButModelNoteKeepsText() {
        let phrase = "Aperture-Delta payroll seed"
        let boxes = [
            ScreenTextRecognizer.TextBox(text: phrase, boundingBox: CGRect(x: 0.1, y: 0.7, width: 0.4, height: 0.1)),
            ScreenTextRecognizer.TextBox(text: "Continue", boundingBox: CGRect(x: 0.1, y: 0.5, width: 0.2, height: 0.1)),
        ]
        let marks = ScreenTextRecognizer.setOfMarks(boxes)!

        let detail = CascadeAppModel.ocrMarksAuditDetail(
            turn: 5,
            axControlCount: 2,
            ocrLineCount: boxes.count,
            marks: marks
        )

        #expect(marks.contains(phrase))
        #expect(detail.contains("turn=5"))
        #expect(detail.contains("controlCount=2"))
        #expect(detail.contains("ocrLineCount=2"))
        #expect(detail.contains("ocrMarksHash=\(CascadeAppModel.auditHash(marks))"))
        #expect(!detail.contains(phrase))
        #expect(!detail.contains(marks))
    }
}
