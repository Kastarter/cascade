import AppKit
import SandboxKit
import WebKit

/// Floating boxes — one per background agent — showing each agent working inside
/// its sandbox. Every box hosts that agent's actual sandbox `WKWebView`, which also
/// keeps WebKit painting so `takeSnapshot` returns live frames instead of blank
/// ones. One panel per agent is essential: a shared panel would evict the previous
/// agent's webView from its window and blind it mid-run.
@MainActor
final class SandboxBoxController: NSObject {
    private final class Box {
        let panel: NSPanel
        let scaler: NSView
        let statusLabel: NSTextField
        let continueButton: NSButton
        var onStop: (() -> Void)?
        var onContinue: (() -> Void)?

        init(panel: NSPanel, scaler: NSView, statusLabel: NSTextField, continueButton: NSButton) {
            self.panel = panel
            self.scaler = scaler
            self.statusLabel = statusLabel
            self.continueButton = continueButton
        }
    }

    private var boxes: [UUID: Box] = [:]

    private let viewW: CGFloat = WebSandbox.width
    private let viewH: CGFloat = WebSandbox.height
    private let headerH: CGFloat = 40

    func show(_ id: UUID, webView: WKWebView, task: String, onStop: @escaping () -> Void) {
        let box = boxes[id] ?? makeBox(for: id)
        box.onStop = onStop
        if webView.superview !== box.scaler {
            webView.removeFromSuperview()
            webView.frame = box.scaler.bounds
            webView.autoresizingMask = [.width, .height]
            box.scaler.addSubview(webView)
        }
        box.statusLabel.stringValue = "● \(task)"
        box.continueButton.isHidden = true
        box.panel.orderFrontRegardless()
        box.panel.displayIfNeeded()
    }

    func updateStatus(_ id: UUID, _ text: String) {
        boxes[id]?.statusLabel.stringValue = text
    }

    /// The agent hit a sign-in wall: keep the box up, let the user log in inside it,
    /// and show a Continue button that resumes the task once they're signed in.
    func requestLogin(_ id: UUID, message: String, onContinue: @escaping () -> Void) {
        guard let box = boxes[id] else { return }
        box.onContinue = onContinue
        box.statusLabel.stringValue = message
        box.continueButton.isHidden = false
        box.panel.orderFrontRegardless()
        box.panel.makeKeyAndOrderFront(nil)
    }

    func hide(_ id: UUID) {
        guard let box = boxes.removeValue(forKey: id) else { return }
        box.scaler.subviews.forEach { $0.removeFromSuperview() }
        box.panel.orderOut(nil)
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

    private func makeBox(for id: UUID) -> Box {
        let width = viewW + 20
        let height = viewH + headerH + 16
        // Activatable (not .nonactivatingPanel) so the user can click + type to sign in
        // inside the box when a task needs a login.
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.title = "Cascade · background"
        if let screen = NSScreen.main {
            // Cascade additional boxes up-and-left so concurrent agents don't overlap.
            let slot = CGFloat(boxes.count)
            panel.setFrameOrigin(NSPoint(
                x: screen.visibleFrame.maxX - width - 24 - slot * 36,
                y: screen.visibleFrame.minY + 24 + slot * 36
            ))
        }

        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))

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
        status.lineBreakMode = .byTruncatingTail
        content.addSubview(status)

        let stop = NSButton(title: "Stop", target: self, action: #selector(stopTapped(_:)))
        stop.frame = NSRect(x: width - 72, y: viewH + 14, width: 60, height: 26)
        stop.bezelStyle = .rounded
        content.addSubview(stop)

        let cont = NSButton(title: "Continue", target: self, action: #selector(continueTapped(_:)))
        cont.frame = NSRect(x: width - 156, y: viewH + 14, width: 80, height: 26)
        cont.bezelStyle = .rounded
        cont.keyEquivalent = "\r"
        cont.isHidden = true
        content.addSubview(cont)

        panel.contentView = content
        let box = Box(panel: panel, scaler: scaler, statusLabel: status, continueButton: cont)
        boxes[id] = box
        return box
    }
}
