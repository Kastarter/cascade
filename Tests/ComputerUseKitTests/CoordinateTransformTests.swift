import CoreGraphics
import Testing

@testable import ComputerUseKit

struct CoordinateTransformTests {
    @Test func retina1440x900UsesExplicit2xBackingScale() throws {
        let transform = try #require(Self.retina1440x900())

        expectBackingScale(transform, x: 2, y: 2)

        expectPoint(transform.backingPixel(fromLogical: .init(x: 720, y: 450))?.point, CGPoint(x: 1440, y: 900))
        expectPoint(transform.backingPixel(fromLogical: .init(x: 0, y: 900))?.point, CGPoint(x: 0, y: 0))
        expectPoint(transform.backingPixel(fromLogical: .init(x: 10, y: 890))?.point, CGPoint(x: 20, y: 20))
        expectPoint(transform.backingPixel(fromLogical: .init(x: 100, y: 0))?.point, CGPoint(x: 200, y: 1800))
        expectPoint(transform.backingPixel(fromLogical: .init(x: 1439.5, y: 0.5))?.point, CGPoint(x: 2879, y: 1799))
        expectPoint(transform.logicalPoint(fromBackingPixel: .init(x: 20, y: 20))?.point, CGPoint(x: 10, y: 890))
    }

    @Test func external1080pUsesExplicit1xBackingScale() throws {
        let transform = try #require(Self.external1080p())

        expectBackingScale(transform, x: 1, y: 1)

        expectPoint(transform.backingPixel(fromLogical: .init(x: 2400, y: 540))?.point, CGPoint(x: 960, y: 540))
        expectPoint(transform.backingPixel(fromLogical: .init(x: 1440, y: 1080))?.point, CGPoint(x: 0, y: 0))
        expectPoint(transform.backingPixel(fromLogical: .init(x: 1450, y: 1070))?.point, CGPoint(x: 10, y: 10))
        expectPoint(transform.logicalPoint(fromBackingPixel: .init(x: 1910, y: 1070))?.point, CGPoint(x: 3350, y: 10))
    }

    @Test func mixedRetinaAndNonRetinaScreensUseOwningDisplayScale() throws {
        let retina = try #require(Self.retina1440x900())
        let external = try #require(Self.external1080p())

        expectBackingScale(retina, x: 2, y: 2)
        expectBackingScale(external, x: 1, y: 1)

        expectPoint(retina.backingPixel(fromLogical: .init(x: 100, y: 100))?.point, CGPoint(x: 200, y: 1600))
        expectPoint(external.backingPixel(fromLogical: .init(x: 1540, y: 100))?.point, CGPoint(x: 100, y: 980))
        #expect(retina.backingPixel(fromLogical: .init(x: 1540, y: 100)) == nil)
        #expect(external.backingPixel(fromLogical: .init(x: 100, y: 100)) == nil)
    }

    @Test func negativeOriginSecondaryDisplayRoundTripsThroughBackingPixels() throws {
        let transform = try #require(Self.left1080p())

        expectBackingScale(transform, x: 1, y: 1)

        let logical = CoordinateTransform.LogicalPoint(x: -960, y: 540)
        let backing = try #require(transform.backingPixel(fromLogical: logical))
        expectPoint(backing.point, CGPoint(x: 960, y: 540))
        expectPoint(transform.backingPixel(fromLogical: .init(x: -1910, y: 1070))?.point, CGPoint(x: 10, y: 10))
        expectPoint(transform.logicalPoint(fromBackingPixel: backing)?.point, logical.point)
        expectPoint(transform.displayLocalPoint(fromLogical: .init(x: -10, y: 20)), CGPoint(x: 1910, y: 20))
        expectPoint(transform.logicalPoint(fromDisplayLocalPoint: CGPoint(x: 25, y: 30))?.point, CGPoint(x: -1895, y: 30))
    }

    @Test func windowSpanningDisplaysRejectsUntilClampedPerOwningDisplay() throws {
        let retina = try #require(Self.retina1440x900())
        let external = try #require(Self.external1080p())
        let spanningWindow = CoordinateTransform.LogicalRect(CGRect(x: 1000, y: 100, width: 900, height: 400))

        #expect(retina.backingRect(fromLogical: spanningWindow) == nil)
        #expect(external.backingRect(fromLogical: spanningWindow) == nil)

        let retinaSlice = try #require(retina.backingRect(fromLogical: spanningWindow, bounds: .clamp))
        expectRect(retinaSlice.rect, CGRect(x: 2000, y: 800, width: 880, height: 800))
        expectRect(
            retina.logicalRect(fromBackingPixelRect: retinaSlice)?.rect,
            CGRect(x: 1000, y: 100, width: 440, height: 400)
        )

        let externalSlice = try #require(external.backingRect(fromLogical: spanningWindow, bounds: .clamp))
        expectRect(externalSlice.rect, CGRect(x: 0, y: 580, width: 460, height: 400))
        expectRect(
            external.logicalRect(fromBackingPixelRect: externalSlice)?.rect,
            CGRect(x: 1440, y: 100, width: 460, height: 400)
        )
    }

    @Test func croppedCanvasOnScaledRetinaDisplayRoundTripsThroughModelCoordinates() throws {
        let screen = try #require(Self.retina1440x900()?.screen)
        let crop = try #require(CoordinateTransform.BackingPixelRect(
            CGRect(x: 400, y: 300, width: 1200, height: 800)
        ))
        let modelSize = try #require(CoordinateTransform.ModelSize(width: 600, height: 400))
        let transform = try #require(CoordinateTransform(
            screen: screen,
            cropInBackingPixels: crop,
            modelInputSize: modelSize
        ))

        expectBackingScale(transform, x: 2, y: 2)

        let logical = CoordinateTransform.LogicalPoint(x: 500, y: 550)
        let backing = try #require(transform.backingPixel(fromLogical: logical))
        expectPoint(backing.point, CGPoint(x: 1000, y: 700))
        expectPoint(transform.cropPixel(fromBackingPixel: backing)?.point, CGPoint(x: 600, y: 400))
        expectPoint(transform.cropPixel(fromLogical: logical)?.point, CGPoint(x: 600, y: 400))
        expectPoint(transform.modelPoint(fromCropPixel: .init(x: 600, y: 400))?.point, CGPoint(x: 300, y: 200))

        expectPoint(transform.invertResize(.init(x: 300, y: 200))?.point, CGPoint(x: 600, y: 400))
        expectPoint(transform.backingPixel(fromModelPoint: .init(x: 300, y: 200))?.point, CGPoint(x: 1000, y: 700))
        expectPoint(transform.logicalPoint(fromModelPoint: .init(x: 300, y: 200))?.point, logical.point)
        #expect(transform.cropPixel(fromLogical: .init(x: 100, y: 100)) == nil)
    }

    @Test func boundsPolicyRejectsOrClampsInvalidModelCoordinates() throws {
        let screen = try #require(CoordinateTransform.ScreenGeometry(
            logicalFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            backingPixelSize: CGSize(width: 200, height: 200)
        ))
        let modelSize = try #require(CoordinateTransform.ModelSize(width: 400, height: 400))
        let transform = try #require(CoordinateTransform(screen: screen, modelInputSize: modelSize))

        #expect(transform.cropPixel(fromModelPoint: .init(x: 500, y: -10), bounds: .reject) == nil)
        expectPoint(
            transform.cropPixel(fromModelPoint: .init(x: 500, y: -10), bounds: .clamp)?.point,
            CGPoint(x: 200, y: 0)
        )
    }

    private static func transform(logicalFrame: CGRect, backingSize: CGSize) -> CoordinateTransform? {
        guard let screen = CoordinateTransform.ScreenGeometry(
            logicalFrame: logicalFrame,
            backingPixelSize: backingSize
        ) else { return nil }
        return CoordinateTransform(screen: screen)
    }

    private static func retina1440x900() -> CoordinateTransform? {
        transform(
            logicalFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            backingSize: CGSize(width: 2880, height: 1800)
        )
    }

    private static func external1080p() -> CoordinateTransform? {
        transform(
            logicalFrame: CGRect(x: 1440, y: 0, width: 1920, height: 1080),
            backingSize: CGSize(width: 1920, height: 1080)
        )
    }

    private static func left1080p() -> CoordinateTransform? {
        transform(
            logicalFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
            backingSize: CGSize(width: 1920, height: 1080)
        )
    }

    private func expectBackingScale(
        _ transform: CoordinateTransform,
        x expectedX: CGFloat,
        y expectedY: CGFloat,
        tolerance: CGFloat = 0.0001
    ) {
        let scaleX = transform.screen.backingPixelSize.width / transform.screen.logicalFrame.width
        let scaleY = transform.screen.backingPixelSize.height / transform.screen.logicalFrame.height
        #expect(abs(scaleX - expectedX) <= tolerance)
        #expect(abs(scaleY - expectedY) <= tolerance)
    }

    private func expectPoint(_ actual: CGPoint?, _ expected: CGPoint, tolerance: CGFloat = 0.0001) {
        guard let actual else {
            Issue.record("Expected \(expected), got nil")
            return
        }
        #expect(abs(actual.x - expected.x) <= tolerance)
        #expect(abs(actual.y - expected.y) <= tolerance)
    }

    private func expectRect(_ actual: CGRect?, _ expected: CGRect, tolerance: CGFloat = 0.0001) {
        guard let actual else {
            Issue.record("Expected \(expected), got nil")
            return
        }
        #expect(abs(actual.origin.x - expected.origin.x) <= tolerance)
        #expect(abs(actual.origin.y - expected.origin.y) <= tolerance)
        #expect(abs(actual.size.width - expected.size.width) <= tolerance)
        #expect(abs(actual.size.height - expected.size.height) <= tolerance)
    }
}
