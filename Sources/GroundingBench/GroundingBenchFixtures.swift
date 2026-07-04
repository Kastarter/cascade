import CoreGraphics
import CoreText
import Foundation
import ImageIO

public enum GroundingBenchFixtures {
    public static func generate(into directory: URL, jsonlURL: URL? = nil) throws -> [GroundingBenchmarkCase] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let firstFrame = directory.appendingPathComponent("synthetic-submit.png")
        let secondFrame = directory.appendingPathComponent("synthetic-search.png")
        let thirdFrame = directory.appendingPathComponent("synthetic-unlabeled.png")
        let fourthFrame = directory.appendingPathComponent("synthetic-save.png")

        try drawFrame(
            to: firstFrame,
            title: "Submit",
            highlight: CGRect(x: 42, y: 58, width: 118, height: 46),
            fill: CGColor(red: 0.09, green: 0.38, blue: 0.76, alpha: 1)
        )
        try drawFrame(
            to: secondFrame,
            title: "Search",
            highlight: CGRect(x: 168, y: 88, width: 78, height: 38),
            fill: CGColor(red: 0.10, green: 0.54, blue: 0.38, alpha: 1)
        )
        try drawFrame(
            to: thirdFrame,
            title: "Later",
            highlight: CGRect(x: 82, y: 138, width: 92, height: 38),
            fill: CGColor(red: 0.62, green: 0.34, blue: 0.11, alpha: 1)
        )
        try drawFrame(
            to: fourthFrame,
            title: "Save",
            highlight: CGRect(x: 58, y: 120, width: 96, height: 40),
            fill: CGColor(red: 0.44, green: 0.18, blue: 0.58, alpha: 1)
        )

        // Ablation candidates are RECORDED points in the fixture image's pixel space (the
        // same space as expectedBoxOrPoint). The three labeled cases are built so the arms
        // provably diverge: axOnly fails search (no AX candidate -- the canvas case),
        // visionOnly fails save (vision candidate deliberately off-target), hybrid hits
        // both => hybrid_failure_rate 0.0 on fixtures.
        let cases = [
            GroundingBenchmarkCase(
                caseID: "fixture-box-submit",
                framePath: firstFrame.path,
                targetText: "Submit",
                targetHash: "fixture-submit",
                expectedBoxOrPoint: .box(CGRect(x: 42, y: 58, width: 118, height: 46)),
                appBundle: "com.cascade.fixture",
                appName: "Fixture",
                outcome: .accept,
                ablationCandidates: [
                    GroundingAblationCandidate(source: .accessibility, x: 101, y: 81, confidence: 0.94),
                    GroundingAblationCandidate(source: .uiTars, x: 101, y: 81, confidence: 0.82),
                ]
            ),
            GroundingBenchmarkCase(
                caseID: "fixture-point-search",
                framePath: secondFrame.path,
                targetText: "Search",
                targetHash: "fixture-search",
                expectedBoxOrPoint: .point(CGPoint(x: 207, y: 107), radius: 14),
                appBundle: "com.cascade.fixture",
                appName: "Fixture",
                outcome: .accept,
                ablationCandidates: [
                    // Canvas-style case: NO AX candidate, accurate vision candidate.
                    GroundingAblationCandidate(source: .uiTars, x: 207, y: 107, confidence: 0.78)
                ]
            ),
            GroundingBenchmarkCase(
                caseID: "fixture-unlabeled-later",
                framePath: thirdFrame.path,
                targetText: nil,
                targetHash: "fixture-later",
                expectedBoxOrPoint: nil,
                appBundle: "com.cascade.fixture",
                appName: "Fixture",
                outcome: .unlabeled
            ),
            GroundingBenchmarkCase(
                caseID: "fixture-ax-favored-save",
                framePath: fourthFrame.path,
                targetText: "Save",
                targetHash: "fixture-save",
                expectedBoxOrPoint: .box(CGRect(x: 58, y: 120, width: 96, height: 40)),
                appBundle: "com.cascade.fixture",
                appName: "Fixture",
                outcome: .accept,
                ablationCandidates: [
                    // AX-favored case: accurate AX candidate, vision candidate deliberately
                    // outside the expected box (the vision-miss arm case).
                    GroundingAblationCandidate(source: .accessibility, x: 106, y: 140, confidence: 0.91),
                    GroundingAblationCandidate(source: .uiTars, x: 262, y: 34, confidence: 0.66),
                ]
            ),
        ]
        if let jsonlURL {
            try GroundingBenchmarkJSONL.write(cases, to: jsonlURL)
        }
        return cases
    }

    private static func drawFrame(to url: URL, title: String, highlight: CGRect, fill: CGColor) throws {
        let width = 320
        let height = 220
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(gray: 0.96, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(gray: 0.83, alpha: 1))
        context.fill(CGRect(x: 20, y: 24, width: 280, height: 172))
        context.setFillColor(fill)
        context.fill(highlight)
        context.setStrokeColor(CGColor(gray: 0.20, alpha: 1))
        context.stroke(highlight, width: 2)
        draw(title, in: highlight.insetBy(dx: 10, dy: 13), context: context)

        guard let image = context.makeImage() else { return }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        try (out as Data).write(to: url, options: .atomic)
    }

    private static func draw(_ text: String, in rect: CGRect, context: CGContext) {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 18, nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(gray: 1, alpha: 1),
        ]
        let attributed = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attributed)
        context.textPosition = CGPoint(x: rect.minX, y: rect.minY)
        CTLineDraw(line, context)
    }
}
