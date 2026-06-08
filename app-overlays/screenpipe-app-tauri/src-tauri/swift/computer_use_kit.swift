// Cascade ComputerUseKit
//
// Compact macOS computer-use bridge for Cascade's Rust ScreenDriver. Portions
// are adapted from MIT-licensed reference implementations:
// - OpenClicky: jasonkneen/openclicky, native Swift CUA runtime and local bridge.
// - Clicky: farzaa/clicky, ScreenCaptureKit cursor-display capture flow.
// - TipTour macOS: milind-soni/tiptour-macos, capture timestamps and permission flow.
//
// This file intentionally has no third-party dependencies or bundled sidecars.

import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import ScreenCaptureKit

private enum CUBridgeError: LocalizedError {
    case invalidJSON
    case invalidAction(String)
    case permissionMissing(String)
    case timeout(String)
    case captureUnavailable(String)
    case eventCreationFailed(String)
    case unknownKey(String)

    var errorDescription: String? {
        switch self {
        case .invalidJSON:
            return "Invalid JSON payload"
        case .invalidAction(let detail):
            return "Invalid action: \(detail)"
        case .permissionMissing(let name):
            return "\(name) permission is required"
        case .timeout(let operation):
            return "\(operation) timed out"
        case .captureUnavailable(let detail):
            return "Screen capture unavailable: \(detail)"
        case .eventCreationFailed(let detail):
            return "Could not create input event: \(detail)"
        case .unknownKey(let key):
            return "Unknown key: \(key)"
        }
    }
}

private struct CUWindowInfo {
    let id: Int
    let pid: pid_t
    let owner: String
    let title: String
    let bounds: CGRect
    let zIndex: Int
    let isOnScreen: Bool
    let layer: Int

    var bundleIdentifier: String? {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

    var json: [String: Any] {
        var result: [String: Any] = [
            "id": id,
            "pid": Int(pid),
            "owner": owner,
            "title": title,
            "bounds": CUJSON.rect(bounds),
            "zIndex": zIndex,
            "isOnScreen": isOnScreen,
            "layer": layer
        ]
        result.setNullable("bundleId", bundleIdentifier)
        return result
    }
}

private struct CUDisplayInfo {
    let id: CGDirectDisplayID?
    let frame: CGRect
    let cgFrame: CGRect
    let scale: CGFloat
    let containsCursor: Bool

    var json: [String: Any] {
        var result: [String: Any] = [
            "frame": CUJSON.rect(frame),
            "cgFrame": CUJSON.rect(cgFrame),
            "scale": Double(scale),
            "containsCursor": containsCursor
        ]
        if let id {
            result["id"] = Int(id)
        } else {
            result["id"] = NSNull()
        }
        return result
    }
}

private enum CUJSON {
    static func envelope(data: [String: Any]) -> UnsafeMutablePointer<CChar>? {
        cString(["ok": true, "data": data])
    }

    static func envelope(error: Error) -> UnsafeMutablePointer<CChar>? {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return cString(["ok": false, "error": message])
    }

    static func parse(_ ptr: UnsafePointer<CChar>?) throws -> [String: Any] {
        guard let ptr else { return [:] }
        let text = String(cString: ptr).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [:] }
        guard let data = text.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CUBridgeError.invalidJSON
        }
        return object
    }

    static func cString(_ object: [String: Any]) -> UnsafeMutablePointer<CChar>? {
        let safeObject = sanitize(object)
        do {
            let data = try JSONSerialization.data(withJSONObject: safeObject, options: [])
            guard let text = String(data: data, encoding: .utf8) else {
                return strdup("{\"ok\":false,\"error\":\"Could not encode JSON\"}")
            }
            return strdup(text)
        } catch {
            let escaped = error.localizedDescription
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return strdup("{\"ok\":false,\"error\":\"\(escaped)\"}")
        }
    }

    static func rect(_ rect: CGRect) -> [String: Any] {
        [
            "x": Double(rect.origin.x),
            "y": Double(rect.origin.y),
            "width": Double(rect.width),
            "height": Double(rect.height)
        ]
    }

    private static func sanitize(_ value: Any) -> Any {
        switch value {
        case let dictionary as [String: Any]:
            return dictionary.reduce(into: [String: Any]()) { result, entry in
                result[entry.key] = sanitize(entry.value)
            }
        case let array as [Any]:
            return array.map(sanitize)
        case let number as NSNumber:
            return number
        case let string as String:
            return string
        case _ as NSNull:
            return NSNull()
        case let bool as Bool:
            return bool
        case let int as Int:
            return int
        case let int32 as Int32:
            return Int(int32)
        case let int64 as Int64:
            return int64
        case let uint32 as UInt32:
            return Int(uint32)
        case let double as Double:
            return double.isFinite ? double : 0
        case let float as Float:
            return float.isFinite ? Double(float) : 0
        case let cgFloat as CGFloat:
            return cgFloat.isFinite ? Double(cgFloat) : 0
        case Optional<Any>.none:
            return NSNull()
        default:
            return String(describing: value)
        }
    }
}

private extension Dictionary where Key == String, Value == Any {
    mutating func setNullable(_ key: String, _ value: Any?) {
        self[key] = value ?? NSNull()
    }
}

private final class CUResultBox<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}

private enum CUThread {
    static func mainSync<T>(timeout seconds: TimeInterval = 8, _ body: @escaping @MainActor () async throws -> T) throws -> T {
        if Thread.isMainThread {
            throw CUBridgeError.invalidAction("ComputerUseKit cannot block the main thread for async capture")
        }

        let semaphore = DispatchSemaphore(value: 0)
        let box = CUResultBox<T>()

        Task { @MainActor in
            let nextResult: Result<T, Error>
            do {
                nextResult = .success(try await body())
            } catch {
                nextResult = .failure(error)
            }
            box.result = nextResult
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + seconds) == .success else {
            throw CUBridgeError.timeout("ComputerUseKit operation")
        }

        return try box.result?.get() ?? { throw CUBridgeError.timeout("ComputerUseKit result") }()
    }
}

private enum CUStatus {
    static func make() -> [String: Any] {
        let screenRecordingGranted = CGPreflightScreenCaptureAccess()
        let accessibilityGranted = AXIsProcessTrusted()
        let inputMonitoringGranted = inputMonitoringLikelyGranted()
        let screenCaptureKitAvailable = isScreenCaptureKitAvailable()
        let nativeCaptureAvailable = screenCaptureKitAvailable || legacyCGWindowListCreateImageAvailable()
        let display = CUDisplay.currentForCursor()
        let windows = CUWindowEnumerator.visibleWindows()
        let focusedWindow = CUWindowEnumerator.frontmostTargetWindow(from: windows)
        let frontmostApp = NSWorkspace.shared.frontmostApplication

        var missing: [String] = []
        if !screenRecordingGranted {
            missing.append("screen_recording")
        }
        if !accessibilityGranted {
            missing.append("accessibility")
        }
        if !inputMonitoringGranted {
            missing.append("input_monitoring")
        }
        var data: [String: Any] = [
            "screenRecordingGranted": screenRecordingGranted,
            "accessibilityGranted": accessibilityGranted,
            "inputMonitoringLikelyGranted": inputMonitoringGranted,
            "screenCaptureKitAvailable": screenCaptureKitAvailable,
            "screenCaptureAvailable": nativeCaptureAvailable,
            "visibleWindowCount": windows.count,
            "displayScale": Double(display.scale),
            "displayFrame": CUJSON.rect(display.frame),
            "display": display.json,
            "missing": missing
        ]
        data.setNullable("activeAppName", frontmostApp?.localizedName)
        data.setNullable("activeBundleId", frontmostApp?.bundleIdentifier)
        data.setNullable("focusedWindow", focusedWindow?.json)
        data.setNullable("focusedWindowTitle", focusedWindow?.title)
        data.setNullable("focusedWindowOwner", focusedWindow?.owner)
        return data
    }

    private static func isScreenCaptureKitAvailable() -> Bool {
        if #available(macOS 14.0, *) {
            return true
        }
        return false
    }

    private static func legacyCGWindowListCreateImageAvailable() -> Bool {
        guard let handle = dlopen(
            "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
            RTLD_LAZY
        ) else {
            return false
        }
        defer { dlclose(handle) }
        return dlsym(handle, "CGWindowListCreateImage") != nil
    }

    private static func inputMonitoringLikelyGranted() -> Bool {
        if #available(macOS 10.15, *) {
            return CGPreflightListenEventAccess()
        }
        return true
    }
}

private enum CUDisplay {
    static func currentForCursor() -> CUDisplayInfo {
        let cursor = NSEvent.mouseLocation
        return display(containing: cursor)
    }

    static func display(containing point: CGPoint) -> CUDisplayInfo {
        let matched = NSScreen.screens.first { $0.frame.contains(point) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen = matched else {
            return CUDisplayInfo(id: nil, frame: .zero, cgFrame: .zero, scale: 1, containsCursor: false)
        }
        return info(for: screen, containsCursor: screen.frame.contains(point))
    }

    static func info(for screen: NSScreen, containsCursor: Bool) -> CUDisplayInfo {
        let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        let cgFrame = displayID.map(CGDisplayBounds) ?? screen.frame
        return CUDisplayInfo(
            id: displayID,
            frame: screen.frame,
            cgFrame: cgFrame,
            scale: screen.backingScaleFactor,
            containsCursor: containsCursor
        )
    }

    static func screenByDisplayID() -> [CGDirectDisplayID: NSScreen] {
        var result: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                result[displayID] = screen
            }
        }
        return result
    }
}

private enum CUWindowEnumerator {
    static func visibleWindows() -> [CUWindowInfo] {
        enumerate(options: [.optionOnScreenOnly, .excludeDesktopElements])
    }

    static func frontmostTargetWindow(from windows: [CUWindowInfo]? = nil) -> CUWindowInfo? {
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let frontmostBundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let candidates = (windows ?? visibleWindows())
            .filter { $0.isOnScreen && $0.layer == 0 && $0.bounds.width > 80 && $0.bounds.height > 60 }
            .filter { window in
                guard let app = NSRunningApplication(processIdentifier: window.pid) else { return true }
                return app.bundleIdentifier != ownBundleIdentifier
            }

        if let frontmostBundleIdentifier, frontmostBundleIdentifier != ownBundleIdentifier {
            let focused = candidates.filter {
                NSRunningApplication(processIdentifier: $0.pid)?.bundleIdentifier == frontmostBundleIdentifier
            }
            if let topFocused = focused.max(by: { $0.zIndex < $1.zIndex }) {
                return topFocused
            }
        }

        return candidates.max(by: { $0.zIndex < $1.zIndex })
    }

    private static func enumerate(options: CGWindowListOption) -> [CUWindowInfo] {
        guard let rawWindows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        let total = rawWindows.count
        return rawWindows.enumerated().compactMap { index, entry in
            parse(entry, zIndex: total - index)
        }
    }

    private static func parse(_ entry: [String: Any], zIndex: Int) -> CUWindowInfo? {
        guard let id = entry[kCGWindowNumber as String] as? Int,
              let rawPid = entry[kCGWindowOwnerPID as String] as? Int,
              let pid = pid_t(exactly: rawPid),
              let boundsDictionary = entry[kCGWindowBounds as String] as? [String: Double] else {
            return nil
        }

        let bounds = CGRect(
            x: boundsDictionary["X"] ?? 0,
            y: boundsDictionary["Y"] ?? 0,
            width: boundsDictionary["Width"] ?? 0,
            height: boundsDictionary["Height"] ?? 0
        )

        return CUWindowInfo(
            id: id,
            pid: pid,
            owner: entry[kCGWindowOwnerName as String] as? String ?? "",
            title: entry[kCGWindowName as String] as? String ?? "",
            bounds: bounds,
            zIndex: zIndex,
            isOnScreen: entry[kCGWindowIsOnscreen as String] as? Bool ?? false,
            layer: entry[kCGWindowLayer as String] as? Int ?? 0
        )
    }
}

private struct CUObserveConfig {
    let maxDimension: Int
    let includeWindows: Bool
    let excludeOwnWindows: Bool

    init(json: [String: Any]) {
        let rawMax = CUValue.int(json["maxDimension"])
            ?? CUValue.int(json["max_dimension"])
            ?? 1280
        maxDimension = min(max(rawMax, 512), 4096)
        includeWindows = CUValue.bool(json["includeWindows"]) ?? CUValue.bool(json["include_windows"]) ?? true
        excludeOwnWindows = CUValue.bool(json["excludeOwnWindows"]) ?? CUValue.bool(json["exclude_own_windows"]) ?? true
    }
}

private enum CUObserver {
    static func observe(config: CUObserveConfig) async throws -> [String: Any] {
        guard CGPreflightScreenCaptureAccess() else {
            throw CUBridgeError.permissionMissing("Screen Recording")
        }

        do {
            if #available(macOS 14.0, *) {
                return try await observeWithScreenCaptureKit(config: config)
            }
        } catch {
            return try observeWithCGWindowList(config: config, screenCaptureKitError: error)
        }

        return try observeWithCGWindowList(config: config, screenCaptureKitError: nil)
    }

    @available(macOS 14.0, *)
    private static func observeWithScreenCaptureKit(config: CUObserveConfig) async throws -> [String: Any] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard !content.displays.isEmpty else {
            throw CUBridgeError.captureUnavailable("No display available")
        }

        let cursor = NSEvent.mouseLocation
        let screenByDisplayID = CUDisplay.screenByDisplayID()
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let ownWindows = config.excludeOwnWindows
            ? content.windows.filter { $0.owningApplication?.bundleIdentifier == ownBundleIdentifier }
            : []

        let sortedDisplays = content.displays.sorted { first, second in
            let firstFrame = screenByDisplayID[first.displayID]?.frame ?? first.frame
            let secondFrame = screenByDisplayID[second.displayID]?.frame ?? second.frame
            let firstContainsCursor = firstFrame.contains(cursor)
            let secondContainsCursor = secondFrame.contains(cursor)
            if firstContainsCursor != secondContainsCursor {
                return firstContainsCursor
            }
            return first.displayID < second.displayID
        }

        let display = sortedDisplays[0]
        let nsScreen = screenByDisplayID[display.displayID]
        let displayFrame = nsScreen?.frame
            ?? CGRect(x: display.frame.origin.x, y: display.frame.origin.y, width: CGFloat(display.width), height: CGFloat(display.height))
        let displayScale = nsScreen?.backingScaleFactor ?? {
            guard displayFrame.width > 0 else { return CGFloat(1) }
            return CGFloat(display.width) / displayFrame.width
        }()

        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(displayFrame.width.rounded()))
        configuration.height = max(1, Int(displayFrame.height.rounded()))
        configuration.showsCursor = true

        let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
        let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        let imageData = try encodePNG(cgImage)

        return observePayload(
            imageData: imageData,
            imageWidth: cgImage.width,
            imageHeight: cgImage.height,
            displayID: display.displayID,
            displayFrame: displayFrame,
            displayCGFrame: CGDisplayBounds(display.displayID),
            displayScale: displayScale,
            cursor: cursor,
            captureBackend: "screencapturekit",
            config: config,
            fallbackReason: nil
        )
    }

    private static func observeWithCGWindowList(config: CUObserveConfig, screenCaptureKitError: Error?) throws -> [String: Any] {
        let cursor = NSEvent.mouseLocation
        let display = CUDisplay.display(containing: cursor)
        let captureRect = display.id.map(CGDisplayBounds) ?? CGRect.infinite
        guard let captured = legacyCGWindowListCreateImage(
            rect: captureRect,
            options: [.optionOnScreenOnly, .excludeDesktopElements],
            windowID: kCGNullWindowID,
            imageOptions: [.bestResolution, .boundsIgnoreFraming]
        ) else {
            let detail = screenCaptureKitError?.localizedDescription ?? "CGWindowListCreateImage returned nil"
            throw CUBridgeError.captureUnavailable(detail)
        }

        let fitted = resizeIfNeeded(
            captured,
            width: max(1, Int(display.frame.width.rounded())),
            height: max(1, Int(display.frame.height.rounded()))
        )
        let imageData = try encodePNG(fitted)
        return observePayload(
            imageData: imageData,
            imageWidth: fitted.width,
            imageHeight: fitted.height,
            displayID: display.id,
            displayFrame: display.frame,
            displayCGFrame: display.cgFrame,
            displayScale: display.scale,
            cursor: cursor,
            captureBackend: "cgwindowlist",
            config: config,
            fallbackReason: screenCaptureKitError?.localizedDescription
        )
    }

    private static func observePayload(
        imageData: Data,
        imageWidth: Int,
        imageHeight: Int,
        displayID: CGDirectDisplayID?,
        displayFrame: CGRect,
        displayCGFrame: CGRect,
        displayScale: CGFloat,
        cursor: CGPoint,
        captureBackend: String,
        config: CUObserveConfig,
        fallbackReason: String?
    ) -> [String: Any] {
        let windows = CUWindowEnumerator.visibleWindows()
        let focusedWindow = CUWindowEnumerator.frontmostTargetWindow(from: windows)
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let timestampMs = Int(Date().timeIntervalSince1970 * 1000)

        var data: [String: Any] = [
            "imageBase64": imageData.base64EncodedString(),
            "imageMimeType": "image/png",
            "logicalWidth": Double(displayFrame.width),
            "logicalHeight": Double(displayFrame.height),
            "screenshotWidth": imageWidth,
            "screenshotHeight": imageHeight,
            "screenshotScaleX": displayFrame.width > 0 ? Double(CGFloat(imageWidth) / displayFrame.width) : 1,
            "screenshotScaleY": displayFrame.height > 0 ? Double(CGFloat(imageHeight) / displayFrame.height) : 1,
            "displayScale": Double(displayScale),
            "displayFrame": CUJSON.rect(displayFrame),
            "displayCGFrame": CUJSON.rect(displayCGFrame),
            "cursor": [
                "x": Double(cursor.x - displayFrame.minX),
                "y": Double(displayFrame.maxY - cursor.y)
            ],
            "captureTimestampMs": timestampMs,
            "captureBackend": captureBackend,
            "visibleWindowCount": windows.count
        ]

        if let displayID {
            data["displayID"] = Int(displayID)
        } else {
            data["displayID"] = NSNull()
        }
        if config.includeWindows {
            data["windows"] = windows.prefix(30).map(\.json)
        } else {
            data["windows"] = []
        }
        data.setNullable("activeAppName", frontmostApp?.localizedName)
        data.setNullable("activeBundleId", frontmostApp?.bundleIdentifier)
        data.setNullable("activeWindowTitle", focusedWindow?.title)
        data.setNullable("focusedWindow", focusedWindow?.json)
        data.setNullable("fallbackReason", fallbackReason)
        return data
    }

    private static func fit(width: Int, height: Int, maxDimension: Int) -> (width: Int, height: Int) {
        let safeWidth = max(1, width)
        let safeHeight = max(1, height)
        let longest = max(safeWidth, safeHeight)
        guard longest > maxDimension else {
            return (safeWidth, safeHeight)
        }

        let scale = CGFloat(maxDimension) / CGFloat(longest)
        return (
            max(1, Int(CGFloat(safeWidth) * scale)),
            max(1, Int(CGFloat(safeHeight) * scale))
        )
    }

    private static func resizeIfNeeded(_ image: CGImage, width: Int, height: Int) -> CGImage {
        guard width != image.width || height != image.height else {
            return image
        }

        guard let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return image
        }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    private typealias LegacyCGWindowListCreateImageFn =
        @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    private static func legacyCGWindowListCreateImage(
        rect: CGRect,
        options: CGWindowListOption,
        windowID: CGWindowID,
        imageOptions: CGWindowImageOption
    ) -> CGImage? {
        guard let handle = dlopen(
            "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
            RTLD_LAZY
        ) else {
            return nil
        }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "CGWindowListCreateImage") else {
            return nil
        }
        let function = unsafeBitCast(symbol, to: LegacyCGWindowListCreateImageFn.self)
        return function(rect, options.rawValue, windowID, imageOptions.rawValue)?
            .takeRetainedValue()
    }

    private static func encodePNG(_ image: CGImage) throws -> Data {
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw CUBridgeError.captureUnavailable("Could not encode PNG")
        }
        return data
    }
}

private enum CUValue {
    static func string(_ value: Any?) -> String? {
        switch value {
        case let value as String:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let value as NSNumber:
            return value.stringValue
        default:
            return nil
        }
    }

    static func double(_ value: Any?) -> Double? {
        switch value {
        case let value as Double:
            return value
        case let value as CGFloat:
            return Double(value)
        case let value as Int:
            return Double(value)
        case let value as NSNumber:
            return value.doubleValue
        case let value as String:
            return Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    static func int(_ value: Any?) -> Int? {
        double(value).map { Int($0) }
    }

    static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let value as Bool:
            return value
        case let value as NSNumber:
            return value.boolValue
        case let value as String:
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "1":
                return true
            case "false", "no", "0":
                return false
            default:
                return nil
            }
        default:
            return nil
        }
    }

    static func arrayOfStrings(_ value: Any?) -> [String] {
        if let strings = value as? [String] {
            return strings
        }
        if let values = value as? [Any] {
            return values.compactMap(string)
        }
        if let string = string(value) {
            return splitChord(string).modifiers
        }
        return []
    }

    static func splitChord(_ text: String) -> (modifiers: [String], key: String) {
        let parts = text
            .split(separator: "+")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard parts.count > 1 else {
            return ([], text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return (Array(parts.dropLast()), parts.last ?? "")
    }
}

private enum CUAction {
    static func act(json: [String: Any]) throws -> [String: Any] {
        let rawType = CUValue.string(json["type"])
            ?? CUValue.string(json["action"])
            ?? CUValue.string(json["kind"])
        guard let actionType = rawType?.lowercased() else {
            throw CUBridgeError.invalidAction("missing type")
        }

        switch actionType {
        case "click", "left_click":
            try requireAccessibility()
            let point = try point(from: json)
            let clickCount = max(1, CUValue.int(json["clickCount"]) ?? CUValue.int(json["click_count"]) ?? 1)
            try CUMouse.click(at: point, count: clickCount)
            return actionResult(type: actionType, point: point, extra: ["clickCount": clickCount])
        case "double_click", "doubleclick":
            try requireAccessibility()
            let point = try point(from: json)
            try CUMouse.click(at: point, count: 2)
            return actionResult(type: actionType, point: point, extra: ["clickCount": 2])
        case "type", "type_text", "text":
            try requireAccessibility()
            guard let text = CUValue.string(json["text"]) ?? CUValue.string(json["value"]) else {
                throw CUBridgeError.invalidAction("type action missing text")
            }
            let delay = max(0, min(200, CUValue.int(json["delayMilliseconds"]) ?? CUValue.int(json["delay_ms"]) ?? 20))
            try CUKeyboard.typeCharacters(text, delayMilliseconds: delay)
            return ["performed": "type", "characters": text.count, "delayMilliseconds": delay]
        case "key", "press_key", "keyboard", "keyboard_shortcut", "hotkey":
            try requireAccessibility()
            guard let rawKey = CUValue.string(json["key"])
                ?? CUValue.string(json["name"])
                ?? CUValue.string(json["shortcut"])
                ?? CUValue.string(json["value"]) else {
                throw CUBridgeError.invalidAction("key action missing key")
            }
            let chord = CUValue.splitChord(rawKey)
            let explicitModifiers = CUValue.arrayOfStrings(json["modifiers"])
            let key = chord.key
            let modifiers = explicitModifiers.isEmpty ? chord.modifiers : explicitModifiers
            try CUKeyboard.press(key, modifiers: modifiers)
            return ["performed": "key", "key": key, "modifiers": modifiers]
        case "scroll", "wheel":
            try requireAccessibility()
            let delta = scrollDelta(from: json)
            let atPoint = optionalPoint(from: json).map(appKitPoint)
            try CUMouse.scroll(deltaX: delta.x, deltaY: delta.y, at: atPoint)
            var result: [String: Any] = ["performed": "scroll", "deltaX": delta.x, "deltaY": delta.y]
            result.setNullable("x", atPoint?.x)
            result.setNullable("y", atPoint?.y)
            return result
        case "open_app", "openapp", "launch_app", "launch":
            let launched = try CUAppLauncher.open(json: json)
            return ["performed": "open_app", "target": launched]
        default:
            throw CUBridgeError.invalidAction("unsupported type \(actionType)")
        }
    }

    private static func requireAccessibility() throws {
        guard AXIsProcessTrusted() else {
            throw CUBridgeError.permissionMissing("Accessibility")
        }
    }

    private static func point(from json: [String: Any]) throws -> CGPoint {
        if let point = optionalPoint(from: json) {
            return appKitPoint(fromAgentPoint: point)
        }
        throw CUBridgeError.invalidAction("missing x/y point")
    }

    private static func optionalPoint(from json: [String: Any]) -> CGPoint? {
        if let x = CUValue.double(json["x"]),
           let y = CUValue.double(json["y"]) {
            return CGPoint(x: x, y: y)
        }

        if let point = json["point"] as? [String: Any],
           let x = CUValue.double(point["x"]),
           let y = CUValue.double(point["y"]) {
            return CGPoint(x: x, y: y)
        }

        if let coordinate = json["coordinate"] as? [String: Any],
           let x = CUValue.double(coordinate["x"]),
           let y = CUValue.double(coordinate["y"]) {
            return CGPoint(x: x, y: y)
        }

        return nil
    }

    private static func appKitPoint(fromAgentPoint point: CGPoint) -> CGPoint {
        let display = CUDisplay.currentForCursor()
        return CGPoint(
            x: display.frame.minX + point.x,
            y: display.frame.maxY - point.y
        )
    }

    private static func scrollDelta(from json: [String: Any]) -> (x: Int32, y: Int32) {
        let amount = Int32(max(-2000, min(2000, CUValue.int(json["amount"]) ?? 520)))
        let rawDirection = CUValue.string(json["direction"])?.lowercased()
        let deltaX = CUValue.int(json["deltaX"]) ?? CUValue.int(json["dx"])
        let deltaY = CUValue.int(json["deltaY"]) ?? CUValue.int(json["dy"])

        if let deltaX, let deltaY {
            return (Int32(max(-2000, min(2000, deltaX))), Int32(max(-2000, min(2000, deltaY))))
        }

        switch rawDirection {
        case "up":
            return (0, abs(amount))
        case "left":
            return (-abs(amount), 0)
        case "right":
            return (abs(amount), 0)
        default:
            return (0, -abs(amount))
        }
    }

    private static func actionResult(type: String, point: CGPoint, extra: [String: Any]) -> [String: Any] {
        var result = extra
        result["performed"] = type
        result["x"] = Double(point.x)
        result["y"] = Double(point.y)
        return result
    }
}

private enum CUMouse {
    static func click(at appKitPoint: CGPoint, count: Int) throws {
        let quartzPoint = quartzPoint(fromAppKitPoint: appKitPoint)
        try postMouseEvent(type: .mouseMoved, at: quartzPoint)
        for index in 0..<max(1, count) {
            try postMouseEvent(type: .leftMouseDown, at: quartzPoint, clickState: index + 1)
            usleep(35_000)
            try postMouseEvent(type: .leftMouseUp, at: quartzPoint, clickState: index + 1)
            if index + 1 < count {
                usleep(80_000)
            }
        }
    }

    static func scroll(deltaX: Int32, deltaY: Int32, at appKitPoint: CGPoint?) throws {
        if let appKitPoint {
            let quartzPoint = quartzPoint(fromAppKitPoint: appKitPoint)
            try postMouseEvent(type: .mouseMoved, at: quartzPoint)
        }

        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: deltaY,
            wheel2: deltaX,
            wheel3: 0
        ) else {
            throw CUBridgeError.eventCreationFailed("scroll deltaX=\(deltaX) deltaY=\(deltaY)")
        }
        event.post(tap: CGEventTapLocation.cghidEventTap)
    }

    private static func quartzPoint(fromAppKitPoint point: CGPoint) -> CGPoint {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }),
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return point
        }

        let appKitFrame = screen.frame
        let quartzFrame = CGDisplayBounds(displayID)
        let localX = point.x - appKitFrame.origin.x
        let localYFromTop = appKitFrame.maxY - point.y
        return CGPoint(
            x: quartzFrame.origin.x + localX,
            y: quartzFrame.origin.y + localYFromTop
        )
    }

    private static func postMouseEvent(type: CGEventType, at point: CGPoint, clickState: Int = 1) throws {
        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else {
            throw CUBridgeError.eventCreationFailed("mouse \(type.rawValue) at \(Int(point.x)),\(Int(point.y))")
        }
        event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        event.post(tap: .cghidEventTap)
    }
}

private enum CUKeyboard {
    static func press(_ key: String, modifiers: [String] = []) throws {
        guard let code = virtualKeyCode(for: key) else {
            throw CUBridgeError.unknownKey(key)
        }
        let flags = modifierMask(for: modifiers)
        try sendKey(code: code, down: true, flags: flags)
        usleep(20_000)
        try sendKey(code: code, down: false, flags: flags)
    }

    static func typeCharacters(_ text: String, delayMilliseconds: Int) throws {
        for character in text {
            try sendUnicodeCharacter(character)
            if delayMilliseconds > 0 {
                usleep(UInt32(delayMilliseconds) * 1_000)
            }
        }
    }

    private static func sendKey(code: Int, down: Bool, flags: CGEventFlags) throws {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: down) else {
            throw CUBridgeError.eventCreationFailed("key code=\(code) down=\(down)")
        }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    private static func sendUnicodeCharacter(_ character: Character) throws {
        let utf16 = Array(String(character).utf16)
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: keyDown) else {
                throw CUBridgeError.eventCreationFailed("unicode character \(character)")
            }
            utf16.withUnsafeBufferPointer { buffer in
                if let baseAddress = buffer.baseAddress {
                    event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: baseAddress)
                }
            }
            event.post(tap: .cghidEventTap)
        }
    }

    private static func modifierMask(for modifiers: [String]) -> CGEventFlags {
        var mask: CGEventFlags = []
        for modifier in modifiers {
            switch modifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "cmd", "command", "meta":
                mask.insert(.maskCommand)
            case "shift":
                mask.insert(.maskShift)
            case "option", "alt":
                mask.insert(.maskAlternate)
            case "ctrl", "control":
                mask.insert(.maskControl)
            case "fn", "function":
                mask.insert(.maskSecondaryFn)
            default:
                break
            }
        }
        return mask
    }

    private static func virtualKeyCode(for name: String) -> Int? {
        let normalized = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
        if let named = namedKeys[normalized] {
            return named
        }
        guard normalized.count == 1, let first = normalized.first else {
            return nil
        }
        if let letter = letterKeys[first] {
            return letter
        }
        if let digit = digitKeys[first] {
            return digit
        }
        if let symbol = symbolKeys[first] {
            return symbol
        }
        return nil
    }

    private static let namedKeys: [String: Int] = [
        "return": 0x24, "enter": 0x24,
        "tab": 0x30,
        "space": 0x31, "spacebar": 0x31,
        "delete": 0x33, "backspace": 0x33,
        "forwarddelete": 0x75, "del": 0x75,
        "escape": 0x35, "esc": 0x35,
        "left": 0x7B, "leftarrow": 0x7B,
        "right": 0x7C, "rightarrow": 0x7C,
        "down": 0x7D, "downarrow": 0x7D,
        "up": 0x7E, "uparrow": 0x7E,
        "home": 0x73, "end": 0x77,
        "pageup": 0x74, "pagedown": 0x79,
        "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76,
        "f5": 0x60, "f6": 0x61, "f7": 0x62, "f8": 0x64,
        "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F
    ]

    private static let letterKeys: [Character: Int] = [
        "a": 0x00, "b": 0x0B, "c": 0x08, "d": 0x02, "e": 0x0E, "f": 0x03,
        "g": 0x05, "h": 0x04, "i": 0x22, "j": 0x26, "k": 0x28, "l": 0x25,
        "m": 0x2E, "n": 0x2D, "o": 0x1F, "p": 0x23, "q": 0x0C, "r": 0x0F,
        "s": 0x01, "t": 0x11, "u": 0x20, "v": 0x09, "w": 0x0D, "x": 0x07,
        "y": 0x10, "z": 0x06
    ]

    private static let digitKeys: [Character: Int] = [
        "0": 0x1D, "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15,
        "5": 0x17, "6": 0x16, "7": 0x1A, "8": 0x1C, "9": 0x19
    ]

    private static let symbolKeys: [Character: Int] = [
        "`": 0x32, "-": 0x1B, "=": 0x18, "[": 0x21, "]": 0x1E,
        "\\": 0x2A, ";": 0x29, "'": 0x27, ",": 0x2B, ".": 0x2F, "/": 0x2C
    ]
}

private enum CUAppLauncher {
    static func open(json: [String: Any]) throws -> String {
        if let bundleId = CUValue.string(json["bundleId"]) ?? CUValue.string(json["bundle_id"]) {
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId),
               NSWorkspace.shared.open(appURL) {
                return bundleId
            }
            throw CUBridgeError.invalidAction("could not launch bundle id \(bundleId)")
        }

        if let path = CUValue.string(json["path"]) {
            let url = URL(fileURLWithPath: path)
            guard NSWorkspace.shared.open(url) else {
                throw CUBridgeError.invalidAction("could not open path \(path)")
            }
            return path
        }

        guard let name = CUValue.string(json["app"])
            ?? CUValue.string(json["name"])
            ?? CUValue.string(json["target"])
            ?? CUValue.string(json["value"]) else {
            throw CUBridgeError.invalidAction("open_app missing app/name/bundleId/path")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", name]
        do {
            try process.run()
            return name
        } catch {
            throw CUBridgeError.invalidAction("could not launch app \(name): \(error.localizedDescription)")
        }
    }
}

@_cdecl("cu_free_string")
public func cuFreeString(_ ptr: UnsafeMutablePointer<CChar>?) {
    if let ptr {
        free(ptr)
    }
}

@_cdecl("cu_status_json")
public func cuStatusJson() -> UnsafeMutablePointer<CChar>? {
    CUJSON.envelope(data: CUStatus.make())
}

@_cdecl("cu_observe_json")
public func cuObserveJson(_ configPtr: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    do {
        let configJSON = try CUJSON.parse(configPtr)
        let config = CUObserveConfig(json: configJSON)
        let data = try CUThread.mainSync(timeout: 10) {
            try await CUObserver.observe(config: config)
        }
        return CUJSON.envelope(data: data)
    } catch {
        return CUJSON.envelope(error: error)
    }
}

@_cdecl("cu_act_json")
public func cuActJson(_ actionPtr: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    do {
        let actionJSON = try CUJSON.parse(actionPtr)
        let data = try CUAction.act(json: actionJSON)
        return CUJSON.envelope(data: data)
    } catch {
        return CUJSON.envelope(error: error)
    }
}
