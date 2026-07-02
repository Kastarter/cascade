import AppKit
import CoreGraphics
import Foundation

/// Authoritative coordinate transform for computer-use grounding.
///
/// Coordinate origins are explicit:
/// - logical points: global AppKit screen points, bottom-left origin
/// - backing pixels: display-local screenshot pixels, top-left origin
/// - crop pixels: crop-local screenshot pixels, top-left origin
/// - model coordinates: smart-resized model-input pixels, top-left origin
public struct CoordinateTransform: Equatable, Sendable {
    public enum BoundsPolicy: Equatable, Sendable {
        case reject
        case clamp
    }

    public struct LogicalPoint: Equatable, Sendable {
        public let point: CGPoint

        public init(_ point: CGPoint) {
            self.point = point
        }

        public init(x: CGFloat, y: CGFloat) {
            self.init(CGPoint(x: x, y: y))
        }
    }

    public struct LogicalRect: Equatable, Sendable {
        public let rect: CGRect

        public init(_ rect: CGRect) {
            self.rect = rect.standardized
        }
    }

    public struct BackingPixelPoint: Equatable, Sendable {
        public let point: CGPoint

        public init(_ point: CGPoint) {
            self.point = point
        }

        public init(x: CGFloat, y: CGFloat) {
            self.init(CGPoint(x: x, y: y))
        }
    }

    public struct BackingPixelRect: Equatable, Sendable {
        public let rect: CGRect

        public init?(_ rect: CGRect) {
            let standardized = rect.standardized
            guard standardized.isFiniteAndPositiveSize else { return nil }
            self.rect = standardized
        }
    }

    public struct CropPixelPoint: Equatable, Sendable {
        public let point: CGPoint

        public init(_ point: CGPoint) {
            self.point = point
        }

        public init(x: CGFloat, y: CGFloat) {
            self.init(CGPoint(x: x, y: y))
        }
    }

    public struct ModelPoint: Equatable, Sendable {
        public let point: CGPoint

        public init(_ point: CGPoint) {
            self.point = point
        }

        public init(x: CGFloat, y: CGFloat) {
            self.init(CGPoint(x: x, y: y))
        }
    }

    public struct ModelSize: Equatable, Sendable {
        public let size: CGSize

        public init?(_ size: CGSize) {
            guard size.isFiniteAndPositive else { return nil }
            self.size = size
        }

        public init?(width: CGFloat, height: CGFloat) {
            self.init(CGSize(width: width, height: height))
        }
    }

    public struct ScreenGeometry: Equatable, Sendable {
        public let displayID: CGDirectDisplayID?
        public let logicalFrame: CGRect
        public let backingPixelSize: CGSize

        public init?(
            displayID: CGDirectDisplayID? = nil,
            logicalFrame: CGRect,
            backingPixelSize: CGSize
        ) {
            let frame = logicalFrame.standardized
            guard frame.isFiniteAndPositiveSize, backingPixelSize.isFiniteAndPositive else { return nil }
            self.displayID = displayID
            self.logicalFrame = frame
            self.backingPixelSize = backingPixelSize
        }

        @MainActor
        public init?(screen: NSScreen) {
            let localLogicalBounds = CGRect(origin: .zero, size: screen.frame.size)
            let localBackingBounds = screen.convertRectToBacking(localLogicalBounds).standardized
            let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                .uint32Value
            self.init(
                displayID: displayID,
                logicalFrame: screen.frame,
                backingPixelSize: localBackingBounds.size
            )
        }

        @MainActor
        public static func containing(_ logicalPoint: LogicalPoint) -> ScreenGeometry? {
            NSScreen.screens
                .first { NSMouseInRect(logicalPoint.point, $0.frame, false) }
                .flatMap(ScreenGeometry.init(screen:))
        }
    }

    public let screen: ScreenGeometry
    public let cropInBackingPixels: BackingPixelRect
    public let modelInputSize: ModelSize?

    public init?(
        screen: ScreenGeometry,
        cropInBackingPixels crop: BackingPixelRect? = nil,
        modelInputSize: ModelSize? = nil
    ) {
        guard let fullBacking = BackingPixelRect(CGRect(origin: .zero, size: screen.backingPixelSize)) else {
            return nil
        }
        let effectiveCrop = crop ?? fullBacking
        guard fullBacking.rect.contains(effectiveCrop.rect, tolerance: 0.5) else { return nil }
        self.screen = screen
        self.cropInBackingPixels = effectiveCrop
        self.modelInputSize = modelInputSize
    }

    @MainActor
    public init?(
        screen: NSScreen,
        cropInBackingPixels crop: BackingPixelRect? = nil,
        modelInputSize: ModelSize? = nil
    ) {
        guard let geometry = ScreenGeometry(screen: screen) else { return nil }
        self.init(screen: geometry, cropInBackingPixels: crop, modelInputSize: modelInputSize)
    }

    @MainActor
    public static func containing(
        _ logicalPoint: LogicalPoint,
        cropInBackingPixels crop: BackingPixelRect? = nil,
        modelInputSize: ModelSize? = nil
    ) -> CoordinateTransform? {
        guard let geometry = ScreenGeometry.containing(logicalPoint) else { return nil }
        return CoordinateTransform(screen: geometry, cropInBackingPixels: crop, modelInputSize: modelInputSize)
    }

    public func backingPixel(fromLogical logical: LogicalPoint, bounds: BoundsPolicy = .reject) -> BackingPixelPoint? {
        let local = CGPoint(
            x: logical.point.x - screen.logicalFrame.minX,
            y: logical.point.y - screen.logicalFrame.minY
        )
        guard let local = Self.point(local, in: CGRect(origin: .zero, size: screen.logicalFrame.size), bounds: bounds) else {
            return nil
        }
        return BackingPixelPoint(
            x: local.x / screen.logicalFrame.width * screen.backingPixelSize.width,
            y: screen.backingPixelSize.height - local.y / screen.logicalFrame.height * screen.backingPixelSize.height
        )
    }

    public func logicalPoint(fromBackingPixel backing: BackingPixelPoint, bounds: BoundsPolicy = .reject) -> LogicalPoint? {
        guard let point = Self.point(
            backing.point,
            in: CGRect(origin: .zero, size: screen.backingPixelSize),
            bounds: bounds
        ) else { return nil }
        let localX = point.x / screen.backingPixelSize.width * screen.logicalFrame.width
        let localY = screen.logicalFrame.height - point.y / screen.backingPixelSize.height * screen.logicalFrame.height
        return LogicalPoint(x: screen.logicalFrame.minX + localX, y: screen.logicalFrame.minY + localY)
    }

    public func cropPixel(fromBackingPixel backing: BackingPixelPoint, bounds: BoundsPolicy = .reject) -> CropPixelPoint? {
        guard let point = Self.point(backing.point, in: cropInBackingPixels.rect, bounds: bounds) else { return nil }
        return CropPixelPoint(x: point.x - cropInBackingPixels.rect.minX, y: point.y - cropInBackingPixels.rect.minY)
    }

    public func backingPixel(fromCropPixel crop: CropPixelPoint, bounds: BoundsPolicy = .reject) -> BackingPixelPoint? {
        let cropBounds = CGRect(origin: .zero, size: cropInBackingPixels.rect.size)
        guard let point = Self.point(crop.point, in: cropBounds, bounds: bounds) else { return nil }
        return BackingPixelPoint(x: cropInBackingPixels.rect.minX + point.x, y: cropInBackingPixels.rect.minY + point.y)
    }

    public func cropPixel(fromLogical logical: LogicalPoint, bounds: BoundsPolicy = .reject) -> CropPixelPoint? {
        guard let backing = backingPixel(fromLogical: logical, bounds: bounds) else { return nil }
        return cropPixel(fromBackingPixel: backing, bounds: bounds)
    }

    public func logicalPoint(fromCropPixel crop: CropPixelPoint, bounds: BoundsPolicy = .reject) -> LogicalPoint? {
        guard let backing = backingPixel(fromCropPixel: crop, bounds: bounds) else { return nil }
        return logicalPoint(fromBackingPixel: backing, bounds: bounds)
    }

    public func modelPoint(fromCropPixel crop: CropPixelPoint, bounds: BoundsPolicy = .reject) -> ModelPoint? {
        guard let modelInputSize,
              let crop = Self.point(crop.point, in: CGRect(origin: .zero, size: cropInBackingPixels.rect.size), bounds: bounds)
        else { return nil }
        return ModelPoint(
            x: crop.x / cropInBackingPixels.rect.width * modelInputSize.size.width,
            y: crop.y / cropInBackingPixels.rect.height * modelInputSize.size.height
        )
    }

    public func cropPixel(fromModelPoint model: ModelPoint, bounds: BoundsPolicy = .reject) -> CropPixelPoint? {
        invertResize(model, bounds: bounds)
    }

    public func logicalPoint(fromModelPoint model: ModelPoint, bounds: BoundsPolicy = .reject) -> LogicalPoint? {
        guard let crop = cropPixel(fromModelPoint: model, bounds: bounds) else { return nil }
        return logicalPoint(fromCropPixel: crop, bounds: bounds)
    }

    public func backingPixel(fromModelPoint model: ModelPoint, bounds: BoundsPolicy = .reject) -> BackingPixelPoint? {
        guard let crop = cropPixel(fromModelPoint: model, bounds: bounds) else { return nil }
        return backingPixel(fromCropPixel: crop, bounds: bounds)
    }

    public func invertResize(_ model: ModelPoint, bounds: BoundsPolicy = .reject) -> CropPixelPoint? {
        guard let modelInputSize else { return nil }
        return Self.invertResize(
            model,
            fromModelInputSize: modelInputSize,
            toCropPixelSize: cropInBackingPixels.rect.size,
            bounds: bounds
        )
    }

    public static func invertResize(
        _ model: ModelPoint,
        fromModelInputSize modelInputSize: ModelSize,
        toCropPixelSize cropPixelSize: CGSize,
        bounds: BoundsPolicy = .reject
    ) -> CropPixelPoint? {
        guard cropPixelSize.isFiniteAndPositive else { return nil }
        guard let point = point(model.point, in: CGRect(origin: .zero, size: modelInputSize.size), bounds: bounds) else {
            return nil
        }
        return CropPixelPoint(
            x: point.x / modelInputSize.size.width * cropPixelSize.width,
            y: point.y / modelInputSize.size.height * cropPixelSize.height
        )
    }

    public func backingRect(fromLogical logical: LogicalRect, bounds: BoundsPolicy = .reject) -> BackingPixelRect? {
        let local = CGRect(
            x: logical.rect.minX - screen.logicalFrame.minX,
            y: logical.rect.minY - screen.logicalFrame.minY,
            width: logical.rect.width,
            height: logical.rect.height
        )
        let logicalBounds = CGRect(origin: .zero, size: screen.logicalFrame.size)
        guard let localRect = Self.rect(local, in: logicalBounds, bounds: bounds) else { return nil }

        let x = localRect.minX / screen.logicalFrame.width * screen.backingPixelSize.width
        let width = localRect.width / screen.logicalFrame.width * screen.backingPixelSize.width
        let height = localRect.height / screen.logicalFrame.height * screen.backingPixelSize.height
        let y = screen.backingPixelSize.height
            - (localRect.minY + localRect.height) / screen.logicalFrame.height * screen.backingPixelSize.height
        return BackingPixelRect.unchecked(CGRect(x: x, y: y, width: width, height: height))
    }

    public func logicalRect(fromBackingPixelRect backing: BackingPixelRect, bounds: BoundsPolicy = .reject) -> LogicalRect? {
        let backingBounds = CGRect(origin: .zero, size: screen.backingPixelSize)
        guard let backingRect = Self.rect(backing.rect, in: backingBounds, bounds: bounds) else { return nil }

        let localX = backingRect.minX / screen.backingPixelSize.width * screen.logicalFrame.width
        let localWidth = backingRect.width / screen.backingPixelSize.width * screen.logicalFrame.width
        let localHeight = backingRect.height / screen.backingPixelSize.height * screen.logicalFrame.height
        let localMaxY = screen.logicalFrame.height
            - backingRect.minY / screen.backingPixelSize.height * screen.logicalFrame.height
        let localY = localMaxY - localHeight
        return LogicalRect(CGRect(
            x: screen.logicalFrame.minX + localX,
            y: screen.logicalFrame.minY + localY,
            width: localWidth,
            height: localHeight
        ))
    }

    public func logicalPoint(fromDisplayLocalPoint point: CGPoint, bounds: BoundsPolicy = .reject) -> LogicalPoint? {
        guard let local = Self.point(point, in: CGRect(origin: .zero, size: screen.logicalFrame.size), bounds: bounds) else {
            return nil
        }
        return LogicalPoint(x: screen.logicalFrame.minX + local.x, y: screen.logicalFrame.minY + local.y)
    }

    public func displayLocalPoint(fromLogical logical: LogicalPoint, bounds: BoundsPolicy = .reject) -> CGPoint? {
        let local = CGPoint(x: logical.point.x - screen.logicalFrame.minX, y: logical.point.y - screen.logicalFrame.minY)
        return Self.point(local, in: CGRect(origin: .zero, size: screen.logicalFrame.size), bounds: bounds)
    }

    private static func point(_ point: CGPoint, in bounds: CGRect, bounds policy: BoundsPolicy) -> CGPoint? {
        guard point.x.isFinite, point.y.isFinite, bounds.isFiniteAndPositiveSize else { return nil }
        switch policy {
        case .reject:
            return bounds.contains(point, tolerance: 0.5) ? point : nil
        case .clamp:
            return CGPoint(
                x: max(bounds.minX, min(point.x, bounds.maxX)),
                y: max(bounds.minY, min(point.y, bounds.maxY))
            )
        }
    }

    private static func rect(_ rect: CGRect, in bounds: CGRect, bounds policy: BoundsPolicy) -> CGRect? {
        let rect = rect.standardized
        guard rect.isFinite, bounds.isFiniteAndPositiveSize else { return nil }
        switch policy {
        case .reject:
            return bounds.contains(rect, tolerance: 0.5) ? rect : nil
        case .clamp:
            let minX = max(bounds.minX, min(rect.minX, bounds.maxX))
            let minY = max(bounds.minY, min(rect.minY, bounds.maxY))
            let maxX = max(bounds.minX, min(rect.maxX, bounds.maxX))
            let maxY = max(bounds.minY, min(rect.maxY, bounds.maxY))
            return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
        }
    }
}

private extension CoordinateTransform.BackingPixelRect {
    static func unchecked(_ rect: CGRect) -> CoordinateTransform.BackingPixelRect {
        CoordinateTransform.BackingPixelRect(rect)!
    }
}

private extension CGSize {
    var isFiniteAndPositive: Bool {
        width.isFinite && height.isFinite && width > 0 && height > 0
    }
}

private extension CGRect {
    var isFinite: Bool {
        origin.x.isFinite && origin.y.isFinite && size.width.isFinite && size.height.isFinite
    }

    var isFiniteAndPositiveSize: Bool {
        isFinite && width > 0 && height > 0
    }

    func contains(_ rect: CGRect, tolerance: CGFloat) -> Bool {
        insetBy(dx: -tolerance, dy: -tolerance).contains(rect)
    }

    func contains(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        insetBy(dx: -tolerance, dy: -tolerance).contains(point)
    }
}
