import AppKit
import SandboxKit
import WebKit

/// A small floating box that shows the background agent working inside its sandbox.
/// It hosts the actual sandbox `WKWebView` (scaled down) — which also keeps WebKit
/// painting so `takeSnapshot` returns live frames instead of blank ones.
@MainActor
final class SandboxBoxController: NSObject {
    private var panel: NSPanel?
    private var scaler: NSView?
    private var statusLabel: NSTextField?
    private var continueButton: NSButton?
    private var onStop: (() -> Void)?
    private var onContinue: (() -> Void)?

    private let viewW: CGFloat = WebSandbox.width
    private let viewH: CGFloat = WebSandbox.height
    private let headerH: CGFloat = 40

    func show(webView: WKWebView, task: String, onStop: @escaping () -> Void) {
        self.onStop = onStop
        ensurePanel()

        if let scaler {
            scaler.subviews.forEach { $0.removeFromSuperview() }
            webView.frame = scaler.bounds
            webView.autoresizingMask = [.width, .height]
            scaler.addSubview(webView)
        }
        statusLabel?.stringValue = "● \(task)"
        continueButton?.isHidden = true
        panel?.title = "Cascade · background"
        panel?.orderFrontRegardless()
        panel?.displayIfNeeded()
    }

    func updateStatus(_ text: String) {
        statusLabel?.stringValue = text
    }

    /// The agent hit a sign-in wall: keep the box up, let the user log in inside it,
    /// and show a Continue button that resumes the task once they're signed in.
    func requestLogin(message: String, onContinue: @escaping () -> Void) {
        self.onContinue = onContinue
        statusLabel?.stringValue = message
        continueButton?.isHidden = false
        panel?.orderFrontRegardless()
        panel?.makeKeyAndOrderFront(nil)
    }

    func hide() {
        scaler?.subviews.forEach { $0.removeFromSuperview() }
        panel?.orderOut(nil)
    }

    @objc private func stopTapped() {
        onStop?()
        hide()
    }

    @objc private func continueTapped() {
        let resume = onContinue
        onContinue = nil
        continueButton?.isHidden = true
        resume?()
    }

    private func ensurePanel() {
        guard panel == nil else { return }
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
        if let screen = NSScreen.main {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - width - 24, y: screen.visibleFrame.minY + 24))
        }

        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))

        // Scaled web container (renders the 1280×820 page into a 640×410 box).
        let scaler = NSView(frame: NSRect(x: 10, y: 10, width: viewW, height: viewH))
        scaler.wantsLayer = true
        scaler.layer?.backgroundColor = NSColor.black.cgColor
        scaler.layer?.cornerRadius = 6
        scaler.layer?.masksToBounds = true
        content.addSubview(scaler)
        self.scaler = scaler

        // Header: status + stop.
        let status = NSTextField(labelWithString: "Starting…")
        status.frame = NSRect(x: 12, y: viewH + 18, width: width - 172, height: 20)
        status.font = .systemFont(ofSize: 12, weight: .medium)
        status.lineBreakMode = .byTruncatingTail
        content.addSubview(status)
        self.statusLabel = status

        let stop = NSButton(title: "Stop", target: self, action: #selector(stopTapped))
        stop.frame = NSRect(x: width - 72, y: viewH + 14, width: 60, height: 26)
        stop.bezelStyle = .rounded
        content.addSubview(stop)

        let cont = NSButton(title: "Continue", target: self, action: #selector(continueTapped))
        cont.frame = NSRect(x: width - 156, y: viewH + 14, width: 80, height: 26)
        cont.bezelStyle = .rounded
        cont.keyEquivalent = "\r"
        cont.isHidden = true
        content.addSubview(cont)
        self.continueButton = cont

        panel.contentView = content
        self.panel = panel
    }
}
