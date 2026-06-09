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
        screenshotPNG: Data,
        question: String,
        displayWidthPoints: Int,
        displayHeightPoints: Int
    ) async -> ElementGuidance {
        guard let key = keyStore.readKey(), !key.isEmpty else {
            return ElementGuidance(point: nil, speech: "Connect your Claude key first.")
        }
        let res = bestResolution(forWidth: displayWidthPoints, height: displayHeightPoints)
        guard let jpeg = resize(png: screenshotPNG, toWidth: res.w, toHeight: res.h) else {
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
    private func resize(png: Data, toWidth width: Int, toHeight height: Int) -> Data? {
        guard let image = NSImage(data: png),
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
