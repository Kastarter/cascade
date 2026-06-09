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
    ///
    /// FAIL-CLOSED: if Screen Recording is not already granted this returns `nil`
    /// without ever calling a capture path or triggering a prompt, per the
    /// architecture's permission rules.
    public static func captureCursorScreenContext(includeImage: Bool = false) async -> ScreenContextSample? {
        guard CGPreflightScreenCaptureAccess() else {
            logger.info("Capture skipped — Screen Recording not granted (fail-closed).")
            return nil
        }
        do {
            return try await capture(includeImage: includeImage)
        } catch {
            logger.error("Screen capture failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Pre-fetches shareable content so the first capture after a permission grant
    /// skips the cold enumeration. Safe to call repeatedly.
    public static func prewarm() {
        guard CGPreflightScreenCaptureAccess() else { return }
        Task { @MainActor in _ = try? await shareableContent() }
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
    ) async throws -> SCStream? {
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
        return stream
    }

    private static func capture(includeImage: Bool) async throws -> ScreenContextSample? {
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
        let text = await ScreenTextRecognizer.recognize(inPNG: png)

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
