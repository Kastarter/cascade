import Foundation
import ImageIO

/// Header-only check that image data is already a JPEG with exactly the given
/// pixel dimensions, so capture paths that pre-size frames at the agent's
/// resolution (see `ComputerUseAgent.captureSize`) can skip the
/// decode → redraw → re-encode round trip on every loop turn.
enum ImageConformance {
    static func isJPEG(_ data: Data, width: Int, height: Int) -> Bool {
        guard data.starts(with: [0xFF, 0xD8]),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int,
              let pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int else { return false }
        return pixelWidth == width && pixelHeight == height
    }
}

/// The Anthropic-recommended Computer Use resolutions, and the one to declare for
/// a given display. Deterministic from the display size, so capture paths can
/// grab the frame at EXACTLY this size as JPEG up front — every consumer
/// (`ComputerUseAgent`, `ElementLocator`) then passes it through untouched
/// instead of decoding and re-encoding a full-resolution PNG.
public enum AgentResolution {
    static let options: [(w: Int, h: Int, ar: Double)] = [
        (1024, 768, 1024.0 / 768.0),   // 4:3
        (1280, 800, 1280.0 / 800.0),   // 16:10 (most Macs)
        (1366, 768, 1366.0 / 768.0),   // ~16:9
    ]

    /// The option whose aspect ratio is closest to the display's (distortion
    /// wrecks the model's X-axis accuracy).
    public static func best(forWidth width: Int, height: Int) -> (w: Int, h: Int) {
        let aspect = Double(width) / Double(max(1, height))
        var best = (w: 1280, h: 800)
        var bestDiff = Double.greatestFiniteMagnitude
        for option in options where abs(aspect - option.ar) < bestDiff {
            bestDiff = abs(aspect - option.ar)
            best = (option.w, option.h)
        }
        return best
    }
}
