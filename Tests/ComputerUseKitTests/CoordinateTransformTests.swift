import CoreGraphics
import Testing

@testable import ComputerUseKit

struct CoordinateTransformTests {
    @Test func retinaLogicalPointsMapToBackingPixelsWithTopLeftOrigin() throws {
        let transform = try #require(Self.transform(
            logicalFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            backingSize: CGSize(width: 2880, height: 1800)
        ))

        expectPoint(transform.backingPixel(fromLogical: .init(x: 720, y: 450))?.point, CGPoint(x: 1440, y: 900))
        expectPoint(transform.backingPixel(fromLogical: .init(x: 10, y: 890))?.point, CGPoint(x: 20, y: 20))
        expectPoint(transform.backingPixel(fromLogical: .init(x: 100, y: 0))?.point, CGPoint(x: 200, y: 1800))
        expectPoint(transform.logicalPoint(fromBackingPixel: .init(x: 20, y: 20))?.point, CGPoint(x: 10, y: 890))
    }

    @Test func negativeOriginDisplayRoundTripsThroughBackingPixels() throws {
        let transform = try #require(Self.transform(
            logicalFrame: CGRect(x: -1280, y: 0, width: 1280, height: 720),
            backingSize: CGSize(width: 1280, height: 720)
        ))

        let logical = CoordinateTransform.LogicalPoint(x: -640, y: 360)
        let backing = try #require(transform.backingPixel(fromLogical: logical))
        expectPoint(backing.point, CGPoint(x: 640, y: 360))
        expectPoint(transform.logicalPoint(fromBackingPixel: backing)?.point, logical.point)
    }

    @Test func modelPointInvertsSmartResizeThenCropBackingLogicalChain() throws {
        let screen = try #require(CoordinateTransform.ScreenGeometry(
            logicalFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            backingPixelSize: CGSize(width: 2880, height: 1800)
        ))
        let crop = try #require(CoordinateTransform.BackingPixelRect(
            CGRect(x: 100, y: 200, width: 1000, height: 500)
        ))
        let modelSize = try #require(CoordinateTransform.ModelSize(width: 1288, height: 644))
        let transform = try #require(CoordinateTransform(
            screen: screen,
            cropInBackingPixels: crop,
            modelInputSize: modelSize
        ))

        let cropPoint = try #require(transform.invertResize(.init(x: 644, y: 322)))
        expectPoint(cropPoint.point, CGPoint(x: 500, y: 250))
        expectPoint(transform.backingPixel(fromCropPixel: cropPoint)?.point, CGPoint(x: 600, y: 450))
        expectPoint(transform.logicalPoint(fromModelPoint: .init(x: 644, y: 322))?.point, CGPoint(x: 300, y: 675))
        expectPoint(transform.modelPoint(fromCropPixel: cropPoint)?.point, CGPoint(x: 644, y: 322))
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

    private func expectPoint(_ actual: CGPoint?, _ expected: CGPoint, tolerance: CGFloat = 0.0001) {
        guard let actual else {
            Issue.record("Expected \(expected), got nil")
            return
        }
        #expect(abs(actual.x - expected.x) <= tolerance)
        #expect(abs(actual.y - expected.y) <= tolerance)
    }
}
