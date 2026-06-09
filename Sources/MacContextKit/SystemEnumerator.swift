import AppKit
import CoreGraphics
import Foundation

// App/window enumeration and display/cursor metadata. Pattern reference:
// `jasonkneen/openclicky` (`OpenClickyComputerUseRuntime` app/window enumerators)
// and its usage-log store — re-implemented as Cascade-owned, permission-light
// observation. Window geometry and owners come from CGWindowList (no Screen
// Recording needed); window titles are only present once Screen Recording is
// granted, so they degrade to nil rather than failing. See docs/THIRD_PARTY_NOTICES.md.

public struct DisplayInfo: Sendable, Equatable, Identifiable {
    public let id: UInt32
    public let frame: CGRect
    public let scale: Double
    public let isMain: Bool

    public init(id: UInt32, frame: CGRect, scale: Double, isMain: Bool) {
        self.id = id
        self.frame = frame
        self.scale = scale
        self.isMain = isMain
    }
}

public struct RunningAppInfo: Sendable, Equatable, Identifiable {
    public let id: Int32
    public let name: String
    public let bundleIdentifier: String?
    public let isActive: Bool

    public init(id: Int32, name: String, bundleIdentifier: String?, isActive: Bool) {
        self.id = id
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.isActive = isActive
    }
}

public struct WindowInfo: Sendable, Equatable, Identifiable {
    public let id: Int
    public let ownerName: String
    public let ownerPID: Int32
    public let title: String?
    public let bounds: CGRect
    public let isOnScreen: Bool

    public init(id: Int, ownerName: String, ownerPID: Int32, title: String?, bounds: CGRect, isOnScreen: Bool) {
        self.id = id
        self.ownerName = ownerName
        self.ownerPID = ownerPID
        self.title = title
        self.bounds = bounds
        self.isOnScreen = isOnScreen
    }
}

public struct SystemSnapshot: Sendable, Equatable {
    public let displays: [DisplayInfo]
    public let cursorLocation: CGPoint
    public let cursorDisplayID: UInt32?
    public let runningApps: [RunningAppInfo]
    public let windows: [WindowInfo]

    public init(
        displays: [DisplayInfo],
        cursorLocation: CGPoint,
        cursorDisplayID: UInt32?,
        runningApps: [RunningAppInfo],
        windows: [WindowInfo]
    ) {
        self.displays = displays
        self.cursorLocation = cursorLocation
        self.cursorDisplayID = cursorDisplayID
        self.runningApps = runningApps
        self.windows = windows
    }
}

@MainActor
public enum SystemEnumerator {
    public static func snapshot(includeWindows: Bool = true) -> SystemSnapshot {
        let displayList = displays()
        let cursor = NSEvent.mouseLocation
        let cursorDisplay = displayList.first { $0.frame.contains(cursor) }?.id
        return SystemSnapshot(
            displays: displayList,
            cursorLocation: cursor,
            cursorDisplayID: cursorDisplay,
            runningApps: runningApps(),
            windows: includeWindows ? onScreenWindows() : []
        )
    }

    public static func displays() -> [DisplayInfo] {
        let mainID = NSScreen.main?.displayNumber
        return NSScreen.screens.compactMap { screen in
            guard let id = screen.displayNumber else { return nil }
            return DisplayInfo(
                id: id,
                frame: screen.frame,
                scale: Double(screen.backingScaleFactor),
                isMain: id == mainID
            )
        }
    }

    /// All running applications. Consumers filter to `activationPolicy == .regular`
    /// when they only want user-facing apps; this returns everything so callers
    /// can decide.
    public static func runningApps() -> [RunningAppInfo] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard let name = app.localizedName else { return nil }
            return RunningAppInfo(
                id: app.processIdentifier,
                name: name,
                bundleIdentifier: app.bundleIdentifier,
                isActive: app.isActive
            )
        }
    }

    public static func onScreenWindows() -> [WindowInfo] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return raw.compactMap { entry in
            guard let ownerPID = entry[kCGWindowOwnerPID as String] as? Int32, ownerPID != ownPID,
                  let windowNumber = entry[kCGWindowNumber as String] as? Int,
                  let boundsDict = entry[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width > 1, bounds.height > 1 else {
                return nil
            }
            let ownerName = entry[kCGWindowOwnerName as String] as? String ?? "Unknown"
            let title = entry[kCGWindowName as String] as? String
            let onScreen = (entry[kCGWindowIsOnscreen as String] as? Bool) ?? true
            return WindowInfo(
                id: windowNumber,
                ownerName: ownerName,
                ownerPID: ownerPID,
                title: (title?.isEmpty == false) ? title : nil,
                bounds: bounds,
                isOnScreen: onScreen
            )
        }
    }
}

private extension NSScreen {
    var displayNumber: UInt32? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
    }
}
