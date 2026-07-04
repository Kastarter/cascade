import AppKit
import CascadeMemory
import CoreGraphics
import CoreText
import Foundation
import ImageIO
@testable import MacContextKit
import PerceptionCore
import Testing
import UniformTypeIdentifiers

@Test
func frameRedactorCoversSensitiveBoxesAndRedactsOCRText() throws {
    let image = renderRedactionFixture(text: "Email jane@example.com", width: 640, height: 240)
    let box = ScreenTextRecognizer.TextBox(
        text: "Email jane@example.com",
        boundingBox: CGRect(x: 0.05, y: 0.35, width: 0.55, height: 0.3)
    )

    let result = try #require(FrameRedactor.redact(imageData: image, boxes: [box]))

    #expect(result.metadata.redactionCount == 1)
    #expect(result.metadata.entityTypes.contains("EMAIL"))
    #expect(result.boxes.first?.text.contains("<EMAIL>") == true)
    #expect(result.boxes.first?.text.contains("jane@example.com") == false)
    let rect = try #require(result.redactionRects.first)
    #expect(rect.width > Double(box.boundingBox.width) * 640)
    #expect(rect.height > Double(box.boundingBox.height) * 240)
    // redactionRects are FrameSpace (top-left); the sampler reads CG bottom-left
    // pixels, so flip the midpoint's y. Same physical pixel as before the retype.
    let mid = rect.midpoint
    #expect(redactedPixelIsDark(result.imageData, at: CGPoint(x: mid.x, y: 240 - mid.y)))
}

// OFF pin: `policyRegions: []` (the only value reachable with
// `cascade.frameRedaction` OFF) must be byte-identical to today's call —
// every new branch short-circuits on isEmpty.
@Test
func emptyPolicyRegionsAreByteIdenticalToDefaultRedaction() throws {
    let image = renderRedactionFixture(text: "Email jane@example.com", width: 640, height: 240)
    let box = ScreenTextRecognizer.TextBox(
        text: "Email jane@example.com",
        boundingBox: CGRect(x: 0.05, y: 0.35, width: 0.55, height: 0.3)
    )
    let base = try #require(FrameRedactor.redact(imageData: image, boxes: [box]))
    let explicitEmpty = try #require(FrameRedactor.redact(imageData: image, boxes: [box], policyRegions: []))
    #expect(base.imageData == explicitEmpty.imageData)
    #expect(base.metadata == explicitEmpty.metadata)
    #expect(base.redactionRects == explicitEmpty.redactionRects)
}

// ON path at the true choke point: a tenant `.redact` policy region blurs its
// pixels, lands in redactionRects, stamps POLICY_REGION into the audit
// manifest, and scrubs any OCR box it overlaps (the FTS/embedding seam).
@Test
func policyRegionBlursPixelsAndRedactsOverlappedText() throws {
    let width = 640
    let height = 240
    let image = renderSolidFixture(width: width, height: height)
    // Benign OCR text (no PII, no keywords) whose Vision box (bottom-left
    // normalized 0.1–0.4 x, 0.4–0.6 y) lies inside the policy region below
    // (top-left FrameSpace pixels: box maps to ~(56, 88, 208, 64) padded).
    let box = ScreenTextRecognizer.TextBox(
        text: "Quarterly totals",
        boundingBox: CGRect(x: 0.1, y: 0.4, width: 0.3, height: 0.2)
    )
    let region = Rect<FrameSpace>(x: 40, y: 80, width: 260, height: 80)

    // Without the region, nothing redacts — the box is benign.
    let plain = try #require(FrameRedactor.redact(imageData: image, boxes: [box]))
    #expect(plain.metadata.redactionCount == 0)
    #expect(plain.boxes.first?.text == "Quarterly totals")

    let result = try #require(FrameRedactor.redact(imageData: image, boxes: [box], policyRegions: [region]))

    #expect(result.redactionRects.contains(region))
    #expect(result.metadata.entityTypes.contains("POLICY_REGION"))
    // Overlapped OCR text is replaced so blur and FTS/embedding agree.
    #expect(result.boxes.first?.text == "<SENSITIVE_TEXT>")
    #expect(result.redactedText.contains("Quarterly") == false)

    // Pixels: black inside the region (corners inset 10px + center), untouched
    // white outside. Sample points are FrameSpace top-left; the sampler is CG
    // bottom-left, so flip y through the image height.
    let inside: [(Double, Double)] = [(50, 90), (290, 90), (50, 150), (290, 150), (170, 120)]
    for (x, y) in inside {
        #expect(redactedPixelIsDark(result.imageData, at: CGPoint(x: x, y: Double(height) - y)), "inside (\(x),\(y))")
    }
    let outside: [(Double, Double)] = [(10, 10), (600, 220), (170, 20), (170, 220)]
    for (x, y) in outside {
        #expect(redactedPixelIsLight(result.imageData, at: CGPoint(x: x, y: Double(height) - y)), "outside (\(x),\(y))")
    }
}

@Test
func frameRedactorDropsWholeFrameWhenPolicySaysPrivate() {
    let policy = CapturePrivacyPolicy(privateModeEnabled: true)
    let reason = FrameRedactor.wholeFrameDropReason(
        appName: "Safari",
        bundleIdentifier: "com.apple.Safari",
        windowTitle: "Inbox",
        rawText: "ordinary text",
        policy: policy
    )
    #expect(reason == "private_mode")
}

@Test
func frameRedactorReportsSensitiveKeywordEntity() throws {
    let image = renderRedactionFixture(text: "Password reset", width: 500, height: 180)
    let box = ScreenTextRecognizer.TextBox(
        text: "Password reset",
        boundingBox: CGRect(x: 0.1, y: 0.3, width: 0.5, height: 0.35)
    )
    let result = try #require(FrameRedactor.redact(imageData: image, boxes: [box]))

    #expect(result.metadata.entityTypes.contains("SENSITIVE_TEXT"))
    #expect(result.boxes.first?.text.contains("<SENSITIVE_TEXT>") == true)
}

private func renderRedactionFixture(text: String, width: Int, height: Int) -> Data {
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    let attributed = NSAttributedString(string: text, attributes: [.font: NSFont.boldSystemFont(ofSize: 54)])
    let line = CTLineCreateWithAttributedString(attributed)
    context.textPosition = CGPoint(x: 24, y: CGFloat(height) / 2 - 22)
    CTLineDraw(line, context)
    let image = context.makeImage()!
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

private func renderSolidFixture(width: Int, height: Int) -> Data {
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = context.makeImage()!
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

private func redactedPixelIsLight(_ data: Data, at point: CGPoint) -> Bool {
    guard let pixel = samplePixel(data, at: point) else { return false }
    return pixel[0] > 200 && pixel[1] > 200 && pixel[2] > 200
}

private func samplePixel(_ data: Data, at point: CGPoint) -> [UInt8]? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    var pixel = [UInt8](repeating: 255, count: 4)
    guard let context = CGContext(
        data: &pixel,
        width: 1,
        height: 1,
        bitsPerComponent: 8,
        bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    context.translateBy(x: -point.x.rounded(.down), y: -point.y.rounded(.down))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return pixel
}

private func redactedPixelIsDark(_ data: Data, at point: CGPoint) -> Bool {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return false }
    var pixel = [UInt8](repeating: 255, count: 4)
    guard let context = CGContext(
        data: &pixel,
        width: 1,
        height: 1,
        bitsPerComponent: 8,
        bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return false }
    context.translateBy(x: -point.x.rounded(.down), y: -point.y.rounded(.down))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return pixel[0] < 20 && pixel[1] < 20 && pixel[2] < 20
}
