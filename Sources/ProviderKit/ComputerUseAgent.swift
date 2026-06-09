import AppKit
import Foundation

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
    private let keyStore: AnthropicKeyStore
    private let model: String
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    private var messages: [[String: Any]] = []
    private var pendingToolIDs: [String] = []
    private var resW = 1280
    private var resH = 800
    private var displayW = 0
    private var displayH = 0

    public init(keyStore: AnthropicKeyStore = AnthropicKeyStore(), model: String = AnthropicModel.sonnet) {
        self.keyStore = keyStore
        self.model = model
    }

    public func begin(goal: String, screenshotPNG: Data, displayWidthPoints: Int, displayHeightPoints: Int) async -> CUStep {
        messages = []
        pendingToolIDs = []
        displayW = displayWidthPoints
        displayH = displayHeightPoints
        let res = bestResolution(displayWidthPoints, displayHeightPoints)
        resW = res.w
        resH = res.h
        guard let jpeg = resize(screenshotPNG, resW, resH) else {
            return CUStep(actions: [], text: "I couldn't read the screen.", done: true)
        }
        messages.append([
            "role": "user",
            "content": [
                imageBlock(jpeg),
                ["type": "text", "text": """
                Task: \(goal)

                Carry this out on the current screen using the computer tool, one action \
                at a time. After each action you'll get a new screenshot. When the task is \
                fully complete, stop using the tool and briefly say it's done.
                """],
            ],
        ])
        return await step()
    }

    public func proceed(screenshotPNG: Data) async -> CUStep {
        guard !pendingToolIDs.isEmpty, let jpeg = resize(screenshotPNG, resW, resH) else {
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

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "tools": [["type": "computer_20251124", "name": "computer", "display_width_px": resW, "display_height_px": resH]],
            "messages": messages,
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            return CUStep(actions: [], text: "", done: true)
        }
        request.httpBody = bodyData

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else {
            return CUStep(actions: [], text: "I couldn't reach Claude just now.", done: true)
        }

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
                if let input = block["input"] as? [String: Any], let action = parseAction(input) {
                    actions.append(action)
                }
            default:
                break
            }
        }
        return CUStep(actions: actions, text: texts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines), done: stopReason != "tool_use")
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

    private func resize(_ png: Data, _ width: Int, _ height: Int) -> Data? {
        guard let image = NSImage(data: png),
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
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }
}
