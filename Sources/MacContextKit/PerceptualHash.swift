import CoreGraphics
import Foundation

/// A cheap perceptual fingerprint of a frame, used to drop near-identical frames
/// so an idle screen doesn't become a new "moment" every second. This is what
/// bounds storage in the continuous recorder — only frames whose hash differs
/// meaningfully from the last stored one become moments.
///
/// Implemented as a **dHash** (difference hash): downscale to a tiny grayscale
/// image and encode whether each pixel is brighter than its right-hand neighbor.
/// dHash is robust to brightness/scale shifts and produces a `UInt64` we can
/// compare with a Hamming distance.
///
/// Determinism matters: the downscale uses a CPU `CGContext` (not a GPU-backed
/// `CIContext`), so the same image yields the same hash on every machine and run.
/// That is what makes the unit tests reliable.
public enum PerceptualHash {
    /// dHash grid is `(width + 1) x height`: each row compares adjacent columns,
    /// yielding `width` bits per row. 9x8 → 8x8 = 64 comparisons → one `UInt64`.
    private static let width = 9
    private static let height = 8

    /// Below or equal to this Hamming distance, two frames are "the same screen"
    /// and the newer one is dropped. Tuned so cursor blinks / clock ticks don't
    /// register but real content changes do.
    public static let defaultSkipThreshold = 6

    /// Computes the dHash of a frame. Safe to call from any thread.
    public static func dHash(_ image: CGImage) -> UInt64 {
        guard let pixels = grayscaleSamples(from: image) else { return 0 }
        var hash: UInt64 = 0
        var bit = 0
        for row in 0..<height {
            let base = row * width
            for col in 0..<(width - 1) {
                if pixels[base + col] < pixels[base + col + 1] {
                    hash |= (1 << UInt64(bit))
                }
                bit += 1
            }
        }
        return hash
    }

    /// Number of differing bits between two hashes. `0` means identical.
    public static func hamming(_ lhs: UInt64, _ rhs: UInt64) -> Int {
        (lhs ^ rhs).nonzeroBitCount
    }

    /// Whether `candidate` is similar enough to `previous` that it should be
    /// dropped as a duplicate.
    public static func isDuplicate(_ candidate: UInt64, of previous: UInt64, threshold: Int = defaultSkipThreshold) -> Bool {
        hamming(candidate, previous) <= threshold
    }

    /// Renders `image` into a `width x height` 8-bit grayscale buffer using a CPU
    /// context with low-quality interpolation (fast, and identical across runs).
    private static func grayscaleSamples(from image: CGImage) -> [UInt8]? {
        let count = width * height
        var buffer = [UInt8](repeating: 0, count: count)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: &buffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}
