import AppKit
import CoreGraphics
import Foundation
import ProviderKit
import Testing

@testable import AppShell
@testable import ComputerUseKit

/// d16 crop-and-refine (ScreenSpot-Pro / DRS-GUI): the visual grounder must see
/// a CROP of the uncertain region at native pixel resolution — never the
/// downscaled full screen — and the crop-local answer must map back to
/// display-local AppKit points through the d01 `CoordinateTransform`. These pin
/// the region gate, the typed crop plan, the result remap, and the wired
/// MixtureGrounder path (flag-gated, full-screen fallback intact).
struct CropRefineGroundingTests {
    // MARK: uncertain-region gate

    @Test func weakMatchesUnionIntoASubScreenCropRegion() throws {
        let index = ScreenElementIndex.build(from: [
            candidate(label: "Stop", bounds: bounds(200, 500, 60, 20)),
            candidate(label: "Stop recording", bounds: bounds(280, 530, 120, 20)),
        ])

        let region = LocalRegionNarrower.uncertainRegion(
            for: "the stop control",
            in: index,
            displayWidthPoints: 1_440,
            displayHeightPoints: 900
        )

        let unwrapped = try #require(region)
        // Contains all the evidence, padded.
        #expect(unwrapped.contains(CGRect(x: 200, y: 500, width: 200, height: 50)))
        // Meaningfully smaller than the screen (the whole point of the crop).
        #expect(unwrapped.width * unwrapped.height <= 1_440 * 900 * 0.60)
        // Stays on the display.
        #expect(CGRect(x: 0, y: 0, width: 1_440, height: 900).contains(unwrapped))
    }

    @Test func noLocalEvidenceMeansNoCropRegion() {
        let index = ScreenElementIndex.build(from: [
            candidate(label: "Save", bounds: bounds(200, 500, 60, 20)),
            candidate(label: "Cancel", bounds: bounds(300, 500, 60, 20)),
        ])

        #expect(LocalRegionNarrower.uncertainRegion(
            for: "the emerald waveform",
            in: index,
            displayWidthPoints: 1_440,
            displayHeightPoints: 900
        ) == nil)
        #expect(LocalRegionNarrower.uncertainRegion(
            for: "anything",
            in: [],
            displayWidthPoints: 1_440,
            displayHeightPoints: 900
        ) == nil)
    }

    @Test func screenSpanningEvidenceRefusesToCrop() {
        // The best match ~fills the screen: a crop would not raise effective
        // resolution, so the gate must abstain and leave full-screen grounding.
        let index = ScreenElementIndex.build(from: [
            candidate(label: "Stop", bounds: bounds(20, 20, 1_400, 860)),
        ])

        #expect(LocalRegionNarrower.uncertainRegion(
            for: "the stop control",
            in: index,
            displayWidthPoints: 1_440,
            displayHeightPoints: 900
        ) == nil)
    }

    // MARK: typed crop plan

    @Test func cropPlanCropsBackingPixelsAndMapsBothWaysThroughTheTypedTransforms() throws {
        // 800×600 points captured at 2× backing (1600×1200 px) — the Retina
        // case the d01 transform exists for.
        let screenshot = try #require(Self.solidJPEG(width: 1_600, height: 1_200))
        let plan = try #require(LocalRegionNarrower.cropRefinePlan(
            screenshot: screenshot,
            region: CGRect(x: 100, y: 200, width: 320, height: 200),
            displayWidthPoints: 800,
            displayHeightPoints: 600
        ))

        #expect(plan.cropWidthPoints == 320)
        #expect(plan.cropHeightPoints == 200)
        // Crop rect in backing pixels: ×2, top-left origin (y = 1200 − (200+200)·2).
        #expect(plan.transform.cropInBackingPixels.rect == CGRect(x: 200, y: 400, width: 640, height: 400))
        // The JPEG really is the crop at native backing resolution.
        let cropDims = try #require(Self.jpegDimensions(plan.croppedJPEG))
        #expect(cropDims == CGSize(width: 640, height: 400))

        // Crop-local grounder output maps back by the typed chain, not a
        // guessed scale: (32,20) in the crop is (132,220) on the display.
        let mapped = try #require(plan.displayPoint(fromCropLocalPoint: CGPoint(x: 32, y: 20)))
        #expect(abs(mapped.x - 132) < 0.01)
        #expect(abs(mapped.y - 220) < 0.01)

        // Rect round trips: the whole crop is the region; the region is the crop.
        let displayRect = try #require(plan.displayRect(
            fromCropLocalRect: CGRect(x: 0, y: 0, width: 320, height: 200)
        ))
        #expect(abs(displayRect.minX - 100) < 0.01 && abs(displayRect.minY - 200) < 0.01)
        #expect(abs(displayRect.width - 320) < 0.01 && abs(displayRect.height - 200) < 0.01)
        let cropRect = try #require(plan.cropLocalRect(
            fromDisplayRect: CGRect(x: 100, y: 200, width: 320, height: 200)
        ))
        #expect(abs(cropRect.minX) < 0.01 && abs(cropRect.minY) < 0.01)
        #expect(abs(cropRect.width - 320) < 0.01 && abs(cropRect.height - 200) < 0.01)
    }

    @Test func fullScreenRegionProducesNoPlan() throws {
        let screenshot = try #require(Self.solidJPEG(width: 1_600, height: 1_200))
        #expect(LocalRegionNarrower.cropRefinePlan(
            screenshot: screenshot,
            region: CGRect(x: 0, y: 0, width: 800, height: 600),
            displayWidthPoints: 800,
            displayHeightPoints: 600
        ) == nil)
        #expect(LocalRegionNarrower.cropRefinePlan(
            screenshot: Data([0x00, 0x01]),
            region: CGRect(x: 100, y: 200, width: 320, height: 200),
            displayWidthPoints: 800,
            displayHeightPoints: 600
        ) == nil)
    }

    // MARK: result remap

    @Test func cropRefinedResultRemapsCandidatesAndRebuildsTheAuditChain() throws {
        let screenshot = try #require(Self.solidJPEG(width: 1_600, height: 1_200))
        let plan = try #require(LocalRegionNarrower.cropRefinePlan(
            screenshot: screenshot,
            region: CGRect(x: 100, y: 200, width: 320, height: 200),
            displayWidthPoints: 800,
            displayHeightPoints: 600
        ))
        let cropLocal = GroundingResult(
            candidates: [
                GroundingCandidate(
                    point: CGPoint(x: 32, y: 20),
                    confidence: 0.9,
                    source: .uiTars,
                    coordinateSpace: .displayLocalAppKitPoints,
                    reason: "ui-tars coordinate",
                    displayBounds: CGRect(x: 12, y: 0, width: 40, height: 40)
                )
            ],
            selectedIndex: 0
        )

        let refined = MixtureGrounder.cropRefinedResult(cropLocal, plan: plan)

        let selected = try #require(refined.selectedCandidate)
        let point = try #require(selected.point)
        #expect(abs(point.x - 132) < 0.01 && abs(point.y - 220) < 0.01)
        #expect(selected.reason == "ui-tars coordinate crop_refined")
        let chain = try #require(selected.coordinateChain)
        // The rebuilt chain describes the REAL screenshot geometry + true crop.
        #expect(chain.screenFrame == CGRect(x: 0, y: 0, width: 800, height: 600))
        #expect(chain.backingPixelSize == CGSize(width: 1_600, height: 1_200))
        #expect(chain.cropRectInBackingPixels == CGRect(x: 200, y: 400, width: 640, height: 400))
        let tokens = chain.auditTokens(rawModel: nil).joined(separator: " ")
        #expect(tokens.contains("cropPX=200.00"))
        #expect(tokens.contains("cropPW=640.00"))
        #expect(tokens.contains("mappedX=132.00"))
        #expect(tokens.contains("mappedY=220.00"))
    }

    // MARK: wired MixtureGrounder path

    @Test func mixtureGrounderGroundsTheCropAndMapsThePointBack() async throws {
        let screenshot = try #require(Self.solidJPEG(width: 1_600, height: 1_200))
        let recorder = GrounderCallRecorder()
        let grounder = MixtureGrounder(
            base: CropAwareGrounderStub(recorder: recorder, cropLocalPoint: CGPoint(x: 32, y: 20)),
            skills: AppSkillRegistry(),
            axPickerEnabled: true,
            cropRefineRegionOverride: { _, _, _, _ in
                CGRect(x: 100, y: 200, width: 320, height: 200)
            }
        )

        let point = await grounder.ground(
            screenshot: screenshot,
            target: "zqx nonexistent d16 target",
            displayWidthPoints: 800,
            displayHeightPoints: 600
        )

        let mapped = try #require(point)
        #expect(abs(mapped.x - 132) < 0.01 && abs(mapped.y - 220) < 0.01)
        // The grounder was asked about the CROP, not the full screen.
        let call = try #require(await recorder.lastCall())
        #expect(call.declaredWidth == 320)
        #expect(call.declaredHeight == 200)
        #expect(Self.jpegDimensions(call.screenshot) == CGSize(width: 640, height: 400))
    }

    @Test func flagOffKeepsTheFullScreenPathByteIdentical() async throws {
        let screenshot = try #require(Self.solidJPEG(width: 1_600, height: 1_200))
        let recorder = GrounderCallRecorder()
        let grounder = MixtureGrounder(
            base: CropAwareGrounderStub(recorder: recorder, cropLocalPoint: CGPoint(x: 32, y: 20)),
            skills: AppSkillRegistry(),
            axPickerEnabled: false,
            cropRefineRegionOverride: { _, _, _, _ in
                CGRect(x: 100, y: 200, width: 320, height: 200)
            }
        )

        _ = await grounder.ground(
            screenshot: screenshot,
            target: "zqx nonexistent d16 target",
            displayWidthPoints: 800,
            displayHeightPoints: 600
        )

        let call = try #require(await recorder.lastCall())
        // Full screen, full declared display — the shipped path untouched.
        #expect(call.declaredWidth == 800)
        #expect(call.declaredHeight == 600)
        #expect(call.screenshot == screenshot)
    }

    // MARK: helpers

    private func candidate(
        label: String,
        bounds: ScreenElementIndex.Bounds,
        source: ScreenElementIndex.Source = .ocr,
        confidence: Double = 0.9,
        trust: Double? = 0.45,
        clickSafety: ScreenElementIndex.ClickSafety? = .passive
    ) -> ScreenElementIndex.Candidate {
        ScreenElementIndex.Candidate(
            bounds: bounds,
            label: label,
            role: .text,
            source: source,
            confidence: confidence,
            trust: trust,
            clickSafety: clickSafety
        )
    }

    private func bounds(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> ScreenElementIndex.Bounds {
        ScreenElementIndex.Bounds(x: x, y: y, width: width, height: height)
    }

    static func solidJPEG(width: Int, height: Int) -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
    }

    static func jpegDimensions(_ data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return CGSize(width: width, height: height)
    }
}

private actor GrounderCallRecorder {
    struct Call {
        let screenshot: Data
        let declaredWidth: Int
        let declaredHeight: Int
    }

    private var calls: [Call] = []

    func record(_ call: Call) {
        calls.append(call)
    }

    func lastCall() -> Call? {
        calls.last
    }
}

/// Returns a fixed crop-local point for crop-sized requests and nothing for
/// full-screen ones, so the test proves WHICH image the mixture handed over.
private struct CropAwareGrounderStub: VisualGrounder {
    let recorder: GrounderCallRecorder
    let cropLocalPoint: CGPoint

    func ground(
        screenshot: Data, target: String, displayWidthPoints: Int, displayHeightPoints: Int
    ) async -> CGPoint? {
        await groundResult(
            screenshot: screenshot, target: target,
            displayWidthPoints: displayWidthPoints, displayHeightPoints: displayHeightPoints
        ).selectedPoint
    }

    func groundResult(
        screenshot: Data, target: String, displayWidthPoints: Int, displayHeightPoints: Int
    ) async -> GroundingResult {
        await recorder.record(.init(
            screenshot: screenshot,
            declaredWidth: displayWidthPoints,
            declaredHeight: displayHeightPoints
        ))
        return GroundingResult(
            candidates: [
                GroundingCandidate(
                    point: cropLocalPoint,
                    confidence: 0.95,
                    source: .uiTars,
                    coordinateSpace: .displayLocalAppKitPoints,
                    reason: "stub"
                )
            ],
            selectedIndex: 0
        )
    }
}
