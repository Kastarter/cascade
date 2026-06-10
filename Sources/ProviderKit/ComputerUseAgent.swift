import AppKit
import Foundation
import OSLog

/// One action Claude wants performed, with coordinates already scaled to
/// **display-local AppKit** points (bottom-left origin).
public enum CUAction: Sendable, Equatable {
    case move(x: Double, y: Double)
    case click(x: Double, y: Double)
    case doubleClick(x: Double, y: Double)
    case tripleClick(x: Double, y: Double)
    case rightClick(x: Double, y: Double)
    /// Press, drag, release — drawing on canvases, moving objects, selecting
    /// ranges. Both points are display-local AppKit (bottom-left origin).
    case drag(fromX: Double, fromY: Double, toX: Double, toY: Double)
    case type(String)
    case key(String)
    case scroll(x: Double, y: Double, direction: String, amount: Int)
    case wait
    case screenshot
    /// Instant programmatic actions (no vision, no cursor): launch/switch to an app
    /// by name, or open a URL. These skip the observe→locate→click loop entirely.
    case openApp(String)
    case openURL(String)
    /// Inspect a region at full native resolution (the model can't read small text
    /// at the loop resolution). Region is NORMALIZED [0,1] with top-left origin —
    /// the executor crops it from a fresh native-resolution capture.
    case zoom(nx: Double, ny: Double, nw: Double, nh: Double)
    /// Draw Cascade's marching-ants highlight + companion cursor over a region to
    /// SHOW the user something. Rect is display-local AppKit points (bottom-left
    /// origin), like the click coordinates.
    case highlight(x: Double, y: Double, width: Double, height: Double, label: String)
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
    /// Text answers for tool_use ids resolved in-process (use_skill pulls) —
    /// consumed by the next tool_result turn instead of the generic "done".
    private var toolResultOverrides: [String: String] = [:]
    private var resW = 1280
    private var resH = 800
    private var displayW = 0
    private var displayH = 0

    private let effort: String
    /// Extra environment context appended to the system prompt (e.g. "you're in a web
    /// sandbox with no tabs or address bar").
    private let environmentNote: String?
    /// Resolves a use_skill tool call to that skill's full instructions. When set,
    /// the use_skill tool is offered and the skill index (from `begin`) tells the
    /// model what it can pull. Pull-based: skill content never rides the prompt.
    private let skillProvider: ((String) -> String?)?

    /// Keeps the model terse and decisive: no narration (fewer output tokens → faster
    /// turns and short text-to-speech), confident action chains batched into one turn
    /// (fewer round trips), brief confirmation only at the end.
    private static let systemPrompt = """
    You are Cascade, operating this Mac to carry out the user's request. Use the computer \
    tool to act. Open apps with the open_app tool and websites with the open_url tool — \
    both are instant; never hunt for an icon in the Dock, Spotlight, or Launchpad, and \
    never type an address by hand. You CAN visually point things out: the highlight tool \
    draws a glowing box on the user's screen over any region — when the user asks you to \
    highlight, mark, point out, or show them something, USE it (this is YOUR capability; \
    it works in every app — never say an app doesn't support highlighting). If on-screen \
    text is too small to read confidently — message contents, sidebar items, small labels \
    — use the computer tool's zoom action on that region instead of guessing. Creative \
    and hands-on work is YOURS to do: when asked to design, draw, write, build, or edit \
    something in an app, carry it out yourself with clicks, drags (left_click_drag for \
    drawing shapes, moving objects, selecting ranges), typing, and shortcuts — NEVER \
    tell the user to do it themselves or merely describe the steps. When you are \
    confident in a short sequence — like clicking a field, typing into it, and \
    pressing Return — chain those tool calls in ONE turn instead of re-observing between \
    them; take uncertain steps one at a time. Be silent and extremely brief: do NOT \
    narrate, explain, or describe what you see or plan — just act. Only when the whole \
    task is finished, reply with a confirmation of five words or fewer. Earlier exchanges \
    from this session may precede the task; use them to resolve references like "it", \
    "that one", or "the first one" — they are context, not new work.
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
        environmentNote: String? = nil,
        skillProvider: ((String) -> String?)? = nil
    ) {
        self.keyStore = keyStore
        self.model = model
        self.effort = effort
        self.environmentNote = environmentNote
        self.skillProvider = skillProvider
    }

    /// The resolution screenshots are sent to the model at, fixed by `begin`.
    /// Callers can capture follow-up frames at exactly this size as JPEG (e.g. via
    /// `ScreenCaptureUtility.captureCursorScreenJPEG`) so `proceed` skips resizing.
    public var captureSize: (width: Int, height: Int) { (resW, resH) }

    /// `conversation` is the session's recent (user, assistant) exchanges, replayed
    /// as plain text turns ahead of the screenshot so the model resolves references
    /// like "the first one" or "reply to it" against what just happened. Old
    /// screenshots are never resent — only the words (the clicky/openclicky
    /// pattern; see docs/THIRD_PARTY_NOTICES.md).
    /// `note` is one line of text grounding (frontmost app + window) sent with the
    /// frame — ~15 tokens that remove a whole class of which-app-am-I-in mistakes.
    /// Instruction text goes BEFORE the image (per Anthropic's computer-use
    /// guidance, it measurably improves click accuracy).
    /// `skillIndex` is the one-line-per-skill catalogue for the use_skill tool —
    /// names + when-to-pull only; the content itself is fetched on demand.
    public func begin(
        goal: String, screenshot: Data, displayWidthPoints: Int, displayHeightPoints: Int,
        conversation: [(user: String, assistant: String)] = [], note: String? = nil,
        skillIndex: String? = nil
    ) async -> CUStep {
        messages = []
        pendingToolIDs = []
        toolResultOverrides = [:]
        displayW = displayWidthPoints
        displayH = displayHeightPoints
        let res = bestResolution(displayWidthPoints, displayHeightPoints)
        resW = res.w
        resH = res.h
        guard let jpeg = resize(screenshot, resW, resH) else {
            return CUStep(actions: [], text: "I couldn't read the screen.", done: true)
        }
        for turn in conversation {
            messages.append(["role": "user", "content": turn.user])
            messages.append(["role": "assistant", "content": turn.assistant])
        }
        var content: [[String: Any]] = [["type": "text", "text": "Task: \(goal)"]]
        if skillProvider != nil, let skillIndex { content.append(["type": "text", "text": skillIndex]) }
        if let note { content.append(["type": "text", "text": note]) }
        content.append(imageBlock(jpeg))
        messages.append(["role": "user", "content": content])
        return await step()
    }

    /// `zoomResult` marks the image as the model-requested zoom crop — it passes
    /// through at its own size instead of being stretched to the loop resolution.
    public func proceed(screenshot: Data, note: String? = nil, zoomResult: Bool = false) async -> CUStep {
        let jpeg = zoomResult ? screenshot : resize(screenshot, resW, resH)
        guard !pendingToolIDs.isEmpty, let jpeg else {
            return CUStep(actions: [], text: "", done: true)
        }
        var results: [[String: Any]] = []
        // The screenshot answers the last tool call that wasn't already resolved
        // in-process (use_skill); resolved ids get their text instead of "done".
        let imageID = pendingToolIDs.last { toolResultOverrides[$0] == nil } ?? pendingToolIDs.last
        for id in pendingToolIDs {
            if id == imageID {
                var content: [[String: Any]] = []
                if let text = toolResultOverrides[id] { content.append(["type": "text", "text": text]) }
                if let note { content.append(["type": "text", "text": note]) }
                content.append(imageBlock(jpeg))
                results.append(["type": "tool_result", "tool_use_id": id, "content": content])
            } else if let text = toolResultOverrides[id] {
                results.append(["type": "tool_result", "tool_use_id": id, "content": text])
            } else {
                results.append(["type": "tool_result", "tool_use_id": id, "content": "done"])
            }
        }
        toolResultOverrides = [:]
        messages.append(["role": "user", "content": results])
        pruneScreenshots()
        return await step()
    }

    private func step(retryOnTruncation: Bool = true, inlineHops: Int = 0) async -> CUStep {
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
        // caches all of them together.
        var tools: [[String: Any]] = [
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
                "name": "highlight",
                "description": "Draw a glowing highlight box on the user's screen over one region, to visually SHOW them something they asked about. Works over any app — this is YOUR overlay, not an app feature. Call it whenever the user asks to highlight, mark, point out, or show where something is. Coordinates are in screenshot pixels. Call again for a different region; the latest box stays visible.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "region": [
                            "type": "array", "items": ["type": "number"],
                            "description": "[x1, y1, x2, y2] — top-left and bottom-right corners of the region, in screenshot pixels",
                        ],
                        "label": ["type": "string", "description": "2-4 word label for what's highlighted"],
                    ],
                    "required": ["region"],
                ],
            ],
            [
                "type": "computer_20251124", "name": "computer",
                "display_width_px": resW, "display_height_px": resH,
                "enable_zoom": true,
                "cache_control": ["type": "ephemeral"],
            ],
        ]
        if skillProvider != nil {
            tools.insert([
                "name": "use_skill",
                "description": "Fetch the full instructions of one skill from the skill list in the first message. Skills are proven playbooks for specific apps and tasks. Whenever a listed skill matches what you are about to do, call this FIRST and follow the returned instructions — it is instant.",
                "input_schema": [
                    "type": "object",
                    "properties": ["name": ["type": "string", "description": "The skill's exact name from the list"]],
                    "required": ["name"],
                ],
            ], at: 2)
        }
        let system = environmentNote.map { "\(Self.systemPrompt)\n\n\($0)" } ?? Self.systemPrompt
        // Adaptive thinking is Anthropic's benchmarked setup for computer use on
        // Sonnet 4.6: the model plans before acting, and fewer wrong clicks means
        // fewer retries — it uses fewer total tokens than no-thinking. max_tokens
        // leaves room for thinking ahead of the tool calls.
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 2048,
            "system": system,
            "thinking": ["type": "adaptive"],
            "output_config": ["effort": effort],
            "tools": tools,
            "messages": Self.withMovingCacheBreakpoints(messages),
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
                case "use_skill":
                    // Resolved right here — no screen action needed. The text is
                    // delivered as this id's tool_result (inline below, or via
                    // proceed when batched with screen actions).
                    let requested = input["name"] as? String ?? ""
                    if let id = block["id"] as? String {
                        if let text = skillProvider?(requested) {
                            Self.logger.info("use_skill pulled: \(requested, privacy: .public)")
                            toolResultOverrides[id] = text
                        } else {
                            toolResultOverrides[id] = "No skill named “\(requested)”. Use one of the exact names from the skill list in the first message."
                        }
                    }
                case "highlight":
                    if let action = parseHighlight(input) { actions.append(action) }
                default:
                    if let action = parseAction(input) { actions.append(action) }
                }
            default:
                break
            }
        }
        // A turn that ONLY pulled skills needs no screen work — answer the tool
        // calls with the skill text right away and let the model continue, without
        // bouncing through the caller's screenshot loop. Hop-capped so a model
        // stuck pulling skills forever falls back to the normal loop.
        if !pendingToolIDs.isEmpty, actions.isEmpty,
           pendingToolIDs.allSatisfy({ toolResultOverrides[$0] != nil }),
           inlineHops < 3 {
            var results: [[String: Any]] = []
            for id in pendingToolIDs {
                results.append([
                    "type": "tool_result", "tool_use_id": id,
                    "content": toolResultOverrides.removeValue(forKey: id) ?? "done",
                ])
            }
            messages.append(["role": "user", "content": results])
            pendingToolIDs = []
            return await step(retryOnTruncation: retryOnTruncation, inlineHops: inlineHops + 1)
        }
        // A max_tokens truncation is NOT completion — with thinking enabled the
        // budget can run out before any tool call. If nothing actionable came back,
        // nudge once; otherwise let the loop execute what did come through and the
        // next tool_result turn continues the task.
        if stopReason == "max_tokens", pendingToolIDs.isEmpty, retryOnTruncation {
            messages.append([
                "role": "user",
                "content": "Your reply was cut off before any tool call. Continue the task now — act with tool calls.",
            ])
            return await step(retryOnTruncation: false, inlineHops: inlineHops)
        }
        let done = !(stopReason == "tool_use" || (stopReason == "max_tokens" && !pendingToolIDs.isEmpty))
        return CUStep(actions: actions, text: texts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines), done: done)
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
        case "triple_click": return coordinate.map { .tripleClick(x: $0.x, y: $0.y) }
        case "middle_click": return coordinate.map { .click(x: $0.x, y: $0.y) }
        case "right_click": return coordinate.map { .rightClick(x: $0.x, y: $0.y) }
        case "mouse_move": return coordinate.map { .move(x: $0.x, y: $0.y) }
        case "left_click_drag":
            guard let start = (input["start_coordinate"] as? [NSNumber]).flatMap({
                $0.count == 2 ? scale(CGPoint(x: $0[0].doubleValue, y: $0[1].doubleValue)) : nil
            }), let end = coordinate else { return nil }
            return .drag(fromX: start.x, fromY: start.y, toX: end.x, toY: end.y)
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
        case "zoom":
            guard let region = input["region"] as? [NSNumber], region.count == 4 else { return .screenshot }
            let x1 = max(0, min(region[0].doubleValue, Double(resW)))
            let y1 = max(0, min(region[1].doubleValue, Double(resH)))
            let x2 = max(x1 + 1, min(region[2].doubleValue, Double(resW)))
            let y2 = max(y1 + 1, min(region[3].doubleValue, Double(resH)))
            return .zoom(
                nx: x1 / Double(resW), ny: y1 / Double(resH),
                nw: (x2 - x1) / Double(resW), nh: (y2 - y1) / Double(resH)
            )
        default: return nil
        }
    }

    /// Highlight tool input → display-local AppKit rect (bottom-left origin).
    private func parseHighlight(_ input: [String: Any]) -> CUAction? {
        guard let region = input["region"] as? [NSNumber], region.count == 4 else { return nil }
        let x1 = max(0, min(region[0].doubleValue, Double(resW)))
        let y1 = max(0, min(region[1].doubleValue, Double(resH)))
        let x2 = max(x1 + 1, min(region[2].doubleValue, Double(resW)))
        let y2 = max(y1 + 1, min(region[3].doubleValue, Double(resH)))
        let sx = Double(displayW) / Double(resW)
        let sy = Double(displayH) / Double(resH)
        let width = (x2 - x1) * sx
        let height = (y2 - y1) * sy
        // Top-left model pixels → bottom-left AppKit: the rect's bottom edge.
        let x = x1 * sx
        let y = Double(displayH) - (y2 * sy)
        let label = (input["label"] as? String ?? "here").trimmingCharacters(in: .whitespacesAndNewlines)
        return .highlight(x: x, y: y, width: width, height: height, label: label.isEmpty ? "here" : label)
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
        AgentResolution.best(forWidth: width, height: height)
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

    /// Adds ephemeral cache breakpoints to the last block of up to the 3 most
    /// recent USER turns (tool results), per Anthropic's computer-use caching
    /// guidance — multiple advancing breakpoints survive big batched-action turns
    /// that a single breakpoint's 20-block lookback could miss. Plus the tools
    /// breakpoint, that's the 4-breakpoint maximum. Operates on a copy — stored
    /// `messages` stay clean (value semantics make this a cheap deep copy).
    private static func withMovingCacheBreakpoints(_ messages: [[String: Any]]) -> [[String: Any]] {
        var out = messages
        var marked = 0
        for index in stride(from: out.count - 1, through: 0, by: -1) {
            guard marked < 3 else { break }
            guard out[index]["role"] as? String == "user",
                  var content = out[index]["content"] as? [[String: Any]], !content.isEmpty else { continue }
            content[content.count - 1]["cache_control"] = ["type": "ephemeral"]
            out[index]["content"] = content
            marked += 1
        }
        return out
    }

    /// Rolling buffer (Anthropic's guidance): once screenshots exceed `threshold`,
    /// replace all but the most recent `keep` with short text placeholders, bounding
    /// the upload payload on long tasks while leaving short tasks untouched. The
    /// 12→3 batch sizing means a prune (and its one-off cache rewrite) happens at
    /// most every ~9 turns, keeping the prefix byte-identical in between.
    private func pruneScreenshots(keep: Int = 3, threshold: Int = 12) {
        messages = Self.pruned(messages, keep: keep, threshold: threshold)
    }

    nonisolated static func pruned(_ messages: [[String: Any]], keep: Int = 3, threshold: Int = 12) -> [[String: Any]] {
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
        guard imageTurns.count > threshold else { return messages }
        var out = messages
        for index in imageTurns.dropLast(keep) {
            guard var content = out[index]["content"] as? [[String: Any]] else { continue }
            for block in content.indices {
                switch content[block]["type"] as? String {
                case "image":
                    content[block] = ["type": "text", "text": "[earlier screenshot omitted]"]
                case "tool_result":
                    // Replace only the inner image; keep text blocks (grounding
                    // notes, injected app-skill instructions) in history.
                    if var inner = content[block]["content"] as? [[String: Any]] {
                        for innerIndex in inner.indices where inner[innerIndex]["type"] as? String == "image" {
                            inner[innerIndex] = ["type": "text", "text": "[earlier screenshot omitted]"]
                        }
                        content[block]["content"] = inner
                    } else {
                        content[block]["content"] = "[earlier screenshot omitted]"
                    }
                default:
                    break
                }
            }
            out[index]["content"] = content
        }
        return out
    }
}
