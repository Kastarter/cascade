import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import OSLog
import ScreenCaptureKit

// ScreenCaptureKit capture flow adapted from `jasonkneen/openclicky`
// (`cursor-buddy/CompanionScreenCaptureUtility.swift`, MIT License): cursor-screen
// selection, own-window exclusion via SCContentFilter, and the SCStreamConfiguration
// + SCScreenshotManager single-frame path. Re-implemented as a Cascade-owned,
// fail-closed observer and paired with on-device OCR. See docs/THIRD_PARTY_NOTICES.md.

/// A privacy-scoped sample of what the employee is actively looking at: the
/// display containing the cursor, reduced to OCR text (and optionally the raw
/// frame). Manager-facing surfaces must never read the raw frame — only
/// allowlisted aggregates derived downstream.
public struct ScreenContextSample: Sendable, Equatable {
    public let ocrText: String
    public let frontAppName: String?
    public let frontBundleIdentifier: String?
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let isCursorScreen: Bool
    /// Present only when explicitly requested; defaults to `nil` so we don't keep
    /// raw screenshots in memory during routine recording.
    public let imagePNG: Data?

    public init(
        ocrText: String,
        frontAppName: String?,
        frontBundleIdentifier: String?,
        pixelWidth: Int,
        pixelHeight: Int,
        isCursorScreen: Bool,
        imagePNG: Data?
    ) {
        self.ocrText = ocrText
        self.frontAppName = frontAppName
        self.frontBundleIdentifier = frontBundleIdentifier
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.isCursorScreen = isCursorScreen
        self.imagePNG = imagePNG
    }

    public var hasText: Bool { !ocrText.isEmpty }
}

@MainActor
public enum ScreenCaptureUtility {
    private static let logger = Logger(subsystem: "com.humain.cascade", category: "capture")

    /// Longest-side cap for the captured frame. High enough that on-screen UI text
    /// OCRs cleanly, bounded so a 4s recorder tick stays cheap.
    private static let maxPixelDimension = 1920

    // SCShareableContent enumerates every window on every display and costs
    // ~80–200ms cold. A short cache keeps back-to-back capture ticks cheap.
    private static var cachedContent: SCShareableContent?
    private static var cacheExpiresAt = Date.distantPast
    private static let cacheLifetime: TimeInterval = 3.0

    /// Captures the display containing the cursor and returns its OCR text.
    /// Pass `includeOCR: false` when only the frame is needed (e.g. vision-model
    /// grounding) — recognition costs hundreds of milliseconds per frame.
    ///
    /// FAIL-CLOSED: if Screen Recording is not already granted this returns `nil`
    /// without ever calling a capture path or triggering a prompt, per the
    /// architecture's permission rules.
    public static func captureCursorScreenContext(includeImage: Bool = false, includeOCR: Bool = true) async -> ScreenContextSample? {
        guard CGPreflightScreenCaptureAccess() else {
            logger.info("Capture skipped — Screen Recording not granted (fail-closed).")
            return nil
        }
        do {
            return try await capture(includeImage: includeImage, includeOCR: includeOCR)
        } catch {
            logger.error("Screen capture failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Captures the cursor display directly at `width`×`height` pixels and encodes
    /// JPEG once — no full-resolution PNG round-trip and no OCR. The hot path for
    /// agent loop turns, which already know the model-facing resolution and only
    /// need the image.
    ///
    /// FAIL-CLOSED: returns `nil` without capturing if Screen Recording isn't granted.
    public static func captureCursorScreenJPEG(width: Int, height: Int, compression: Double = 0.7) async -> Data? {
        guard CGPreflightScreenCaptureAccess() else {
            logger.info("Capture skipped — Screen Recording not granted (fail-closed).")
            return nil
        }
        do {
            let content = try await shareableContent()
            guard let display = cursorDisplay(in: content) else {
                logger.info("Capture skipped — no display available.")
                return nil
            }
            let filter = SCContentFilter(display: display, excludingWindows: ownAppWindows(in: content))
            let configuration = SCStreamConfiguration()
            configuration.width = max(1, width)
            configuration.height = max(1, height)
            configuration.showsCursor = false
            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            return jpegData(from: cgImage, compression: compression)
        } catch {
            logger.error("Screen capture failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Captures the cursor display at NATIVE resolution and returns just the given
    /// normalized region (top-left origin, [0,1]) as JPEG — the agent's zoom: full
    /// pixel detail for small text that is illegible at the loop resolution. The
    /// crop is capped at `maxDimension` on its long side.
    ///
    /// FAIL-CLOSED: returns `nil` without capturing if Screen Recording isn't granted.
    public static func captureCursorScreenZoomJPEG(
        normalizedRect: CGRect, maxDimension: Int = 1024, compression: Double = 0.8
    ) async -> Data? {
        guard CGPreflightScreenCaptureAccess() else {
            logger.info("Capture skipped — Screen Recording not granted (fail-closed).")
            return nil
        }
        do {
            let content = try await shareableContent()
            guard let display = cursorDisplay(in: content) else { return nil }
            let filter = SCContentFilter(display: display, excludingWindows: ownAppWindows(in: content))
            let configuration = SCStreamConfiguration()
            let scale = nsScreensByDisplayID()[display.displayID]?.backingScaleFactor ?? 2.0
            configuration.width = max(1, Int((CGFloat(display.width) * scale).rounded()))
            configuration.height = max(1, Int((CGFloat(display.height) * scale).rounded()))
            configuration.showsCursor = false
            let frame = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            let cropRect = CGRect(
                x: (normalizedRect.minX * CGFloat(frame.width)).rounded(.down),
                y: (normalizedRect.minY * CGFloat(frame.height)).rounded(.down),
                width: max(1, (normalizedRect.width * CGFloat(frame.width)).rounded()),
                height: max(1, (normalizedRect.height * CGFloat(frame.height)).rounded())
            ).intersection(CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
            guard !cropRect.isEmpty, let crop = frame.cropping(to: cropRect) else { return nil }

            let longSide = max(crop.width, crop.height)
            guard longSide > maxDimension else { return jpegData(from: crop, compression: compression) }
            let factor = CGFloat(maxDimension) / CGFloat(longSide)
            let width = max(1, Int((CGFloat(crop.width) * factor).rounded()))
            let height = max(1, Int((CGFloat(crop.height) * factor).rounded()))
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ) else { return nil }
            NSGraphicsContext.saveGraphicsState()
            let context = NSGraphicsContext(bitmapImageRep: rep)
            NSGraphicsContext.current = context
            context?.imageInterpolation = .high
            NSImage(cgImage: crop, size: .zero).draw(
                in: NSRect(x: 0, y: 0, width: width, height: height),
                from: .zero, operation: .copy, fraction: 1.0
            )
            NSGraphicsContext.restoreGraphicsState()
            return rep.representation(using: .jpeg, properties: [.compressionFactor: compression])
        } catch {
            logger.error("Zoom capture failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Pre-fetches shareable content so the first capture after a permission grant
    /// skips the cold enumeration. Safe to call repeatedly.
    public static func prewarm() {
        guard CGPreflightScreenCaptureAccess() else { return }
        Task { @MainActor in _ = try? await shareableContent() }
    }

    /// The focused window of `pid` as a normalized (top-left origin, [0,1]) rect
    /// on the cursor display — the crop the native-resolution OCR pass needs.
    /// Returns nil when the window is unavailable or not on the cursor display.
    public static func focusedWindowNormalizedRect(pid: pid_t) -> CGRect? {
        guard AXIsProcessTrusted() else { return nil }
        let appRef = AXUIElementCreateApplication(pid)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &focusedRef) == .success,
              let focusedRef else { return nil }
        let window = focusedRef as! AXUIElement

        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef, let sizeRef else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionRef as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size),
              size.width > 1, size.height > 1 else { return nil }

        // AX coordinates are global top-left; CGDisplayBounds matches that space.
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main,
              let displayID = screen.displayID else { return nil }
        let displayBounds = CGDisplayBounds(displayID)
        let windowRect = CGRect(origin: origin, size: size).intersection(displayBounds)
        guard !windowRect.isEmpty else { return nil }
        return CGRect(
            x: (windowRect.minX - displayBounds.minX) / displayBounds.width,
            y: (windowRect.minY - displayBounds.minY) / displayBounds.height,
            width: windowRect.width / displayBounds.width,
            height: windowRect.height / displayBounds.height
        )
    }

    /// The display the cursor is on right now — lets the rewind recorder notice
    /// the user moved to another monitor and follow them there.
    public static func currentCursorDisplayID() async -> CGDirectDisplayID? {
        guard CGPreflightScreenCaptureAccess() else { return nil }
        guard let content = try? await shareableContent() else { return nil }
        return cursorDisplay(in: content)?.displayID
    }

    /// Builds a continuous `SCStream` over the cursor display for the always-on
    /// recorder, reusing the same cursor-display selection, own-window exclusion,
    /// and 1920 long-side cap as the single-frame path. Frames arrive on
    /// `sampleHandlerQueue`; `output` receives them and also acts as the stream
    /// delegate (for stop/error callbacks).
    ///
    /// FAIL-CLOSED: returns `nil` without building anything if Screen Recording
    /// isn't already granted.
    public static func makeRewindStream(
        output: SCStreamOutput & SCStreamDelegate,
        sampleHandlerQueue: DispatchQueue,
        fps: Int32 = 1
    ) async throws -> (stream: SCStream, displayID: CGDirectDisplayID)? {
        guard CGPreflightScreenCaptureAccess() else {
            logger.info("Rewind stream skipped — Screen Recording not granted (fail-closed).")
            return nil
        }
        let content = try await shareableContent()
        guard let display = cursorDisplay(in: content) else {
            logger.info("Rewind stream skipped — no display available.")
            return nil
        }

        let filter = SCContentFilter(display: display, excludingWindows: ownAppWindows(in: content))

        let configuration = SCStreamConfiguration()
        let (width, height) = outputPixelSize(for: display)
        configuration.width = width
        configuration.height = height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: max(fps, 1))
        configuration.queueDepth = 3
        configuration.showsCursor = true
        configuration.pixelFormat = kCVPixelFormatType_32BGRA

        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: sampleHandlerQueue)
        return (stream, display.displayID)
    }

    private static func capture(includeImage: Bool, includeOCR: Bool = true) async throws -> ScreenContextSample? {
        let content = try await shareableContent()
        guard let display = cursorDisplay(in: content) else {
            logger.info("Capture skipped — no display available.")
            return nil
        }

        let filter = SCContentFilter(display: display, excludingWindows: ownAppWindows(in: content))

        let configuration = SCStreamConfiguration()
        let (width, height) = outputPixelSize(for: display)
        configuration.width = width
        configuration.height = height
        configuration.showsCursor = false

        let cgImage = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )

        guard let png = pngData(from: cgImage) else {
            logger.error("Capture failed — could not encode frame to PNG.")
            return nil
        }

        let front = NSWorkspace.shared.frontmostApplication
        let isCursorScreen = appKitFrame(for: display).contains(NSEvent.mouseLocation)
        let text = includeOCR ? await ScreenTextRecognizer.recognize(inPNG: png) : ""

        return ScreenContextSample(
            ocrText: text,
            frontAppName: front?.localizedName,
            frontBundleIdentifier: front?.bundleIdentifier,
            pixelWidth: cgImage.width,
            pixelHeight: cgImage.height,
            isCursorScreen: isCursorScreen,
            imagePNG: includeImage ? png : nil
        )
    }

    private static func shareableContent() async throws -> SCShareableContent {
        if let cached = cachedContent, cacheExpiresAt > Date() {
            return cached
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        cachedContent = content
        cacheExpiresAt = Date().addingTimeInterval(cacheLifetime)
        return content
    }

    /// Excludes Cascade's own windows (overlays, dock, main window) so we never
    /// record our own UI back into the employee's context.
    private static func ownAppWindows(in content: SCShareableContent) -> [SCWindow] {
        let ownBundle = Bundle.main.bundleIdentifier
        return content.windows.filter { $0.owningApplication?.bundleIdentifier == ownBundle }
    }

    private static func cursorDisplay(in content: SCShareableContent) -> SCDisplay? {
        guard !content.displays.isEmpty else { return nil }
        let mouse = NSEvent.mouseLocation
        let screens = nsScreensByDisplayID()

        if let onCursor = content.displays.first(where: { display in
            (screens[display.displayID]?.frame ?? cgFrame(of: display)).contains(mouse)
        }) {
            return onCursor
        }

        if let mainID = NSScreen.main?.displayID,
           let mainDisplay = content.displays.first(where: { $0.displayID == mainID }) {
            return mainDisplay
        }
        return content.displays.first
    }

    private static func outputPixelSize(for display: SCDisplay) -> (Int, Int) {
        let scale = nsScreensByDisplayID()[display.displayID]?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2.0
        let nativeWidth = max(1, Int((CGFloat(display.width) * scale).rounded()))
        let nativeHeight = max(1, Int((CGFloat(display.height) * scale).rounded()))

        if nativeWidth >= nativeHeight {
            let width = min(nativeWidth, maxPixelDimension)
            let height = Int((CGFloat(width) * CGFloat(nativeHeight) / CGFloat(nativeWidth)).rounded())
            return (max(width, 1), max(height, 1))
        } else {
            let height = min(nativeHeight, maxPixelDimension)
            let width = Int((CGFloat(height) * CGFloat(nativeWidth) / CGFloat(nativeHeight)).rounded())
            return (max(width, 1), max(height, 1))
        }
    }

    private static func pngData(from cgImage: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }

    private static func jpegData(from cgImage: CGImage, compression: Double) -> Data? {
        NSBitmapImageRep(cgImage: cgImage).representation(using: .jpeg, properties: [.compressionFactor: compression])
    }

    /// Maps each `SCDisplay` to its `NSScreen` so we can reason about cursor
    /// position in AppKit (bottom-left origin) coordinates, which is the space
    /// `NSEvent.mouseLocation` uses.
    private static func nsScreensByDisplayID() -> [CGDirectDisplayID: NSScreen] {
        var map: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let id = screen.displayID {
                map[id] = screen
            }
        }
        return map
    }

    private static func appKitFrame(for display: SCDisplay) -> CGRect {
        nsScreensByDisplayID()[display.displayID]?.frame ?? cgFrame(of: display)
    }

    private static func cgFrame(of display: SCDisplay) -> CGRect {
        CGRect(
            x: display.frame.origin.x,
            y: display.frame.origin.y,
            width: CGFloat(display.width),
            height: CGFloat(display.height)
        )
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
