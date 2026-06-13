import AppKit
import SandboxKit
import WebKit

/// Floating boxes — one per background agent — showing each agent working inside
/// its sandbox. Every box hosts that agent's actual sandbox `WKWebView`, which also
/// keeps WebKit painting so `takeSnapshot` returns live frames instead of blank
/// ones. One panel per agent is essential: a shared panel would evict the previous
/// agent's webView from its window and blind it mid-run.
///
/// Docked at the screen's middle-right as a small chip holding the Cascade logo
/// (the webView stays mounted underneath, faintly visible, so WebKit keeps
/// painting). Hovering blooms it into the full box — status, Stop, and the live
/// sandbox. It pins itself expanded while a sign-in is pending or while the user
/// is interacting (key window), so it never collapses mid-login.
@MainActor
final class SandboxBoxController: NSObject {
    private final class Box {
        let panel: NSPanel
        let scaler: NSView
        let statusLabel: NSTextField
        let continueButton: NSButton
        let stopButton: NSButton
        let steerField: NSTextField
        let cover: NSView
        let logo: NSImageView
        /// Current scaleUnitSquare factor applied to `scaler` (1 = full size).
        var scale: CGFloat = 1
        var isExpanded = true
        var onStop: (() -> Void)?
        var onContinue: (() -> Void)?
        var onSteer: ((String) -> Void)?

        init(panel: NSPanel, scaler: NSView, statusLabel: NSTextField, continueButton: NSButton, stopButton: NSButton, steerField: NSTextField, cover: NSView, logo: NSImageView) {
            self.panel = panel
            self.scaler = scaler
            self.statusLabel = statusLabel
            self.continueButton = continueButton
            self.stopButton = stopButton
            self.steerField = steerField
            self.cover = cover
            self.logo = logo
        }
    }

    /// Borderless panel that can still become key, so the user can click and type
    /// inside the sandbox to sign in.
    private final class SandboxPanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    private var boxes: [UUID: Box] = [:]

    private let viewW: CGFloat = WebSandbox.width
    private let viewH: CGFloat = WebSandbox.height
    private let headerH: CGFloat = 40
    /// Footer row holding the "steer the agent" text field (expanded only).
    private let steerRowH: CGFloat = 36
    /// Side of the collapsed logo chip.
    private let chipSide: CGFloat = 60

    func show(_ id: UUID, webView: WKWebView, task: String, onStop: @escaping () -> Void, onSteer: @escaping (String) -> Void) {
        let isNew = boxes[id] == nil
        let box = boxes[id] ?? makeBox(for: id)
        box.onStop = onStop
        box.onSteer = onSteer
        box.onContinue = nil
        if webView.superview !== box.scaler {
            webView.removeFromSuperview()
            // Fixed logical size; the scaler's scaled coordinate space miniaturizes
            // it visually without changing the page viewport the agent sees.
            webView.frame = NSRect(x: 0, y: 0, width: viewW, height: viewH)
            webView.autoresizingMask = []
            box.scaler.addSubview(webView)
        }
        box.statusLabel.stringValue = "● \(task)"
        if isNew { layout(box, expanded: false, animate: false) }
        ensureHoverTimer()
        box.panel.orderFrontRegardless()
        box.panel.displayIfNeeded()
    }

    func updateStatus(_ id: UUID, _ text: String) {
        boxes[id]?.statusLabel.stringValue = text
    }

    /// The agent hit a sign-in wall: expand and pin the box, let the user log in
    /// inside it, and show a Continue button that resumes the task once they're in.
    func requestLogin(_ id: UUID, message: String, onContinue: @escaping () -> Void) {
        guard let box = boxes[id] else { return }
        box.onContinue = onContinue
        box.statusLabel.stringValue = message
        layout(box, expanded: true, animate: true)
        box.panel.orderFrontRegardless()
        box.panel.makeKeyAndOrderFront(nil)
    }

    func hide(_ id: UUID) {
        guard let box = boxes.removeValue(forKey: id) else { return }
        box.scaler.subviews.forEach { $0.removeFromSuperview() }
        box.panel.orderOut(nil)
        if boxes.isEmpty {
            hoverTimer?.invalidate()
            hoverTimer = nil
        }
    }

    @objc private func stopTapped(_ sender: NSButton) {
        guard let (id, box) = boxes.first(where: { $0.value.panel === sender.window }) else { return }
        box.onStop?()
        hide(id)
    }

    @objc private func continueTapped(_ sender: NSButton) {
        guard let box = boxes.first(where: { $0.value.panel === sender.window })?.value else { return }
        let resume = box.onContinue
        box.onContinue = nil
        box.continueButton.isHidden = true
        resume?()
    }

    /// User typed a correction into the box and pressed Return — hand it to the agent
    /// for its next turn, then clear the field + reflect it in the status.
    @objc private func steerSubmitted(_ sender: NSTextField) {
        guard let box = boxes.first(where: { $0.value.panel === sender.window })?.value else { return }
        let message = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        box.onSteer?(message)
        sender.stringValue = ""
        box.statusLabel.stringValue = "↳ told it: \(message)"
    }

    // MARK: - Hover expand / collapse

    /// Hover is driven by polling the global mouse position (same pattern as the
    /// guide cursor's follow loop) — tracking areas on borderless floating panels
    /// are unreliable across app activation states, and the rule is simple:
    /// cursor on the box → expanded; cursor off it → chip. No clicking involved.
    private var hoverTimer: Timer?

    private func ensureHoverTimer() {
        guard hoverTimer == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickHover() }
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
    }

    private func tickHover() {
        guard !boxes.isEmpty else { return }
        let mouse = NSEvent.mouseLocation
        for box in boxes.values {
            let inside = box.panel.frame.insetBy(dx: -2, dy: -2).contains(mouse)
            if inside, !box.isExpanded {
                layout(box, expanded: true, animate: true)
            } else if !inside, box.isExpanded {
                // Only a pending sign-in pins the box open.
                guard box.onContinue == nil else { continue }
                layout(box, expanded: false, animate: true)
            }
        }
    }

    /// Sizes the panel and its content for the given state, keeping the panel's
    /// right edge and vertical centre pinned so it blooms leftward from its
    /// middle-right dock.
    private func layout(_ box: Box, expanded: Bool, animate: Bool) {
        box.isExpanded = expanded
        let width: CGFloat = expanded ? viewW + 20 : chipSide
        let height: CGFloat = expanded ? viewH + headerH + 16 + steerRowH : chipSide

        // The webview scales to sit (faint, covered by the logo chip) inside the
        // collapsed box, which keeps WebKit painting between hovers.
        let s: CGFloat = expanded ? 1 : (chipSide - 8) / viewW
        let factor = s / box.scale
        if factor != 1 {
            box.scaler.scaleUnitSquare(to: NSSize(width: factor, height: factor))
            box.scale = s
        }

        let current = box.panel.frame
        let origin = NSPoint(x: current.maxX - width, y: current.midY - height / 2)
        box.panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true, animate: animate)

        if expanded {
            // Shifted up by the footer steer row.
            box.scaler.frame = NSRect(x: 10, y: 10 + steerRowH, width: viewW, height: viewH)
        } else {
            let pw = round(viewW * s), ph = round(viewH * s)
            box.scaler.frame = NSRect(x: (chipSide - pw) / 2, y: (chipSide - ph) / 2, width: pw, height: ph)
        }

        box.statusLabel.isHidden = !expanded
        box.stopButton.isHidden = !expanded
        box.continueButton.isHidden = !expanded || box.onContinue == nil
        box.steerField.isHidden = !expanded
        if expanded {
            let top = viewH + 10 + steerRowH // y of the webView's top edge; the header sits just above it
            box.statusLabel.frame = NSRect(x: 12, y: top + 8, width: width - 172, height: 20)
            box.stopButton.frame = NSRect(x: width - 72, y: top + 4, width: 60, height: 26)
            box.continueButton.frame = NSRect(x: width - 156, y: top + 4, width: 80, height: 26)
            box.steerField.frame = NSRect(x: 12, y: 8, width: width - 24, height: 24)
        }

        box.cover.isHidden = expanded
        box.cover.frame = NSRect(x: 0, y: 0, width: width, height: height)
        box.logo.frame = NSRect(x: (width - 26) / 2, y: (height - 26) / 2, width: 26, height: 26)
        (box.panel.contentView)?.layer?.cornerRadius = expanded ? 14 : 16
    }

    private func makeBox(for id: UUID) -> Box {
        let width = viewW + 20
        let height = viewH + headerH + 16 + steerRowH
        // Activatable (not .nonactivatingPanel) so the user can click + type to sign in
        // inside the box when a task needs a login.
        let panel = SandboxPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless],
            backing: .buffered, defer: false
        )
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.appearance = NSAppearance(named: .darkAqua)
        if let screen = NSScreen.main {
            // Middle-right dock; additional concurrent agents stack downward.
            let slot = CGFloat(boxes.count)
            panel.setFrameOrigin(NSPoint(
                x: screen.visibleFrame.maxX - width - 20,
                y: screen.visibleFrame.midY - height / 2 - slot * (chipSide + 14)
            ))
        }

        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(calibratedWhite: 0.07, alpha: 0.97).cgColor
        content.layer?.cornerRadius = 14
        content.layer?.masksToBounds = true
        content.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.14).cgColor
        content.layer?.borderWidth = 1
        content.autoresizingMask = [.width, .height]

        let scaler = NSView(frame: NSRect(x: 10, y: 10, width: viewW, height: viewH))
        scaler.wantsLayer = true
        scaler.layer?.backgroundColor = NSColor.black.cgColor
        scaler.layer?.cornerRadius = 6
        scaler.layer?.masksToBounds = true
        content.addSubview(scaler)

        // Header: status + stop.
        let status = NSTextField(labelWithString: "Starting…")
        status.frame = NSRect(x: 12, y: viewH + 18, width: width - 172, height: 20)
        status.font = .systemFont(ofSize: 12, weight: .medium)
        status.textColor = .labelColor
        status.lineBreakMode = .byTruncatingTail
        content.addSubview(status)

        let stop = NSButton(title: "Stop", target: self, action: #selector(stopTapped(_:)))
        stop.frame = NSRect(x: width - 72, y: viewH + 14, width: 60, height: 26)
        stop.bezelStyle = .rounded
        stop.controlSize = .small
        content.addSubview(stop)

        let cont = NSButton(title: "Continue", target: self, action: #selector(continueTapped(_:)))
        cont.frame = NSRect(x: width - 156, y: viewH + 14, width: 80, height: 26)
        cont.bezelStyle = .rounded
        cont.controlSize = .small
        cont.keyEquivalent = "\r"
        cont.isHidden = true
        content.addSubview(cont)

        // Footer: "cursor for the agent" — type a correction, ⏎ sends it to the agent's
        // next turn. Editable, so the panel must be able to become key (SandboxPanel is).
        let steer = NSTextField()
        steer.frame = NSRect(x: 12, y: 8, width: width - 24, height: 24)
        steer.placeholderString = "Tell the agent something… (⏎ to send)"
        steer.font = .systemFont(ofSize: 11)
        steer.bezelStyle = .roundedBezel
        steer.focusRingType = .none
        steer.target = self
        steer.action = #selector(steerSubmitted(_:))
        content.addSubview(steer)

        // Collapsed-state face: a dim cover with the Cascade logo, sitting above
        // the (tiny, still-painting) webview.
        let cover = NSView(frame: content.bounds)
        cover.wantsLayer = true
        cover.layer?.backgroundColor = NSColor(calibratedWhite: 0.05, alpha: 0.72).cgColor
        content.addSubview(cover)

        let logoImage = NSImage(named: "cascadeTemplate")
            ?? NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Cascade")
        let logo = NSImageView(image: logoImage ?? NSImage())
        logo.image?.isTemplate = true
        logo.contentTintColor = NSColor(calibratedWhite: 0.95, alpha: 1)
        logo.imageScaling = .scaleProportionallyUpOrDown
        content.addSubview(logo)

        panel.contentView = content
        let box = Box(panel: panel, scaler: scaler, statusLabel: status, continueButton: cont, stopButton: stop, steerField: steer, cover: cover, logo: logo)
        boxes[id] = box
        return box
    }
}
