import AppKit
import ApplicationServices
import Combine
import CascadeMemory
import CoreGraphics
import Foundation
import MacContextKit

public enum ComputerUseAction: Equatable, Sendable {
    case move(x: Double, y: Double)
    case click(x: Double, y: Double)
    case doubleClick(x: Double, y: Double)
    case tripleClick(x: Double, y: Double)
    case rightClick(x: Double, y: Double)
    /// Press at (fromX, fromY), drag to (toX, toY), release — drawing, moving
    /// objects, selecting ranges. Coordinates are CG global (top-left origin).
    case drag(fromX: Double, fromY: Double, toX: Double, toY: Double)
    case key(String, modifiers: [String])
    case typeText(String)
    case scroll(deltaX: Double, deltaY: Double)
    case openURL(String)
}

/// Shared, thread-safe stop signal for a supervised computer-use run. The visible
/// STOP control flips this; the actuator checks it before every action so STOP
/// actually halts the agent rather than only hiding the dock.
public final class AgentRunState: @unchecked Sendable {
    private let lock = NSLock()
    private var _stopRequested = false

    public init() {}

    public var isStopRequested: Bool {
        lock.lock(); defer { lock.unlock() }
        return _stopRequested
    }

    public func requestStop() {
        lock.lock(); _stopRequested = true; lock.unlock()
    }

    /// Clears the stop flag at the start of a new approved intent.
    public func reset() {
        lock.lock(); _stopRequested = false; lock.unlock()
    }
}

public struct ComputerUseHealth: Equatable, Sendable {
    public var ready: Bool
    public var permissions: CapturePermissionStatus
    public var message: String

    public init(ready: Bool, permissions: CapturePermissionStatus, message: String) {
        self.ready = ready
        self.permissions = permissions
        self.message = message
    }
}

public struct UseDeviceHotkey: Equatable, Sendable {
    public static let `default` = UseDeviceHotkey(
        keyCode: 49,
        requiredModifiers: [.control, .option],
        label: "Control-Option-Space"
    )

    public let keyCode: UInt16
    public let requiredModifiers: Set<Modifier>
    public let label: String

    public init(keyCode: UInt16, requiredModifiers: Set<Modifier>, label: String) {
        self.keyCode = keyCode
        self.requiredModifiers = requiredModifiers
        self.label = label
    }

    public func matches(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> Bool {
        guard keyCode == self.keyCode else { return false }
        let normalized = modifierFlags.intersection([.control, .option, .shift, .command])
        return requiredModifiers.allSatisfy { modifier in
            normalized.contains(modifier.eventFlag)
        }
    }

    public enum Modifier: String, Sendable {
        case control
        case option
        case shift
        case command

        fileprivate var eventFlag: NSEvent.ModifierFlags {
            switch self {
            case .control: .control
            case .option: .option
            case .shift: .shift
            case .command: .command
            }
        }
    }
}

@MainActor
public final class UseDeviceHotkeyMonitor: ObservableObject {
    public let pressed = PassthroughSubject<Void, Never>()

    @Published public private(set) var running = false
    @Published public private(set) var statusMessage = "Hotkey is stopped."

    private let hotkey: UseDeviceHotkey
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var lastPress = Date.distantPast

    public init(hotkey: UseDeviceHotkey = .default) {
        self.hotkey = hotkey
    }

    public var label: String {
        hotkey.label
    }

    public func start() {
        guard !running else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
            return event
        }
        running = true
        statusMessage = "Hotkey is listening."
    }

    public func stop() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        running = false
        statusMessage = "Hotkey is stopped."
    }

    public func triggerForTesting() {
        publishPress()
    }

    private func handle(_ event: NSEvent) {
        guard hotkey.matches(keyCode: UInt16(event.keyCode), modifierFlags: event.modifierFlags) else {
            return
        }
        let now = Date()
        guard now.timeIntervalSince(lastPress) > 0.45 else { return }
        lastPress = now
        publishPress()
    }

    private func publishPress() {
        statusMessage = "Use-device hotkey pressed."
        pressed.send(())
    }
}

public protocol ComputerUseActuator: Sendable {
    func health() async -> ComputerUseHealth
    func perform(_ action: ComputerUseAction) async throws
}

public enum ComputerUseError: Error, LocalizedError {
    case notReady(String)
    case unsupported(String)
    case stopped

    public var errorDescription: String? {
        switch self {
        case .notReady(let message): message
        case .unsupported(let message): message
        case .stopped: "Stopped by the user before the action ran."
        }
    }
}

/// Snaps a model-chosen click point to the center of the interactive element
/// under it — vision coordinates are routinely a few pixels off, and a click on
/// a button's edge that lands on the gap beside it is the classic misclick.
/// Conservative on purpose: only small, genuinely clickable elements snap, so
/// canvas apps (whose AX hit-test returns the giant canvas) never misfire.
enum AXClickSnap {
    private static let interactiveRoles: Set<String> = [
        "AXButton", "AXMenuItem", "AXMenuButton", "AXCheckBox", "AXRadioButton",
        "AXPopUpButton", "AXLink", "AXTextField", "AXTextArea", "AXSearchField",
        "AXComboBox", "AXDisclosureTriangle", "AXTabButton", "AXSegmentedControl",
    ]
    private static let maxSnapDistance: CGFloat = 28
    private static let maxElementSize = CGSize(width: 360, height: 130)

    static func snapped(_ point: CGPoint) -> CGPoint? {
        let system = AXUIElementCreateSystemWide()
        var ref: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &ref) == .success,
              let element = ref else { return nil }
        var roleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
              let role = roleRef as? String, interactiveRoles.contains(role) else { return nil }
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef, let sizeRef else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionRef as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size),
              size.width > 1, size.height > 1,
              size.width <= maxElementSize.width, size.height <= maxElementSize.height else { return nil }
        let center = CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
        let distance = hypot(center.x - point.x, center.y - point.y)
        guard distance > 0.5, distance <= maxSnapDistance else { return nil }
        return center
    }
}

public struct NativeComputerUseActuator: ComputerUseActuator {
    private let runState: AgentRunState?

    public init(runState: AgentRunState? = nil) {
        self.runState = runState
    }

    public func health() async -> ComputerUseHealth {
        let status = await MainActor.run { PermissionProbe.currentStatus() }
        let ready = status.canRunScreenAgent
        return ComputerUseHealth(
            ready: ready,
            permissions: status,
            message: ready
                ? "Screen agent is ready."
                : "Screen agent needs \(status.missingLabels.joined(separator: ", "))."
        )
    }

    public func perform(_ action: ComputerUseAction) async throws {
        // STOP is checked before health and before the event posts, so the
        // visible STOP control halts the run even mid-sequence.
        if runState?.isStopRequested == true { throw ComputerUseError.stopped }

        let current = await health()
        guard current.ready else { throw ComputerUseError.notReady(current.message) }

        if runState?.isStopRequested == true { throw ComputerUseError.stopped }

        switch action {
        case .move(let x, let y):
            try move(to: CGPoint(x: x, y: y))
        case .click(let x, let y):
            try await click(at: snapping(CGPoint(x: x, y: y)))
        case .doubleClick(let x, let y):
            try await doubleClick(at: snapping(CGPoint(x: x, y: y)))
        case .tripleClick(let x, let y):
            try await tripleClick(at: CGPoint(x: x, y: y))
        case .rightClick(let x, let y):
            try await rightClick(at: snapping(CGPoint(x: x, y: y)))
        case .drag(let fromX, let fromY, let toX, let toY):
            try await drag(from: CGPoint(x: fromX, y: fromY), to: CGPoint(x: toX, y: toY))
        case .key(let key, let modifiers):
            try pressKey(key, modifiers: modifiers, pid: await frontmostPID())
        case .typeText(let text):
            try await typeText(text, pid: await frontmostPID())
        case .scroll(let deltaX, let deltaY):
            try scroll(deltaX: deltaX, deltaY: deltaY)
        case .openURL(let raw):
            try await openURL(raw)
        }
    }

    /// AX+vision fused grounding for live clicks: vision picked the point, the
    /// accessibility hit-test corrects it to the element's center when it's a
    /// near-miss on a real control.
    private func snapping(_ point: CGPoint) -> CGPoint {
        AXClickSnap.snapped(point) ?? point
    }

    /// Keys post to the frontmost app's process (tiptour-macos pattern): they
    /// land in the app the agent is working even if another window steals
    /// focus mid-run, and the user's own typing never interleaves at the HID
    /// level. Falls back to the global tap when there's no frontmost app.
    private func frontmostPID() async -> pid_t? {
        await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    }

    private func move(to point: CGPoint) throws {
        guard let moved = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) else {
            throw ComputerUseError.unsupported("Could not create move event.")
        }
        moved.post(tap: .cghidEventTap)
    }

    /// Apps that track the pointer through move events (Blender/GHOST, games,
    /// GL canvases) process button events at the LAST MOVED-TO position — the
    /// coordinates embedded in down/up are ignored, and CGWarp generates no
    /// move events. A real mouse always moves before it presses; so do we.
    private func settleAt(_ point: CGPoint) async throws {
        try move(to: point)
        try? await Task.sleep(for: .milliseconds(20))
    }

    private func click(at point: CGPoint) async throws {
        try await settleAt(point)
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else {
            throw ComputerUseError.unsupported("Could not create mouse event.")
        }
        for event in [down, up] {
            event.setIntegerValueField(.mouseEventClickState, value: 1)
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func doubleClick(at point: CGPoint) async throws {
        try await settleAt(point)
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else {
            throw ComputerUseError.unsupported("Could not create double-click event.")
        }
        for event in [down, up] {
            event.setIntegerValueField(.mouseEventClickState, value: 2)
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func tripleClick(at point: CGPoint) async throws {
        try await settleAt(point)
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else {
            throw ComputerUseError.unsupported("Could not create triple-click event.")
        }
        for event in [down, up] {
            event.setIntegerValueField(.mouseEventClickState, value: 3)
        }
        for _ in 0..<3 {
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    /// A real press-drag-release: down at the start, interpolated drag events so
    /// apps that track the pointer (canvases, sliders, text selection) see a human-
    /// like motion, then up at the destination.
    private func drag(from start: CGPoint, to end: CGPoint) async throws {
        try await settleAt(start)
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: start, mouseButton: .left) else {
            throw ComputerUseError.unsupported("Could not create drag event.")
        }
        down.post(tap: .cghidEventTap)
        let steps = 14
        for index in 1...steps {
            if runState?.isStopRequested == true {
                // Always release the button — a stuck drag is worse than a stop.
                CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left)?
                    .post(tap: .cghidEventTap)
                throw ComputerUseError.stopped
            }
            let t = Double(index) / Double(steps)
            let point = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            guard let dragged = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left) else { continue }
            dragged.post(tap: .cghidEventTap)
            try? await Task.sleep(for: .milliseconds(12))
        }
        guard let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left) else {
            throw ComputerUseError.unsupported("Could not create drag-release event.")
        }
        up.post(tap: .cghidEventTap)
    }

    private func rightClick(at point: CGPoint) async throws {
        try await settleAt(point)
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown, mouseCursorPosition: point, mouseButton: .right),
              let up = CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp, mouseCursorPosition: point, mouseButton: .right) else {
            throw ComputerUseError.unsupported("Could not create right-click event.")
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func scroll(deltaX: Double, deltaY: Double) throws {
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(deltaY),
            wheel2: Int32(deltaX),
            wheel3: 0
        ) else {
            throw ComputerUseError.unsupported("Could not create scroll event.")
        }
        event.post(tap: .cghidEventTap)
    }

    private func openURL(_ raw: String) async throws {
        guard let url = URL(string: raw), url.scheme == "http" || url.scheme == "https" else {
            throw ComputerUseError.unsupported("Refusing to open a non-web URL: \(raw)")
        }
        await MainActor.run { _ = NSWorkspace.shared.open(url) }
    }

    private func pressKey(_ key: String, modifiers: [String], pid: pid_t?) throws {
        if let reason = SecureInputGuard.refusalReason(secureInputActive: SecureInputGuard.isActive()) {
            throw ComputerUseError.unsupported(reason)
        }
        guard let code = KeyCodes.code(for: key) else {
            throw ComputerUseError.unsupported("Unknown key: \(key)")
        }
        let flags = KeyCodes.flags(for: modifiers)
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else {
            throw ComputerUseError.unsupported("Could not create keyboard event.")
        }
        down.flags = flags
        up.flags = flags
        post(down, pid: pid)
        post(up, pid: pid)
    }

    /// Types in chunks with a small pace between events. Per-character bursts with
    /// zero delay get DROPPED by Catalyst/Electron apps (WhatsApp, Slack…) — the
    /// keys "press" but nothing lands in the field.
    private func typeText(_ text: String, pid: pid_t?) async throws {
        if let reason = SecureInputGuard.refusalReason(secureInputActive: SecureInputGuard.isActive()) {
            throw ComputerUseError.unsupported(reason)
        }
        // Grapheme-safe chunks: a raw UTF-16 window can cut a surrogate pair (emoji)
        // in half and inject a broken glyph.
        for chunk in TextChunker.graphemeSafeChunks(text, maxUTF16: 16) {
            if runState?.isStopRequested == true { throw ComputerUseError.stopped }
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
                throw ComputerUseError.unsupported("Could not create text event.")
            }
            chunk.withUnsafeBufferPointer { buffer in
                down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: buffer.baseAddress)
                up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: buffer.baseAddress)
            }
            post(down, pid: pid)
            post(up, pid: pid)
            try? await Task.sleep(for: .milliseconds(12))
        }
    }

    /// Per-PID delivery for keyboard events, with the global HID tap as the
    /// fallback. Targeted posting can't be stolen by a focus change mid-run.
    private func post(_ event: CGEvent, pid: pid_t?) {
        if let pid {
            event.postToPid(pid)
        } else {
            event.post(tap: .cghidEventTap)
        }
    }
}

private enum KeyCodes {
    /// Full ANSI layout — a shortcut with ANY letter/digit/symbol must work; an
    /// "Unknown key" here used to abort entire agent runs (e.g. cmd+n in Figma).
    static func code(for key: String) -> CGKeyCode? {
        switch key.lowercased() {
        case "return", "enter": 36
        case "escape", "esc": 53
        case "tab": 48
        case "space": 49
        case "delete", "backspace": 51
        case "forwarddelete": 117
        case "home": 115
        case "end": 119
        case "pageup": 116
        case "pagedown": 121
        case "left": 123
        case "right": 124
        case "down": 125
        case "up": 126
        case "f1": 122
        case "f2": 120
        case "f3": 99
        case "f4": 118
        case "f5": 96
        case "f6": 97
        case "f7": 98
        case "f8": 100
        case "f9": 101
        case "f10": 109
        case "f11": 103
        case "f12": 111
        case "a": 0
        case "s": 1
        case "d": 2
        case "f": 3
        case "h": 4
        case "g": 5
        case "z": 6
        case "x": 7
        case "c": 8
        case "v": 9
        case "b": 11
        case "q": 12
        case "w": 13
        case "e": 14
        case "r": 15
        case "y": 16
        case "t": 17
        case "o": 31
        case "u": 32
        case "i": 34
        case "p": 35
        case "l": 37
        case "j": 38
        case "k": 40
        case "n": 45
        case "m": 46
        case "1": 18
        case "2": 19
        case "3": 20
        case "4": 21
        case "5": 23
        case "6": 22
        case "7": 26
        case "8": 28
        case "9": 25
        case "0": 29
        case "-", "minus": 27
        case "=", "equal", "equals", "plus": 24
        case "[": 33
        case "]": 30
        case "\\": 42
        case ";": 41
        case "'": 39
        case ",", "comma": 43
        case ".", "period": 47
        case "/", "slash": 44
        case "`", "grave": 50
        default: nil
        }
    }

    static func flags(for modifiers: [String]) -> CGEventFlags {
        var flags: CGEventFlags = []
        for modifier in modifiers.map({ $0.lowercased() }) {
            switch modifier {
            case "command", "cmd", "meta": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "option", "alt": flags.insert(.maskAlternate)
            case "control", "ctrl": flags.insert(.maskControl)
            default: break
            }
        }
        return flags
    }
}

@MainActor
public final class ControlDockModel: ObservableObject {
    @Published public private(set) var visible = false
    @Published public private(set) var title = "Cascade is ready"
    @Published public private(set) var detail = "No agent is using the computer."

    /// Invoked when the user presses STOP, so the owner can halt an in-flight
    /// agent run (flip the `AgentRunState`, cancel tasks) — not just hide the dock.
    public var onStop: (@MainActor () -> Void)?

    public init() {}

    public func show(title: String, detail: String) {
        self.title = title
        self.detail = detail
        visible = true
    }

    public func stop() {
        onStop?()
        title = "Stopped"
        detail = "Cascade returned control to you."
        visible = false
    }

    /// Hides the dock without halting anything — for transient notices
    /// (scheduled-agent reminders) that aren't a running agent.
    public func dismiss() {
        visible = false
    }
}
