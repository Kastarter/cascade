import AppKit
import Foundation

// MARK: - Grounding split (Phase 1 of the model-downgrade roadmap)
//
// The field consensus — and Cascade's own audited finding — is that *grounding*
// (knowing WHERE to click), not reasoning, is the GUI-agent bottleneck, and the
// way to make the on-screen agent good enough to downgrade the thinker later is to
// move grounding OUT of the model into a dedicated grounder. SOTA open-source
// stacks (Agent-S, trycua/cua) pair a strong planner with a small vision grounder;
// the grounder everyone reaches for is ByteDance's UI-TARS-1.5-7B, which grounds
// from PIXELS ALONE — exactly the case that defeats AX on iWork/Blender canvases
// (audit run 53666: AX exposes only chrome, no slide elements).
//
// This file is the grounder ENGINE only. It is wired STRUCTURALLY (the runtime
// names a target and the runtime acts on the returned point) — never as an
// advisory tool the model must choose to call. That distinction is load-bearing:
// every advisory grounding scaffold tried so far (pushed coords, the Tab recipe,
// the reverted `find_element` tool) was ignored by the model. See
// [[cascade-cu-downgrade-research]].

/// A grounder turns "where is X on this screen" into a clickable point WITHOUT a
/// cloud reasoning round trip in the hot path. Conformers: `UITARSGrounder` (local
/// MLX/vLLM, the cost+latency win) and `ClaudeVisualGrounder` (the proven engine,
/// kept as a fallback and for parity testing).
public protocol VisualGrounder: Sendable {
    /// Returns the target's location in **display-local AppKit points** (bottom-left
    /// origin) — the same coordinate space the executor's click path consumes — or
    /// `nil` when the grounder is unreachable or finds nothing confident.
    func ground(
        screenshot: Data,
        target: String,
        displayWidthPoints: Int,
        displayHeightPoints: Int
    ) async -> CGPoint?

    /// Locates a target as a REGION to frame (the "where is X" marching-ants
    /// highlight) — display-local AppKit rect + a short spoken line. Returns nil
    /// when this grounder can't produce one (unreachable, or not implemented), so
    /// the caller falls back to the proven Claude region locator.
    func groundRegion(
        screenshot: Data,
        target: String,
        displayWidthPoints: Int,
        displayHeightPoints: Int
    ) async -> ElementRegion?
}

public extension VisualGrounder {
    /// Default: no region grounding (the caller falls back to ElementLocator). The
    /// Claude grounder uses this default on purpose — the fallback IS its engine,
    /// at full quality (tight box + spoken line + conversation context).
    func groundRegion(
        screenshot: Data, target: String, displayWidthPoints: Int, displayHeightPoints: Int
    ) async -> ElementRegion? { nil }
}

// MARK: - Claude-backed grounder (the proven engine, as a fallback)

/// Wraps the existing `ElementLocator` (Claude Computer Use vision) behind the
/// `VisualGrounder` protocol. This is the engine Cascade already proved sound; it
/// costs a cloud round trip, so it is the fallback, not the hot path.
public struct ClaudeVisualGrounder: VisualGrounder {
    private let locator: ElementLocator

    public init(locator: ElementLocator = ElementLocator()) {
        self.locator = locator
    }

    public func ground(
        screenshot: Data,
        target: String,
        displayWidthPoints: Int,
        displayHeightPoints: Int
    ) async -> CGPoint? {
        await locator.guide(
            screenshot: screenshot,
            question: "click \(target)",
            displayWidthPoints: displayWidthPoints,
            displayHeightPoints: displayHeightPoints
        ).point
    }
}

// MARK: - UI-TARS local grounder (the cost + latency win)

/// Grounds against a locally-served **UI-TARS-1.5-7B** (Apache-2.0, Qwen2.5-VL
/// based) over an OpenAI-compatible `/v1/chat/completions` endpoint — vLLM,
/// SGLang, LM Studio, or `mlx-community/UI-TARS-1.5-7B-4bit` via mlx-vlm. No cloud
/// round trip, no per-token API cost, sub-second on Apple Silicon.
///
/// SETUP (the user runs this on their Mac; the model can't run in CI):
///   `pip install mlx-vlm` then serve `mlx-community/UI-TARS-1.5-7B-4bit`, or run
///   vLLM/LM Studio on `ByteDance-Seed/UI-TARS-1.5-7B`. Point `baseURL` at it.
///
/// RUNTIME-UNVERIFIED against a live model in this environment — the coordinate
/// parser and scaling math are unit-pinned (a wrong number clicks empty space);
/// the live request/response shape needs a dry run once a model is serving.
public struct UITARSGrounder: VisualGrounder {
    private let endpoint: URL
    private let model: String
    private let apiKey: String?
    private let session: URLSession

    /// - Parameters:
    ///   - baseURL: OpenAI-compatible chat-completions endpoint. Defaults to the
    ///     vLLM/SGLang local default; LM Studio is `http://localhost:1234/v1/...`.
    ///   - model: the served model id (deployment-specific).
    ///   - apiKey: Bearer token for hosted endpoints; omit for a local server.
    public init(
        baseURL: URL = URL(string: "http://localhost:8000/v1/chat/completions")!,
        model: String = "ui-tars-1.5-7b",
        apiKey: String? = nil,
        session: URLSession = .shared
    ) {
        self.endpoint = baseURL
        self.model = model
        self.apiKey = apiKey
        self.session = session
    }

    public func ground(
        screenshot: Data,
        target: String,
        displayWidthPoints: Int,
        displayHeightPoints: Int
    ) async -> CGPoint? {
        // Resize to the same Anthropic-recommended resolution the rest of the agent
        // declares, so coords come back in a known image space (frames captured at
        // this size pass through untouched). UI-TARS-1.5-7B emits ABSOLUTE pixel
        // coords in the input image's space.
        let res = AgentResolution.best(forWidth: displayWidthPoints, height: displayHeightPoints)
        guard let jpeg = Self.resizeJPEG(screenshot, toWidth: res.w, toHeight: res.h) else { return nil }
        guard let content = await callModel(jpeg: jpeg, target: target, declaredW: res.w, declaredH: res.h) else {
            return nil
        }
        guard let imagePoint = Self.parseBox(content) else { return nil }
        // UI-TARS (Qwen2.5-VL) returns ABSOLUTE coords in the SMART-RESIZED image
        // space — NOT the space of the JPEG we sent. Map back through smart_resize
        // before scaling to the display, or every click carries the resize offset
        // (worst on small targets). Live-verified: a 1280×800 send yields coords in
        // 1288×812, and mapping through it lands on target to the pixel. See
        // bytedance/UI-TARS README_coordinates.md.
        let resized = Self.smartResize(width: res.w, height: res.h)
        return Self.toDisplayPoint(
            imagePoint: imagePoint,
            imageW: resized.w, imageH: resized.h,
            displayW: displayWidthPoints, displayH: displayHeightPoints
        )
    }

    /// Reproduces Qwen2.5-VL's `smart_resize` (UI-TARS's image processor): each
    /// dimension is rounded to a multiple of `factor`, and the total pixel count is
    /// kept within [minPixels, maxPixels] at a fixed aspect ratio. UI-TARS emits
    /// click coordinates in THIS resized space, so `ground` maps them back through
    /// it. Pure + pinned — a wrong size offsets every click. Defaults match the
    /// official processor (factor 28, min 100·28², max 16384·28²); a live probe
    /// confirmed a 1280×800 send returns coords in the 1288×812 it produces.
    static func smartResize(
        width: Int, height: Int,
        factor: Int = 28, minPixels: Int = 100 * 28 * 28, maxPixels: Int = 16384 * 28 * 28
    ) -> (w: Int, h: Int) {
        let w = Double(max(1, width)), h = Double(max(1, height)), f = Double(factor)
        func roundTo(_ v: Double) -> Int { Int((v / f).rounded()) * factor }
        func floorTo(_ v: Double) -> Int { Int((v / f).rounded(.down)) * factor }
        func ceilTo(_ v: Double) -> Int { Int((v / f).rounded(.up)) * factor }
        var wb = max(factor, roundTo(w))
        var hb = max(factor, roundTo(h))
        if wb * hb > maxPixels {
            let beta = (w * h / Double(maxPixels)).squareRoot()
            wb = max(factor, floorTo(w / beta))
            hb = max(factor, floorTo(h / beta))
        } else if wb * hb < minPixels {
            let beta = (Double(minPixels) / (w * h)).squareRoot()
            wb = ceilTo(w * beta)
            hb = ceilTo(h * beta)
        }
        return (wb, hb)
    }

    /// Region grounding for the highlight: locate the target's click point, then
    /// frame a box around it. UI-TARS grounds to a point; a box around it is plenty
    /// for "show me where X is" (the marquee frames the area). Returns nil on any
    /// miss (unreachable OR not found) so the caller falls back to Claude.
    public func groundRegion(
        screenshot: Data, target: String, displayWidthPoints: Int, displayHeightPoints: Int
    ) async -> ElementRegion? {
        guard let point = await ground(
            screenshot: screenshot, target: target,
            displayWidthPoints: displayWidthPoints, displayHeightPoints: displayHeightPoints
        ) else { return nil }
        let rect = Self.boxAround(point: point, displayW: displayWidthPoints, displayH: displayHeightPoints)
        return ElementRegion(rect: rect, speech: "Here — it's in this area.")
    }

    /// A display-local AppKit rect framing a located point — ~12%×8% of the
    /// display, clamped on screen. Pure + pinned (a bad rect frames empty space).
    static func boxAround(point: CGPoint, displayW: Int, displayH: Int) -> CGRect {
        let w = CGFloat(displayW) * 0.12
        let h = CGFloat(displayH) * 0.08
        let x = max(0, min(point.x - w / 2, CGFloat(displayW) - w))
        let y = max(0, min(point.y - h / 2, CGFloat(displayH) - h))
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// The grounding instruction. Kept minimal and tunable — UI-TARS is trained to
    /// emit an action grammar; for pure grounding we ask for the single click point.
    static func prompt(target: String) -> String {
        """
        You are a GUI grounding model. Look at the screenshot and locate the element \
        described by this instruction:
        "\(target)"
        Respond with ONLY a single click action at that element's center, in the \
        format: click(start_box='(x,y)') where x and y are pixel coordinates in the \
        screenshot. Output nothing else.
        """
    }

    private func callModel(jpeg: Data, target: String, declaredW: Int, declaredH: Int) async -> String? {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        // Short per-attempt cap: grounding normally returns in ~1s, so a connection
        // that hasn't answered in 8s is dead — fail fast and recycle on the next
        // attempt rather than hang the whole turn. Most failures are immediate
        // resets (not timeouts), so this only bounds the rare true-hang case.
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        // Don't reuse a pooled keep-alive connection: Parasail drops idle ones, and
        // reusing a dead socket is the "broken pipe / SSL bad record mac" failure
        // class. A fresh connection per call sidesteps it (the cost is one TLS
        // handshake — negligible next to inference, and worth it for reliability).
        request.setValue("close", forHTTPHeaderField: "Connection")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")
        }
        let dataURL = "data:image/jpeg;base64,\(jpeg.base64EncodedString())"
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 128,
            "temperature": 0,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "text", "text": Self.prompt(target: target)],
                    ["type": "image_url", "image_url": ["url": dataURL]],
                ],
            ]],
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = bodyData
        // Hosted UI-TARS over OpenRouter hits transient TLS/connection failures
        // (broken pipe, "SSL bad record mac", 429/5xx) on a variable fraction of
        // calls — measured 0–20% in live probes. Treating those as "element not
        // found" produced spurious grounding misses that stacked into a stall. So
        // RETRY transient failures; only a clean 2xx (parsed downstream) or a
        // non-retryable 4xx ends it. A wrong nil here = a dead agent. 5 attempts so
        // a bad patch (each call mostly failing) still resolves before the stall
        // guard trips; failures are fast (immediate reset, not the 12s timeout).
        for attempt in 0..<5 {
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { return nil }
                if (200..<300).contains(http.statusCode) { return Self.extractContent(data) }
                // 4xx won't improve on retry (bad request / auth), except the
                // throttle / request-timeout codes which are transient.
                if (400..<500).contains(http.statusCode), http.statusCode != 408, http.statusCode != 429 {
                    return nil
                }
                // 5xx / 408 / 429 → fall through and retry.
            } catch {
                // Transport error (TLS / connection reset / timeout) → retry.
            }
            if attempt < 4 { try? await Task.sleep(for: .milliseconds(300)) }
        }
        return nil
    }

    /// Pulls `choices[0].message.content` out of an OpenAI chat-completions reply.
    /// `content` may be a plain string or (rarely) an array of content parts.
    static func extractContent(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else { return nil }
        if let text = message["content"] as? String { return text }
        if let parts = message["content"] as? [[String: Any]] {
            return parts.compactMap { $0["text"] as? String }.joined(separator: " ")
        }
        return nil
    }

    /// Parses UI-TARS's coordinate output into a point in **image pixel** space.
    /// Handles the documented grammar variants:
    ///   `click(start_box='(197,525)')`
    ///   `click(start_box='<|box_start|>(100,200)<|box_end|>')`
    ///   `(640, 360)` / `[100, 200]`
    ///   a 4-number region `(x1,y1,x2,y2)` → its center
    /// THE part most likely to be wrong, so it is pure and heavily pinned.
    static func parseBox(_ text: String) -> CGPoint? {
        // Box tokens are framing only — strip them so the numbers read cleanly.
        let cleaned = text
            .replacingOccurrences(of: "<|box_start|>", with: "")
            .replacingOccurrences(of: "<|box_end|>", with: "")

        // Prefer a parenthesised/bracketed group of 2 or 4 numbers.
        let grouped = "[\\(\\[]\\s*(-?\\d+(?:\\.\\d+)?)\\s*,\\s*(-?\\d+(?:\\.\\d+)?)(?:\\s*,\\s*(-?\\d+(?:\\.\\d+)?)\\s*,\\s*(-?\\d+(?:\\.\\d+)?))?\\s*[\\)\\]]"
        if let m = firstMatch(grouped, in: cleaned), let x1 = m[1], let y1 = m[2] {
            if let x2 = m[3], let y2 = m[4] {
                return CGPoint(x: (x1 + x2) / 2, y: (y1 + y2) / 2)  // region → center
            }
            return CGPoint(x: x1, y: y1)
        }
        // Fallback: the first bare comma-separated pair anywhere.
        let pair = "(-?\\d+(?:\\.\\d+)?)\\s*,\\s*(-?\\d+(?:\\.\\d+)?)"
        if let m = firstMatch(pair, in: cleaned), let x = m[1], let y = m[2] {
            return CGPoint(x: x, y: y)
        }
        return nil
    }

    /// Runs `pattern` and returns capture groups 1...n as optional CGFloats
    /// (index 0 is the whole match, kept nil for callers to index groups by number).
    private static func firstMatch(_ pattern: String, in text: String) -> [Int: CGFloat]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
            return nil
        }
        var groups: [Int: CGFloat] = [:]
        for i in 1..<match.numberOfRanges {
            guard let range = Range(match.range(at: i), in: text),
                  let value = Double(text[range]) else { continue }
            groups[i] = CGFloat(value)
        }
        return groups.isEmpty ? nil : groups
    }

    /// Image-pixel point (top-left origin) → display-local AppKit point
    /// (bottom-left origin). Mirrors `ElementLocator.guide`'s scaling exactly so a
    /// UI-TARS point and a Claude point feed the identical click path. A wrong
    /// number here clicks empty space, so it is pure and pinned.
    static func toDisplayPoint(
        imagePoint: CGPoint, imageW: Int, imageH: Int, displayW: Int, displayH: Int
    ) -> CGPoint {
        let clampedX = max(0, min(imagePoint.x, CGFloat(imageW)))
        let clampedY = max(0, min(imagePoint.y, CGFloat(imageH)))
        let scaledX = (clampedX / CGFloat(imageW)) * CGFloat(displayW)
        let scaledYFromTop = (clampedY / CGFloat(imageH)) * CGFloat(displayH)
        let scaledYFromBottom = CGFloat(displayH) - scaledYFromTop
        return CGPoint(x: scaledX, y: scaledYFromBottom)
    }

    /// Exact-pixel JPEG resize (bypasses NSImage's Retina 2× backing) so the image
    /// sent matches the declared dimensions. Frames already captured at the target
    /// size pass through without a re-encode.
    static func resizeJPEG(_ imageData: Data, toWidth width: Int, toHeight height: Int) -> Data? {
        if ImageConformance.isJPEG(imageData, width: width, height: height) { return imageData }
        guard let image = NSImage(data: imageData),
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
              ) else { return nil }
        rep.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current = context
        context?.imageInterpolation = .high
        image.draw(
            in: NSRect(x: 0, y: 0, width: width, height: height),
            from: NSRect(origin: .zero, size: image.size),
            operation: .copy, fraction: 1.0
        )
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }
}
