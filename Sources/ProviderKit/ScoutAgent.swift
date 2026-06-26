import Foundation

/// The downgraded on-screen brain (Tier 2 of the model-downgrade roadmap): a
/// PLANNER (Qwen3.7 Plus via OpenRouter) paired with a GROUNDER (UI-TARS). This is
/// the Agent-S architecture — the planner decides the next action and NAMES its
/// target in words; the grounder turns that name into a click coordinate. Output
/// is the same `CUAction`/`CUStep` the Claude agent emits, so the executor
/// (`executeCU`) and the episode gates are reused unchanged.
///
/// Why this shape: Qwen3.7 Plus is a multimodal GUI-agent model — it SEES the
/// screenshot (passed when `visionCapable`) AND is handed the screen as TEXT
/// (accessibility controls + OCR Set-of-Marks; on the web, page text +
/// interactives) via `screenText` as naming hints. It reasons over both and names
/// targets; coordinates are delegated to the dedicated grounder. The planner never
/// emits pixels. A text-only model (GLM-5.2, `visionCapable = false`) gets the
/// `screenText` alone. See [[cascade-cu-downgrade-research]].
///
/// RUNTIME-UNVERIFIED end to end (no planner/UI-TARS/live screen in CI). The action
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
        public let click: String?    // "single"/"double" for a type/click target
        public let thought: String   // short narration / done reason
    }

    private let planner: ScoutPlannerClient
    private let grounder: VisualGrounder
    private let model: String
    /// Whether the planner model is multimodal — when true the screenshot is sent to
    /// the planner each turn (Qwen3.7 Plus SEES the screen); when false it plans from
    /// the AX + OCR `screenText` only (a text-only model like GLM-5.2). Either way the
    /// grounder still reads the screenshot.
    private let visionCapable: Bool
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

    /// Fixed environment guidance appended to the system prompt — the per-surface
    /// rules that aren't a per-app skill (e.g. the web sandbox: no tabs, use
    /// open_url, NEEDS_LOGIN/INCOMPLETE protocol). nil for the on-screen agent.
    private let environmentNote: String?

    public init(
        planner: ScoutPlannerClient = ScoutPlannerClient(),
        grounder: VisualGrounder,
        model: String = ScoutModel.qwen37Plus,
        visionCapable: Bool = true,
        environmentNote: String? = nil,
        skillProvider: ((String) -> String?)? = nil,
        skillIndex: String? = nil,
        harnessProvider: (@MainActor (String, [String: Any]) async -> String)? = nil,
        harnessTier: HarnessTier = .off,
        recallEnabled: Bool = false
    ) {
        self.planner = planner
        self.grounder = grounder
        self.model = model
        self.visionCapable = visionCapable
        self.environmentNote = environmentNote
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
            // Resolve ALL recall tools (so a list_sessions/get_timeframe emitted from
            // the shared history still routes), even though toolsPrompt only
            // advertises the two a weak planner can use without an ISO time window.
            if recallEnabled { s.formUnion(RecordRecall.toolNames) }
        }
        return s
    }

    /// Resolution screenshots are captured + sent at — same contract as
    /// `ComputerUseAgent.captureSize`, so the episode runner captures once.
    public var captureSize: (width: Int, height: Int) {
        let res = AgentResolution.best(forWidth: max(1, displayW), height: max(1, displayH))
        return (res.w, res.h)
    }

    /// `screenText` is the AX + OCR view of the screen (web: page text + interactives)
    /// — naming hints alongside the screenshot for a vision planner, or the sole view
    /// for a text-only one; the `screenshot` goes to the grounder (and to the planner
    /// when `visionCapable`). `conversation` seeds cross-turn
    /// memory (so Scout resolves "it"/"the first one"); `skill` is the frontmost
    /// app's playbook, PUSHED into the system prompt (Scout won't pull); `note` is an
    /// optional first-turn nudge. Parity with the Opus path's harness.
    public func begin(
        goal: String, screenshot: Data, displayWidthPoints: Int, displayHeightPoints: Int,
        screenText: String? = nil,
        conversation: [(user: String, assistant: String)] = [], note: String? = nil, skill: String? = nil
    ) async -> CUStep {
        self.goal = goal
        displayW = displayWidthPoints
        displayH = displayHeightPoints
        history = conversation
        episodeCopied = false
        goalAsksForPaste = ComputerUseAgent.goalMentionsClipboard(goal)
        applySkill(skill)
        return await step(screenshot: screenshot, screenText: screenText, note: note)
    }

    /// `screenText` is this turn's screen rendered as text (the planner has no image);
    /// `note` is an optional runtime nudge (e.g. a no-effect warning) — the structural
    /// way to steer a cheap planner that can't otherwise tell its last action did
    /// nothing. `skill` is the playbook for the app frontmost THIS turn — refreshed
    /// every turn so it tracks the app actually in focus (e.g. once Scout opens Keynote).
    public func proceed(screenshot: Data, screenText: String? = nil, note: String? = nil, skill: String? = nil) async -> CUStep {
        applySkill(skill)
        return await step(screenshot: screenshot, screenText: screenText, note: note)
    }

    /// Updates the pushed app playbook (a nil skill leaves the last one in place, so
    /// a transient "no frontmost skill" doesn't wipe it) and rebuilds the prompt.
    private func applySkill(_ skill: String?) {
        if let skill, !skill.isEmpty { pushedSkill = skill }
        rebuildSystem()
    }

    /// episodeSystem = base prompt + tool catalogue + the pushed app playbook.
    private func rebuildSystem() {
        var s = Self.perceptionIntro(visionCapable: visionCapable) + "\n\n" + Self.systemPrompt + toolsPrompt
        if let environmentNote, !environmentNote.isEmpty {
            s += "\n\n" + environmentNote
        }
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
            lines.append("- search_record {\"action\":\"search_record\",\"query\":\"…\"} · inspect_moment {\"action\":\"inspect_moment\",\"id\":<n>} — recall what the user already saw on screen EARLIER (use when the goal refers to something not on screen now).")
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

    private func step(screenshot: Data, screenText: String? = nil, note: String? = nil, carried: String? = nil, hop: Int = 0, parseRetry: Bool = false) async -> CUStep {
        lastGroundMiss = nil
        lastGroundLog = nil
        // Lead with the goal, then the screen, then any tool results / nudge, then the
        // ask. A vision planner (Qwen3.7 Plus) also gets the screenshot, so the
        // AX/OCR text is framed as a Set-of-Marks AID; a text-only model gets it as
        // its sole view.
        var user = "Goal: \(goal)\n\n"
        if let screenText, !screenText.isEmpty {
            user += visionCapable
                ? "ELEMENTS ON SCREEN (read via accessibility + OCR — use these exact names to target the screenshot below):\n\(screenText)\n\n"
                : "WHAT'S ON SCREEN NOW — read from the live UI via accessibility + OCR (this text IS your view of the screen; there is no image):\n\(screenText)\n\n"
        }
        if let carried, !carried.isEmpty { user += "Results of your tool calls:\n" + carried + "\n\n" }
        if let note, !note.isEmpty { user += note + "\n\n" }
        user += "Decide the next action(s) and reply with the JSON object only."
        let reply: String
        do {
            reply = try await planner.complete(
                // A vision model SEES the screenshot; a text-only model gets nil (it
                // plans from screenText). Headroom for a batched reply with thoughts:
                // a small cap truncated ambitious batches mid-JSON (and a reasoning
                // model can return empty content when the cap is spent on thinking).
                system: episodeSystem, user: user,
                imageJPEG: visionCapable ? screenshot : nil,
                model: model, maxTokens: 1500, prior: history
            )
        } catch {
            // Surface the real reason (GLM rate-limit / transport / empty) so the
            // runner can audit WHY the run failed instead of stopping silently.
            return CUStep(actions: [], text: "planner error: \(error)", done: true, failed: true)
        }
        let raw = Self.parseRawActions(reply)
        guard !raw.isEmpty else {
            // A non-empty reply that didn't parse is usually a cut-off batch (JSON
            // truncated) or prose. Rather than burn an idle turn toward the stall
            // guard, re-prompt ONCE for a compact valid action; only then go idle.
            if !reply.isEmpty, !parseRetry {
                history.append((user: "(unparseable reply)", assistant: String(reply.prefix(200))))
                let recover = "Your previous reply was not valid JSON (it may have been cut off). Reply with ONLY a single compact JSON action object — no prose, no code fences. If you meant several steps, send FEWER this turn."
                return await step(screenshot: screenshot, screenText: screenText, note: recover, parseRetry: true)
            }
            // Unparseable → an empty, non-done turn; the runner's stall guard
            // ends the episode if this repeats.
            return CUStep(actions: [], text: reply.isEmpty ? "" : String(reply.prefix(120)), done: false)
        }
        // In-process tool calls (use_skill / harness / recall) resolve WITHOUT a
        // screen action — the Scout analog of the Opus inline hop. Resolve any in the
        // reply, append the results to history. Then: if the reply ALSO had screen
        // actions, execute them THIS turn (don't re-prompt — that would re-run the
        // model up to the hop cap per turn); only a tools-ONLY reply re-prompts the
        // same screenshot for the next decision (hop-capped). The cursor never moves
        // on a tools-only hop.
        let tools = availableTools
        let toolCalls = raw.filter { ($0["action"] as? String).map(tools.contains) ?? false }
        let plan = raw.compactMap { Self.parseOne($0) }
        if !toolCalls.isEmpty {
            var results = carried ?? ""
            for call in toolCalls {
                guard let name = call["action"] as? String else { continue }
                let r = await resolveTool(name: name, input: call)
                results += "[\(name)] \(String(r.prefix(2000)))\n\n"
            }
            // Compact history (the results travel via `carried`, not in history, so a
            // multi-hop turn doesn't duplicate them across entries).
            history.append((user: "(tool call)", assistant: String(reply.prefix(300))))
            if plan.isEmpty, hop < 6 {
                return await step(screenshot: screenshot, screenText: screenText, note: note, carried: results, hop: hop + 1)
            }
            // Screen actions present (or hop cap hit): fall through to run them; the
            // tool results are in history for the model's next turn.
        }
        guard !plan.isEmpty else {
            return CUStep(actions: [], text: reply.isEmpty ? "" : String(reply.prefix(120)), done: false)
        }
        // Batch safety (VeriGUI's screen-idempotency lesson): every target in a batch
        // grounds against THIS frame, so a grounded action that runs after the screen
        // already changed this turn would aim at a stale layout. The weak planner
        // can't be trusted to honour the prompt's "don't batch past a screen change",
        // so the runtime TRUNCATES the plan at the first grounded action that would
        // follow a navigation (or a submitting fill) — the dropped tail re-grounds
        // next turn against the fresh screen. Multiple fills of placeholders that
        // coexist on one frame (title + subtitle) still chain. Append only what we
        // actually run to history, so the model doesn't think it did the dropped tail.
        let batch = Self.safeBatchPrefix(plan)
        // Compact memory (words-only, like the vision planner never resent old
        // frames): store the assistant's actions + any nudge it was given — NEVER the
        // full screen-as-text, which is huge and stale by the next turn (the fresh
        // screenText is re-sent every turn as the CURRENT user message instead).
        let historyUser = (note?.isEmpty == false) ? String(note!.prefix(160)) : "(observed the screen)"
        history.append((user: historyUser, assistant: batch.map(Self.historyLine).joined(separator: " ; ")))
        // Ground every named target in the safe prefix CONCURRENTLY against this one
        // frame — the lookups are independent, so a two-fill turn pays one grounding
        // latency, not two in series. Results are recorded in plan order so the
        // miss/log the runner reads is deterministic. (Capture isolated locals; the
        // task closures can't touch actor state.)
        let g = grounder, dw = displayW, dh = displayH
        var groundResults: [(idx: Int, target: String, point: CGPoint?)] = []
        await withTaskGroup(of: (Int, String, CGPoint?).self) { group in
            for (i, a) in batch.enumerated() {
                guard let target = Self.groundTarget(of: a) else { continue }
                group.addTask {
                    (i, target, await g.ground(screenshot: screenshot, target: target, displayWidthPoints: dw, displayHeightPoints: dh))
                }
            }
            for await r in group { groundResults.append(r) }
        }
        var grounded: [Int: CGPoint] = [:]
        var logs: [String] = []
        for r in groundResults.sorted(by: { $0.idx < $1.idx }) {
            if let p = r.point {
                grounded[r.idx] = p
                logs.append("hit \"\(r.target)\" @ (\(Int(p.x)),\(Int(p.y)))")
            } else {
                if lastGroundMiss == nil { lastGroundMiss = r.target }
                logs.append("miss \"\(r.target)\"")
            }
        }
        lastGroundLog = logs.isEmpty ? nil : logs.joined(separator: "; ")
        // Expand the (pre-grounded) plan into executable actions. Stop counting at
        // "done" but still run any action — done only takes effect when nothing
        // executable remains.
        var cuActions: [CUAction] = []
        var sawDone = false
        for (i, a) in batch.enumerated() {
            if a.kind == .done { sawDone = true; continue }
            cuActions.append(contentsOf: expand(a, groundedPoint: grounded[i]))
        }
        let spoken = batch.first(where: { !$0.thought.isEmpty })?.thought ?? ""
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

    /// The on-screen target a parsed action must ground, or nil when it needs no
    /// grounding (keys, waits, open_app/url, a scroll/type with no named target). Pure
    /// — drives both the concurrent grounding pass and `safeBatchPrefix`.
    nonisolated static func groundTarget(of a: ScoutAction) -> String? {
        switch a.kind {
        case .click, .doubleClick: return a.target
        case .scroll: return a.target
        case .type: return (a.target?.isEmpty == false) ? a.target : nil
        case .openApp, .openURL, .key, .wait, .done: return nil
        }
    }

    /// True when an action changes the on-screen LAYOUT (navigation), so a grounded
    /// action batched AFTER it would aim at a stale frame. Typing/fills change pixels
    /// but not the position of other visible controls, so they aren't counted here
    /// (their submit-navigation risk is handled by the fill rule in `safeBatchPrefix`).
    nonisolated static func mutatesLayout(_ a: ScoutAction) -> Bool {
        switch a.kind {
        case .click, .doubleClick, .scroll, .openApp, .openURL, .key: return true
        case .type, .wait, .done: return false
        }
    }

    /// The leading run of a batch that is safe to execute against ONE screenshot: a
    /// grounded action may not follow a navigation (which moved the layout) or a
    /// fill (which can submit and navigate) unless it is itself a fill of a
    /// co-visible placeholder. The dropped tail re-grounds next turn on the fresh
    /// screen. Pure + pinned — this is the structural batch-safety guard.
    nonisolated static func safeBatchPrefix(_ plan: [ScoutAction]) -> [ScoutAction] {
        var out: [ScoutAction] = []
        var navigated = false
        var sawFill = false
        for a in plan {
            let needsGround = groundTarget(of: a) != nil
            let isFill = a.kind == .type && (a.target?.isEmpty == false)
            if needsGround {
                if navigated { break }            // grounds against a navigated-away frame
                if sawFill && !isFill { break }   // e.g. fill a search box → click a result
            }
            out.append(a)
            if isFill { sawFill = true }
            if mutatesLayout(a) { navigated = true }
        }
        return out
    }

    /// Expands a parsed action (with its target already grounded, if any) into
    /// executable `CUAction`s. A grounding miss (`groundedPoint == nil` for an action
    /// that needed one) yields no actions, making the turn idle so the runner
    /// re-observes and the model tries again.
    private func expand(_ a: ScoutAction, groundedPoint: CGPoint?) -> [CUAction] {
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
            let point = groundedPoint ?? CGPoint(x: CGFloat(displayW) / 2, y: CGFloat(displayH) / 2)
            return [.scroll(x: point.x, y: point.y, direction: a.direction ?? "down", amount: a.amount ?? 3)]
        case .click, .doubleClick:
            guard let point = groundedPoint else { return [] }
            return [a.kind == .doubleClick ? .doubleClick(x: point.x, y: point.y) : .click(x: point.x, y: point.y)]
        case .type:
            guard let text = a.text else { return [] }
            // Target named → click into it and replace (the fill batch); no target
            // → type into whatever's focused. DEFAULT to a DOUBLE click: it enters
            // text editing on a canvas placeholder (Keynote/Pages title/subtitle),
            // where a single click only SELECTS the box and the fill's cmd+a then
            // becomes Select-All-Objects + a stray paste — the audited flail. The
            // weak planner won't reliably ask for double itself, so we default to it
            // (harmless on a plain field: cmd+a still replaces). Force single with
            // click:"single" only for a field where a double-click misbehaves.
            guard let target = a.target, !target.isEmpty else { return [.type(text)] }
            guard let point = groundedPoint else { return [] }
            return ComputerUseAgent.fillActions(at: point, text: text, double: a.click != "single", submit: "return")
        }
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
            click: nonEmpty(json["click"] as? String),
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

    /// The perception sentence — adapts to whether the planner model can see the
    /// screenshot (Qwen3.7 Plus) or only the AX + OCR text (GLM-5.2). Prepended to
    /// `systemPrompt` in `rebuildSystem`.
    static func perceptionIntro(visionCapable: Bool) -> String {
        visionCapable
            ? """
            You are an on-screen computer-use agent that drives the user's screen to \
            accomplish their goal. Each turn you SEE a screenshot of the screen, and you \
            are also given a TEXT list of the on-screen elements (read via accessibility \
            and OCR) — use those exact names to refer to what you see. When you NAME a \
            target, a locator turns it into an exact click for you, so you never output \
            coordinates.
            """
            : """
            You are an on-screen computer-use agent that drives the user's screen to \
            accomplish their goal. You do NOT see an image — each turn you are given a \
            TEXT description of what's on screen right now, read from the live UI via \
            accessibility (the app's own controls) and OCR (the visible text). Plan from \
            that text. When you NAME a target, a locator turns it into an exact click for \
            you, so you never output coordinates.
            """
    }

    static let systemPrompt = """
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
    - "type": enter text. "text" is what to type; "target" (optional) is the field, \
      DESCRIBED BY THE ON-SCREEN TEXT (its visible label or placeholder) — never the \
      text you intend to type. Given a target it is double-clicked (to enter editing), \
      its contents selected, and replaced with "text". For the rare plain field where \
      a double-click misbehaves, add "click":"single". With no target, the text goes \
      to whatever already has focus.
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
    - The on-screen text can be INCOMPLETE for graphics / canvas apps (Keynote \
      slides, Blender, design tools) where there's little to read. If what you need \
      isn't listed, don't assume it's absent — open the relevant menu or panel, or \
      use a keyboard shortcut, to reveal and act on it.
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
