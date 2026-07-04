import CascadeMemory
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import PerceptionCore
import UniformTypeIdentifiers

/// `cascade.frameRedaction` — default OFF (absent ⇒ false ⇒ today's capture is
/// byte-identical: the capture-gate `.redact` verdict keeps degrading to drop,
/// and the always-on PII redaction below runs unchanged). Read ONCE at
/// construction (ContextRecorder.Options / CascadeAppModel init), never per frame.
public enum FrameRedactionFlag {
    public static let key = "cascade.frameRedaction"

    public static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key)
    }
}

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
        /// FrameSpace-typed (top-left pixel space) — an untyped or mis-spaced
        /// rect can no longer reach the blur fill (the 34c2efa kill).
        public let redactionRects: [Rect<FrameSpace>]
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

    /// `policyRegions` are tenant-policy `.redact(regions:)` rects (FrameSpace,
    /// top-left) blurred ON TOP of the always-on PII redaction. Empty (the
    /// default, and the only value reachable with `cascade.frameRedaction` OFF)
    /// short-circuits every policy-region branch so this path is today's exact
    /// code — byte-identity pinned in FrameRedactorTests.
    public static func redact(
        imageData: Data,
        boxes: [ScreenTextRecognizer.TextBox],
        policy: CapturePrivacyPolicy = .default,
        compression: CGFloat = 0.6,
        policyRegions: [Rect<FrameSpace>] = []
    ) -> Result? {
        guard let image = decode(imageData) else { return nil }
        var entityTypes = Set<String>()
        var rects: [Rect<FrameSpace>] = []

        // Pass 1: per-box sensitivity (keyword label or PII finding) + text redaction.
        var sensitive = [Bool](repeating: false, count: boxes.count)
        var redactedTexts = [String](repeating: "", count: boxes.count)
        for (i, box) in boxes.enumerated() {
            let pii = PIIDetector.redact(box.text, includeNames: false, highConfidenceOnly: false)
            let keywordSensitive = policy.isSensitiveText(box.text)
            var redactedText = pii.redacted
            if keywordSensitive {
                redactedText = policy.redactingSensitiveKeywords(in: redactedText)
                entityTypes.insert("SENSITIVE_TEXT")
            }
            for finding in pii.findings { entityTypes.insert(finding.type.rawValue) }
            sensitive[i] = keywordSensitive || !pii.findings.isEmpty
            redactedTexts[i] = redactedText
        }

        // Pass 2: a sensitive LABEL leaks its value into the neighbouring OCR box
        // ("Password:" and "102010203*2" are separate boxes). Redact every box that
        // shares a line (vertical overlap) with a sensitive box so the value is covered.
        let seedSensitive = sensitive
        for i in boxes.indices where seedSensitive[i] {
            let a = boxes[i].boundingBox
            for j in boxes.indices where !sensitive[j] {
                let b = boxes[j].boundingBox
                let yOverlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
                if yOverlap > 0.4 * min(a.height, b.height) {
                    sensitive[j] = true
                    redactedTexts[j] = "<SENSITIVE_TEXT>"
                    entityTypes.insert("SENSITIVE_TEXT")
                }
            }
        }

        // Pass 3 (only reachable when `cascade.frameRedaction` wired regions in):
        // a tenant `.redact(regions:)` verdict — any OCR box intersecting a policy
        // region loses its text too, so the blur and FTS/embedding agree, and the
        // regions themselves are appended below so blank-region blur works even
        // with zero OCR boxes.
        if !policyRegions.isEmpty {
            entityTypes.insert("POLICY_REGION")
            for (i, box) in boxes.enumerated() {
                let boxRect = frameRect(
                    visionNormalized: box.boundingBox,
                    imageWidth: image.width,
                    imageHeight: image.height
                )
                if policyRegions.contains(where: { intersects($0, boxRect) }) {
                    sensitive[i] = true
                    redactedTexts[i] = "<SENSITIVE_TEXT>"
                }
            }
        }

        var redactedBoxes: [ScreenTextRecognizer.TextBox] = []
        for (i, box) in boxes.enumerated() {
            if sensitive[i] {
                rects.append(frameRect(visionNormalized: box.boundingBox, imageWidth: image.width, imageHeight: image.height))
            }
            redactedBoxes.append(ScreenTextRecognizer.TextBox(
                text: redactedTexts[i],
                boundingBox: box.boundingBox,
                confidence: box.confidence
            ))
        }

        rects.append(contentsOf: policyRegions)

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

    /// Typed fill: only `Rect<FrameSpace>` can reach `context.fill` — a
    /// mis-spaced rect is a COMPILE error, not raw PII persisted (34c2efa).
    private static func draw(image: CGImage, covering rects: [Rect<FrameSpace>]) -> CGImage? {
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
            context.fill(cgFillRect(rect, imageHeight: height).intersection(full))
        }
        return context.makeImage()
    }

    /// The ONE Vision-normalized (bottom-left) → FrameSpace pixel (top-left)
    /// conversion, preserving today's ±max(8, min(w,h)*0.01) padding and
    /// `.integral`. `.integral` commutes with the integer-height flip applied
    /// back at the fill site, so the blurred pixels are bit-identical to the
    /// old bottom-left `pixelRect` math.
    static func frameRect(visionNormalized normalized: CGRect, imageWidth: Int, imageHeight: Int) -> Rect<FrameSpace> {
        let w = CGFloat(imageWidth)
        let h = CGFloat(imageHeight)
        let padding = max(CGFloat(8), min(w, h) * 0.01)
        let topLeft = CGRect(
            x: normalized.minX * w,
            y: (1 - normalized.maxY) * h,
            width: normalized.width * w,
            height: normalized.height * h
        ).insetBy(dx: -padding, dy: -padding).integral
        return Rect<FrameSpace>(
            x: topLeft.minX,
            y: topLeft.minY,
            width: topLeft.width,
            height: topLeft.height
        )
    }

    /// The ONE FrameSpace (top-left) → CGContext (bottom-left) flip, applied
    /// only at the fill site.
    private static func cgFillRect(_ rect: Rect<FrameSpace>, imageHeight: Int) -> CGRect {
        CGRect(
            x: rect.x,
            y: Double(imageHeight) - rect.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    private static func intersects(_ a: Rect<FrameSpace>, _ b: Rect<FrameSpace>) -> Bool {
        a.x < b.x + b.width && b.x < a.x + a.width
            && a.y < b.y + b.height && b.y < a.y + a.height
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
