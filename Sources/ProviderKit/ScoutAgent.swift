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
///
/// `@MainActor` (like ComputerUseAgent) because it now calls the @MainActor harness
/// provider with non-Sendable input; the pure static parsers are `nonisolated` so
/// tests + the parse contract stay callable off the actor.
@MainActor
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
    /// Paste-gate state (mirrors ComputerUseAgent): a bare cmd+v pastes the USER's
    /// clipboard, so it's allowed only when Scout itself copied this episode, or the
    /// goal is explicitly about the clipboard.
    private var episodeCopied = false
    private var goalAsksForPaste = false
    /// In-process tools (resolved without a screen action, like the Opus inline
    /// hop): use_skill PULLS a skill by name; the harness/recall providers run
    /// file/shell/record-history tools. nil = that capability off.
    private let skillProvider: ((String) -> String?)?
    private let harnessProvider: (@MainActor (String, [String: Any]) async -> String)?
    private let harnessTier: HarnessTier
    private let recallEnabled: Bool
    /// One-line-per-skill catalogue for use_skill (so Scout knows what it CAN pull).
    private let skillIndex: String?
    /// System prompt for the episode — base prompt + tool catalogue + any pushed
    /// app skill. Rebuilt by `applySkill`; `pushedSkill` survives a transient nil.
    private var episodeSystem = ScoutAgent.systemPrompt
    private var pushedSkill: String?

    public init(
        vision: GroqVisionClient = GroqVisionClient(),
        grounder: VisualGrounder,
        model: String = GroqModel.llama4Scout,
        skillProvider: ((String) -> String?)? = nil,
        skillIndex: String? = nil,
        harnessProvider: (@MainActor (String, [String: Any]) async -> String)? = nil,
        harnessTier: HarnessTier = .off,
        recallEnabled: Bool = false
    ) {
        self.vision = vision
        self.grounder = grounder
        self.model = model
        self.skillProvider = skillProvider
        self.skillIndex = skillIndex
        self.harnessProvider = harnessProvider
        self.harnessTier = harnessProvider == nil ? .off : harnessTier
        self.recallEnabled = recallEnabled && harnessProvider != nil
        rebuildSystem()
    }

    /// Tools available this run, by name — drives both the prompt catalogue and the
    /// in-process resolver. Mirrors the Opus path's tiers.
    private var availableTools: Set<String> {
        var s = Set<String>()
        if skillProvider != nil { s.insert("use_skill") }
        if harnessProvider != nil {
            if harnessTier != .off { s.formUnion(["search_files", "read_file", "list_folder"]) }
            if harnessTier == .full { s.formUnion(["run_command", "run_applescript", "write_file"]) }
            if recallEnabled { s.formUnion(["search_record", "get_timeframe", "inspect_moment"]) }
        }
        return s
    }

    /// Resolution screenshots are captured + sent at — same contract as
    /// `ComputerUseAgent.captureSize`, so the episode runner captures once.
    public var captureSize: (width: Int, height: Int) {
        let res = AgentResolution.best(forWidth: max(1, displayW), height: max(1, displayH))
        return (res.w, res.h)
    }

    /// `conversation` seeds cross-turn memory (the shared assist history, so Scout
    /// resolves "it"/"the first one"); `skill` is the frontmost app's playbook,
    /// PUSHED into the system prompt (Scout won't pull); `note` is the first turn's
    /// grounding line (frontmost app + window). Parity with the Opus path's harness.
    public func begin(
        goal: String, screenshot: Data, displayWidthPoints: Int, displayHeightPoints: Int,
        conversation: [(user: String, assistant: String)] = [], note: String? = nil, skill: String? = nil
    ) async -> CUStep {
        self.goal = goal
        displayW = displayWidthPoints
        displayH = displayHeightPoints
        history = conversation
        episodeCopied = false
        goalAsksForPaste = ComputerUseAgent.goalMentionsClipboard(goal)
        applySkill(skill)
        return await step(screenshot: screenshot, note: note)
    }

    /// `note` is an optional runtime nudge (e.g. a no-effect warning + the controls
    /// actually on screen) appended to this turn's instruction — the structural way
    /// to steer a cheap planner that can't otherwise tell its last action did nothing.
    /// `skill` is the playbook for the app frontmost THIS turn — refreshed every
    /// turn so it tracks the app actually in focus (e.g. once Scout opens Keynote).
    public func proceed(screenshot: Data, note: String? = nil, skill: String? = nil) async -> CUStep {
        applySkill(skill)
        return await step(screenshot: screenshot, note: note)
    }

    /// Updates the pushed app playbook (a nil skill leaves the last one in place, so
    /// a transient "no frontmost skill" doesn't wipe it) and rebuilds the prompt.
    private func applySkill(_ skill: String?) {
        if let skill, !skill.isEmpty { pushedSkill = skill }
        rebuildSystem()
    }

    /// episodeSystem = base prompt + tool catalogue + the pushed app playbook.
    private func rebuildSystem() {
        var s = Self.systemPrompt + toolsPrompt
        if let pushedSkill, !pushedSkill.isEmpty {
            s += """


            App playbook for the app you are working in — follow its approach and \
            recipes, but carry each step out with YOUR actions (name the target to \
            click or type into; ignore any references to coordinates, fill_field, or a \
            computer tool — those are not your tools):

            \(pushedSkill)
            """
        }
        episodeSystem = s
    }

    /// The in-process tool catalogue injected into the system prompt — only the
    /// tools actually available this run, expressed as the JSON actions Scout emits
    /// (they resolve instantly with no screen action, like the Opus inline hop).
    private var toolsPrompt: String {
        let t = availableTools
        guard !t.isEmpty else { return "" }
        var lines = ["", "",
            "INSTANT TOOLS — emit these like any action; they return a result WITHOUT touching the screen, so use them BEFORE acting when relevant:"]
        if t.contains("use_skill") {
            lines.append("- use_skill: fetch a playbook's full instructions — {\"action\":\"use_skill\",\"name\":\"<exact skill name>\"}.")
            if let skillIndex, !skillIndex.isEmpty { lines.append("  Available skills:\n\(skillIndex)") }
        }
        if t.contains("search_files") {
            lines.append("- search_files {\"action\":\"search_files\",\"query\":\"…\",\"folder\":\"~/Desktop\"} · read_file {\"action\":\"read_file\",\"path\":\"…\"} · list_folder {\"action\":\"list_folder\",\"path\":\"…\"} — find/read files instead of clicking through Finder (folder optional).")
        }
        if t.contains("run_command") {
            lines.append("- run_command {\"action\":\"run_command\",\"command\":\"…\"} · run_applescript {\"action\":\"run_applescript\",\"script\":\"…\"} · write_file {\"action\":\"write_file\",\"path\":\"…\",\"content\":\"…\"} — ONLY for data/file work the user asked for, never to do on-screen work the user is watching.")
        }
        if t.contains("search_record") {
            lines.append("- search_record {\"action\":\"search_record\",\"query\":\"…\"} · get_timeframe · inspect_moment {\"action\":\"inspect_moment\",\"id\":<n>} — recall what the user already saw on screen EARLIER (use when the goal refers to something not on screen now).")
        }
        return lines.joined(separator: "\n")
    }

    /// The target Scout named this turn but the grounder could NOT locate — read by
    /// the runner so it can tell Scout to re-describe (instead of silently going
    /// idle and stalling). nil when the last turn grounded fine or named no target.
    public private(set) var lastGroundMiss: String?
    /// Human-readable grounding outcome for the audit log — e.g. `hit "Save" @
    /// (450,438)` or `miss "New Document"`. Lets the audit show WHERE each grounded
    /// click landed (or that it found nothing), the visibility we were missing.
    public private(set) var lastGroundLog: String?

    private func step(screenshot: Data, note: String? = nil, carried: String? = nil, hop: Int = 0) async -> CUStep {
        lastGroundMiss = nil
        lastGroundLog = nil
        var user = "Goal: \(goal)\n\nDecide the next action(s) and reply with the JSON object only."
        if let carried, !carried.isEmpty { user += "\n\nResults of your tool calls:\n" + carried }
        if let note, !note.isEmpty { user += "\n\n" + note }
        let reply: String
        do {
            reply = try await vision.complete(
                system: episodeSystem, user: user, imageJPEG: screenshot,
                model: model, maxTokens: 600, prior: history
            )
        } catch {
            return CUStep(actions: [], text: "I couldn't reach the planner.", done: true, failed: true)
        }
        let raw = Self.parseRawActions(reply)
        guard !raw.isEmpty else {
            // Unparseable → an empty, non-done turn; the runner's stall guard
            // ends the episode if this repeats.
            return CUStep(actions: [], text: reply.isEmpty ? "" : String(reply.prefix(120)), done: false)
        }
        // In-process tool calls (use_skill / harness / recall) resolve WITHOUT a
        // screen action — the Scout analog of the Opus inline hop. Resolve them, feed
        // results back, and re-prompt the SAME screenshot (hop-capped); a tool turn
        // never touches the cursor. A reply mixing tools + screen actions is treated
        // as tools-first (the screen actions were decided before the results existed).
        let tools = availableTools
        let toolCalls = raw.filter { ($0["action"] as? String).map(tools.contains) ?? false }
        if !toolCalls.isEmpty, hop < 6 {
            var results = carried ?? ""
            for call in toolCalls {
                guard let name = call["action"] as? String else { continue }
                let r = await resolveTool(name: name, input: call)
                results += "[\(name)] \(String(r.prefix(2000)))\n\n"
            }
            history.append((user: user, assistant: String(reply.prefix(400))))
            return await step(screenshot: screenshot, note: note, carried: results, hop: hop + 1)
        }
        let plan = raw.compactMap { Self.parseOne($0) }
        guard !plan.isEmpty else {
            return CUStep(actions: [], text: reply.isEmpty ? "" : String(reply.prefix(120)), done: false)
        }
        history.append((user: user, assistant: plan.map(Self.historyLine).joined(separator: " ; ")))
        // Expand the batch. All actions ground against THIS turn's screenshot, so
        // the model is told to only batch steps predictable from the current screen
        // (the no-effect guard catches a batch that ran past a screen change). Stop
        // at the first "done" — anything after it can't be planned from this frame.
        var cuActions: [CUAction] = []
        var sawDone = false
        for a in plan {
            // Skip (don't break on) a "done" so a [done, action] ordering still runs
            // the action; done only takes effect when nothing executable remains.
            if a.kind == .done { sawDone = true; continue }
            cuActions.append(contentsOf: await actions(for: a, screenshot: screenshot))
        }
        let spoken = plan.first(where: { !$0.thought.isEmpty })?.thought ?? ""
        // The runner returns on `done` BEFORE executing actions, so only finish when
        // there's nothing to run this turn; a [fill, done] batch runs the fill now
        // and the model confirms done next turn.
        if cuActions.isEmpty {
            return CUStep(actions: [], text: spoken.isEmpty && sawDone ? "Done." : spoken, done: sawDone)
        }
        return CUStep(actions: cuActions, text: spoken, done: false)
    }

    /// Resolves one in-process tool call to a text result. use_skill goes through
    /// the skill provider (name OR target); everything else (harness + recall) goes
    /// through the harness provider, which routes recall vs file/shell itself.
    private func resolveTool(name: String, input: [String: Any]) async -> String {
        if name == "use_skill" {
            let skillName = (input["name"] as? String) ?? (input["target"] as? String) ?? ""
            return skillProvider?(skillName) ?? "No skill named “\(skillName)”."
        }
        return await harnessProvider?(name, input) ?? "The \(name) tool isn't available."
    }

    /// Maps a parsed action to executable `CUAction`s, grounding named targets via
    /// the grounder. An empty result (grounding miss) makes the turn idle — the
    /// runner re-observes and the model tries again.
    private func actions(for a: ScoutAction, screenshot: Data) async -> [CUAction] {
        switch a.kind {
        case .openApp: return a.target.map { [.openApp($0)] } ?? []
        case .openURL: return a.target.map { [.openURL($0)] } ?? []
        case .key:
            guard let key = a.key else { return [] }
            // Copy-aware paste gate (mirrors the Opus path's pasteRefusal). A bare
            // cmd+v / ctrl+v pastes the USER's clipboard and corrupts the field —
            // allow it ONLY when Scout copied something itself this episode (a real
            // copy→paste workflow) or the goal is about the clipboard. Otherwise
            // drop it; Scout's `type` delivers text itself.
            if ComputerUseAgent.isCopyCombo(key) { episodeCopied = true; return [.key(key)] }
            if ComputerUseAgent.isPasteCombo(key), !(episodeCopied || goalAsksForPaste) { return [] }
            return [.key(key)]
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
        let point = await grounder.ground(
            screenshot: screenshot, target: target,
            displayWidthPoints: displayW, displayHeightPoints: displayH
        )
        if let point {
            lastGroundLog = "hit \"\(target)\" @ (\(Int(point.x)),\(Int(point.y)))"
        } else {
            lastGroundMiss = target
            lastGroundLog = "miss \"\(target)\""
        }
        return point
    }

    nonisolated private static func historyLine(_ a: ScoutAction) -> String {
        var parts = [a.kind.rawValue]
        if let t = a.target { parts.append("→ \(t)") }
        if let text = a.text { parts.append("\"\(text.prefix(40))\"") }
        if let k = a.key { parts.append(k) }
        return parts.joined(separator: " ")
    }

    /// Parses ONE action from a reply (tolerating prose / ``` fences). Kept for the
    /// single-action contract + tests; `parseScoutActions` handles batches.
    nonisolated public static func parseScoutAction(_ text: String) -> ScoutAction? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
              start < end,
              let data = String(text[start...end]).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return parseOne(json)
    }

    /// Raw action dicts from a reply — the source of truth for BOTH tool calls
    /// (which need arbitrary input fields like path/command) and screen actions.
    /// Handles a batch `{"actions":[…]}` (outer "thought" carried onto elements
    /// lacking their own) or a single `{action:…}` object. A stray non-object
    /// element in the batch is skipped, not fatal.
    nonisolated static func parseRawActions(_ text: String) -> [[String: Any]] {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
              start < end,
              let data = String(text[start...end]).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        if let arr = json["actions"] as? [Any] {
            let outerThought = json["thought"] as? String
            return arr.compactMap { element in
                guard var e = element as? [String: Any] else { return nil }
                if e["thought"] == nil, let outerThought { e["thought"] = outerThought }
                return e
            }
        }
        return [json]
    }

    /// Parses one OR several SCREEN actions (back-compat + tests). Built on
    /// `parseRawActions`; non-action dicts (e.g. tool calls) drop out via parseOne.
    nonisolated public static func parseScoutActions(_ text: String) -> [ScoutAction] {
        parseRawActions(text).compactMap { parseOne($0) }
    }

    nonisolated private static func parseOne(_ json: [String: Any]) -> ScoutAction? {
        guard let rawAction = (json["action"] as? String)?.lowercased(),
              let kind = mapKind(rawAction) else { return nil }
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

    nonisolated private static func mapKind(_ raw: String) -> ScoutAction.Kind? {
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

    nonisolated private static func nonEmpty(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    static let systemPrompt = """
    You are an on-screen computer-use agent. You see the user's screen and drive it \
    to accomplish their goal.

    Reply with ONLY JSON — no prose, no code fences. For ONE action:
    {"thought": "<one short clause on what you're doing>", "action": "<one action>", \
    "target": "<the on-screen element, named in plain words>", "text": "<text to type>", \
    "key": "<key combo>", "direction": "<up|down>", "amount": <int>}
    To do several PREDICTABLE steps in one turn, batch them:
    {"thought": "<clause>", "actions": [{"action": …}, {"action": …}]}
    Only batch steps you can predict from the CURRENT screen (e.g. fill the title, \
    then fill the subtitle). If the next step depends on something not yet visible (a \
    menu about to open, a dialog that may appear), do ONE action and look again — \
    never batch past an action that changes what's on screen.

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

    Rules:
    - Take the MOST DIRECT route: a keyboard shortcut beats a menu, a menu beats \
      clicking through panels, and an app playbook's recipe (pushed to you below, if \
      any) beats improvising. Follow the playbook when one is given.
    - Prefer open_app/open_url over hunting for an icon. Name targets precisely — the \
      locator matches your words against what's on screen, so describe the VISIBLE \
      element (its label/role/nearby text), never the text you intend to type.
    - If your last action did NOT change the screen, do NOT repeat it — the control \
      isn't there, is disabled, or needs a different gesture. Pick a different \
      control, menu, or approach (a third identical attempt is never the answer).
    - To enter text use "type" — it delivers the text itself. NEVER press cmd+v/ctrl+v \
      to enter content: you don't own the clipboard and it pastes what the USER copied.
    - Do the work INSIDE the app the task names, through its own UI. Never detour to \
      Terminal, shell, or scripts (or an app's built-in script/macro editor) unless \
      the task itself is about them or the user asked for a script.
    - Creative and hands-on work is YOURS: when asked to design, draw, write, build, \
      or edit something, do it yourself — never tell the user to do it or just \
      describe the steps.
    - After opening an app the first frame may show a splash or template/theme \
      chooser — wait for it to settle, and never repeat a new-document action until \
      the screen proves the previous one didn't work (extra presses make extra docs).
    - "thought" is SPOKEN to the user: keep it human, ≤8 words, no coordinates or \
      tool names. Only "done" when the goal is genuinely accomplished, judged by \
      what's on screen.
    """
}
