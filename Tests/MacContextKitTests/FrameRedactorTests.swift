import AppKit
import CascadeMemory
import CoreGraphics
import CoreText
import Foundation
import ImageIO
@testable import MacContextKit
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
    #expect(rect.width > box.boundingBox.width * 640)
    #expect(rect.height > box.boundingBox.height * 240)
    #expect(redactedPixelIsDark(result.imageData, at: CGPoint(x: rect.midX, y: rect.midY)))
}

@Test
func frameRedactorKeepsWholeFrameWhenPolicySaysPrivate() {
    let policy = CapturePrivacyPolicy(privateModeEnabled: true)
    let reason = FrameRedactor.wholeFrameDropReason(
        appName: "Safari",
        bundleIdentifier: "com.apple.Safari",
        windowTitle: "Inbox",
        rawText: "ordinary text",
        policy: policy
    )
    #expect(reason == nil)
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
