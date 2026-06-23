import Foundation

/// The downgraded on-screen brain (Tier 2 of the model-downgrade roadmap): a
/// vision PLANNER (Llama 4 Scout via Groq) paired with a GROUNDER (UI-TARS). This
/// is the Agent-S architecture — Scout looks at the screen and decides the next
/// action, NAMING its target in words; the grounder turns that name into a click
/// coordinate. Output is the same `CUAction`/`CUStep` the Claude agent emits, so
/// the executor (`executeCU`) and the episode gates are reused unchanged.
///
/// Why this shape: a general multimodal model like Scout plans well but grounds
/// poorly (weak at exact pixel coordinates), so coordinates are delegated to the
/// dedicated grounder. The model never emits pixels. See
/// [[cascade-cu-downgrade-research]].
///
/// RUNTIME-UNVERIFIED end to end (no Scout/UI-TARS/live screen in CI). The action
/// parser is pure + pinned; the live loop needs a dry run once both models serve.
public final class ScoutAgent {
    /// One parsed instruction from Scout. The model picks exactly one next action
    /// and names the target; the runtime grounds + executes it.
    public struct ScoutAction: Equatable, Sendable {
        public enum Kind: String, Sendable {
            case click, doubleClick, type, key, scroll, openApp, openURL, wait, done
        }
        public let kind: Kind
        public let target: String?   // a named UI element (grounded to a point)
        public let text: String?     // text to type
        public let key: String?      // e.g. "cmd+s", "return"
        public let direction: String? // scroll: "up"/"down"
        public let amount: Int?      // scroll clicks
        public let thought: String   // short narration / done reason
    }

    private let vision: GroqVisionClient
    private let grounder: VisualGrounder
    private let model: String
    private var displayW = 0
    private var displayH = 0
    private var history: [(user: String, assistant: String)] = []
    private var goal = ""

    public init(
        vision: GroqVisionClient = GroqVisionClient(),
        grounder: VisualGrounder,
        model: String = GroqModel.llama4Scout
    ) {
        self.vision = vision
        self.grounder = grounder
        self.model = model
    }

    /// Resolution screenshots are captured + sent at — same contract as
    /// `ComputerUseAgent.captureSize`, so the episode runner captures once.
    public var captureSize: (width: Int, height: Int) {
        let res = AgentResolution.best(forWidth: max(1, displayW), height: max(1, displayH))
        return (res.w, res.h)
    }

    public func begin(goal: String, screenshot: Data, displayWidthPoints: Int, displayHeightPoints: Int) async -> CUStep {
        self.goal = goal
        displayW = displayWidthPoints
        displayH = displayHeightPoints
        history = []
        return await step(screenshot: screenshot)
    }

    public func proceed(screenshot: Data) async -> CUStep {
        await step(screenshot: screenshot)
    }

    private func step(screenshot: Data) async -> CUStep {
        let user = "Goal: \(goal)\n\nDecide the single next action and reply with the JSON object only."
        let reply: String
        do {
            reply = try await vision.complete(
                system: Self.systemPrompt, user: user, imageJPEG: screenshot,
                model: model, maxTokens: 600, prior: history
            )
        } catch {
            return CUStep(actions: [], text: "I couldn't reach the planner.", done: true, failed: true)
        }
        guard let action = Self.parseScoutAction(reply) else {
            // Unparseable → an empty, non-done turn; the runner's stall guard
            // ends the episode if this repeats.
            return CUStep(actions: [], text: reply.isEmpty ? "" : String(reply.prefix(120)), done: false)
        }
        history.append((user: user, assistant: Self.historyLine(action)))
        if action.kind == .done {
            return CUStep(actions: [], text: action.thought.isEmpty ? "Done." : action.thought, done: true)
        }
        let actions = await actions(for: action, screenshot: screenshot)
        return CUStep(actions: actions, text: action.thought, done: false)
    }

    /// Maps a parsed action to executable `CUAction`s, grounding named targets via
    /// the grounder. An empty result (grounding miss) makes the turn idle — the
    /// runner re-observes and the model tries again.
    private func actions(for a: ScoutAction, screenshot: Data) async -> [CUAction] {
        switch a.kind {
        case .openApp: return a.target.map { [.openApp($0)] } ?? []
        case .openURL: return a.target.map { [.openURL($0)] } ?? []
        case .key: return a.key.map { [.key($0)] } ?? []
        case .wait: return [.wait]
        case .done: return []
        case .scroll:
            let point = await groundedPoint(a.target, screenshot: screenshot)
                ?? CGPoint(x: CGFloat(displayW) / 2, y: CGFloat(displayH) / 2)
            return [.scroll(x: point.x, y: point.y, direction: a.direction ?? "down", amount: a.amount ?? 3)]
        case .click, .doubleClick:
            guard let point = await groundedPoint(a.target, screenshot: screenshot) else { return [] }
            return [a.kind == .doubleClick ? .doubleClick(x: point.x, y: point.y) : .click(x: point.x, y: point.y)]
        case .type:
            guard let text = a.text else { return [] }
            // Target named → click into it and replace (the fill batch); no target
            // → type into whatever's focused.
            guard let target = a.target, !target.isEmpty else { return [.type(text)] }
            guard let point = await groundedPoint(target, screenshot: screenshot) else { return [] }
            return ComputerUseAgent.fillActions(at: point, text: text, double: false, submit: "return")
        }
    }

    private func groundedPoint(_ target: String?, screenshot: Data) async -> CGPoint? {
        guard let target, !target.isEmpty else { return nil }
        return await grounder.ground(
            screenshot: screenshot, target: target,
            displayWidthPoints: displayW, displayHeightPoints: displayH
        )
    }

    private static func historyLine(_ a: ScoutAction) -> String {
        var parts = [a.kind.rawValue]
        if let t = a.target { parts.append("→ \(t)") }
        if let text = a.text { parts.append("\"\(text.prefix(40))\"") }
        if let k = a.key { parts.append(k) }
        return parts.joined(separator: " ")
    }

    /// Parses Scout's JSON action out of a reply (tolerating prose / ``` fences).
    /// Pure + pinned — the brain's contract with the runtime. Returns nil when no
    /// usable action object is present.
    public static func parseScoutAction(_ text: String) -> ScoutAction? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
              start < end,
              let data = String(text[start...end]).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawAction = (json["action"] as? String)?.lowercased() else { return nil }
        guard let kind = mapKind(rawAction) else { return nil }
        return ScoutAction(
            kind: kind,
            target: nonEmpty(json["target"] as? String),
            text: json["text"] as? String,
            key: nonEmpty(json["key"] as? String),
            direction: nonEmpty(json["direction"] as? String),
            amount: (json["amount"] as? NSNumber)?.intValue,
            thought: (json["thought"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static func mapKind(_ raw: String) -> ScoutAction.Kind? {
        switch raw {
        case "click", "left_click": return .click
        case "double_click", "doubleclick": return .doubleClick
        case "type", "fill": return .type
        case "key", "keypress", "hotkey": return .key
        case "scroll": return .scroll
        case "open_app", "openapp", "launch": return .openApp
        case "open_url", "openurl", "goto": return .openURL
        case "wait": return .wait
        case "done", "finish", "complete": return .done
        default: return nil
        }
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    static let systemPrompt = """
    You are an on-screen computer-use agent. You see the user's screen and drive it \
    to accomplish their goal, ONE action at a time.

    Reply with ONLY a single JSON object — no prose, no code fences — of this shape:
    {"thought": "<one short clause on what you're doing>", "action": "<one action>", \
    "target": "<the on-screen element, named in plain words>", "text": "<text to type>", \
    "key": "<key combo>", "direction": "<up|down>", "amount": <int>}

    Actions:
    - "click" / "double_click": press an element. Put what to click in "target", \
      described by its visible label, role, or nearby text (e.g. "the Save button", \
      "the search field", "the subtitle placeholder"). DO NOT output coordinates — \
      naming the target is enough; the system locates it for you.
    - "type": enter text. "text" is what to type; "target" (optional) is the field \
      to type into — given a target, it is clicked and its contents replaced.
    - "key": press a key or combo in "key" (e.g. "return", "cmd+s", "tab", "escape").
    - "scroll": "direction" up/down, optional "target" to scroll over, "amount" clicks.
    - "open_app": launch/focus an app named in "target". "open_url": open "target" URL.
    - "wait": let the screen settle. "done": the goal is complete; say why in "thought".

    Rules: pick the most direct next action. Prefer open_app/open_url over hunting on \
    screen. Name targets precisely — the locator matches your words against the screen. \
    Only "done" when the goal is genuinely accomplished, judged by what's on screen.
    """
}
