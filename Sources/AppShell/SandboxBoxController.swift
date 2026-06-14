import AppKit
import SandboxKit
import WebKit

/// Cascade design tokens for the watch box (dark values — the box is always darkAqua),
/// mirrored from CascadeDesignSystem so the box reads in the same language as the Reel
/// page: the live screen is framed like a SceneCard, agent surfaces use the "intentional
/// blue" (cascadeAgent), and the chrome uses the cascade panel/border ramp.
private enum Tok {
    static func hex(_ h: String) -> NSColor {
        var v: UInt64 = 0
        Scanner(string: h).scanHexInt64(&v)
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
    static let bg = hex("141713")        // cascadePanel
    static let bgDeep = hex("0A0D0A")    // cascadeBG
    static let panel2 = hex("1D211C")    // cascadePanel2
    static let border = hex("2D322C")    // cascadeBorder
    static let borderHi = hex("454B44")  // cascadeBorderHi
    static let agent = hex("5BC8EA")     // cascadeAgent — live-agent blue
    static let good = hex("8FBF7A")      // cascadeGood
    static let warn = hex("E9A679")      // cascadeWarn / cascadeAccent
    static let text = hex("F4F4EF")      // cascadeText
    static let text2 = hex("B1B0A9")     // cascadeText2
    static let text3 = hex("75756D")     // cascadeText3
}

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
            let avail = bounds.width > 1 ? bounds.width : 280
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
                dot.layer?.backgroundColor = Tok.agent.cgColor

                let label = NSTextField(wrappingLabelWithString: text)
                label.translatesAutoresizingMaskIntoConstraints = false
                label.font = .systemFont(ofSize: 12)
                label.textColor = Tok.text2
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
                card.layer?.backgroundColor = Tok.agent.withAlphaComponent(0.16).cgColor

                let bar = NSView()
                bar.translatesAutoresizingMaskIntoConstraints = false
                bar.wantsLayer = true
                bar.layer?.cornerRadius = 1.5
                bar.layer?.backgroundColor = Tok.agent.cgColor

                let label = NSTextField(wrappingLabelWithString: text)
                label.translatesAutoresizingMaskIntoConstraints = false
                label.font = .systemFont(ofSize: 12, weight: .medium)
                label.textColor = Tok.text
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
        /// Native companion cursor over the live screen (the agent's "cursor").
        let cursorView: NSImageView
        /// "● LIVE" badge on the screen pane, echoing the Reel's "Captured · Local".
        let liveBadge: NSView
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
             cover: NSView, logo: NSImageView, cursorView: NSImageView, liveBadge: NSView) {
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
            self.cursorView = cursorView
            self.liveBadge = liveBadge
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

    // Side-by-side geometry (a fixed-size expanded box — every inner frame is constant,
    // so layout() only ever toggles between this and the collapsed chip): the live
    // sandbox screen on the LEFT, the chat column (transcript + composer) on the RIGHT,
    // a header spanning the top.
    private let boxW: CGFloat = 760
    private let boxH: CGFloat = 430
    private let pad: CGFloat = 12
    private let headerH: CGFloat = 28
    private let inputH: CGFloat = 38
    private let gap: CGFloat = 12
    /// Width of the left-hand live-screen pane.
    private let screenAreaW: CGFloat = 430
    /// Side of the collapsed logo chip.
    private let chipSide: CGFloat = 60

    /// Scale that fits the 900×560 sandbox into the left screen pane.
    private var previewScale: CGFloat { screenAreaW / viewW }
    /// Left edge + width of the right-hand chat column.
    private var chatX: CGFloat { pad + screenAreaW + gap }
    private var chatW: CGFloat { boxW - chatX - pad }
    /// Top of the content area (below the header strip).
    private var contentTop: CGFloat { boxH - pad - headerH - 8 }
    /// The live-screen pane's frame when expanded (left pane, vertically centred).
    private var expandedScreenFrame: NSRect {
        let pw = round(viewW * previewScale), ph = round(viewH * previewScale)
        return NSRect(x: pad, y: pad + ((contentTop - pad) - ph) / 2, width: pw, height: ph)
    }

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
        let identity = NSMutableAttributedString(string: "Cascade", attributes: [
            .foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
        ])
        identity.append(NSAttributedString(string: "   \(task)", attributes: [
            .foregroundColor: NSColor(calibratedWhite: 0.6, alpha: 1), .font: NSFont.systemFont(ofSize: 12),
        ]))
        box.titleLabel.attributedStringValue = identity
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
        box.statusDot.layer?.backgroundColor = (state == .needsYou ? Tok.warn : Tok.good).cgColor
    }

    /// Flies the native companion cursor to a page point (top-left coords, 900×560) and
    /// pings a ripple — the agent's visible "cursor" over the live screen.
    func moveCursor(_ id: UUID, toPagePoint p: CGPoint) {
        guard let box = boxes[id], box.isExpanded else { return }
        let sf = box.scaler.frame
        let cx = sf.minX + p.x * previewScale
        let cy = sf.maxY - p.y * previewScale // page y is top-down; content is bottom-up
        let h = box.cursorView.frame.height
        box.cursorView.isHidden = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.32
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            box.cursorView.animator().setFrameOrigin(NSPoint(x: cx - 2, y: cy - h + 2))
        }
        rippleCursor(box, at: NSPoint(x: cx, y: cy))
    }

    /// A quick expanding ring at the tap point, like the on-screen agent's click ripple.
    private func rippleCursor(_ box: Box, at point: NSPoint) {
        guard let host = box.panel.contentView?.layer else { return }
        let r: CGFloat = 9
        let ring = CAShapeLayer()
        ring.frame = CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2)
        ring.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: r * 2, height: r * 2), transform: nil)
        ring.fillColor = Tok.agent.withAlphaComponent(0.25).cgColor
        ring.strokeColor = Tok.agent.cgColor
        ring.lineWidth = 2
        host.addSublayer(ring)
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.5; scale.toValue = 2.6
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.95; fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 0.5
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.add(group, forKey: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { ring.removeFromSuperlayer() }
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

        let pw = round(viewW * s), ph = round(viewH * s)
        if expanded {
            box.scaler.frame = expandedScreenFrame // left pane, vertically centred
        } else {
            box.scaler.frame = NSRect(x: (chipSide - pw) / 2, y: (chipSide - ph) / 2, width: pw, height: ph)
        }

        box.statusDot.isHidden = !expanded
        box.titleLabel.isHidden = !expanded
        box.stopButton.isHidden = !expanded
        box.transcript.isHidden = !expanded
        box.liveBadge.isHidden = !expanded
        box.cursorView.isHidden = true // re-appears on the next agent action
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
        content.layer?.backgroundColor = Tok.bg.cgColor
        content.layer?.cornerRadius = 16
        content.layer?.masksToBounds = true
        content.layer?.borderColor = Tok.border.cgColor
        content.layer?.borderWidth = 1
        content.autoresizingMask = [.width, .height]

        // --- Header: status dot · Cascade · task · Stop ----------------------------
        let headerY = boxH - pad - headerH
        let dot = NSView(frame: NSRect(x: pad + 2, y: headerY + (headerH - 9) / 2, width: 9, height: 9))
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4.5
        dot.layer?.backgroundColor = Tok.good.cgColor
        content.addSubview(dot)

        let title = NSTextField(labelWithString: "Starting…")
        title.frame = NSRect(x: pad + 18, y: headerY + 3, width: boxW - (pad + 18) - 64, height: 18)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = Tok.text
        title.lineBreakMode = .byTruncatingTail
        content.addSubview(title)

        let stop = NSButton(title: "Stop", target: self, action: #selector(stopTapped(_:)))
        stop.frame = NSRect(x: boxW - pad - 50, y: headerY, width: 50, height: 24)
        stop.bezelStyle = .rounded
        stop.controlSize = .small
        stop.contentTintColor = .systemRed
        content.addSubview(stop)

        // --- Left pane: the live screen, framed like the Reel's SceneCard ----------
        let scaler = NSView(frame: NSRect(x: pad, y: 0, width: viewW, height: viewH))
        scaler.wantsLayer = true
        scaler.layer?.backgroundColor = NSColor.black.cgColor
        scaler.layer?.cornerRadius = 12
        scaler.layer?.masksToBounds = true
        scaler.layer?.borderColor = Tok.borderHi.cgColor
        scaler.layer?.borderWidth = 1
        content.addSubview(scaler)

        // Faint divider between the screen pane and the chat column.
        let divider = NSView(frame: NSRect(x: chatX - gap / 2, y: pad, width: 1, height: contentTop - pad))
        divider.wantsLayer = true
        divider.layer?.backgroundColor = Tok.border.cgColor
        content.addSubview(divider)

        // --- Right column: chat transcript above the composer ----------------------
        let inputTop = pad + inputH
        let transcriptY = inputTop + 10
        let transcript = ChatTranscriptView(frame: NSRect(
            x: chatX, y: transcriptY, width: chatW, height: max(80, contentTop - transcriptY)
        ))
        transcript.layer?.backgroundColor = Tok.bgDeep.withAlphaComponent(0.5).cgColor
        content.addSubview(transcript)

        // --- Composer: rounded pill with a send button -----------------------------
        let inputBar = NSView(frame: NSRect(x: chatX, y: pad, width: chatW, height: inputH))
        inputBar.wantsLayer = true
        inputBar.layer?.cornerRadius = inputH / 2
        inputBar.layer?.backgroundColor = Tok.panel2.cgColor
        inputBar.layer?.borderColor = Tok.border.cgColor
        inputBar.layer?.borderWidth = 1

        let steer = NSTextField(frame: NSRect(x: 14, y: (inputH - 20) / 2, width: inputBar.frame.width - 14 - 44, height: 20))
        steer.isBezeled = false
        steer.drawsBackground = false
        steer.focusRingType = .none
        steer.font = .systemFont(ofSize: 12)
        steer.textColor = Tok.text
        steer.placeholderAttributedString = NSAttributedString(
            string: "Message the agent…",
            attributes: [.foregroundColor: Tok.text3, .font: NSFont.systemFont(ofSize: 12)]
        )
        steer.delegate = self
        inputBar.addSubview(steer)

        let send = NSButton(image: NSImage(systemSymbolName: "arrow.up.circle.fill", accessibilityDescription: "Send") ?? NSImage(), target: self, action: #selector(sendTapped(_:)))
        send.frame = NSRect(x: inputBar.frame.width - 34, y: (inputH - 26) / 2, width: 26, height: 26)
        send.isBordered = false
        send.imageScaling = .scaleProportionallyUpOrDown
        send.contentTintColor = Tok.agent
        send.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        inputBar.addSubview(send)
        content.addSubview(inputBar)

        // Sign-in resume button — occupies the input bar's slot when a login is pending.
        let cont = NSButton(title: "I've signed in — continue", target: self, action: #selector(continueTapped(_:)))
        cont.frame = NSRect(x: chatX, y: pad, width: chatW, height: inputH)
        cont.bezelStyle = .rounded
        cont.keyEquivalent = "\r" // only active while shown (login); hidden buttons are skipped
        cont.isHidden = true
        content.addSubview(cont)

        // "● LIVE" badge on the screen pane (top-right), echoing the Reel's capture badge.
        let sf = expandedScreenFrame
        let badge = NSView(frame: NSRect(x: sf.maxX - 60, y: sf.maxY - 26, width: 52, height: 18))
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 9
        badge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
        badge.layer?.borderColor = Tok.agent.withAlphaComponent(0.4).cgColor
        badge.layer?.borderWidth = 1
        let bdot = NSView(frame: NSRect(x: 9, y: 6, width: 6, height: 6))
        bdot.wantsLayer = true
        bdot.layer?.cornerRadius = 3
        bdot.layer?.backgroundColor = Tok.good.cgColor
        badge.addSubview(bdot)
        let blabel = NSTextField(labelWithString: "LIVE")
        blabel.frame = NSRect(x: 20, y: 2, width: 28, height: 13)
        blabel.font = .systemFont(ofSize: 9, weight: .bold)
        blabel.textColor = Tok.agent
        badge.addSubview(blabel)
        content.addSubview(badge)

        // Native companion cursor over the live screen — bulletproof vs. an in-page one.
        let cursorView = NSImageView(image: NSImage(systemSymbolName: "cursorarrow", accessibilityDescription: "Agent cursor") ?? NSImage())
        cursorView.frame = NSRect(x: sf.minX + 20, y: sf.midY, width: 22, height: 22)
        cursorView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .bold)
        cursorView.contentTintColor = Tok.agent
        cursorView.wantsLayer = true
        cursorView.layer?.shadowColor = NSColor.black.cgColor
        cursorView.layer?.shadowRadius = 3
        cursorView.layer?.shadowOpacity = 0.75
        cursorView.layer?.shadowOffset = .zero
        cursorView.layer?.masksToBounds = false
        cursorView.isHidden = true
        content.addSubview(cursorView)

        // --- Collapsed chip face ---------------------------------------------------
        let cover = NSView(frame: content.bounds)
        cover.wantsLayer = true
        cover.layer?.backgroundColor = Tok.bgDeep.withAlphaComponent(0.72).cgColor
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
                      cover: cover, logo: logo, cursorView: cursorView, liveBadge: badge)
        boxes[id] = box
        return box
    }
}
