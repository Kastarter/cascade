import ApplicationServices
import Foundation
import Testing

@testable import MacContextKit

struct ScreenCaptureUtilityTests {
    @Test func decodeAXPointAcceptsOnlyAXPointValues() {
        var point = CGPoint(x: 18.5, y: -9.25)
        let value = AXValueCreate(.cgPoint, &point)

        #expect(ScreenCaptureUtility.decodeAXPoint(value) == point)
        #expect(ScreenCaptureUtility.decodeAXPoint("not an AXValue" as CFString) == nil)
        #expect(ScreenCaptureUtility.decodeAXPoint(NSNumber(value: 7)) == nil)
    }

    @Test func decodeAXSizeAcceptsOnlyAXSizeValues() {
        var size = CGSize(width: 320.5, height: 240.25)
        let value = AXValueCreate(.cgSize, &size)

        #expect(ScreenCaptureUtility.decodeAXSize(value) == size)
        #expect(ScreenCaptureUtility.decodeAXSize("not an AXValue" as CFString) == nil)
        #expect(ScreenCaptureUtility.decodeAXSize(NSNumber(value: 7)) == nil)
    }
}
