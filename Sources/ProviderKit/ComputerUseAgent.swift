import AppKit
import Foundation
import OSLog

/// One action Claude wants performed, with coordinates already scaled to
/// **display-local AppKit** points (bottom-left origin).
public enum CUAction: Sendable, Equatable {
    case move(x: Double, y: Double)
    case click(x: Double, y: Double)
    case doubleClick(x: Double, y: Double)
    case rightClick(x: Double, y: Double)
    case type(String)
    case key(String)
    case scroll(x: Double, y: Double, direction: String, amount: Int)
    case wait
    case screenshot
    /// Instant programmatic actions (no vision, no cursor): launch/switch to an app
    /// by name, or open a URL. These skip the observe→locate→click loop entirely.
    case openApp(String)
    case openURL(String)
}

public struct CUStep: Sendable {
    public let actions: [CUAction]
    public let text: String
    public let done: Bool
}

/// Drives Claude's Computer Use tool as a real agentic loop: send the goal + a
/// screenshot, Claude returns the next action, you execute it and call `proceed`
/// with the resulting screenshot, repeat until `done`. Maintains the message
/// history (with tool_use / tool_result image turns). Adapted from the Computer Use
/// pattern in `jasonkneen/openclicky`. See docs/THIRD_PARTY_NOTICES.md.
@MainActor
public final class ComputerUseAgent {
    private static let logger = Logger(subsystem: "com.humain.cascade", category: "computeruse")

    private let keyStore: AnthropicKeyStore
    private let model: String
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    private var messages: [[String: Any]] = []
    private var pendingToolIDs: [String] = []
    private var resW = 1280
    private var resH = 800
    private var displayW = 0
    private var displayH = 0

    private let effort: String
    /// Extra environment context appended to the system prompt (e.g. "you're in a web
    /// sandbox with no tabs or address bar").
    private let environmentNote: String?

    /// Keeps the model terse and decisive: no narration (fewer output tokens → faster
    /// turns and short text-to-speech), confident action chains batched into one turn
    /// (fewer round trips), brief confirmation only at the end.
    private static let systemPrompt = """
    You are Cascade, operating this Mac to carry out the user's request. Use the computer \
    tool to act. Open apps with the open_app tool and websites with the open_url tool — \
    both are instant; never hunt for an icon in the Dock, Spotlight, or Launchpad, and \
    never type an address by hand. When you are confident in a short sequence — like \
    clicking a field, typing into it, and pressing Return — chain those tool calls in \
    ONE turn instead of re-observing between them; take uncertain steps one at a time. \
    Be silent and extremely brief: do NOT narrate, explain, or describe what you see or \
    plan — just act. Only when the whole task is finished, reply with a confirmation of \
    five words or fewer.
    """

    /// Browser-tab guidance for the FOREGROUND (real-screen) agent — a real browser with
    /// a tab bar. Not used by the single-view web sandbox.
    public static let foregroundBrowserNote = """
    If the task involves a website, reach it with the open_url tool — it opens the page \
    in the user's default browser instantly. Call open_url ONCE per site, then keep \
    working in the tab that appeared. Never open extra tabs (no "+" button, no cmd+t) \
    and never type into the address bar — use open_url instead.
    """

    public init(
        keyStore: AnthropicKeyStore = AnthropicKeyStore(),
        model: String = AnthropicModel.sonnet,
        effort: String = "medium",
        environmentNote: String? = nil
    ) {
        self.keyStore = keyStore
        self.model = model
        self.effort = effort
        self.environmentNote = environmentNote
    }

    /// The resolution screenshots are sent to the model at, fixed by `begin`.
    /// Callers can capture follow-up frames at exactly this size as JPEG (e.g. via
    /// `ScreenCaptureUtility.captureCursorScreenJPEG`) so `proceed` skips resizing.
    public var captureSize: (width: Int, height: Int) { (resW, resH) }

    public func begin(goal: String, screenshot: Data, displayWidthPoints: Int, displayHeightPoints: Int) async -> CUStep {
        messages = []
        pendingToolIDs = []
        displayW = displayWidthPoints
        displayH = displayHeightPoints
        let res = bestResolution(displayWidthPoints, displayHeightPoints)
        resW = res.w
        resH = res.h
        guard let jpeg = resize(screenshot, resW, resH) else {
            return CUStep(actions: [], text: "I couldn't read the screen.", done: true)
        }
        messages.append([
            "role": "user",
            "content": [
                imageBlock(jpeg),
                ["type": "text", "text": "Task: \(goal)"],
            ],
        ])
        return await step()
    }

    public func proceed(screenshot: Data) async -> CUStep {
        guard !pendingToolIDs.isEmpty, let jpeg = resize(screenshot, resW, resH) else {
            return CUStep(actions: [], text: "", done: true)
        }
        var results: [[String: Any]] = []
        for (index, id) in pendingToolIDs.enumerated() {
            if index == pendingToolIDs.count - 1 {
                results.append(["type": "tool_result", "tool_use_id": id, "content": [imageBlock(jpeg)]])
            } else {
                results.append(["type": "tool_result", "tool_use_id": id, "content": "done"])
            }
        }
        messages.append(["role": "user", "content": results])
        pruneScreenshots()
        return await step()
    }

    private func step() async -> CUStep {
        guard let key = keyStore.readKey(), !key.isEmpty else {
            return CUStep(actions: [], text: "Connect your Claude key first.", done: true)
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 40
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("computer-use-2025-11-24", forHTTPHeaderField: "anthropic-beta")

        // Cache the static prefix (system + tool defs) and the most recent turn, so the
        // growing screenshot history is re-read from cache instead of reprocessed.
        // The instant tools come first; the breakpoint on the last (computer) tool
        // caches all three together.
        let tools: [[String: Any]] = [
            [
                "name": "open_app",
                "description": "Instantly launch or switch to a macOS app by its exact name (e.g. \"Safari\", \"Notes\"). Call this whenever an app needs to be opened or focused — it is far faster than finding the app on screen.",
                "input_schema": [
                    "type": "object",
                    "properties": ["name": ["type": "string", "description": "The app's exact name"]],
                    "required": ["name"],
                ],
            ],
            [
                "name": "open_url",
                "description": "Instantly open a web address. Call this whenever a website needs to be reached — it is far faster than typing an address or searching for the site.",
                "input_schema": [
                    "type": "object",
                    "properties": ["url": ["type": "string", "description": "Full https:// URL"]],
                    "required": ["url"],
                ],
            ],
            [
                "type": "computer_20251124", "name": "computer",
                "display_width_px": resW, "display_height_px": resH,
                "cache_control": ["type": "ephemeral"],
            ],
        ]
        let system = environmentNote.map { "\(Self.systemPrompt)\n\n\($0)" } ?? Self.systemPrompt
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 512,
            "system": system,
            "output_config": ["effort": effort],
            "tools": tools,
            "messages": Self.withMovingCacheBreakpoint(messages),
        ]
        // .sortedKeys keeps the rendered body byte-stable across turns — prompt
        // caching is a prefix match, and unordered keys would silently invalidate it.
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else {
            return CUStep(actions: [], text: "", done: true)
        }
        request.httpBody = bodyData

        guard let data = await Self.send(request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else {
            return CUStep(actions: [], text: "I couldn't reach Claude just now.", done: true)
        }
        Self.logUsage(json)

        messages.append(["role": "assistant", "content": content])
        let stopReason = json["stop_reason"] as? String

        var texts: [String] = []
        var actions: [CUAction] = []
        pendingToolIDs = []
        for block in content {
            switch block["type"] as? String {
            case "text":
                if let text = block["text"] as? String { texts.append(text) }
            case "tool_use":
                if let id = block["id"] as? String { pendingToolIDs.append(id) }
                let input = block["input"] as? [String: Any] ?? [:]
                switch block["name"] as? String {
                case "open_app":
                    if let app = input["name"] as? String { actions.append(.openApp(app)) }
                case "open_url":
                    if let url = input["url"] as? String { actions.append(.openURL(url)) }
                default:
                    if let action = parseAction(input) { actions.append(action) }
                }
            default:
                break
            }
        }
        return CUStep(actions: actions, text: texts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines), done: stopReason != "tool_use")
    }

    /// Posts the request, retrying once on transport errors, 429, and 5xx (honoring
    /// Retry-After, capped). A transient blip otherwise aborts the entire multi-step
    /// task — far costlier than a short pause.
    private static func send(_ request: URLRequest) async -> Data? {
        for attempt in 0..<2 {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { return nil }
                if (200..<300).contains(http.statusCode) { return data }
                guard attempt == 0, http.statusCode == 429 || http.statusCode >= 500 else {
                    logger.error("step failed — HTTP \(http.statusCode)")
                    return nil
                }
                let retryAfter = http.value(forHTTPHeaderField: "retry-after").flatMap(Double.init)
                logger.info("step got HTTP \(http.statusCode) — retrying once")
                try? await Task.sleep(for: .seconds(min(retryAfter ?? 1.0, 5)))
            } catch {
                guard attempt == 0 else { return nil }
                logger.info("step transport error — retrying once: \(error.localizedDescription, privacy: .public)")
                try? await Task.sleep(for: .seconds(1))
            }
        }
        return nil
    }

    /// Cache telemetry: if `cache read` stays 0 across turns, prompt caching is
    /// silently broken and every turn re-processes the full screenshot history.
    private static func logUsage(_ json: [String: Any]) {
        guard let usage = json["usage"] as? [String: Any] else { return }
        let input = (usage["input_tokens"] as? NSNumber)?.intValue ?? 0
        let cacheRead = (usage["cache_read_input_tokens"] as? NSNumber)?.intValue ?? 0
        let cacheWrite = (usage["cache_creation_input_tokens"] as? NSNumber)?.intValue ?? 0
        let output = (usage["output_tokens"] as? NSNumber)?.intValue ?? 0
        logger.info("step tokens — input: \(input), cache read: \(cacheRead), cache write: \(cacheWrite), output: \(output)")
    }

    private func parseAction(_ input: [String: Any]) -> CUAction? {
        guard let action = input["action"] as? String else { return nil }
        let coordinate: CGPoint? = (input["coordinate"] as? [NSNumber]).flatMap {
            $0.count == 2 ? scale(CGPoint(x: $0[0].doubleValue, y: $0[1].doubleValue)) : nil
        }
        switch action {
        case "left_click", "left_mouse_down": return coordinate.map { .click(x: $0.x, y: $0.y) }
        case "double_click": return coordinate.map { .doubleClick(x: $0.x, y: $0.y) }
        case "right_click": return coordinate.map { .rightClick(x: $0.x, y: $0.y) }
        case "mouse_move": return coordinate.map { .move(x: $0.x, y: $0.y) }
        case "type": return (input["text"] as? String).map { .type($0) }
        case "key": return (input["text"] as? String).map { .key($0) }
        case "scroll":
            let center = coordinate ?? CGPoint(x: Double(displayW) / 2, y: Double(displayH) / 2)
            return .scroll(
                x: center.x, y: center.y,
                direction: input["scroll_direction"] as? String ?? "down",
                amount: (input["scroll_amount"] as? NSNumber)?.intValue ?? 3
            )
        case "wait": return .wait
        case "screenshot", "cursor_position": return .screenshot
        default: return nil
        }
    }

    private func scale(_ point: CGPoint) -> CGPoint {
        let cx = max(0, min(point.x, CGFloat(resW)))
        let cy = max(0, min(point.y, CGFloat(resH)))
        let x = (cx / CGFloat(resW)) * CGFloat(displayW)
        let yFromTop = (cy / CGFloat(resH)) * CGFloat(displayH)
        return CGPoint(x: x, y: CGFloat(displayH) - yFromTop)
    }

    private func imageBlock(_ jpeg: Data) -> [String: Any] {
        ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString()]]
    }

    private func bestResolution(_ width: Int, _ height: Int) -> (w: Int, h: Int) {
        let aspect = Double(width) / Double(max(1, height))
        let options: [(w: Int, h: Int, ar: Double)] = [(1024, 768, 1.333), (1280, 800, 1.6), (1366, 768, 1.779)]
        var best = (w: 1280, h: 800)
        var bestDiff = Double.greatestFiniteMagnitude
        for option in options where abs(aspect - option.ar) < bestDiff {
            bestDiff = abs(aspect - option.ar)
            best = (option.w, option.h)
        }
        return best
    }

    private func resize(_ imageData: Data, _ width: Int, _ height: Int) -> Data? {
        // Frames captured at the agent resolution (see `captureSize`) pass through
        // untouched instead of paying a decode → redraw → re-encode round trip.
        if ImageConformance.isJPEG(imageData, width: width, height: height) { return imageData }
        guard let image = NSImage(data: imageData),
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            return nil
        }
        rep.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        let ctx = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current = ctx
        ctx?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height), from: NSRect(origin: .zero, size: image.size), operation: .copy, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
    }

    /// Adds an ephemeral cache breakpoint to the last block of the final turn so the
    /// prefix is re-read from cache next turn. Operates on a copy — stored `messages`
    /// stay clean (value semantics make this a cheap deep copy).
    private static func withMovingCacheBreakpoint(_ messages: [[String: Any]]) -> [[String: Any]] {
        var out = messages
        guard var last = out.last,
              var content = last["content"] as? [[String: Any]], !content.isEmpty else { return out }
        content[content.count - 1]["cache_control"] = ["type": "ephemeral"]
        last["content"] = content
        out[out.count - 1] = last
        return out
    }

    /// Rolling buffer (Anthropic's guidance): once screenshots exceed `threshold`,
    /// replace all but the most recent `keep` with short text placeholders, bounding
    /// the upload payload on long tasks while leaving short tasks untouched.
    private func pruneScreenshots(keep: Int = 3, threshold: Int = 8) {
        var imageTurns: [Int] = []
        for (index, message) in messages.enumerated() {
            guard let content = message["content"] as? [[String: Any]] else { continue }
            let hasImage = content.contains { block in
                if block["type"] as? String == "image" { return true }
                if block["type"] as? String == "tool_result", let inner = block["content"] as? [[String: Any]] {
                    return inner.contains { $0["type"] as? String == "image" }
                }
                return false
            }
            if hasImage { imageTurns.append(index) }
        }
        guard imageTurns.count > threshold else { return }
        for index in imageTurns.dropLast(keep) {
            guard var content = messages[index]["content"] as? [[String: Any]] else { continue }
            for block in content.indices {
                switch content[block]["type"] as? String {
                case "image":
                    content[block] = ["type": "text", "text": "[earlier screenshot omitted]"]
                case "tool_result":
                    content[block]["content"] = "[earlier screenshot omitted]"
                default:
                    break
                }
            }
            messages[index]["content"] = content
        }
    }
}
