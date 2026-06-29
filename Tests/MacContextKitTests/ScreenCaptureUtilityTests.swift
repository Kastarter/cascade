import ApplicationServices
import Foundation
import Testing

@testable import MacContextKit

struct ScreenCaptureUtilityTests {
    @Test func decodeAXElementAcceptsOnlyAXElements() {
        let element = AXUIElementCreateSystemWide()

        #expect(decodeAXElement(element) != nil)
        #expect(decodeAXElement(nil) == nil)
        #expect(decodeAXElement("not an AXUIElement" as CFString) == nil)
        #expect(decodeAXElement(NSNumber(value: 7)) == nil)
    }

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

    @Test @MainActor func malformedFocusedWindowHelpersReturnEmptyValues() {
        let malformed = "not an AXUIElement" as CFString

        #expect(AXTextHarvester.text(forFocusedWindowRef: nil).isEmpty)
        #expect(AXTextHarvester.text(forFocusedWindowRef: malformed).isEmpty)
        #expect(AppWindowObserver.frontmostWindowTitle(focusedWindowRef: nil) == nil)
        #expect(AppWindowObserver.frontmostWindowTitle(focusedWindowRef: malformed) == nil)
        #expect(ScreenCaptureUtility.focusedWindowNormalizedRect(focusedWindowRef: nil) == nil)
        #expect(ScreenCaptureUtility.focusedWindowNormalizedRect(focusedWindowRef: malformed) == nil)
    }

    @Test func axClientRejectsInvalidFrames() {
        let display = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let valid = CGRect(x: 10, y: 10, width: 100, height: 40)
        let zero = CGRect(x: 10, y: 10, width: 0, height: 40)
        let offscreen = CGRect(x: 2000, y: 10, width: 100, height: 40)

        #expect((try? AXClient.validateFrame(valid, knownDisplays: [display]).get()) == valid)
        #expect((try? AXClient.validateFrame(zero, knownDisplays: [display]).get()) == nil)
        #expect((try? AXClient.validateFrame(offscreen, knownDisplays: [display]).get()) == nil)
    }

    @Test func axClientUsesParentFallbackForTinyChildFrame() throws {
        let display = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let parent = CGRect(x: 20, y: 20, width: 200, height: 80)
        let zero = CGRect(x: 20, y: 20, width: 0, height: 0)

        let resolved = try AXClient.validateFrame(zero, knownDisplays: [display], parentFrame: parent).get()
        #expect(resolved == parent)
    }
}
