import AppKit
import SandboxKit
import WebKit

/// Floating chat windows — one per background agent — that let you watch each agent
/// work inside its sandbox AND talk to it like a chat.
///
/// Docked at the screen's middle-right as a small chip holding the Cascade logo (the
/// webView stays mounted underneath, faintly visible, so WebKit keeps painting and
/// `takeSnapshot` returns live frames). Hovering blooms it into the full chat:
///   • a scaled live preview of the agent's sandbox screen (top),
///   • a scrolling transcript — the agent's progress on the left, your steers on the
///     right, as chat bubbles (middle),
///   • a rounded message field with a send button (bottom).
///
/// One panel per agent is essential: a shared panel would evict the previous agent's
/// webView from its window and blind it mid-run. It pins itself expanded while a
/// sign-in is pending or while you're typing (key window), so it never collapses
/// mid-login or mid-message.
@MainActor
final class SandboxBoxController: NSObject, NSTextFieldDelegate {
    // MARK: - Chat transcript (scrolling bubble list)

    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    /// A scrollable column of chat bubbles. Agent messages sit left (grey), the user's
    /// steers sit right (accent). Auto-scrolls to the newest message.
    private final class ChatTranscriptView: NSView {
        enum Role { case agent, user }

        private let scroll = NSScrollView()
        private let stack = NSStackView()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.cornerRadius = 10
            layer?.masksToBounds = true

            scroll.translatesAutoresizingMaskIntoConstraints = false
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.scrollerStyle = .overlay
            scroll.verticalScrollElasticity = .allowed
            addSubview(scroll)

            let doc = FlippedView()
            doc.translatesAutoresizingMaskIntoConstraints = false
            scroll.documentView = doc

            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 8
            stack.translatesAutoresizingMaskIntoConstraints = false
            stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
            doc.addSubview(stack)

            NSLayoutConstraint.activate([
                scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
                scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
                scroll.topAnchor.constraint(equalTo: topAnchor),
                scroll.bottomAnchor.constraint(equalTo: bottomAnchor),

                doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
                doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
                doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
                doc.bottomAnchor.constraint(equalTo: stack.bottomAnchor),

                stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
                stack.topAnchor.constraint(equalTo: doc.topAnchor),
            ])
        }

        required init?(coder: NSCoder) { fatalError() }

        func append(role: Role, text: String) {
            let avail = max(bounds.width, 360)
            let row = NSView()
            row.translatesAutoresizingMaskIntoConstraints = false

            switch role {
            case .agent:
                // A Claude-Code-style step line: an accent dot in the gutter, then the
                // agent's words running full width. No bubble — reads like a transcript.
                let dot = NSView()
                dot.translatesAutoresizingMaskIntoConstraints = false
                dot.wantsLayer = true
                dot.layer?.cornerRadius = 3.5
                dot.layer?.backgroundColor = NSColor.controlAccentColor.cgColor

                let label = NSTextField(wrappingLabelWithString: text)
                label.translatesAutoresizingMaskIntoConstraints = false
                label.font = .systemFont(ofSize: 12)
                label.textColor = NSColor(calibratedWhite: 0.86, alpha: 1)
                label.isSelectable = true
                label.preferredMaxLayoutWidth = avail - 56

                row.addSubview(dot)
                row.addSubview(label)
                NSLayoutConstraint.activate([
                    dot.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 2),
                    dot.topAnchor.constraint(equalTo: row.topAnchor, constant: 5),
                    dot.widthAnchor.constraint(equalToConstant: 7),
                    dot.heightAnchor.constraint(equalToConstant: 7),
                    label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 9),
                    label.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                    label.topAnchor.constraint(equalTo: row.topAnchor),
                    label.bottomAnchor.constraint(equalTo: row.bottomAnchor),
                ])

            case .user:
                // A distinct card — accent left bar + faint tint — so the user's own
                // words clearly stand apart from the agent's stream (Cursor-style).
                let card = NSView()
                card.translatesAutoresizingMaskIntoConstraints = false
                card.wantsLayer = true
                card.layer?.cornerRadius = 8
                card.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor

                let bar = NSView()
                bar.translatesAutoresizingMaskIntoConstraints = false
                bar.wantsLayer = true
                bar.layer?.cornerRadius = 1.5
                bar.layer?.backgroundColor = NSColor.controlAccentColor.cgColor

                let label = NSTextField(wrappingLabelWithString: text)
                label.translatesAutoresizingMaskIntoConstraints = false
                label.font = .systemFont(ofSize: 12, weight: .medium)
                label.textColor = .white
                label.isSelectable = true
                label.preferredMaxLayoutWidth = avail - 70

                row.addSubview(card)
                card.addSubview(bar)
                card.addSubview(label)
                NSLayoutConstraint.activate([
                    card.leadingAnchor.constraint(equalTo: row.leadingAnchor),
                    card.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                    card.topAnchor.constraint(equalTo: row.topAnchor),
                    card.bottomAnchor.constraint(equalTo: row.bottomAnchor),
                    bar.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 8),
                    bar.topAnchor.constraint(equalTo: card.topAnchor, constant: 8),
                    bar.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8),
                    bar.widthAnchor.constraint(equalToConstant: 3),
                    label.leadingAnchor.constraint(equalTo: bar.trailingAnchor, constant: 10),
                    label.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
                    label.topAnchor.constraint(equalTo: card.topAnchor, constant: 8),
                    label.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8),
                ])
            }

            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20).isActive = true
            scrollToBottom()
        }

        private func scrollToBottom() {
            layoutSubtreeIfNeeded()
            guard let doc = scroll.documentView else { return }
            let y = max(0, doc.frame.height - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    // MARK: - Box

    private final class Box {
        let panel: NSPanel
        let scaler: NSView
        let statusDot: NSView
        let titleLabel: NSTextField
        let transcript: ChatTranscriptView
        let inputBar: NSView
        let steerField: NSTextField
        let sendButton: NSButton
        let continueButton: NSButton
        let stopButton: NSButton
        let cover: NSView
        let logo: NSImageView
        /// Current scaleUnitSquare factor applied to `scaler` (1 = unscaled bounds).
        var scale: CGFloat = 1
        var isExpanded = true
        /// Last agent line shown — so a repeated status doesn't stutter the transcript.
        var lastAgentText: String?
        var onStop: (() -> Void)?
        var onContinue: (() -> Void)?
        var onSteer: ((String) -> Void)?

        init(panel: NSPanel, scaler: NSView, statusDot: NSView, titleLabel: NSTextField,
             transcript: ChatTranscriptView, inputBar: NSView, steerField: NSTextField,
             sendButton: NSButton, continueButton: NSButton, stopButton: NSButton,
             cover: NSView, logo: NSImageView) {
            self.panel = panel
            self.scaler = scaler
            self.statusDot = statusDot
            self.titleLabel = titleLabel
            self.transcript = transcript
            self.inputBar = inputBar
            self.steerField = steerField
            self.sendButton = sendButton
            self.continueButton = continueButton
            self.stopButton = stopButton
            self.cover = cover
            self.logo = logo
        }
    }

    /// Borderless panel that can still become key, so the user can click and type
    /// inside the sandbox to sign in, and type messages to the agent.
    private final class SandboxPanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    private var boxes: [UUID: Box] = [:]

    private let viewW: CGFloat = WebSandbox.width
    private let viewH: CGFloat = WebSandbox.height

    // Chat-window geometry (a fixed-size expanded box — every inner frame is constant,
    // so layout() only ever toggles between this and the collapsed chip).
    private let boxW: CGFloat = 420
    private let boxH: CGFloat = 600
    private let pad: CGFloat = 12
    private let headerH: CGFloat = 26
    private let inputH: CGFloat = 40
    /// Side of the collapsed logo chip.
    private let chipSide: CGFloat = 60

    /// Scale that fits the 900×560 sandbox into the chat preview strip.
    private var previewScale: CGFloat { (boxW - 2 * pad) / viewW }

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
        box.titleLabel.stringValue = task
        setDot(box, .working)
        if isNew { layout(box, expanded: false, animate: false) }
        ensureHoverTimer()
        box.panel.orderFrontRegardless()
        box.panel.displayIfNeeded()
    }

    /// A new agent line — appended as an agent bubble (skipping a verbatim repeat).
    func updateStatus(_ id: UUID, _ text: String) {
        guard let box = boxes[id] else { return }
        appendAgent(box, text)
        setDot(box, .working)
    }

    /// The agent hit a sign-in wall: expand and pin the box, post the ask as an agent
    /// message, and swap the input bar for a Continue button that resumes once they're in.
    func requestLogin(_ id: UUID, message: String, onContinue: @escaping () -> Void) {
        guard let box = boxes[id] else { return }
        box.onContinue = onContinue
        appendAgent(box, message)
        setDot(box, .needsYou)
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

    // MARK: - Message plumbing

    private enum DotState { case working, needsYou }

    private func setDot(_ box: Box, _ state: DotState) {
        box.statusDot.layer?.backgroundColor = (state == .needsYou
            ? NSColor.systemOrange : NSColor.systemGreen).cgColor
    }

    private func appendAgent(_ box: Box, _ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != box.lastAgentText else { return }
        box.lastAgentText = trimmed
        box.transcript.append(role: .agent, text: trimmed)
    }

    private func appendUser(_ box: Box, _ text: String) {
        box.transcript.append(role: .user, text: text)
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
        showInputBar(box) // continue button hides, message field returns
        resume?()
    }

    /// Return in the message field sends (and only Return — the field's target/action
    /// would otherwise also fire on focus loss, submitting a half-typed message when the
    /// user clicks into the sandbox to sign in).
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.insertNewline(_:)),
              let box = boxes.first(where: { $0.value.panel === control.window })?.value else { return false }
        submitSteer(box)
        return true
    }

    @objc private func sendTapped(_ sender: NSButton) {
        guard let box = boxes.first(where: { $0.value.panel === sender.window })?.value else { return }
        submitSteer(box)
    }

    /// Hand the typed message to the agent for its next turn, show it as a user bubble,
    /// and clear the field.
    private func submitSteer(_ box: Box) {
        let message = box.steerField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        appendUser(box, message)
        box.onSteer?(message)
        box.steerField.stringValue = ""
    }

    // MARK: - Hover expand / collapse

    /// Hover is driven by polling the global mouse position (same pattern as the guide
    /// cursor's follow loop) — tracking areas on borderless floating panels are
    /// unreliable across app activation states. Cursor on the box → expanded; off → chip.
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
                // Pinned open during a sign-in OR while the user is typing a message (key
                // window) — so it never collapses mid-login or mid-message if the cursor
                // drifts off the box.
                guard box.onContinue == nil, !box.panel.isKeyWindow else { continue }
                layout(box, expanded: false, animate: true)
            }
        }
    }

    // MARK: - Layout

    private func showInputBar(_ box: Box) {
        let loggingIn = box.onContinue != nil
        box.inputBar.isHidden = !box.isExpanded || loggingIn
        box.continueButton.isHidden = !box.isExpanded || !loggingIn
    }

    /// Sizes the panel for the given state, keeping the panel's right edge and vertical
    /// centre pinned so it blooms leftward from its middle-right dock. Every inner frame
    /// is fixed (set in makeBox); here we only resize the panel, rescale the preview, and
    /// toggle chat-vs-chip visibility.
    private func layout(_ box: Box, expanded: Bool, animate: Bool) {
        box.isExpanded = expanded
        let width: CGFloat = expanded ? boxW : chipSide
        let height: CGFloat = expanded ? boxH : chipSide

        // The webview scales to the preview strip when expanded, and down to a faint
        // chip-sized thumbnail when collapsed (which keeps WebKit painting between hovers).
        let s: CGFloat = expanded ? previewScale : (chipSide - 8) / viewW
        let factor = s / box.scale
        if factor != 1 {
            box.scaler.scaleUnitSquare(to: NSSize(width: factor, height: factor))
            box.scale = s
        }

        let current = box.panel.frame
        let origin = NSPoint(x: current.maxX - width, y: current.midY - height / 2)
        box.panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true, animate: animate)

        if expanded {
            let pw = round(viewW * s), ph = round(viewH * s)
            // Preview sits below the header strip.
            box.scaler.frame = NSRect(x: pad, y: boxH - pad - headerH - 8 - ph, width: pw, height: ph)
        } else {
            let pw = round(viewW * s), ph = round(viewH * s)
            box.scaler.frame = NSRect(x: (chipSide - pw) / 2, y: (chipSide - ph) / 2, width: pw, height: ph)
        }

        box.statusDot.isHidden = !expanded
        box.titleLabel.isHidden = !expanded
        box.stopButton.isHidden = !expanded
        box.transcript.isHidden = !expanded
        showInputBar(box)

        box.cover.isHidden = expanded
        box.cover.frame = NSRect(x: 0, y: 0, width: width, height: height)
        box.logo.frame = NSRect(x: (width - 26) / 2, y: (height - 26) / 2, width: 26, height: 26)
        box.panel.contentView?.layer?.cornerRadius = 16
    }

    private func makeBox(for id: UUID) -> Box {
        // Activatable (not .nonactivatingPanel) so the user can click + type to sign in,
        // and to message the agent.
        let panel = SandboxPanel(
            contentRect: NSRect(x: 0, y: 0, width: boxW, height: boxH),
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
                x: screen.visibleFrame.maxX - boxW - 20,
                y: screen.visibleFrame.midY - boxH / 2 - slot * (chipSide + 14)
            ))
        }

        let content = NSView(frame: NSRect(x: 0, y: 0, width: boxW, height: boxH))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(calibratedWhite: 0.09, alpha: 0.98).cgColor
        content.layer?.cornerRadius = 16
        content.layer?.masksToBounds = true
        content.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.14).cgColor
        content.layer?.borderWidth = 1
        content.autoresizingMask = [.width, .height]

        // --- Header: status dot · task title · Stop --------------------------------
        let headerY = boxH - pad - headerH
        let dot = NSView(frame: NSRect(x: pad + 2, y: headerY + (headerH - 9) / 2, width: 9, height: 9))
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4.5
        dot.layer?.backgroundColor = NSColor.systemGreen.cgColor
        content.addSubview(dot)

        let title = NSTextField(labelWithString: "Starting…")
        title.frame = NSRect(x: pad + 18, y: headerY + 3, width: boxW - (pad + 18) - 64, height: 18)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        content.addSubview(title)

        let stop = NSButton(title: "Stop", target: self, action: #selector(stopTapped(_:)))
        stop.frame = NSRect(x: boxW - pad - 50, y: headerY, width: 50, height: 24)
        stop.bezelStyle = .rounded
        stop.controlSize = .small
        stop.contentTintColor = .systemRed
        content.addSubview(stop)

        // --- Preview strip (set precisely in layout) -------------------------------
        let scaler = NSView(frame: NSRect(x: pad, y: 0, width: viewW, height: viewH))
        scaler.wantsLayer = true
        scaler.layer?.backgroundColor = NSColor.black.cgColor
        scaler.layer?.cornerRadius = 8
        scaler.layer?.masksToBounds = true
        scaler.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.12).cgColor
        scaler.layer?.borderWidth = 1
        content.addSubview(scaler)

        // --- Transcript (between preview and input) --------------------------------
        let previewH = round(viewH * previewScale)
        let previewBottom = boxH - pad - headerH - 8 - previewH
        let inputTop = pad + inputH
        let transcriptY = inputTop + 10
        let transcript = ChatTranscriptView(frame: NSRect(
            x: pad, y: transcriptY,
            width: boxW - 2 * pad,
            height: max(60, previewBottom - 10 - transcriptY)
        ))
        transcript.layer?.backgroundColor = NSColor(calibratedWhite: 0, alpha: 0.18).cgColor
        content.addSubview(transcript)

        // --- Input bar: rounded pill with a send button ----------------------------
        let inputBar = NSView(frame: NSRect(x: pad, y: pad, width: boxW - 2 * pad, height: inputH))
        inputBar.wantsLayer = true
        inputBar.layer?.cornerRadius = inputH / 2
        inputBar.layer?.backgroundColor = NSColor(calibratedWhite: 0.18, alpha: 1).cgColor
        inputBar.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.10).cgColor
        inputBar.layer?.borderWidth = 1

        let steer = NSTextField(frame: NSRect(x: 14, y: (inputH - 20) / 2, width: inputBar.frame.width - 14 - 44, height: 20))
        steer.isBezeled = false
        steer.drawsBackground = false
        steer.focusRingType = .none
        steer.font = .systemFont(ofSize: 12)
        steer.textColor = .white
        steer.placeholderAttributedString = NSAttributedString(
            string: "Message the agent…",
            attributes: [.foregroundColor: NSColor(calibratedWhite: 0.6, alpha: 1), .font: NSFont.systemFont(ofSize: 12)]
        )
        steer.delegate = self
        inputBar.addSubview(steer)

        let send = NSButton(image: NSImage(systemSymbolName: "arrow.up.circle.fill", accessibilityDescription: "Send") ?? NSImage(), target: self, action: #selector(sendTapped(_:)))
        send.frame = NSRect(x: inputBar.frame.width - 34, y: (inputH - 26) / 2, width: 26, height: 26)
        send.isBordered = false
        send.imageScaling = .scaleProportionallyUpOrDown
        send.contentTintColor = .controlAccentColor
        send.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        inputBar.addSubview(send)
        content.addSubview(inputBar)

        // Sign-in resume button — occupies the input bar's slot when a login is pending.
        let cont = NSButton(title: "I've signed in — continue", target: self, action: #selector(continueTapped(_:)))
        cont.frame = NSRect(x: pad, y: pad, width: boxW - 2 * pad, height: inputH)
        cont.bezelStyle = .rounded
        cont.keyEquivalent = "\r" // only active while shown (login); hidden buttons are skipped
        cont.isHidden = true
        content.addSubview(cont)

        // --- Collapsed chip face ---------------------------------------------------
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
        let box = Box(panel: panel, scaler: scaler, statusDot: dot, titleLabel: title,
                      transcript: transcript, inputBar: inputBar, steerField: steer,
                      sendButton: send, continueButton: cont, stopButton: stop,
                      cover: cover, logo: logo)
        boxes[id] = box
        return box
    }
}
