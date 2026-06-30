import CoreGraphics
import Testing

@testable import MacContextKit

struct DisplayCoordinateMapperTests {
    @Test func mainDisplayLocalAppKitToCGGlobal() throws {
        let mapper = DisplayCoordinateMapper(
            displayID: 1,
            appKitFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            cgBounds: CGRect(x: 0, y: 0, width: 1440, height: 900),
            backingScaleFactor: 2
        )

        #expect(mapper.appKitGlobal(fromScreenLocal: CGPoint(x: 10, y: 890)) == CGPoint(x: 10, y: 890))
        #expect(mapper.cgGlobal(fromScreenLocal: CGPoint(x: 10, y: 890)) == CGPoint(x: 10, y: 10))
        #expect(mapper.screenLocalAppKit(fromCGGlobal: CGPoint(x: 10, y: 10)) == CGPoint(x: 10, y: 890))
    }

    @Test func secondaryDisplayLeftSupportsNegativeX() {
        let mapper = DisplayCoordinateMapper(
            displayID: 2,
            appKitFrame: CGRect(x: -1280, y: 0, width: 1280, height: 720),
            cgBounds: CGRect(x: -1280, y: 0, width: 1280, height: 720),
            backingScaleFactor: 1
        )

        #expect(mapper.appKitGlobal(fromScreenLocal: CGPoint(x: 640, y: 360)) == CGPoint(x: -640, y: 360))
        #expect(mapper.cgGlobal(fromScreenLocal: CGPoint(x: 640, y: 360)) == CGPoint(x: -640, y: 360))
    }

    @Test func secondaryDisplayAboveSupportsNegativeAppKitY() {
        let mapper = DisplayCoordinateMapper(
            displayID: 3,
            appKitFrame: CGRect(x: 0, y: -900, width: 1440, height: 900),
            cgBounds: CGRect(x: 0, y: -900, width: 1440, height: 900),
            backingScaleFactor: 1
        )

        #expect(mapper.appKitGlobal(fromScreenLocal: CGPoint(x: 720, y: 450)) == CGPoint(x: 720, y: -450))
        #expect(mapper.cgGlobal(fromScreenLocal: CGPoint(x: 720, y: 450)) == CGPoint(x: 720, y: -450))
    }

    @Test func mixedRetinaPixelConversionUsesImageSizeNotPointScaleForCoordinates() {
        let mapper = DisplayCoordinateMapper(
            displayID: 4,
            appKitFrame: CGRect(x: 1440, y: 0, width: 1280, height: 720),
            cgBounds: CGRect(x: 1440, y: 0, width: 1280, height: 720),
            backingScaleFactor: 2
        )

        let pixel = mapper.capturedImagePixel(
            fromCGGlobal: CGPoint(x: 1440 + 640, y: 360),
            imageSize: CGSize(width: 2560, height: 1440)
        )
        #expect(pixel == CGPoint(x: 1280, y: 720))
        #expect(mapper.outputPixelSize(maxDimension: 1920) == (1920, 1080))
    }

    @Test func offDisplayPointsAreRejected() {
        let mapper = DisplayCoordinateMapper(
            displayID: 5,
            appKitFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            cgBounds: CGRect(x: 0, y: 0, width: 1440, height: 900),
            backingScaleFactor: 1
        )

        #expect(mapper.screenLocalAppKit(fromCGGlobal: CGPoint(x: 2000, y: 450)) == nil)
        #expect(mapper.cgGlobal(fromScreenLocal: CGPoint(x: 1500, y: 450)) == nil)
    }

    @Test func cgGlobalAXFrameMapsToDisplayLocalAppKitRect() {
        let mapper = DisplayCoordinateMapper(
            displayID: 6,
            appKitFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            cgBounds: CGRect(x: 0, y: 0, width: 1440, height: 900),
            backingScaleFactor: 2
        )

        let rect = mapper.screenLocalAppKit(fromCGGlobal: CGRect(x: 100, y: 120, width: 240, height: 60))
        #expect(rect == CGRect(x: 100, y: 720, width: 240, height: 60))
    }

    @Test func cgGlobalAXFrameClipsToDisplay() {
        let mapper = DisplayCoordinateMapper(
            displayID: 7,
            appKitFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            cgBounds: CGRect(x: 0, y: 0, width: 1440, height: 900),
            backingScaleFactor: 1
        )

        let rect = mapper.screenLocalAppKit(fromCGGlobal: CGRect(x: -20, y: 850, width: 80, height: 80))
        #expect(rect == CGRect(x: 0, y: 0, width: 60, height: 50))
    }

    @Test func offDisplayAndDegenerateAXFramesAreRejected() {
        let mapper = DisplayCoordinateMapper(
            displayID: 8,
            appKitFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            cgBounds: CGRect(x: 0, y: 0, width: 1440, height: 900),
            backingScaleFactor: 1
        )

        #expect(mapper.screenLocalAppKit(fromCGGlobal: CGRect(x: 1600, y: 100, width: 40, height: 40)) == nil)
        #expect(mapper.screenLocalAppKit(fromCGGlobal: CGRect(x: 100, y: 100, width: 0, height: 40)) == nil)
    }
}
