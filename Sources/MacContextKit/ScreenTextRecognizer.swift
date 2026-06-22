import CoreGraphics
import Foundation
import ImageIO
import OSLog
import Vision

/// On-device OCR over a captured frame. No network, no provider — this turns a
/// local screenshot into searchable text so the Reel and Q&A can ground in what
/// was actually on screen. Lives in `MacContextKit` because it is part of local
/// observation, not agent action.
public enum ScreenTextRecognizer {
    private static let logger = Logger(subsystem: "com.humain.cascade", category: "ocr")

    /// Recognizes text in a PNG-encoded frame.
    ///
    /// Declared `async` and non-isolated on purpose: callers on the main actor
    /// `await` this so the CPU-bound Vision pass runs off the main thread and the
    /// UI stays smooth. Returns recognized lines joined by newlines, or `""` when
    /// nothing is read.
    public static func recognize(inPNG data: Data, level: VNRequestTextRecognitionLevel = .accurate) async -> String {
        guard let cgImage = decode(imageData: data) else {
            logger.error("OCR skipped — could not decode PNG frame.")
            return ""
        }
        return recognize(in: cgImage, level: level)
    }

    /// Synchronous Vision recognition over a `CGImage`. Safe to call from any
    /// thread; the request handler holds no shared state.
    ///
    /// `level` lets the always-on recorder pick the cheap `.fast` model for the
    /// common case where the Accessibility channel already owns the text, and
    /// reserve the slow `.accurate` model for frames where OCR is load-bearing.
    public static func recognize(in cgImage: CGImage, level: VNRequestTextRecognitionLevel = .accurate) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        // Language correction is an extra NLP pass that mostly helps the slower
        // `.accurate` model; on the cheap `.fast` insurance pass it's wasted cost.
        request.usesLanguageCorrection = (level == .accurate)

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            logger.error("OCR failed: \(error.localizedDescription, privacy: .public)")
            return ""
        }

        guard let observations = request.results else { return "" }
        let lines = observations.compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }

    // MARK: - On-device grounding (B4): locate recorded text on the live screen

    /// A recognized text line and where it sits — `boundingBox` is Vision-normalized
    /// (0…1, LOWER-LEFT origin, matching AppKit's bottom-left display points, so no
    /// Y-flip is needed when mapping to a screen).
    public struct TextBox: Sendable, Equatable {
        public let text: String
        public let boundingBox: CGRect
        public init(text: String, boundingBox: CGRect) {
            self.text = text
            self.boundingBox = boundingBox
        }
    }

    /// On-device OCR returning each line WITH its bounding box — the perception half
    /// of the B4 grounder: re-find a recorded click target by its text on a live
    /// frame, with NO model round-trip and NO Accessibility (so it works on the
    /// canvas/Electron apps where the AX tree is blind). Accepts PNG or JPEG.
    public static func recognizeBoxes(inImageData data: Data, level: VNRequestTextRecognitionLevel = .accurate) -> [TextBox] {
        guard let cgImage = decode(imageData: data) else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        request.usesLanguageCorrection = (level == .accurate)
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        guard (try? handler.perform([request])) != nil, let observations = request.results else { return [] }
        return observations.compactMap { obs in
            guard let text = obs.topCandidates(1).first?.string else { return nil }
            return TextBox(text: text, boundingBox: obs.boundingBox)
        }
    }

    /// The text line that best matches a recorded `anchor`, or nil when nothing
    /// scores — vague text must never hijack a click. Pure + unit-pinned. Scoring
    /// mirrors AXElementResolver.matchScore (exact 3 / contains 2 / word-overlap 1+)
    /// so the OCR tier ranks text the same way the AX tier does.
    public static func bestMatch(anchor: String, in boxes: [TextBox]) -> TextBox? {
        let needle = normalizeText(anchor)
        guard !needle.isEmpty else { return nil }
        var best: TextBox?
        var bestScore = 0.0
        for box in boxes {
            let score = matchScore(needle: needle, candidate: normalizeText(box.text))
            if score > bestScore { bestScore = score; best = box }
        }
        return best
    }

    static func normalizeText(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func matchScore(needle: String, candidate: String) -> Double {
        guard !needle.isEmpty, !candidate.isEmpty else { return 0 }
        if candidate == needle { return 3 }
        if candidate.contains(needle) || needle.contains(candidate) { return 2 }
        let nWords = Set(needle.split(separator: " "))
        let cWords = Set(candidate.split(separator: " "))
        guard !nWords.isEmpty else { return 0 }
        let overlap = Double(nWords.intersection(cWords).count) / Double(nWords.count)
        return overlap >= 0.6 ? 1 + overlap : 0
    }

    private static func decode(imageData data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        return image
    }
}
