import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import MacContextKit
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
