import AppKit
import ApplicationServices
import Combine
import CascadeMemory
import CoreGraphics
import Foundation
import MacContextKit

public enum ComputerUseAction: Equatable, Sendable {
    case click(x: Double, y: Double)
    case key(String, modifiers: [String])
    case typeText(String)
    case scroll(deltaX: Double, deltaY: Double)
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

    public var errorDescription: String? {
        switch self {
        case .notReady(let message): message
        case .unsupported(let message): message
        }
    }
}

public struct NativeComputerUseActuator: ComputerUseActuator {
    public init() {}

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
        let current = await health()
        guard current.ready else { throw ComputerUseError.notReady(current.message) }

        switch action {
        case .click(let x, let y):
            try click(at: CGPoint(x: x, y: y))
        case .key(let key, let modifiers):
            try pressKey(key, modifiers: modifiers)
        case .typeText(let text):
            try typeText(text)
        case .scroll:
            throw ComputerUseError.unsupported("Scroll routing is not enabled in the first slice.")
        }
    }

    private func click(at point: CGPoint) throws {
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else {
            throw ComputerUseError.unsupported("Could not create mouse event.")
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func pressKey(_ key: String, modifiers: [String]) throws {
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
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func typeText(_ text: String) throws {
        for scalar in text.unicodeScalars {
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
                throw ComputerUseError.unsupported("Could not create text event.")
            }
            var value = UniChar(scalar.value)
            down.keyboardSetUnicodeString(stringLength: 1, unicodeString: &value)
            up.keyboardSetUnicodeString(stringLength: 1, unicodeString: &value)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }
}

private enum KeyCodes {
    static func code(for key: String) -> CGKeyCode? {
        switch key.lowercased() {
        case "return", "enter": 36
        case "escape", "esc": 53
        case "tab": 48
        case "space": 49
        case "delete", "backspace": 51
        case "left": 123
        case "right": 124
        case "down": 125
        case "up": 126
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

    public init() {}

    public func show(title: String, detail: String) {
        self.title = title
        self.detail = detail
        visible = true
    }

    public func stop() {
        title = "Stopped"
        detail = "Cascade returned control to you."
        visible = false
    }
}
