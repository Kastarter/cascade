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
        guard let cgImage = decode(png: data) else {
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

    private static func decode(png data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        return image
    }
}
