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

    // MARK: - Region grid (change-aware dedup)

    /// The screen as a `grid x grid` of independently-hashed regions. A whole-
    /// frame hash dilutes a small change (one new chat message) across 64 bits
    /// and drops the frame as "the same screen"; per-region hashes make any
    /// locally meaningful change defeat the dedup, so it's never skipped.
    public static let gridDimension = 3

    /// Per-region skip threshold. A region is 1/9 of the screen, so its 64 bits
    /// are far more sensitive than the whole-frame hash — slightly tighter than
    /// the global threshold, still loose enough for cursor blinks.
    public static let regionSkipThreshold = 5

    /// dHashes of the `gridDimension²` regions of the frame, row-major.
    public static func gridHashes(_ image: CGImage) -> [UInt64] {
        let grid = gridDimension
        // One downscale pass for the whole frame: each region gets its own
        // 9x8 sample block, so the buffer is (9*grid) x (8*grid) grayscale.
        let bufferWidth = width * grid
        let bufferHeight = height * grid
        var buffer = [UInt8](repeating: 0, count: bufferWidth * bufferHeight)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: &buffer,
            width: bufferWidth,
            height: bufferHeight,
            bitsPerComponent: 8,
            bytesPerRow: bufferWidth,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return Array(repeating: 0, count: grid * grid)
        }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: bufferWidth, height: bufferHeight))

        var hashes: [UInt64] = []
        hashes.reserveCapacity(grid * grid)
        for regionRow in 0..<grid {
            for regionCol in 0..<grid {
                var hash: UInt64 = 0
                var bit = 0
                for row in 0..<height {
                    let bufferRow = regionRow * height + row
                    let base = bufferRow * bufferWidth + regionCol * width
                    for col in 0..<(width - 1) {
                        if buffer[base + col] < buffer[base + col + 1] {
                            hash |= (1 << UInt64(bit))
                        }
                        bit += 1
                    }
                }
                hashes.append(hash)
            }
        }
        return hashes
    }

    /// Folds the per-region grid hashes into one 64-bit frame signature, reusing
    /// the grid's single downscale instead of paying for a second whole-frame
    /// `dHash` pass on the hot path. Stored as a moment's `frameHash`; dedup keys
    /// off the grid itself, so this fold only needs to be stable and well-
    /// distributed (the per-index rotation keeps two frames that differ only in
    /// *which* region changed from XOR-cancelling to the same value).
    public static func combinedHash(_ grid: [UInt64]) -> UInt64 {
        var result: UInt64 = 0
        for (index, hash) in grid.enumerated() {
            let r = UInt64((index * 7) % 64)
            result ^= (r == 0 ? hash : (hash << r) | (hash >> (64 - r)))
        }
        return result
    }

    /// Duplicate only when EVERY region is within threshold — one changed
    /// region (a new message, a fresh dialog) is enough to keep the frame.
    public static func isDuplicateGrid(
        _ candidate: [UInt64], of previous: [UInt64], threshold: Int = regionSkipThreshold
    ) -> Bool {
        guard candidate.count == previous.count, !candidate.isEmpty else { return false }
        return zip(candidate, previous).allSatisfy { hamming($0, $1) <= threshold }
    }

    /// Returns row-major grid cells whose regional hashes changed beyond
    /// `threshold`, mapped into image coordinates for later cropped OCR.
    public static func diffRegions(
        current: [UInt64],
        previous: [UInt64],
        threshold: Int = regionSkipThreshold,
        imageSize: CGSize
    ) -> [CGRect] {
        let grid = gridDimension
        guard current.count == previous.count, current.count == grid * grid else { return [] }

        let cellWidth = imageSize.width / CGFloat(grid)
        let cellHeight = imageSize.height / CGFloat(grid)

        var regions: [CGRect] = []
        regions.reserveCapacity(current.count)
        for index in current.indices where hamming(current[index], previous[index]) > threshold {
            let row = index / grid
            let col = index % grid
            let minX = CGFloat(col) * cellWidth
            let minY = CGFloat(row) * cellHeight
            let maxX = col == grid - 1 ? imageSize.width : CGFloat(col + 1) * cellWidth
            let maxY = row == grid - 1 ? imageSize.height : CGFloat(row + 1) * cellHeight
            regions.append(CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
        }
        return regions
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
