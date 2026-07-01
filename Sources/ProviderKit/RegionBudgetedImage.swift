import AppKit
import Foundation

/// AQuaUI-style image budgeting for local/BYO visual grounders. Hosted endpoints keep
/// the existing full-frame resize/crop retry path; local calls can preserve sharper
/// pixels around cursor/OCR/AX-priority rectangles while still fitting the model size.
public enum RegionBudgetedImage {
    public struct NormalizedRegion: Equatable, Sendable {
        public let rect: CGRect
        public let priority: Int

        public init(rect: CGRect, priority: Int) {
            self.rect = rect
            self.priority = priority
        }
    }

    public static func normalize(
        regions: [CGRect],
        displayWidthPoints: Int,
        displayHeightPoints: Int,
        maxRegions: Int = 12
    ) -> [NormalizedRegion] {
        let display = CGRect(x: 0, y: 0, width: max(1, displayWidthPoints), height: max(1, displayHeightPoints))
        return regions.enumerated().compactMap { index, raw -> NormalizedRegion? in
            let clamped = raw.standardized.intersection(display)
            guard !clamped.isNull, !clamped.isEmpty, clamped.width >= 1, clamped.height >= 1 else {
                return nil
            }
            let normalized = CGRect(
                x: clamped.minX / display.width,
                y: clamped.minY / display.height,
                width: clamped.width / display.width,
                height: clamped.height / display.height
            )
            return NormalizedRegion(rect: normalized, priority: max(0, maxRegions - index))
        }
        .sorted {
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            if $0.rect.area != $1.rect.area { return $0.rect.area < $1.rect.area }
            return "\($0.rect.origin.x),\($0.rect.origin.y)" < "\($1.rect.origin.x),\($1.rect.origin.y)"
        }
        .prefix(maxRegions)
        .map { $0 }
    }

    public static func composeJPEG(
        screenshot: Data,
        outputWidth: Int,
        outputHeight: Int,
        displayWidthPoints: Int,
        displayHeightPoints: Int,
        priorityRegions: [CGRect],
        hostedMode: Bool,
        compression: Double = 0.85
    ) -> Data? {
        guard !hostedMode else { return nil }
        let regions = normalize(
            regions: priorityRegions,
            displayWidthPoints: displayWidthPoints,
            displayHeightPoints: displayHeightPoints
        )
        guard !regions.isEmpty else { return nil }
        guard let image = NSImage(data: screenshot),
              let rep = NSBitmapImageRep(
                  bitmapDataPlanes: nil,
                  pixelsWide: max(1, outputWidth),
                  pixelsHigh: max(1, outputHeight),
                  bitsPerSample: 8,
                  samplesPerPixel: 4,
                  hasAlpha: true,
                  isPlanar: false,
                  colorSpaceName: .deviceRGB,
                  bytesPerRow: 0,
                  bitsPerPixel: 0
              ) else { return nil }
        rep.size = NSSize(width: outputWidth, height: outputHeight)
        NSGraphicsContext.saveGraphicsState()
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
            NSGraphicsContext.restoreGraphicsState()
            return nil
        }
        NSGraphicsContext.current = context
        context.imageInterpolation = .medium
        image.draw(
            in: NSRect(x: 0, y: 0, width: outputWidth, height: outputHeight),
            from: NSRect(origin: .zero, size: image.size),
            operation: .copy,
            fraction: 1
        )
        context.imageInterpolation = .high
        for region in regions {
            let src = rect(region.rect, in: image.size)
            let dst = rect(region.rect, in: NSSize(width: outputWidth, height: outputHeight))
            image.draw(in: dst, from: src, operation: .copy, fraction: 1)
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: compression])
    }

    private static func rect(_ normalized: CGRect, in size: NSSize) -> CGRect {
        CGRect(
            x: normalized.minX * size.width,
            y: normalized.minY * size.height,
            width: normalized.width * size.width,
            height: normalized.height * size.height
        )
    }
}

private extension CGRect {
    var area: CGFloat { max(0, width) * max(0, height) }
}
