import CascadeMemory
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum FrameRedactor {
    public struct Metadata: Codable, Equatable, Sendable {
        public let redactionCount: Int
        public let entityTypes: [String]
        public let detectorVersions: [String: String]
        public let wholeFrameDropReason: String?
        public let redactedFrameHash: String?

        public init(
            redactionCount: Int,
            entityTypes: [String],
            detectorVersions: [String: String] = ["pii": PIIDetector.redactionVersion],
            wholeFrameDropReason: String? = nil,
            redactedFrameHash: String? = nil
        ) {
            self.redactionCount = redactionCount
            self.entityTypes = entityTypes
            self.detectorVersions = detectorVersions
            self.wholeFrameDropReason = wholeFrameDropReason
            self.redactedFrameHash = redactedFrameHash
        }
    }

    public struct Result: Sendable {
        public let imageData: Data
        public let boxes: [ScreenTextRecognizer.TextBox]
        public let redactionRects: [CGRect]
        public let metadata: Metadata

        public var redactedText: String {
            ScreenContentStructurer.structure(boxes, topLeftOrigin: false).readingOrderText
        }
    }

    public static func wholeFrameDropReason(
        appName: String,
        bundleIdentifier: String?,
        windowTitle: String?,
        rawText: String,
        policy: CapturePrivacyPolicy = .default
    ) -> String? {
        let decision = policy.decision(
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            windowTitle: windowTitle,
            text: rawText
        )
        return decision.allowed ? nil : decision.reason
    }

    public static func redact(
        imageData: Data,
        boxes: [ScreenTextRecognizer.TextBox],
        policy: CapturePrivacyPolicy = .default,
        compression: CGFloat = 0.6
    ) -> Result? {
        guard let image = decode(imageData) else { return nil }
        var entityTypes = Set<String>()
        var redactedBoxes: [ScreenTextRecognizer.TextBox] = []
        var rects: [CGRect] = []

        for box in boxes {
            let pii = PIIDetector.redact(box.text, includeNames: false, highConfidenceOnly: false)
            // Private mode redacts ALL text so the frame is still recorded (rewind works)
            // but no on-screen text is stored in the clear.
            let keywordSensitive = policy.privateModeEnabled || policy.isSensitiveText(box.text)
            var redactedText = pii.redacted
            if keywordSensitive {
                redactedText = policy.redactingSensitiveKeywords(in: redactedText)
                entityTypes.insert("SENSITIVE_TEXT")
            }
            for finding in pii.findings {
                entityTypes.insert(finding.type.rawValue)
            }
            if keywordSensitive || !pii.findings.isEmpty {
                rects.append(pixelRect(for: box.boundingBox, imageWidth: image.width, imageHeight: image.height))
            }
            redactedBoxes.append(ScreenTextRecognizer.TextBox(
                text: redactedText,
                boundingBox: box.boundingBox,
                confidence: box.confidence
            ))
        }

        guard let redactedImage = draw(image: image, covering: rects),
              let encoded = encodeJPEG(redactedImage, compression: compression) else { return nil }
        let metadata = Metadata(
            redactionCount: rects.count,
            entityTypes: entityTypes.sorted(),
            redactedFrameHash: sha256Hex(encoded)
        )
        return Result(imageData: encoded, boxes: redactedBoxes, redactionRects: rects, metadata: metadata)
    }

    public static func redactedText(_ text: String, policy: CapturePrivacyPolicy = .default) -> String {
        let pii = PIIDetector.redact(text, includeNames: false, highConfidenceOnly: false).redacted
        return policy.redactingSensitiveKeywords(in: pii)
    }

    private static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func draw(image: CGImage, covering rects: [CGRect]) -> CGImage? {
        let width = image.width
        let height = image.height
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(image, in: full)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        for rect in rects {
            context.fill(rect.intersection(full))
        }
        return context.makeImage()
    }

    private static func pixelRect(for normalized: CGRect, imageWidth: Int, imageHeight: Int) -> CGRect {
        let w = CGFloat(imageWidth)
        let h = CGFloat(imageHeight)
        let padding = max(CGFloat(8), min(w, h) * 0.01)
        let rect = CGRect(
            x: normalized.minX * w,
            y: normalized.minY * h,
            width: normalized.width * w,
            height: normalized.height * h
        ).insetBy(dx: -padding, dy: -padding)
        return rect.integral
    }

    private static func encodeJPEG(_ image: CGImage, compression: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality as String: compression
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
