import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CascadeMemory
import CoreGraphics
import Foundation
import OSLog

// Records the user's actual clicks and keystrokes so agents can be built from —
// and replay — real workflows. This is, in effect, a consented, LOCAL-ONLY
// keylogger, so the privacy boundary is strict and fail-closed:
//
//   • Only runs when Input Monitoring AND Accessibility are already granted.
//   • Drops every event in a PrivacyRules-sensitive app (banking/password/etc.).
//   • Never records keystrokes while macOS secure input is on (password fields).
//   • Never records Cascade itself.
//   • Stays local; retention-pruned alongside frames.
//
// The CGEvent tap runs on a dedicated thread; its callback only reads a cached
// app-context snapshot and appends Sendable primitives to a lock-guarded queue.
// A drain task coalesces keystrokes into typed runs and writes batches to the
// store off the tap thread.

/// Pure privacy predicate — the single source of truth for "may this event be
/// recorded?". Factored out so it can be unit-tested without a real event tap.
public enum InputCaptureGate {
    public static func shouldRecord(
        isOwnApp: Bool,
        isSensitive: Bool,
        isKeyEvent: Bool,
        secureInputEnabled: Bool
    ) -> Bool {
        if isOwnApp || isSensitive { return false }
        if isKeyEvent && secureInputEnabled { return false }
        return true
    }
}

public final class InputRecorder: @unchecked Sendable {
    private struct AppContext: Sendable {
        var app: String
        var bundle: String?
        var window: String?
        var isSensitive: Bool
        var isOwnApp: Bool
        static let empty = AppContext(app: "Unknown", bundle: nil, window: nil, isSensitive: false, isOwnApp: false)
    }

    private struct Where: Sendable {
        let app: String
        let bundle: String?
        let window: String?
    }

    private enum Raw: Sendable {
        case click(x: Double, y: Double, double: Bool, at: Date, in: Where)
        case rightClick(x: Double, y: Double, at: Date, in: Where)
        case scroll(x: Double, y: Double, dx: Double, dy: Double, at: Date, in: Where)
        case character(String, at: Date, in: Where)
        case keyCombo(key: String, modifiers: [String], at: Date, in: Where)
    }

    private let store: CascadeStore
    private let logger = Logger(subsystem: "com.humain.cascade", category: "input")

    private let contextLock = NSLock()
    private var currentContext = AppContext.empty

    private let queueLock = NSLock()
    private var queue: [Raw] = []

    private var tap: CFMachPort?
    private var thread: Thread?
    private let runLoopLock = NSLock()
    private var runLoop: CFRunLoop?
    private var drainTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var workspaceObserver: NSObjectProtocol?
    private var stopped = true

    public init(store: CascadeStore) {
        self.store = store
    }

    public var isRunning: Bool { tap != nil }

    /// Starts input capture. FAIL-CLOSED: does nothing unless Input Monitoring and
    /// Accessibility are already granted.
    @MainActor
    public func start() {
        guard tap == nil else { return }
        guard CGPreflightListenEventAccess(), AXIsProcessTrusted() else {
            logger.info("Input capture skipped — Input Monitoring/Accessibility not granted (fail-closed).")
            return
        }
        refreshContext()

        let mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue) |
            (1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: inputTapCallback,
            userInfo: refcon
        ) else {
            logger.error("Input capture skipped — could not create event tap.")
            return
        }
        self.tap = tap
        stopped = false

        let thread = Thread { [weak self] in
            guard let self, let tap = self.tap else { return }
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            let loop = CFRunLoopGetCurrent()
            self.runLoopLock.lock(); self.runLoop = loop; self.runLoopLock.unlock()
            CFRunLoopAddSource(loop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.name = "com.humain.cascade.input-tap"
        self.thread = thread
        thread.start()

        observeWorkspace()
        startContextRefresh()
        startDraining()
        logger.info("Input capture started.")
        Task { [store] in _ = try? await store.appendAudit(AuditEvent(actor: "system", action: "input.record.start", detail: "Input recording started")) }
    }

    @MainActor
    public func stop() {
        guard tap != nil else { return }
        stopped = true
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        runLoopLock.lock()
        if let loop = runLoop { CFRunLoopStop(loop) }
        runLoop = nil
        runLoopLock.unlock()
        drainTask?.cancel(); drainTask = nil
        refreshTask?.cancel(); refreshTask = nil
        if let observer = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            workspaceObserver = nil
        }
        tap = nil
        thread = nil
        logger.info("Input capture stopped.")
        Task { [store] in
            await self.drain()
            _ = try? await store.appendAudit(AuditEvent(actor: "system", action: "input.record.stop", detail: "Input recording stopped"))
        }
    }

    // MARK: - Tap callback path (off-main, on the tap thread)

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        let context = snapshotContext()
        let isKey = (type == .keyDown)
        let secure = isKey ? IsSecureEventInputEnabled() : false
        guard InputCaptureGate.shouldRecord(
            isOwnApp: context.isOwnApp,
            isSensitive: context.isSensitive,
            isKeyEvent: isKey,
            secureInputEnabled: secure
        ) else { return }

        let now = Date()
        let location = Where(app: context.app, bundle: context.bundle, window: context.window)

        switch type {
        case .leftMouseDown:
            let clickState = event.getIntegerValueField(.mouseEventClickState)
            let point = event.location
            enqueue(.click(x: Double(point.x), y: Double(point.y), double: clickState >= 2, at: now, in: location))
        case .rightMouseDown:
            let point = event.location
            enqueue(.rightClick(x: Double(point.x), y: Double(point.y), at: now, in: location))
        case .scrollWheel:
            let dy = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
            let dx = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
            let point = event.location
            enqueue(.scroll(x: Double(point.x), y: Double(point.y), dx: dx, dy: dy, at: now, in: location))
        case .keyDown:
            handleKey(event, at: now, in: location)
        default:
            break
        }
    }

    private func handleKey(_ event: CGEvent, at now: Date, in location: Where) {
        let keycode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        var modifiers: [String] = []
        if flags.contains(.maskCommand) { modifiers.append("command") }
        if flags.contains(.maskControl) { modifiers.append("control") }
        if flags.contains(.maskAlternate) { modifiers.append("option") }
        if flags.contains(.maskShift) { modifiers.append("shift") }
        // Command/Control mean "shortcut", not text. Option is a text modifier on
        // macOS (accents), so it does not force a combo.
        let isShortcut = flags.contains(.maskCommand) || flags.contains(.maskControl)

        if let special = Self.specialKeyName(keycode) {
            enqueue(.keyCombo(key: special, modifiers: modifiers.filter { $0 != "shift" }, at: now, in: location))
            return
        }
        let chars = Self.unicodeString(from: event)
        if isShortcut {
            let name = chars.isEmpty ? "key\(keycode)" : chars.lowercased()
            enqueue(.keyCombo(key: name, modifiers: modifiers.filter { $0 != "shift" }, at: now, in: location))
        } else if !chars.isEmpty {
            enqueue(.character(chars, at: now, in: location))
        }
    }

    private func enqueue(_ raw: Raw) {
        queueLock.lock()
        queue.append(raw)
        queueLock.unlock()
    }

    private func snapshotContext() -> AppContext {
        contextLock.lock(); defer { contextLock.unlock() }
        return currentContext
    }

    // MARK: - Drain (coalesce + persist, off the tap thread)

    private func startDraining() {
        drainTask = Task { [weak self] in
            while let self, !self.stopped, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await self.drain()
            }
        }
    }

    /// Synchronously drains the pending queue under the lock (the lock APIs aren't
    /// usable directly from an async context).
    private func takePending() -> [Raw] {
        queueLock.lock()
        defer { queueLock.unlock() }
        let items = queue
        queue.removeAll(keepingCapacity: true)
        return items
    }

    private func drain() async {
        let items = takePending()
        guard !items.isEmpty else { return }

        var events: [InputEvent] = []
        var typed = ""
        var typedWhere: Where?
        var typedAt = Date()
        func flushTyped() {
            guard !typed.isEmpty, let location = typedWhere else { return }
            events.append(InputEvent(capturedAt: typedAt, kind: .type, text: typed, appName: location.app, bundleIdentifier: location.bundle, windowTitle: location.window))
            typed = ""
            typedWhere = nil
        }

        for item in items {
            switch item {
            case .character(let char, let at, let location):
                if let current = typedWhere, current.app != location.app { flushTyped() }
                if typed.isEmpty { typedWhere = location; typedAt = at }
                typed += char
            case .keyCombo(let key, let modifiers, let at, let location):
                flushTyped()
                events.append(InputEvent(capturedAt: at, kind: .key, key: key, modifiers: modifiers, appName: location.app, bundleIdentifier: location.bundle, windowTitle: location.window))
            case .click(let x, let y, let double, let at, let location):
                flushTyped()
                events.append(InputEvent(capturedAt: at, kind: double ? .doubleClick : .click, x: x, y: y, appName: location.app, bundleIdentifier: location.bundle, windowTitle: location.window))
            case .rightClick(let x, let y, let at, let location):
                flushTyped()
                events.append(InputEvent(capturedAt: at, kind: .rightClick, x: x, y: y, appName: location.app, bundleIdentifier: location.bundle, windowTitle: location.window))
            case .scroll(let x, let y, let dx, let dy, let at, let location):
                flushTyped()
                let modifiers = ["\(Int(dx))", "\(Int(dy))"]
                events.append(InputEvent(capturedAt: at, kind: .scroll, x: x, y: y, modifiers: modifiers, appName: location.app, bundleIdentifier: location.bundle, windowTitle: location.window))
            }
        }
        flushTyped()
        if !events.isEmpty {
            try? await store.insertInputEvents(events)
        }
    }

    // MARK: - Frontmost-app context (updated on main; read on the tap thread)

    @MainActor
    private func refreshContext() {
        let snapshot = AppWindowObserver.snapshot()
        let bundle = snapshot.bundleIdentifier
        let context = AppContext(
            app: snapshot.appName,
            bundle: bundle,
            window: snapshot.windowTitle,
            isSensitive: PrivacyRules.isSensitive(appName: snapshot.appName, bundleIdentifier: bundle, windowTitle: snapshot.windowTitle),
            isOwnApp: bundle == Bundle.main.bundleIdentifier
        )
        contextLock.lock()
        currentContext = context
        contextLock.unlock()
    }

    @MainActor
    private func observeWorkspace() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshContext() }
        }
    }

    private func startContextRefresh() {
        refreshTask = Task { [weak self] in
            while let self, !self.stopped, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(1500))
                await self.refreshContext()
            }
        }
    }

    // MARK: - Key naming

    private static func specialKeyName(_ keycode: Int) -> String? {
        switch keycode {
        case kVK_Return, kVK_ANSI_KeypadEnter: return "return"
        case kVK_Tab: return "tab"
        case kVK_Delete: return "delete"
        case kVK_ForwardDelete: return "forwardDelete"
        case kVK_Escape: return "escape"
        case kVK_LeftArrow: return "left"
        case kVK_RightArrow: return "right"
        case kVK_UpArrow: return "up"
        case kVK_DownArrow: return "down"
        case kVK_Home: return "home"
        case kVK_End: return "end"
        case kVK_PageUp: return "pageUp"
        case kVK_PageDown: return "pageDown"
        default: return nil
        }
    }

    private static func unicodeString(from event: CGEvent) -> String {
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &buffer)
        guard length > 0 else { return "" }
        let string = String(utf16CodeUnits: buffer, count: length)
        // Drop control characters (e.g. the raw value behind Return) — those are
        // handled as named keys, not text.
        return string.unicodeScalars.allSatisfy { $0.value >= 32 } ? string : ""
    }
}

/// C tap callback. Reads the recorder from the refcon, classifies the event off
/// the main thread, and passes it through unchanged (listen-only).
private func inputTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let refcon {
        let recorder = Unmanaged<InputRecorder>.fromOpaque(refcon).takeUnretainedValue()
        recorder.handle(type: type, event: event)
    }
    return Unmanaged.passUnretained(event)
}
