import AppKit
import CoreGraphics
import Foundation

public struct DisplayCoordinateMapper: Equatable, Sendable {
    public let displayID: CGDirectDisplayID
    /// AppKit global points for this display, bottom-left origin in Cocoa's screen space.
    public let appKitFrame: CGRect
    /// CG global points for this display, top-left origin in CoreGraphics/AX event space.
    public let cgBounds: CGRect
    public let backingScaleFactor: CGFloat

    public init(
        displayID: CGDirectDisplayID,
        appKitFrame: CGRect,
        cgBounds: CGRect,
        backingScaleFactor: CGFloat
    ) {
        self.displayID = displayID
        self.appKitFrame = appKitFrame
        self.cgBounds = cgBounds
        self.backingScaleFactor = backingScaleFactor
    }

    public init?(screen: NSScreen) {
        guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        self.init(
            displayID: id.uint32Value,
            appKitFrame: screen.frame,
            cgBounds: CGDisplayBounds(id.uint32Value),
            backingScaleFactor: screen.backingScaleFactor
        )
    }

    public func appKitGlobal(fromScreenLocal point: CGPoint, tolerance: CGFloat = 1) -> CGPoint? {
        guard containsScreenLocal(point, tolerance: tolerance) else { return nil }
        return CGPoint(x: appKitFrame.minX + point.x, y: appKitFrame.minY + point.y)
    }

    public func cgGlobal(fromScreenLocal point: CGPoint, tolerance: CGFloat = 1) -> CGPoint? {
        guard containsScreenLocal(point, tolerance: tolerance) else { return nil }
        return CGPoint(
            x: cgBounds.minX + point.x,
            y: cgBounds.minY + (appKitFrame.height - point.y)
        )
    }

    public func screenLocalAppKit(fromCGGlobal point: CGPoint, tolerance: CGFloat = 1) -> CGPoint? {
        guard cgBounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point) else { return nil }
        return CGPoint(
            x: point.x - cgBounds.minX,
            y: appKitFrame.height - (point.y - cgBounds.minY)
        )
    }

    public func capturedImagePixel(fromCGGlobal point: CGPoint, imageSize: CGSize, tolerance: CGFloat = 1) -> CGPoint? {
        guard imageSize.width > 0, imageSize.height > 0,
              cgBounds.width > 0, cgBounds.height > 0,
              cgBounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point) else { return nil }
        let fx = min(max((point.x - cgBounds.minX) / cgBounds.width, 0), 1)
        let fy = min(max((point.y - cgBounds.minY) / cgBounds.height, 0), 1)
        return CGPoint(x: fx * imageSize.width, y: fy * imageSize.height)
    }

    public func capturedImagePixel(fromScreenLocal point: CGPoint, imageSize: CGSize, tolerance: CGFloat = 1) -> CGPoint? {
        guard let cg = cgGlobal(fromScreenLocal: point, tolerance: tolerance) else { return nil }
        return capturedImagePixel(fromCGGlobal: cg, imageSize: imageSize, tolerance: tolerance)
    }

    public func outputPixelSize(maxDimension: Int = 1920) -> (Int, Int) {
        Self.outputPixelSize(
            widthPoints: appKitFrame.width,
            heightPoints: appKitFrame.height,
            backingScaleFactor: backingScaleFactor,
            maxDimension: maxDimension
        )
    }

    public static func outputPixelSize(
        widthPoints: CGFloat,
        heightPoints: CGFloat,
        backingScaleFactor: CGFloat,
        maxDimension: Int = 1920
    ) -> (Int, Int) {
        let scale = max(backingScaleFactor, 1)
        let nativeWidth = max(1, Int((widthPoints * scale).rounded()))
        let nativeHeight = max(1, Int((heightPoints * scale).rounded()))
        if nativeWidth >= nativeHeight {
            let width = min(nativeWidth, maxDimension)
            let height = Int((CGFloat(width) * CGFloat(nativeHeight) / CGFloat(nativeWidth)).rounded())
            return (max(width, 1), max(height, 1))
        } else {
            let height = min(nativeHeight, maxDimension)
            let width = Int((CGFloat(height) * CGFloat(nativeWidth) / CGFloat(nativeHeight)).rounded())
            return (max(width, 1), max(height, 1))
        }
    }

    private func containsScreenLocal(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        CGRect(origin: .zero, size: appKitFrame.size)
            .insetBy(dx: -tolerance, dy: -tolerance)
            .contains(point)
    }
}
