import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
@testable import MacContextKit
import Testing
import UniformTypeIdentifiers
import Vision

@Test
func recognizesRenderedText() async {
    let png = renderPNG(text: "CASCADE OCR 2026", width: 640, height: 200)
    let result = await ScreenTextRecognizer.recognize(inPNG: png)
    #expect(result.uppercased().contains("CASCADE"))
}

@Test
func fastLevelStillRecognizesText() async {
    // The recorder runs `.fast` on rich-AX frames as a cheap insurance pass;
    // it must still read high-contrast on-screen text.
    let png = renderPNG(text: "CASCADE FAST", width: 640, height: 200)
    let result = await ScreenTextRecognizer.recognize(inPNG: png, level: .fast)
    #expect(result.uppercased().contains("CASCADE"))
}

@Test
func emptyDataRecognizesNothing() async {
    let result = await ScreenTextRecognizer.recognize(inPNG: Data())
    #expect(result.isEmpty)
}

@Test
func regionOfInterestIsClippedAndBoxesStayInFullFrameSpace() {
    let clipped = ScreenTextRecognizer.clippedRegionOfInterest(CGRect(x: -0.2, y: 0.25, width: 0.7, height: 0.9))

    #expect(abs((clipped?.minX ?? 0) - 0) <= 0.0001)
    #expect(abs((clipped?.minY ?? 0) - 0.25) <= 0.0001)
    #expect(abs((clipped?.width ?? 0) - 0.5) <= 0.0001)
    #expect(abs((clipped?.height ?? 0) - 0.75) <= 0.0001)
    let fullFrame = ScreenTextRecognizer.fullFrameBoundingBox(
        CGRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2),
        regionOfInterest: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
    )
    #expect(fullFrame == CGRect(x: 0.5, y: 0.5, width: 0.1, height: 0.1))
}

@Test
func thumbnailDecodeHonorsMaxDimension() {
    let png = renderPNG(text: "CASCADE THUMBNAIL", width: 1200, height: 400)
    let size = ScreenTextRecognizer.decodedImageSize(imageData: png, maxDecodeDimension: 300)

    #expect(size != nil)
    if let size {
        #expect(max(size.width, size.height) <= 300)
    }
}

@Test
func regionOfInterestOCRExcludesTextOutsideRegion() async {
    let png = renderTwoColumnPNG(left: "LEFTTOKEN", right: "RIGHTTOKEN", width: 1000, height: 260)
    let fullFrame = await ScreenTextRecognizer.recognize(inPNG: png, level: .accurate).uppercased()
    guard fullFrame.contains("LEFTTOKEN"), fullFrame.contains("RIGHTTOKEN") else {
        return
    }
    let result = await ScreenTextRecognizer.recognize(
        inPNG: png,
        level: .accurate,
        regionOfInterest: CGRect(x: 0, y: 0, width: 0.46, height: 1)
    ).uppercased()

    #expect(result.contains("LEFTTOKEN"))
    #expect(!result.contains("RIGHTTOKEN"))
}

// MARK: - B4 on-device OCR grounding

private func box(_ text: String, _ rect: CGRect = CGRect(x: 0, y: 0, width: 0.1, height: 0.1)) -> ScreenTextRecognizer.TextBox {
    ScreenTextRecognizer.TextBox(text: text, boundingBox: rect)
}

@Test
func bestMatchPicksExactOverPartialAndRejectsNoise() {
    let boxes = [box("Delete"), box("Send Message"), box("Send"), box("Reply All")]
    // Exact label beats the containing "Send Message".
    #expect(ScreenTextRecognizer.bestMatch(anchor: "Send", in: boxes)?.text == "Send")
    // No credible match → nil, so the caller falls through to Claude vision / pixel
    // rather than letting vague text hijack the click.
    #expect(ScreenTextRecognizer.bestMatch(anchor: "Compose", in: boxes) == nil)
    #expect(ScreenTextRecognizer.bestMatch(anchor: "", in: boxes) == nil)
}

@Test
func ocrMatchScoreMirrorsAXTiers() {
    #expect(ScreenTextRecognizer.matchScore(needle: "send", candidate: "send") == 3)
    #expect(ScreenTextRecognizer.matchScore(needle: "send", candidate: "send message") == 2)
    #expect(ScreenTextRecognizer.matchScore(needle: "send", candidate: "delete") == 0)
}

@Test
func recognizeBoxesReturnsTextWithNormalizedBoundingBox() async {
    // The perception half of the grounder: rendered text must come back WITH a usable
    // normalized box, and bestMatch must locate it (no real screen capture needed).
    let png = renderPNG(text: "INVOICE 4821", width: 640, height: 200)
    let boxes = await Task.detached { ScreenTextRecognizer.recognizeBoxes(inImageData: png) }.value
    #expect(!boxes.isEmpty)
    let match = ScreenTextRecognizer.bestMatch(anchor: "INVOICE", in: boxes)
    let found = try? #require(match)
    if let found {
        // Vision boxes are normalized 0…1; a real match sits inside the frame.
        #expect(found.boundingBox.minX >= 0 && found.boundingBox.maxX <= 1)
        #expect(found.boundingBox.minY >= 0 && found.boundingBox.maxY <= 1)
        #expect(found.boundingBox.width > 0 && found.boundingBox.height > 0)
    }
}

@Test
func recognizeDetailedBoxesReturnsLineAndTokenGeometry() async {
    let png = renderPNG(text: "TOTAL DUE 443355", width: 900, height: 220)
    let detailed = await Task.detached {
        ScreenTextRecognizer.recognizeDetailedBoxes(inImageData: png, level: .accurate)
    }.value

    guard !detailed.lineBoxes.isEmpty else { return }
    #expect(detailed.lineBoxes.first?.text.uppercased().contains("TOTAL") == true)
    if !detailed.tokenBoxes.isEmpty {
        #expect(detailed.tokenBoxes.contains { $0.text.uppercased().contains("TOTAL") })
        #expect(detailed.tokenBoxes.allSatisfy {
            $0.boundingBox.minX >= 0 && $0.boundingBox.maxX <= 1 &&
            $0.boundingBox.minY >= 0 && $0.boundingBox.maxY <= 1
        })
    }
}

// MARK: - OCR Set-of-Marks (planner perception on canvas / sparse-AX surfaces)

@Test
func positionBucketsMapVisionBoxToHumanQuadrant() {
    // Vision boxes are 0…1, LOWER-LEFT origin → a high midY sits at the TOP.
    #expect(ScreenTextRecognizer.position(of: CGRect(x: 0.45, y: 0.45, width: 0.1, height: 0.1)) == "middle center")
    #expect(ScreenTextRecognizer.position(of: CGRect(x: 0.0, y: 0.9, width: 0.1, height: 0.05)) == "top left")
    #expect(ScreenTextRecognizer.position(of: CGRect(x: 0.9, y: 0.0, width: 0.1, height: 0.05)) == "bottom right")
}

@Test
func setOfMarksListsTextTopToBottomDedupedAndDropsNoise() {
    let boxes = [
        box("Subtitle", CGRect(x: 0.4, y: 0.40, width: 0.2, height: 0.05)),
        box("Presentation Title", CGRect(x: 0.4, y: 0.70, width: 0.2, height: 0.05)),
        box("Subtitle", CGRect(x: 0.4, y: 0.39, width: 0.2, height: 0.05)),  // duplicate text
        box("x", CGRect(x: 0.1, y: 0.10, width: 0.02, height: 0.02)),         // single-char noise
    ]
    let marks = ScreenTextRecognizer.setOfMarks(boxes)
    let s = try? #require(marks)
    if let s {
        // Title (higher on screen) is listed before Subtitle.
        let title = s.range(of: "Presentation Title")
        let sub = s.range(of: "Subtitle")
        #expect(title != nil && sub != nil)
        if let title, let sub { #expect(title.lowerBound < sub.lowerBound) }
        #expect(!s.contains("\"x\""))                                          // 1-char dropped
        #expect(s.components(separatedBy: "\"Subtitle\"").count - 1 == 1)      // deduped
    }
}

@Test
func setOfMarksIsNilWhenNoRealText() {
    #expect(ScreenTextRecognizer.setOfMarks([]) == nil)
    #expect(ScreenTextRecognizer.setOfMarks([box(" "), box("a")]) == nil)  // blank + single char
}

@Test
func setOfMarksDropsLongBodyTextKeepsLabels() {
    let paragraph = "This is a long line of body text that is clearly prose, not a clickable label, and must be dropped"
    let boxes = [
        box("Title", CGRect(x: 0.4, y: 0.70, width: 0.2, height: 0.05)),
        box(paragraph, CGRect(x: 0.4, y: 0.30, width: 0.5, height: 0.1)),
    ]
    let marks = ScreenTextRecognizer.setOfMarks(boxes)
    let s = try? #require(marks)
    if let s {
        #expect(s.contains("\"Title\""))             // short label kept
        #expect(!s.contains("body text"))            // long prose dropped
    }
}

/// Renders high-contrast text into a PNG so the OCR pass has a deterministic,
/// permission-free input — no real screen capture required in tests.
private func renderPNG(text: String, width: Int, height: Int) -> Data {
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!

    // White background.
    context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))

    // Black text — CTLineDraw uses the context fill color when the attributed
    // string carries no explicit foreground color.
    context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
    let font = NSFont.boldSystemFont(ofSize: 72)
    let attributed = NSAttributedString(string: text, attributes: [.font: font])
    let line = CTLineCreateWithAttributedString(attributed)
    context.textPosition = CGPoint(x: 24, y: CGFloat(height) / 2 - 28)
    CTLineDraw(line, context)

    let image = context.makeImage()!
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(
        data as CFMutableData,
        UTType.png.identifier as CFString,
        1,
        nil
    )!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

private func renderTwoColumnPNG(left: String, right: String, width: Int, height: Int) -> Data {
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
    let font = NSFont.boldSystemFont(ofSize: 64)
    let baseline = CGFloat(height) / 2 - 24
    context.textPosition = CGPoint(x: 24, y: baseline)
    CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: left, attributes: [.font: font])), context)
    context.textPosition = CGPoint(x: CGFloat(width) * 0.58, y: baseline)
    CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: right, attributes: [.font: font])), context)

    let image = context.makeImage()!
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(
        data as CFMutableData,
        UTType.png.identifier as CFString,
        1,
        nil
    )!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}
