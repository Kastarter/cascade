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
