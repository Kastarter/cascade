import AppKit
import CoreGraphics
import Foundation

/// Actuates a `ComputerUseAction` by posting events **straight into one app's
/// process** (`CGEvent.postToPid`) — never the global HID tap. So it moves NO
/// real cursor and steals NO focus: the user keeps working while this drives a
/// background app, and several actuators bound to different pids never collide.
/// This is the linchpin of parallel on-screen agents (see
/// docs/PARALLEL_AGENTS_PLAN.md).
///
/// Coordinates are GLOBAL CG (top-left origin), same as `NativeComputerUseActuator`.
/// RUNTIME-UNVERIFIED: pid-posted MOUSE events are the one piece Cascade hasn't
/// proven; per-app variance is expected (hover menus/tooltips and some dialogs
/// may still need the real cursor). Prove it before trusting it.
public struct PidEventActuator: ComputerUseActuator {
    private let pid: pid_t
    private let runState: AgentRunState?

    public init(pid: pid_t, runState: AgentRunState? = nil) {
        self.pid = pid
        self.runState = runState
    }

    public func health() async -> ComputerUseHealth {
        // Same permission surface as the on-screen actuator (Accessibility +
        // Input Monitoring authorize event posting); reuse its probe.
        await NativeComputerUseActuator(runState: runState).health()
    }

    public func perform(_ action: ComputerUseAction) async throws {
        if runState?.isStopRequested == true { throw ComputerUseError.stopped }
        switch action {
        case .move(let x, let y):
            postMove(to: CGPoint(x: x, y: y))
        case .click(let x, let y):
            try await click(at: CGPoint(x: x, y: y), clicks: 1, button: .left)
        case .doubleClick(let x, let y):
            try await click(at: CGPoint(x: x, y: y), clicks: 2, button: .left)
        case .tripleClick(let x, let y):
            try await click(at: CGPoint(x: x, y: y), clicks: 3, button: .left)
        case .rightClick(let x, let y):
            try await click(at: CGPoint(x: x, y: y), clicks: 1, button: .right)
        case .drag(let fromX, let fromY, let toX, let toY):
            try await drag(from: CGPoint(x: fromX, y: fromY), to: CGPoint(x: toX, y: toY))
        case .key(let key, let modifiers):
            try pressKey(key, modifiers: modifiers)
        case .typeText(let text):
            try await typeText(text)
        case .scroll(let deltaX, let deltaY):
            scroll(deltaX: deltaX, deltaY: deltaY)
        case .openURL(let raw):
            if let url = URL(string: raw), url.scheme == "http" || url.scheme == "https" {
                await MainActor.run { _ = NSWorkspace.shared.open(url) }
            }
        }
    }

    private func post(_ event: CGEvent) { event.postToPid(pid) }

    /// Pointer-tracking apps process button events at the LAST position a move
    /// event delivered (the embedded coords are ignored) — so always move the
    /// process's pointer first. To the pid only: the real cursor never moves.
    private func postMove(to point: CGPoint) {
        guard let moved = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) else { return }
        post(moved)
    }

    private func click(at point: CGPoint, clicks: Int, button: CGMouseButton) async throws {
        postMove(to: point)
        try? await Task.sleep(for: .milliseconds(20))
        if runState?.isStopRequested == true { throw ComputerUseError.stopped }
        let down: CGEventType = button == .right ? .rightMouseDown : .leftMouseDown
        let up: CGEventType = button == .right ? .rightMouseUp : .leftMouseUp
        for n in 1...clicks {
            guard let d = CGEvent(mouseEventSource: nil, mouseType: down, mouseCursorPosition: point, mouseButton: button),
                  let u = CGEvent(mouseEventSource: nil, mouseType: up, mouseCursorPosition: point, mouseButton: button) else {
                throw ComputerUseError.unsupported("Could not create mouse event.")
            }
            d.setIntegerValueField(.mouseEventClickState, value: Int64(n))
            u.setIntegerValueField(.mouseEventClickState, value: Int64(n))
            post(d)
            post(u)
        }
    }

    private func drag(from start: CGPoint, to end: CGPoint) async throws {
        postMove(to: start)
        try? await Task.sleep(for: .milliseconds(20))
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: start, mouseButton: .left) else {
            throw ComputerUseError.unsupported("Could not create drag event.")
        }
        post(down)
        let steps = 24
        for i in 1...steps {
            if runState?.isStopRequested == true {
                CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left).map(post)
                throw ComputerUseError.stopped
            }
            let t = Double(i) / Double(steps)
            let p = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            guard let dragged = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: p, mouseButton: .left) else { continue }
            post(dragged)
            try? await Task.sleep(for: .milliseconds(8))
        }
        guard let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left) else {
            throw ComputerUseError.unsupported("Could not create drag release.")
        }
        post(up)
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
        post(down)
        post(up)
    }

    private func typeText(_ text: String) async throws {
        let units = Array(text.utf16)
        var index = 0
        while index < units.count {
            if runState?.isStopRequested == true { throw ComputerUseError.stopped }
            let chunk = Array(units[index..<min(index + 16, units.count)])
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
                throw ComputerUseError.unsupported("Could not create text event.")
            }
            chunk.withUnsafeBufferPointer { buffer in
                down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: buffer.baseAddress)
                up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: buffer.baseAddress)
            }
            post(down)
            post(up)
            try? await Task.sleep(for: .milliseconds(12))
            index += 16
        }
    }

    private func scroll(deltaX: Double, deltaY: Double) {
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
            wheel1: Int32(deltaY), wheel2: Int32(deltaX), wheel3: 0
        ) else { return }
        post(event)
    }
}
