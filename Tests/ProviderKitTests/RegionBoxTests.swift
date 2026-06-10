import CoreGraphics
@testable import ProviderKit
import Testing

/// The highlight marquee is only as good as the box the model returns —
/// `normalize` has to absorb the two ways it goes wrong: corner-format answers
/// ([x1, y1, x2, y2] instead of [x, y, w, h]) and boxes that spill off screen.
struct RegionBoxTests {
    @Test func wellFormedBoxPassesThrough() {
        let box = ElementLocator.normalize(box: [100, 50, 300, 200], width: 1280, height: 800)
        #expect(box == [100, 50, 300, 200])
    }

    @Test func cornerFormatIsConvertedToSize() {
        // [400, 300, 1200, 700] read as [x, y, w, h] runs off the image, but read
        // as [x1, y1, x2, y2] it's a valid in-bounds box — so treat it as corners.
        let box = ElementLocator.normalize(box: [400, 300, 1200, 700], width: 1280, height: 800)
        #expect(box == [400, 300, 800, 400])
    }

    @Test func overflowingSizeIsClampedToBounds() {
        // Reads as size and overflows, but is NOT valid as corners (w < x) —
        // so it stays a size and gets clamped to the right/bottom edges.
        let box = ElementLocator.normalize(box: [1000, 700, 600, 300], width: 1280, height: 800)
        #expect(box == [1000, 700, 280, 100])
    }

    @Test func negativeOriginIsClampedToZero() {
        let box = ElementLocator.normalize(box: [-20, -10, 300, 200], width: 1280, height: 800)
        #expect(box == [0, 0, 300, 200])
    }

    @Test func fullScreenBoxSurvives() {
        let box = ElementLocator.normalize(box: [0, 0, 1280, 800], width: 1280, height: 800)
        #expect(box == [0, 0, 1280, 800])
    }
}
