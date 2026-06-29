import CoreGraphics
import MacContextKit
import Testing

@Test
func diffRegionsReturnsEmptyForUnchangedGrid() {
    let previous = grid()
    let current = grid()

    #expect(PerceptualHash.diffRegions(current: current, previous: previous, imageSize: CGSize(width: 300, height: 210)).isEmpty)
}

@Test
func diffRegionsReturnsExpectedRectForOneChangedCell() {
    let previous = grid()
    let current = grid(changes: [4: hash(withBits: PerceptualHash.regionSkipThreshold + 1)])

    let regions = PerceptualHash.diffRegions(
        current: current,
        previous: previous,
        imageSize: CGSize(width: 300, height: 210)
    )

    #expect(regions == [CGRect(x: 100, y: 70, width: 100, height: 70)])
}

@Test
func diffRegionsPreservesRowMajorOrderForMultipleChanges() {
    let previous = grid()
    let current = grid(changes: [8: 1, 2: 1, 3: 1])

    let regions = PerceptualHash.diffRegions(
        current: current,
        previous: previous,
        threshold: 0,
        imageSize: CGSize(width: 90, height: 60)
    )

    #expect(regions == [
        CGRect(x: 60, y: 0, width: 30, height: 20),
        CGRect(x: 0, y: 20, width: 30, height: 20),
        CGRect(x: 60, y: 40, width: 30, height: 20)
    ])
}

@Test
func diffRegionsPinsThresholdBoundary() {
    let previous = grid()
    let current = grid(changes: [
        0: hash(withBits: PerceptualHash.regionSkipThreshold),
        1: hash(withBits: PerceptualHash.regionSkipThreshold + 1)
    ])

    let regions = PerceptualHash.diffRegions(
        current: current,
        previous: previous,
        imageSize: CGSize(width: 300, height: 210)
    )

    #expect(regions == [CGRect(x: 100, y: 0, width: 100, height: 70)])
}

@Test
func diffRegionsPinsLastCellToImageEdges() {
    let previous = grid()
    let current = grid(changes: [8: 1])
    let imageSize = CGSize(width: 301, height: 203)

    let regions = PerceptualHash.diffRegions(
        current: current,
        previous: previous,
        threshold: 0,
        imageSize: imageSize
    )

    #expect(regions.count == 1)
    guard let region = regions.first else { return }
    #expect(abs(region.maxX - imageSize.width) < 0.0001)
    #expect(abs(region.maxY - imageSize.height) < 0.0001)
}

@Test
func normalizedChangedRegionMapsMaskToPaddedUnion() {
    let center = PerceptualHash.normalizedChangedRegion(changedCellsMask: 1 << 4, padding: 0)
    #expect(center == CGRect(x: 1.0 / 3.0, y: 1.0 / 3.0, width: 1.0 / 3.0, height: 1.0 / 3.0))

    let clipped = PerceptualHash.normalizedChangedRegion(changedCellsMask: 1 << 0, padding: 0.1)
    #expect(clipped?.minX == 0)
    #expect(clipped?.minY == 0)
    #expect(abs((clipped?.maxX ?? 0) - ((1.0 / 3.0) + 0.1)) <= 0.0001)
    #expect(abs((clipped?.maxY ?? 0) - ((1.0 / 3.0) + 0.1)) <= 0.0001)
}

private func grid(changes: [Int: UInt64] = [:]) -> [UInt64] {
    var hashes = Array(repeating: UInt64(0), count: PerceptualHash.gridDimension * PerceptualHash.gridDimension)
    for (index, hash) in changes {
        hashes[index] = hash
    }
    return hashes
}

private func hash(withBits count: Int) -> UInt64 {
    guard count > 0 else { return 0 }
    return (0..<count).reduce(UInt64(0)) { result, bit in result | (UInt64(1) << UInt64(bit)) }
}
