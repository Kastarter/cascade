import AppKit
import WebKit

/// An isolated, off-to-the-side web environment the background agent works inside —
/// its own ephemeral cookie/storage jar, never touching the user's real screen.
/// Vision comes from `WKWebView.takeSnapshot` (like the old Rust Local Sandbox); the
/// agent acts by injecting JavaScript (click at a point, type, scroll, navigate).
///
/// The view is kept on-screen-but-tiny inside a floating box so WebKit doesn't
/// throttle painting (a fully off-screen view returns blank snapshots).
@MainActor
public final class WebSandbox: NSObject {
    /// Logical page size. The agent's vision + coordinates are all in this space.
    /// Shown 1:1 in the watch box (no scaling) so the page renders reliably and the
    /// user can sign in inside it when needed.
    public static let width: CGFloat = 900
    public static let height: CGFloat = 560

    public let webView: WKWebView
    private var loadContinuation: CheckedContinuation<Void, Never>?

    public override init() {
        let config = WKWebViewConfiguration()
        // Persistent session so a one-time sign-in inside the box sticks across runs
        // (the agent reuses it on later tasks instead of hitting the login wall again).
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: WebSandbox.width, height: WebSandbox.height), configuration: config)
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    public var currentURL: String { webView.url?.absoluteString ?? "" }
    public var title: String { webView.title ?? "" }

    /// Loads a URL and waits until the page finishes (or ~12s elapses).
    public func navigate(to urlString: String) async {
        var raw = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.lowercased().hasPrefix("http") { raw = "https://" + raw }
        guard let url = URL(string: raw) else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            loadContinuation = continuation
            webView.load(URLRequest(url: url))
            // Safety timeout so a hung/slow page can't wedge the loop.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(12))
                self.resumeLoad()
            }
        }
        // Give JS-rendered pages a beat to paint before the first snapshot.
        try? await Task.sleep(for: .milliseconds(900))
    }

    private func resumeLoad() {
        loadContinuation?.resume()
        loadContinuation = nil
    }

    /// Renders the live page to a PNG for the agent's vision (and the watch box).
    /// `afterScreenUpdates` is essential — without it the snapshot fires before the
    /// page paints and comes back blank.
    public func snapshotPNG() async -> Data? {
        webView.layoutSubtreeIfNeeded()
        webView.window?.displayIfNeeded()
        try? await Task.sleep(for: .milliseconds(120))
        let config = WKSnapshotConfiguration()
        config.rect = webView.bounds
        config.afterScreenUpdates = true
        return await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            webView.takeSnapshot(with: config) { image, _ in
                guard let image, image.size.width > 1, image.size.height > 1,
                      let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: png)
            }
        }
    }

    @discardableResult
    public func runJS(_ script: String) async -> String? {
        // The async form keeps the non-Sendable JS result on the main actor; we only
        // hand back a Sendable string. (Throws on `undefined` results — ignored.)
        let result = try? await webView.evaluateJavaScript(script)
        guard let result, !(result is NSNull) else { return nil }
        return String(describing: result)
    }

    /// Clicks at a top-left page coordinate by synthesizing real mouse events on the
    /// element under that point.
    public func click(xTopLeft x: CGFloat, yTopLeft y: CGFloat) async {
        let js = """
        (function(x, y){
          var el = document.elementFromPoint(x, y);
          if (!el) return 'none';
          var opts = {bubbles:true, cancelable:true, clientX:x, clientY:y, view:window};
          ['pointerdown','mousedown','pointerup','mouseup','click'].forEach(function(t){
            try { el.dispatchEvent(new (t.indexOf('pointer')===0?PointerEvent:MouseEvent)(t, opts)); } catch(e){}
          });
          if (el.focus) { try { el.focus(); } catch(e){} }
          return (el.tagName || '') + (el.href ? (' '+el.href) : '');
        })(\(Int(x)), \(Int(y)));
        """
        _ = await runJS(js)
        try? await Task.sleep(for: .milliseconds(150))
    }

    /// Types text into the currently focused field.
    public func typeText(_ text: String) async {
        let escaped = jsString(text)
        let js = """
        (function(t){
          var el = document.activeElement;
          if (!el) return 'noactive';
          if (el.isContentEditable) { el.textContent = (el.textContent||'') + t;
            el.dispatchEvent(new InputEvent('input',{bubbles:true})); return 'ce'; }
          var proto = el.tagName==='TEXTAREA' ? window.HTMLTextAreaElement.prototype : window.HTMLInputElement.prototype;
          var desc = Object.getOwnPropertyDescriptor(proto,'value');
          var next = (el.value||'') + t;
          if (desc && desc.set) desc.set.call(el, next); else el.value = next;
          el.dispatchEvent(new Event('input',{bubbles:true}));
          el.dispatchEvent(new Event('change',{bubbles:true}));
          return 'ok';
        })(\(escaped));
        """
        _ = await runJS(js)
    }

    /// Presses a key on the focused element (Enter submits its form).
    public func pressKey(_ key: String) async {
        let normalized = key.lowercased()
        let keyName: String
        let code: Int
        switch normalized {
        case "return", "enter": keyName = "Enter"; code = 13
        case "tab": keyName = "Tab"; code = 9
        case "escape", "esc": keyName = "Escape"; code = 27
        case "backspace", "delete": keyName = "Backspace"; code = 8
        default: keyName = key; code = 0
        }
        let js = """
        (function(){
          var el = document.activeElement || document.body;
          var opts = {bubbles:true, cancelable:true, key:'\(keyName)', code:'\(keyName)', keyCode:\(code), which:\(code)};
          ['keydown','keypress','keyup'].forEach(function(t){ try { el.dispatchEvent(new KeyboardEvent(t, opts)); } catch(e){} });
          if ('\(keyName)' === 'Enter' && el.form && el.form.requestSubmit) { try { el.form.requestSubmit(); } catch(e){} }
          return 'ok';
        })();
        """
        _ = await runJS(js)
        try? await Task.sleep(for: .milliseconds(250))
    }

    public func scroll(dy: CGFloat) async {
        _ = await runJS("window.scrollBy(0, \(Int(dy)));")
        try? await Task.sleep(for: .milliseconds(150))
    }

    private func jsString(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "")
        return "'\(escaped)'"
    }
}

extension WebSandbox: WKUIDelegate {
    /// "Open in new tab/window" (window.open, target="_blank") has nowhere to go in a
    /// single-view sandbox, so collapse it into THIS view — the task continues here
    /// instead of stalling on a tab that never appears.
    public func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }
}

extension WebSandbox: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        resumeLoad()
    }
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        resumeLoad()
    }
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        resumeLoad()
    }
}
