import AppKit
import Foundation

// Element location via Claude's Computer Use tool. Adapted from
// `jasonkneen/openclicky` (`ElementLocationDetector.swift`, MIT): the
// aspect-ratio-matched resize, the `computer_20251124` tool declaration, and the
// pixel-coordinate parse. Re-implemented as a Cascade-owned, BYOK locator.
// See docs/THIRD_PARTY_NOTICES.md.
//
// The Computer Use tool activates Claude's specialized pixel-counting training,
// which is far more accurate at coordinates than plain vision. We resize the
// screenshot to the Anthropic-recommended resolution closest to the display's
// aspect ratio (avoids distortion that wrecks X-axis accuracy).
public struct ElementGuidance: Sendable {
    /// Display-local AppKit point (bottom-left origin); nil when no element matched.
    public let point: CGPoint?
    /// One short sentence to speak to the user.
    public let speech: String

    public init(point: CGPoint?, speech: String) {
        self.point = point
        self.speech = speech
    }
}

/// A region to frame on screen (for "where do I find/do X" answers).
public struct ElementRegion: Sendable {
    /// Display-local AppKit rect (bottom-left origin); nil when nothing matched.
    public let rect: CGRect?
    public let speech: String

    public init(rect: CGRect?, speech: String) {
        self.rect = rect
        self.speech = speech
    }
}

public struct ElementLocator: Sendable {
    private let keyStore: AnthropicKeyStore
    private let model: String
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    public init(keyStore: AnthropicKeyStore = AnthropicKeyStore(), model: String = AnthropicModel.sonnet) {
        self.keyStore = keyStore
        self.model = model
    }

    private static let resolutions: [(w: Int, h: Int, ar: Double)] = [
        (1024, 768, 1024.0 / 768.0),   // 4:3
        (1280, 800, 1280.0 / 800.0),   // 16:10 (most Macs)
        (1366, 768, 1366.0 / 768.0),   // ~16:9
    ]

    /// Locates the element the user asked about. Returns its position in
    /// **display-local AppKit coordinates** (bottom-left origin), or nil when no
    /// confident element was found (or no key / API error).
    /// Locates the element the user asked about **and** a one-sentence spoken
    /// instruction, in a single Computer Use call. `point` is display-local AppKit
    /// coords (bottom-left), nil when no confident element was found.
    public func guide(
        screenshot: Data,
        question: String,
        displayWidthPoints: Int,
        displayHeightPoints: Int
    ) async -> ElementGuidance {
        guard let key = keyStore.readKey(), !key.isEmpty else {
            return ElementGuidance(point: nil, speech: "Connect your Claude key first.")
        }
        let res = bestResolution(forWidth: displayWidthPoints, height: displayHeightPoints)
        guard let jpeg = resize(image: screenshot, toWidth: res.w, toHeight: res.h) else {
            return ElementGuidance(point: nil, speech: "I couldn't read the screen image.")
        }
        guard let result = await callComputerUse(jpeg: jpeg, question: question, declaredW: res.w, declaredH: res.h, key: key) else {
            return ElementGuidance(point: nil, speech: "I couldn't reach Claude just now.")
        }

        let fallback = result.point != nil ? "Here — this is what you're looking for." : "I couldn't find that on the current screen."
        let speech = result.text.isEmpty ? fallback : result.text

        guard let raw = result.point else {
            return ElementGuidance(point: nil, speech: speech)
        }
        let clampedX = max(0, min(raw.x, CGFloat(res.w)))
        let clampedY = max(0, min(raw.y, CGFloat(res.h)))
        let scaledX = (clampedX / CGFloat(res.w)) * CGFloat(displayWidthPoints)
        let scaledYFromTop = (clampedY / CGFloat(res.h)) * CGFloat(displayHeightPoints)
        // Computer Use uses top-left origin; convert to AppKit bottom-left.
        let scaledYFromBottom = CGFloat(displayHeightPoints) - scaledYFromTop
        return ElementGuidance(point: CGPoint(x: scaledX, y: scaledYFromBottom), speech: speech)
    }

    /// Finds the bounding box of the on-screen region where the user would do/find what
    /// they asked, to frame with the dashed marquee. Returns a display-local AppKit rect
    /// (bottom-left origin) + one short spoken sentence.
    public func locateRegion(
        screenshot: Data,
        question: String,
        displayWidthPoints: Int,
        displayHeightPoints: Int
    ) async -> ElementRegion {
        guard let key = keyStore.readKey(), !key.isEmpty else {
            return ElementRegion(rect: nil, speech: "Connect your Claude key first.")
        }
        let res = bestResolution(forWidth: displayWidthPoints, height: displayHeightPoints)
        guard let jpeg = resize(image: screenshot, toWidth: res.w, toHeight: res.h) else {
            return ElementRegion(rect: nil, speech: "I couldn't read the screen image.")
        }
        guard let result = await callRegion(jpeg: jpeg, question: question, declaredW: res.w, declaredH: res.h, key: key) else {
            return ElementRegion(rect: nil, speech: "I couldn't reach Claude just now.")
        }
        let speech = result.say.isEmpty
            ? (result.box != nil ? "Here — it's in this area." : "I couldn't find that on the current screen.")
            : result.say
        guard let raw = result.box else { return ElementRegion(rect: nil, speech: speech) }

        // box = [x, y, w, h] top-left, in resized pixels → display-local AppKit bottom-left.
        let box = Self.normalize(box: raw, width: CGFloat(res.w), height: CGFloat(res.h))
        let sx = CGFloat(displayWidthPoints) / CGFloat(res.w)
        let sy = CGFloat(displayHeightPoints) / CGFloat(res.h)
        let x = box[0] * sx
        let w = max(8, box[2] * sx)
        let yTop = box[1] * sy
        let h = max(8, box[3] * sy)
        let yBottom = CGFloat(displayHeightPoints) - (yTop + h)
        let rect = CGRect(x: x, y: yBottom, width: w, height: h)
        return ElementRegion(rect: rect, speech: speech)
    }

    /// The model sometimes answers with corners ([x1, y1, x2, y2]) instead of the
    /// requested [x, y, w, h], which doubles the marquee's size, and sometimes lets
    /// the box spill past the screenshot's edge. Detect the corner format (the
    /// "width/height" would run off the image while reading them as corners
    /// wouldn't) and clamp the result into bounds, so the frame on screen always
    /// matches a region that actually exists.
    static func normalize(box: [CGFloat], width: CGFloat, height: CGFloat) -> [CGFloat] {
        var x = box[0], y = box[1], w = box[2], h = box[3]
        let overflowsAsSize = x + w > width * 1.02 || y + h > height * 1.02
        let validAsCorners = w > x && h > y && w <= width * 1.02 && h <= height * 1.02
        if overflowsAsSize && validAsCorners {
            w -= x
            h -= y
        }
        x = min(max(0, x), width - 1)
        y = min(max(0, y), height - 1)
        w = min(max(1, w), width - x)
        h = min(max(1, h), height - y)
        return [x, y, w, h]
    }

    private func callRegion(jpeg: Data, question: String, declaredW: Int, declaredH: Int, key: String) async -> (box: [CGFloat]?, say: String)? {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let prompt = """
        A screenshot of the user's screen is attached; it is \(declaredW) by \(declaredH) pixels. \
        The user asked: "\(question)"

        Find the single on-screen region where they would do or find that — the area to \
        frame for them (a button, menu, panel, list, sidebar, field, or section). Reply with \
        ONLY compact JSON, no other text:
        {"box": [x, y, w, h], "say": "<one short friendly sentence telling them where/how>"}
        where x,y is the TOP-LEFT corner and w,h are the WIDTH and HEIGHT of the region \
        (not the bottom-right corner), in the screenshot's pixels. The box must fit inside \
        the \(declaredW)×\(declaredH) image and hug the region tightly — no bigger than the \
        element itself. If it is not visible on screen, use {"box": null, "say": "..."}.
        """

        let body: [String: Any] = [
            // Region detection is a simple bounding-box vision task — Haiku is ~2× faster
            // and plenty accurate for framing, so the find loop isn't bottlenecked on it.
            "model": AnthropicModel.haiku,
            "max_tokens": 400,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString()]],
                    ["type": "text", "text": prompt],
                ],
            ]],
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = bodyData
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let text = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String else {
            return nil
        }
        return parseRegion(text)
    }

    private func parseRegion(_ text: String) -> (box: [CGFloat]?, say: String) {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
              let data = String(text[start...end]).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let say = (json["say"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let nums = json["box"] as? [NSNumber], nums.count == 4 {
            return (nums.map { CGFloat(truncating: $0) }, say)
        }
        return (nil, say)
    }

    private func bestResolution(forWidth width: Int, height: Int) -> (w: Int, h: Int) {
        let aspect = Double(width) / Double(max(1, height))
        var best = (w: 1280, h: 800)
        var bestDiff = Double.greatestFiniteMagnitude
        for r in Self.resolutions {
            let diff = abs(aspect - r.ar)
            if diff < bestDiff { bestDiff = diff; best = (r.w, r.h) }
        }
        return best
    }

    private func callComputerUse(jpeg: Data, question: String, declaredW: Int, declaredH: Int, key: String) async -> (point: CGPoint?, text: String)? {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("computer-use-2025-11-24", forHTTPHeaderField: "anthropic-beta")

        let prompt = """
        A screenshot of the user's current screen is attached. The user said: "\(question)"

        Click the single UI element they want — the exact button, link, menu item, \
        field, or icon — using ONE left_click action at its center. The screenshot is \
        already provided, so do NOT take a screenshot. If nothing matches well, \
        left_click the closest relevant element.
        """

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "tools": [[
                "type": "computer_20251124",
                "name": "computer",
                "display_width_px": declaredW,
                "display_height_px": declaredH,
            ]],
            "tool_choice": ["type": "tool", "name": "computer"],
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString()]],
                    ["type": "text", "text": prompt],
                ],
            ]],
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = bodyData

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            return nil
        }
        return parse(data)
    }

    /// Claude's response: a `text` block (the spoken instruction) and/or a
    /// `tool_use` block with `{"coordinate": [x, y]}`. Returns both.
    private func parse(_ data: Data) -> (point: CGPoint?, text: String)? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else { return nil }
        var coordinate: CGPoint?
        var texts: [String] = []
        for block in content {
            let type = block["type"] as? String
            if type == "text", let text = block["text"] as? String {
                texts.append(text)
            } else if type == "tool_use",
                      let input = block["input"] as? [String: Any],
                      let coord = input["coordinate"] as? [NSNumber],
                      coord.count == 2 {
                coordinate = CGPoint(x: coord[0].doubleValue, y: coord[1].doubleValue)
            }
        }
        return (coordinate, texts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Resizes to an exact pixel size (bypassing NSImage's Retina 2× backing) so the
    /// JPEG sent matches the resolution declared to the Computer Use tool.
    private func resize(image imageData: Data, toWidth width: Int, toHeight height: Int) -> Data? {
        // Frames already captured as JPEG at the target size (the agent loops capture
        // at the declared resolution) pass through without a re-encode.
        if ImageConformance.isJPEG(imageData, width: width, height: height) { return imageData }
        guard let image = NSImage(data: imageData),
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: width,
                pixelsHigh: height,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
              ) else {
            return nil
        }
        rep.size = NSSize(width: width, height: height)

        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current = context
        context?.imageInterpolation = .high
        image.draw(
            in: NSRect(x: 0, y: 0, width: width, height: height),
            from: NSRect(origin: .zero, size: image.size),
            operation: .copy,
            fraction: 1.0
        )
        NSGraphicsContext.restoreGraphicsState()

        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }
}
