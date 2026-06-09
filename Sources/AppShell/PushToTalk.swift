import AppKit
import Combine

/// Global push-to-talk: hold the **Right Command (⌘)** key to talk to the cursor
/// agent. Uses `NSEvent` flagsChanged monitors (delivered on the main thread), so
/// it works while you're in any app. Requires the same Accessibility / Input
/// Monitoring trust as the use-device hotkey.
@MainActor
public final class PushToTalkMonitor {
    public var onPress: (() -> Void)?
    public var onRelease: (() -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var held = false

    /// Right Command key code.
    private static let talkKeyCode: UInt16 = 54

    public init() {}

    public func start() {
        guard globalMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let isTalkKey = event.keyCode == Self.talkKeyCode
            let commandDown = event.modifierFlags.contains(.command)
            Task { @MainActor in self?.handle(isTalkKey: isTalkKey, down: commandDown) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let isTalkKey = event.keyCode == Self.talkKeyCode
            let commandDown = event.modifierFlags.contains(.command)
            Task { @MainActor in self?.handle(isTalkKey: isTalkKey, down: commandDown) }
            return event
        }
    }

    public func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    private func handle(isTalkKey: Bool, down: Bool) {
        guard isTalkKey else { return }
        if down, !held {
            held = true
            onPress?()
        } else if !down, held {
            held = false
            onRelease?()
        }
    }
}
