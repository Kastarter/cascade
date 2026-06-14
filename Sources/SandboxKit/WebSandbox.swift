import AppKit
import WebKit

/// An isolated, off-to-the-side web environment the background agent works inside —
/// never touching the user's real screen. It deliberately uses the DEFAULT (persistent)
/// website data store so the agent reuses the user's existing sign-in sessions —
/// the NEEDS_LOGIN pause exists for the sites where that isn't enough.
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
    /// Bumped per navigation so a navigation's safety-timeout can only resume ITS
    /// OWN load, never a later one's.
    private var navGeneration = 0
    /// The WKNavigation `navigate()` is waiting on. The delegate callbacks resume the
    /// continuation ONLY for this exact navigation — so an unrelated load (an in-page
    /// link, a `createWebViewWith` redirect) can't resume it early.
    private var pendingNavigation: WKNavigation?

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
        navGeneration &+= 1
        let generation = navGeneration
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            loadContinuation = continuation
            pendingNavigation = webView.load(URLRequest(url: url))
            // Safety timeout so a hung/slow page can't wedge the loop — but tagged by
            // generation, so a stale timer from THIS load can't fire during a LATER
            // load and resume the wrong continuation.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(12))
                if self.navGeneration == generation { self.resumeLoad() }
            }
        }
        // Give JS-rendered pages a beat to paint before the first snapshot.
        try? await Task.sleep(for: .milliseconds(900))
    }

    private func resumeLoad() {
        loadContinuation?.resume()
        loadContinuation = nil
        pendingNavigation = nil
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

    // MARK: - Action point (drives the native companion cursor in the watch box)

    /// The last page point (top-left coords) the agent acted on. The watch box reads
    /// this after each action and flies its NATIVE cursor overlay there — bulletproof
    /// vs. an in-page cursor (no page CSP/SPA can wipe it, and it stays out of the
    /// agent's own screenshots).
    public private(set) var lastActionPoint: CGPoint?

    /// Returns the pending action point and clears it, so a non-acting tool
    /// (read_page / list_interactives) never re-fires a stale point.
    public func consumeActionPoint() -> CGPoint? {
        defer { lastActionPoint = nil }
        return lastActionPoint
    }

    /// Pulls a leading "@@x,y@@" the action JS prepends (the element centre it acted on)
    /// into `lastActionPoint`, returning the result with that marker stripped.
    @discardableResult
    private func captureActionPoint(_ result: String?) -> String? {
        guard let result, result.hasPrefix("@@"),
              let close = result.range(of: "@@", range: result.index(result.startIndex, offsetBy: 2)..<result.endIndex)
        else { return result }
        let coords = result[result.index(result.startIndex, offsetBy: 2)..<close.lowerBound].split(separator: ",").compactMap { Double($0) }
        if coords.count == 2 { lastActionPoint = CGPoint(x: coords[0], y: coords[1]) }
        return String(result[close.upperBound...])
    }

    /// Records where the agent's pointer is headed (top-left page coords) — there's no
    /// real pointer in the sandbox, so this only feeds the watch box's cursor overlay.
    public func moveCursor(toTopLeftX x: CGFloat, y: CGFloat) async {
        lastActionPoint = CGPoint(x: x, y: y)
    }

    /// Clicks at a top-left page coordinate by synthesizing real mouse events on the
    /// element under that point.
    public func click(xTopLeft x: CGFloat, yTopLeft y: CGFloat) async {
        lastActionPoint = CGPoint(x: x, y: y)
        let js = """
        (function(x, y){
          var el = document.elementFromPoint(x, y);
          if (!el) return 'none';
          var opts = {bubbles:true, cancelable:true, clientX:x, clientY:y, view:window};
          ['pointerdown','mousedown','pointerup','mouseup','click'].forEach(function(t){
            try { el.dispatchEvent(new (t.indexOf('pointer')===0?PointerEvent:MouseEvent)(t, opts)); } catch(e){}
          });
          // Focus the right target AND place the caret, so a following type lands here.
          // Rich editors (Notion, Google Docs) are contenteditable, not inputs — a
          // synthetic click alone never puts the caret in them, so typing went nowhere.
          var host = el;
          while (host && host.parentElement && host.parentElement.isContentEditable) host = host.parentElement;
          if (host && host.isContentEditable) {
            try { host.focus(); } catch(e){}
            try {
              var r = document.caretRangeFromPoint(x, y);
              if (r) { var s = window.getSelection(); s.removeAllRanges(); s.addRange(r); }
            } catch(e){}
          } else if (el.focus) { try { el.focus(); } catch(e){} }
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
          var pt = '';
          if (el.getBoundingClientRect) { var br = el.getBoundingClientRect();
            pt = '@@' + Math.round(br.left + 12) + ',' + Math.round(br.top + br.height/2) + '@@'; }
          if (el.isContentEditable) {
            // Insert AT THE CARET via execCommand — ProseMirror/Notion/Docs see the right
            // beforeinput/input events; clobbering textContent (the old way) corrupts them.
            var ok = false; try { ok = document.execCommand('insertText', false, t); } catch(e){}
            if (!ok) {
              try { el.dispatchEvent(new InputEvent('beforeinput',{bubbles:true,cancelable:true,inputType:'insertText',data:t})); } catch(e){}
              try { el.dispatchEvent(new InputEvent('input',{bubbles:true,inputType:'insertText',data:t})); } catch(e){}
            }
            return pt+'ce';
          }
          var proto = el.tagName==='TEXTAREA' ? window.HTMLTextAreaElement.prototype : window.HTMLInputElement.prototype;
          var desc = Object.getOwnPropertyDescriptor(proto,'value');
          var next = (el.value||'') + t;
          if (desc && desc.set) desc.set.call(el, next); else el.value = next;
          el.dispatchEvent(new Event('input',{bubbles:true}));
          el.dispatchEvent(new Event('change',{bubbles:true}));
          return pt+'ok';
        })(\(escaped));
        """
        captureActionPoint(await runJS(js))
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

    // MARK: - DOM harness (the web analog of the Mac file/shell harness)
    // These read + act on the page semantically, returned inline so the agent never
    // needs a screenshot round-trip for content or for clicking a named control.

    /// The page's title, URL, and visible text (capped) — read content directly.
    public func readPageText() async -> String {
        let js = """
        (function(){
          var t = document.title || '';
          var u = location.href || '';
          var body = document.body ? (document.body.innerText || '') : '';
          body = body.replace(/\\n{3,}/g,'\\n\\n').trim();
          if (body.length > 4000) body = body.slice(0,4000) + '\\n…[truncated]';
          return 'TITLE: '+t+'\\nURL: '+u+'\\n\\n'+body;
        })();
        """
        return await runJS(js) ?? "Couldn't read the page."
    }

    /// The page's visible clickable + fillable elements, labelled — so the agent can
    /// act on them by text instead of guessing pixel coordinates.
    public func listInteractives() async -> String {
        let js = """
        (function(){
          var sel = 'a[href], button, input:not([type=hidden]), textarea, select, [role=button], [role=link]';
          var els = Array.prototype.slice.call(document.querySelectorAll(sel));
          var out = [];
          for (var i=0;i<els.length && out.length<60;i++){
            var e=els[i]; var r=e.getBoundingClientRect();
            if (r.width<=0 || r.height<=0) continue;
            var tag=e.tagName.toLowerCase();
            var label=((e.getAttribute('aria-label')||e.placeholder||e.value||e.innerText||e.getAttribute('title')||'')+'').trim().replace(/\\s+/g,' ');
            if (label.length>80) label=label.slice(0,80);
            var field=(tag==='input'||tag==='textarea'||tag==='select');
            if (!label && !field) continue;
            out.push((out.length+1)+'. ['+(field?'field':(tag==='a'?'link':'button'))+'] '+(label||'(unlabeled '+tag+')'));
          }
          return out.length ? out.join('\\n') : 'No interactive elements found.';
        })();
        """
        return await runJS(js) ?? "Couldn't list the page elements."
    }

    /// Clicks the visible element whose label best matches `text` (shortest match wins).
    /// Reports the element centre (for the watch box's cursor) via the "@@x,y@@" marker.
    public func clickByText(_ text: String) async -> String {
        let js = """
        (function(q){
          q=(q||'').toLowerCase();
          var sel='a[href], button, [role=button], [role=link], input[type=submit], input[type=button]';
          var els=Array.prototype.slice.call(document.querySelectorAll(sel));
          var best=null,bestLen=1e9;
          for(var i=0;i<els.length;i++){var e=els[i];var r=e.getBoundingClientRect();if(r.width<=0||r.height<=0)continue;
            var label=((e.getAttribute('aria-label')||e.value||e.innerText||e.getAttribute('title')||'')+'').toLowerCase().trim();
            if(label.indexOf(q)!==-1 && label.length<bestLen){best=e;bestLen=label.length;}}
          if(!best) return 'NO_MATCH: nothing clickable matching that text.';
          best.scrollIntoView({block:'center'});
          var rr=best.getBoundingClientRect(); var cx=rr.left+rr.width/2, cy=rr.top+rr.height/2;
          var o={bubbles:true,cancelable:true,clientX:cx,clientY:cy,view:window};
          ['pointerdown','mousedown','pointerup','mouseup','click'].forEach(function(t){try{best.dispatchEvent(new (t.indexOf('pointer')===0?PointerEvent:MouseEvent)(t,o));}catch(e){}});
          if(best.focus){try{best.focus();}catch(e){}}
          return '@@'+Math.round(cx)+','+Math.round(cy)+'@@CLICKED: '+((best.innerText||best.value||best.getAttribute('aria-label')||best.tagName)+'').trim().slice(0,80);
        })(\(jsString(text)));
        """
        let result = captureActionPoint(await runJS(js)) ?? "Click failed."
        try? await Task.sleep(for: .milliseconds(250))
        return result
    }

    /// Types `value` into the input/textarea whose label/placeholder/name best matches
    /// `field` (or the sole field on the page).
    public func fillField(_ field: String, value: String) async -> String {
        let js = """
        (function(q,val){
          q=(q||'').toLowerCase();
          var els=Array.prototype.slice.call(document.querySelectorAll('input:not([type=hidden]):not([type=submit]):not([type=button]), textarea'));
          function labelFor(e){var l=(e.getAttribute('aria-label')||e.placeholder||e.name||'')+'';
            if(e.id){var lab=document.querySelector('label[for="'+e.id+'"]'); if(lab) l+=' '+lab.innerText;} return l.toLowerCase();}
          var best=null;
          for(var i=0;i<els.length;i++){var e=els[i];var r=e.getBoundingClientRect();if(r.width<=0||r.height<=0)continue; if(labelFor(e).indexOf(q)!==-1){best=e;break;}}
          if(!best && els.length===1) best=els[0];
          if(!best) return 'NO_MATCH: no field matching that label.';
          best.scrollIntoView({block:'center'});
          var fr=best.getBoundingClientRect(); var cx=fr.left+12, cy=fr.top+fr.height/2;
          best.focus();
          var proto=best.tagName==='TEXTAREA'?window.HTMLTextAreaElement.prototype:window.HTMLInputElement.prototype;
          var desc=Object.getOwnPropertyDescriptor(proto,'value');
          if(desc&&desc.set) desc.set.call(best,val); else best.value=val;
          best.dispatchEvent(new Event('input',{bubbles:true}));
          best.dispatchEvent(new Event('change',{bubbles:true}));
          return '@@'+Math.round(cx)+','+Math.round(cy)+'@@FILLED: '+((best.getAttribute('aria-label')||best.placeholder||best.name||'field')+'').slice(0,60)+' = '+(val+'').slice(0,60);
        })(\(jsString(field)),\(jsString(value)));
        """
        return captureActionPoint(await runJS(js)) ?? "Fill failed."
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
            // Collapse the "new tab" into this view, and adopt its navigation so a
            // navigate() awaiting the superseded load resumes when this one finishes.
            pendingNavigation = webView.load(URLRequest(url: url))
        }
        return nil
    }
}

extension WebSandbox: WKNavigationDelegate {
    // Resume only when the navigation that ended is the one navigate() is waiting on —
    // a stray in-page or redirected load finishing must not resume it early.
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if navigation === pendingNavigation { resumeLoad() }
    }
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if navigation === pendingNavigation { resumeLoad() }
    }
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if navigation === pendingNavigation { resumeLoad() }
    }
}
