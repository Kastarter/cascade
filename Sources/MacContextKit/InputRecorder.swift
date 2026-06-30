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

public enum AXTargetDescriptorBuilder {
    public static let actionableRoles: Set<String> = [
        "AXButton", "AXMenuItem", "AXMenuBarItem", "AXRow", "AXCell", "AXLink",
        "AXTextField", "AXTextArea", "AXSearchField", "AXComboBox", "AXPopUpButton",
        "AXCheckBox", "AXRadioButton", "AXTab", "AXOutlineRow", "AXStaticText",
        "AXSlider", "AXDisclosureTriangle",
    ]

    public static func descriptor(
        for element: AXUIElement,
        fallbackLabel: String? = nil,
        windowTitle: String? = nil,
        createdFrom: String? = nil
    ) -> AXTargetDescriptorV2 {
        AXClient.setMessagingTimeout(element)
        let role = string(element, kAXRoleAttribute as String)
        let label = fallbackLabel ?? labelText(of: element) ?? ""
        let safeWindowTitle = sanitizedContextText(windowTitle)
        let value = string(element, kAXValueAttribute as String)
        let frame = frame(of: element)
        let ancestorPath = ancestors(of: element)
        let sibling = siblingInfo(for: element)
        let bucket = frame.map(frameBucketString)
        let exactFrame = frame.map(frameString)
        let subtree = subtreeShape(of: element, maxDepth: 2, maxNodes: 24)
        let semanticPhrase = AXTargetDescriptorV2.semanticPhrase(
            label: label,
            role: role,
            container: ancestorPath.last,
            ancestorPath: ancestorPath,
            neighborLabels: sibling.neighborLabels,
            windowTitle: safeWindowTitle
        )
        let structuralPath = (ancestorPath + [role, String(sibling.roleIndex ?? sibling.index ?? -1)].compactMap { $0 }).joined(separator: "|")

        return AXTargetDescriptorV2(
            label: label,
            role: role,
            identifier: string(element, kAXIdentifierAttribute as String),
            container: ancestorPath.last,
            windowTitle: safeWindowTitle,
            ancestorPath: ancestorPath,
            siblingIndex: sibling.index,
            siblingRoleIndex: sibling.roleIndex,
            neighborLabels: sibling.neighborLabels,
            frameBucket: bucket,
            frame: exactFrame,
            valueHash: value.map(AuditIdentity.hash),
            enabled: bool(element, kAXEnabledAttribute as String),
            selected: bool(element, kAXSelectedAttribute as String),
            focused: bool(element, kAXFocusedAttribute as String),
            pathHash: structuralPath.isEmpty ? nil : AuditIdentity.hash(structuralPath),
            subtree: subtree.summary,
            subtreeHash: subtree.hash,
            semanticTextHash: AXTargetDescriptorV2.semanticTextHash(for: semanticPhrase),
            semanticHash: semanticHash(role: role, label: label),
            createdFrom: createdFrom
        )
    }

    public static func encodedDescriptor(
        for element: AXUIElement,
        fallbackLabel: String? = nil,
        windowTitle: String? = nil,
        createdFrom: String? = nil
    ) -> String? {
        let descriptor = descriptor(
            for: element,
            fallbackLabel: fallbackLabel,
            windowTitle: windowTitle,
            createdFrom: createdFrom
        )
        guard descriptor.hasSignal else { return nil }
        return descriptor.encodedJSON()
    }

    public static func labeledActionableAncestor(
        from element: AXUIElement,
        maxHops: Int = 4,
        windowTitle: String? = nil,
        createdFrom: String? = nil
    ) -> (element: AXUIElement, label: String, descriptor: String?)? {
        var current = element
        for _ in 0..<maxHops {
            let role = string(current, kAXRoleAttribute as String) ?? ""
            if actionableRoles.contains(role),
               let label = labelText(of: current),
               !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return (
                    current,
                    String(label.prefix(80)),
                    encodedDescriptor(
                        for: current,
                        fallbackLabel: String(label.prefix(80)),
                        windowTitle: windowTitle,
                        createdFrom: createdFrom
                    )
                )
            }
            guard let parent = parent(of: current) else { break }
            current = parent
        }
        return nil
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        guard case .success(let value) = AXClient.attribute(element, attribute, as: String.self) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        guard case .success(let value) = AXClient.attribute(element, attribute, as: Bool.self) else { return nil }
        return value
    }

    private static func parent(of element: AXUIElement) -> AXUIElement? {
        guard case .success(let parent) = AXClient.elementAttribute(element, kAXParentAttribute as String) else {
            return nil
        }
        return parent
    }

    private static func labelText(of element: AXUIElement) -> String? {
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXHelpAttribute] {
            if let text = string(element, attribute), !PrivacyRules.isSensitiveText(text) {
                return text
            }
        }
        return nil
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard case .success(let frame) = AXClient.frame(element) else { return nil }
        return frame
    }

    private static func ancestors(of element: AXUIElement, maxDepth: Int = 6) -> [String] {
        var out: [String] = []
        var current = element
        for _ in 0..<maxDepth {
            guard let parent = parent(of: current) else { break }
            let role = string(parent, kAXRoleAttribute as String) ?? ""
            let title = labelText(of: parent) ?? ""
            if let container = AXTargetDescriptor.container(role: role, title: title) {
                out.insert(container, at: 0)
            }
            current = parent
        }
        return out
    }

    private static func sanitizedContextText(_ text: String?) -> String? {
        guard let text, !PrivacyRules.isSensitiveText(text) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(80))
    }

    private static func siblingInfo(for element: AXUIElement) -> (index: Int?, roleIndex: Int?, neighborLabels: [String]) {
        guard let parent = parent(of: element),
              case .success(let children) = AXClient.children(parent),
              let index = children.firstIndex(where: { CFEqual($0, element) }) else {
            return (nil, nil, [])
        }
        let role = string(element, kAXRoleAttribute as String)
        let sameRoleBefore = children[..<index].filter { string($0, kAXRoleAttribute as String) == role }.count
        let roleIndex = role == nil ? nil : sameRoleBefore
        let labels = [index - 1, index + 1].compactMap { candidate -> String? in
            guard children.indices.contains(candidate) else { return nil }
            return labelText(of: children[candidate]).map { String($0.prefix(60)) }
        }
        return (index, roleIndex, labels)
    }

    private static func frameBucketString(_ frame: CGRect) -> String {
        let bucket = UIStateSnapshot.FrameBucket(frame)
        return "\(bucket.x),\(bucket.y),\(bucket.width),\(bucket.height)"
    }

    private static func frameString(_ frame: CGRect) -> String {
        [
            Int(frame.minX.rounded()),
            Int(frame.minY.rounded()),
            Int(frame.width.rounded()),
            Int(frame.height.rounded()),
        ].map(String.init).joined(separator: ",")
    }

    private static func subtreeShape(
        of element: AXUIElement,
        maxDepth: Int,
        maxNodes: Int
    ) -> (summary: String?, hash: String?) {
        var parts: [String] = []
        func walk(_ node: AXUIElement, depth: Int) {
            guard depth <= maxDepth, parts.count < maxNodes else { return }
            let role = string(node, kAXRoleAttribute as String) ?? "AXUnknown"
            let labelHash = labelText(of: node).map(AuditIdentity.hash) ?? "none"
            parts.append("\(depth):\(role):\(labelHash)")
            guard depth < maxDepth, case .success(let children) = AXClient.children(node) else { return }
            for child in children {
                guard parts.count < maxNodes else { return }
                walk(child, depth: depth + 1)
            }
        }
        walk(element, depth: 0)
        guard !parts.isEmpty else { return (nil, nil) }
        return ("nodes=\(parts.count)", AuditIdentity.hash(parts.joined(separator: "|")))
    }

    private static func semanticHash(role: String?, label: String) -> String? {
        let normalized = [role, label]
            .compactMap { $0?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "|")
        return normalized.isEmpty ? nil : AuditIdentity.hash(normalized)
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
    private var policy: CapturePrivacyPolicy
    private let logger = Logger(subsystem: "com.humain.cascade", category: "input")

    private let contextLock = NSLock()
    private var currentContext = AppContext.empty

    private let queueLock = NSLock()
    private var queue: [Raw] = []

    // AX labels of clicked elements, resolved asynchronously at click time (the
    // hit-test runs ms after the click, before the UI changes) and matched to
    // their click events at drain time. The label is what lets a recipe replay
    // re-find its target by identity instead of trusting a stale pixel (the
    // tiptour-macos pattern — see docs/THIRD_PARTY_NOTICES.md).
    private let labelLock = NSLock()
    private var clickLabels: [(at: Date, x: Double, y: Double, label: String, descriptor: String?)] = []

    private var tap: CFMachPort?
    private var thread: Thread?
    private let runLoopLock = NSLock()
    private var runLoop: CFRunLoop?
    private var drainTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var workspaceObserver: NSObjectProtocol?
    private var stopped = true

    public var onActivity: (@Sendable (InputActivity) -> Void)?

    public init(store: CascadeStore, policy: CapturePrivacyPolicy = .default) {
        self.store = store
        self.policy = policy
    }

    public func updatePolicy(_ policy: CapturePrivacyPolicy) {
        contextLock.lock()
        self.policy = policy
        currentContext.isSensitive = !policy.decision(
            appName: currentContext.app,
            bundleIdentifier: currentContext.bundle,
            windowTitle: currentContext.window
        ).allowed
        contextLock.unlock()
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
	            resolveClickLabel(at: point, when: now, windowTitle: location.window)
	        case .rightMouseDown:
	            let point = event.location
	            enqueue(.rightClick(x: Double(point.x), y: Double(point.y), at: now, in: location))
	            resolveClickLabel(at: point, when: now, windowTitle: location.window)
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

    /// Hit-tests the AX element under a click off the tap thread (the tap callback
    /// must stay fast). Runs only for events that already passed the app/window
    /// privacy gate; the label TEXT gets its own check — an element title can
    /// smuggle a sensitive phrase out of an otherwise unflagged window.
    private func resolveClickLabel(at point: CGPoint, when: Date, windowTitle: String?) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self, let hit = Self.axClickTarget(atCG: point, windowTitle: windowTitle) else { return }
            let label = InputEventSanitizer.sanitize(text: hit.label, kind: .click)
            let descriptor = InputEventSanitizer.sanitize(descriptor: hit.descriptor)
            guard label != nil || descriptor != nil else { return }
            self.labelLock.lock()
            self.clickLabels.append((at: when, x: Double(point.x), y: Double(point.y), label: label ?? "", descriptor: descriptor))
            if self.clickLabels.count > 64 { self.clickLabels.removeFirst(self.clickLabels.count - 64) }
            self.labelLock.unlock()
        }
    }

    /// Whether a click's label has resolved yet (non-consuming — used to decide
    /// whether to defer the click to the next drain).
    private func hasClickLabel(at: Date, x: Double, y: Double) -> Bool {
        labelLock.lock(); defer { labelLock.unlock() }
        return clickLabels.contains {
            abs($0.at.timeIntervalSince(at)) < 0.5 && abs($0.x - x) < 2 && abs($0.y - y) < 2
        }
    }

    /// The resolved label + stable AX descriptor for a click at (time, point),
    /// consuming it on match.
    private func takeClickTarget(at: Date, x: Double, y: Double) -> (label: String, descriptor: String?)? {
        labelLock.lock(); defer { labelLock.unlock() }
        guard let index = clickLabels.firstIndex(where: {
            abs($0.at.timeIntervalSince(at)) < 0.5 && abs($0.x - x) < 2 && abs($0.y - y) < 2
        }) else { return nil }
        let hit = clickLabels.remove(at: index)
        return (hit.label, hit.descriptor)
    }

    /// The clicked element's human label PLUS a stable AX descriptor (role +
    /// accessibility identifier), climbing to the nearest labeled, actionable
    /// ancestor — hit-tests often land on an unlabeled leaf. The label titles the
    /// recipe and seeds OCR re-grounding; the descriptor is what the replay cascade
    /// ranks on so a moved/renamed control is still re-found (XCUIAutomation-style:
    /// identifier first, then role to disambiguate equal labels). `descriptor` is
    /// `nil` when the matched ancestor exposes neither a usable role nor identifier.
    private static func axClickTarget(atCG point: CGPoint, windowTitle: String?) -> (label: String, descriptor: String?)? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.3)
        var ref: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &ref) == .success,
              let element = ref else { return nil }
        return AXTargetDescriptorBuilder.labeledActionableAncestor(
            from: element,
            windowTitle: windowTitle,
            createdFrom: "input_recorder"
        ).map {
            ($0.label, $0.descriptor)
        }
    }

    /// The clicked element's structural container — its parent's "role: title" via the
    /// shared `AXTargetDescriptor.container` formatter, so it compares equal to what
    /// the replay resolver reads. Lets the cascade disambiguate identical labels by
    /// where they sit (Healenium-style). `nil` when there's no parent / no signal.
    private static func containerLabel(of element: AXUIElement) -> String? {
        var parentRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parentRef) == .success,
              let parent = parentRef, CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
        let parentElement = parent as! AXUIElement
        var roleRef: CFTypeRef?
        let role = AXUIElementCopyAttributeValue(parentElement, kAXRoleAttribute as CFString, &roleRef) == .success
            ? (roleRef as? String ?? "") : ""
        var title = ""
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
            var textRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(parentElement, attribute as CFString, &textRef) == .success,
               let text = textRef as? String, !text.trimmingCharacters(in: .whitespaces).isEmpty {
                // A parent's title can smuggle a sensitive phrase (a row reading
                // "Password: …") past the label gate — drop the title (keep the
                // structural role) when it trips the privacy rules.
                title = PrivacyRules.isSensitiveText(text) ? "" : text
                break
            }
        }
        return AXTargetDescriptor.container(role: role, title: title)
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

    /// Puts deferred items back at the FRONT of the queue, ahead of anything that
    /// arrived while draining, so event order is preserved.
    private func requeue(_ items: [Raw]) {
        queueLock.lock()
        defer { queueLock.unlock() }
        queue.insert(contentsOf: items, at: 0)
    }

    private func drain() async {
        var items = takePending()
        guard !items.isEmpty else { return }

        // A click's AX label resolves asynchronously; a click captured right before
        // this drain may not have its label yet. Defer that click AND everything
        // after it to the next drain (order must be preserved — a recipe with
        // reordered steps replays wrong). `stopped` flushes everything as-is.
        if !stopped, let deferIndex = items.firstIndex(where: { item in
            switch item {
            case .click(let x, let y, _, let at, _), .rightClick(let x, let y, let at, _):
                return Date().timeIntervalSince(at) < 0.35 && !hasClickLabel(at: at, x: x, y: y)
            default:
                return false
            }
        }) {
            let deferred = Array(items[deferIndex...])
            items.removeSubrange(deferIndex...)
            requeue(deferred)
            guard !items.isEmpty else { return }
        }

        var events: [InputEvent] = []
        var typed = ""
        var typedWhere: Where?
        var typedAt = Date()
        func flushTyped() {
            guard !typed.isEmpty, let location = typedWhere else { return }
            events.append(InputEvent(
                capturedAt: typedAt,
                kind: .type,
                text: InputEventSanitizer.typedShape(for: typed),
                appName: location.app,
                bundleIdentifier: location.bundle,
                windowTitle: location.window
            ))
            emitActivity(.typingRun, at: typedAt, in: location)
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
                emitActivity(.keyCombo, at: at, in: location)
            case .click(let x, let y, let double, let at, let location):
                flushTyped()
                // For clicks, `text` carries the clicked element's AX label and
                // `targetDescriptor` its stable role+identifier locator so the replay
                // cascade can re-find the target by identity, not stale pixels.
                let hit = takeClickTarget(at: at, x: x, y: y)
                if hit == nil { logger.debug("click stored without AX label in \(location.app, privacy: .public)") }
	                events.append(InputEvent(capturedAt: at, kind: double ? .doubleClick : .click, x: x, y: y, text: hit?.label, appName: location.app, bundleIdentifier: location.bundle, windowTitle: location.window, targetDescriptor: hit?.descriptor))
                emitActivity(.click, at: at, in: location)
            case .rightClick(let x, let y, let at, let location):
                flushTyped()
                let hit = takeClickTarget(at: at, x: x, y: y)
                if hit == nil { logger.debug("right-click stored without AX label in \(location.app, privacy: .public)") }
	                events.append(InputEvent(capturedAt: at, kind: .rightClick, x: x, y: y, text: hit?.label, appName: location.app, bundleIdentifier: location.bundle, windowTitle: location.window, targetDescriptor: hit?.descriptor))
                emitActivity(.click, at: at, in: location)
            case .scroll(let x, let y, let dx, let dy, let at, let location):
                flushTyped()
                let modifiers = ["\(Int(dx))", "\(Int(dy))"]
                events.append(InputEvent(capturedAt: at, kind: .scroll, x: x, y: y, modifiers: modifiers, appName: location.app, bundleIdentifier: location.bundle, windowTitle: location.window))
                emitActivity(.scroll, at: at, in: location)
            }
        }
        flushTyped()
        if !events.isEmpty {
            try? await store.insertInputEvents(events)
        }
    }

    private func emitActivity(_ kind: InputActivityKind, at date: Date, in location: Where) {
        onActivity?(InputActivity(
            kind: kind,
            capturedAt: date,
            appName: location.app,
            bundleIdentifier: location.bundle,
            windowTitle: location.window
        ))
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
	            isSensitive: !policy.decision(appName: snapshot.appName, bundleIdentifier: bundle, windowTitle: snapshot.windowTitle).allowed,
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
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshContext()
                let context = self.snapshotContext()
                guard !context.isOwnApp, !context.isSensitive else { return }
                self.emitActivity(.appActivated, at: Date(), in: Where(app: context.app, bundle: context.bundle, window: context.window))
            }
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
