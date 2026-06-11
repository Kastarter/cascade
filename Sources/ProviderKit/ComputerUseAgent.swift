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
    /// Screen actions already executed mid-stream through `streamSink` — they are
    /// NOT in `actions`. Lets callers count activity without re-running them.
    public let streamedActions: Int

    init(actions: [CUAction], text: String, done: Bool, streamedActions: Int = 0) {
        self.actions = actions
        self.text = text
        self.done = done
        self.streamedActions = streamedActions
    }
}

/// One piece of a streamed model reply, delivered in response order the moment
/// its block finishes generating — actions execute while the rest of the reply
/// is still being written, instead of after the full round trip.
public enum CUStreamItem: Sendable {
    /// A completed narration clause (speak it now — the next action block is
    /// still generating, which is the natural head start).
    case text(String)
    /// A completed screen action, ready to execute immediately.
    case action(CUAction)
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
    /// Direct-Mac harness: which tier of file/shell tools to offer, and the
    /// executor that runs one call (the caller owns auditing, gating, and STOP).
    /// Harness calls resolve in-process like use_skill — a search→read→answer
    /// chain costs zero screenshots.
    private let harnessTier: HarnessTier
    private let harnessProvider: (@MainActor (String, [String: Any]) async -> String)?

    /// Mid-stream delivery: when set, each completed text block and screen action
    /// is handed over the moment it finishes generating, so the caller acts while
    /// the rest of the reply streams in (the round-trip wait stops being idle
    /// time). Return false to abort the turn — STOP pressed, episode superseded,
    /// or an action failed; the agent drops the half-turn and returns immediately.
    /// zoom/screenshot directives and use_skill/harness calls are never streamed —
    /// they keep their existing post-response handling (crops, audit, gating).
    public var streamSink: (@MainActor (CUStreamItem) async -> Bool)?

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
    tell the user to do it themselves or merely describe the steps. Do that work INSIDE \
    the app the task names, through its own UI: never detour to Terminal, shell \
    commands, or scripts unless the task itself is about them or the user explicitly \
    asked for a script. An app's built-in scripting surface — Blender's Python editor, \
    an Office macro pane — IS a script: build with clicks, fields, and shortcuts no \
    matter how big or repetitive the job, unless the user asked for code. Every turn \
    costs the user seconds of waiting, so make turns COUNT: when the next several \
    actions are all predictable from the current screenshot — click a field, type, Tab, \
    type, Return; a click whose target is already visible; a known hotkey sequence — \
    chain them ALL as tool calls in ONE turn. Three to six actions is a normal turn; a \
    single-action turn is the exception, reserved for steps whose outcome you genuinely \
    cannot predict (a menu about to open, a dialog that may appear). Re-observe only \
    when the next action depends on something the screen has not shown yet. Always take \
    the MOST DIRECT route you know and commit to it before acting: a keyboard shortcut \
    beats a menu, a menu beats clicking through panels, and a skill's recipe beats \
    improvising. Never open an app, window, or menu just to verify something the \
    screenshot already shows, and never redo a step the screen proves succeeded — every \
    detour is seconds the user spends watching a motionless cursor. To REPLACE \
    what a field already contains (a value, a name, a hex color), click the field, \
    select all with cmd+a, then use the type action with the new value — chained in one \
    turn. Typing into a field that still holds its old text APPENDS to it, and clearing \
    character-by-character with repeated Delete presses is never the way. The type \
    action delivers its text reliably by itself (using the clipboard internally when \
    needed) — NEVER press cmd+v or ctrl+v as a key action to enter content: you do not \
    control the clipboard, and that key pastes whatever the USER last copied, corrupting \
    the field. Narrate in ONE short clause (eight words \
    max) when you start a distinct phase — "opening the reply", "writing the poem now". \
    The clause must announce what you are ABOUT to do in that same turn, placed BEFORE \
    those tool calls — never describe work you already finished, and never repeat a \
    clause you already said. The user hears these, so keep them human; no coordinates, \
    tools, or screenshots. After launching an app, the first frame may still \
    show its splash or template screen — wait for it to settle, and NEVER repeat a \
    new-document action (cmd+n or a New button) until the current frame proves the \
    previous one didn't work: extra presses create extra documents. When the whole task \
    is finished, reply with a short confirmation. Earlier exchanges from this session may \
    precede the task; use them to resolve references like "it", "that one", or "the \
    first one" — they are context, not new work.
    """

    /// What the harness tools are and when to reach for them — appended to the
    /// system prompt only when the matching tier is active, so the model is
    /// never told about tools it doesn't have.
    private static let harnessReadOnlyNote = """
    You also have direct file tools that need no screenshots and are instant: search_files \
    (Spotlight search of this Mac), list_folder, and read_file. When the task is finding, \
    checking, or reading files or folders — "search my desktop for X", "what's in that \
    folder" — use these FIRST instead of clicking through Finder windows. When the task \
    lives on screen (an app's UI, a website), do NOT detour through the file tools — act \
    on screen immediately. When the task NAMES AN APP (Notes, Mail, Keynote, ...), the \
    artifact lives INSIDE that app: a file on disk whose name resembles the task is NOT \
    the target, no matter how exact the match looks. Reading or editing such a file \
    never completes an in-app task — treat file hits as background context and do the \
    work in the named app on screen.
    """

    private static let harnessPowerNote = """
    You can also automate directly: run_command executes a zsh command, run_applescript \
    drives scriptable apps, and write_file writes a text file. PICK ONE LANE PER STEP \
    AND COMMIT: if a step is file work, do it entirely with these tools; if it's screen \
    work, do it entirely on screen — mixing both on the same artifact wastes turns and \
    confuses the result. The ARTIFACT picks the lane, and a task that names an app pins \
    its artifact to that app's UI: editing a look-alike file on disk does not check off, \
    reply to, or update anything inside Notes, Mail, or any other app — that is the \
    file lane completing the WRONG artifact, not the task. CREATING FILES AND FOLDERS IS FILE WORK: build the file with \
    its final name directly at its destination in ONE command (write_file for \
    text/markdown; run_command with textutil for .docx/.rtf, e.g. \
    `printf '%s' "..." > /tmp/t.txt && textutil -convert docx /tmp/t.txt -output \
    ~/Desktop/folder/name.docx`), then `open` the file — never create an untitled \
    document in an app and fight the Save dialog when one command places the finished \
    file. Prefer plain shell over AppleScript when both work: AppleScript pauses for a \
    per-app consent prompt the first time it touches an app. Bulk or data-heavy work in \
    Excel, Numbers, Mail, or Finder should be ONE script, not hundreds of clicks — but \
    that is DATA work only: building something the user asked to watch being made (a \
    deck, a 3D scene, a design) is screen work in that app's UI, never a script target. \
    And never use write_file or run_command as a ferry for screen work — writing \
    content to /tmp to open or paste into an app is mixing lanes; enter it in the app \
    directly. Every \
    command is shown to the user and recorded in their audit log. If a script fails \
    twice, fall back to doing it on screen.
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
        skillProvider: ((String) -> String?)? = nil,
        harnessTier: HarnessTier = .off,
        harnessProvider: (@MainActor (String, [String: Any]) async -> String)? = nil
    ) {
        self.keyStore = keyStore
        self.model = model
        self.effort = effort
        self.environmentNote = environmentNote
        self.skillProvider = skillProvider
        self.harnessTier = harnessProvider == nil ? .off : harnessTier
        self.harnessProvider = harnessProvider
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
        // Harness tools sit before the computer tool so its cache breakpoint
        // covers them. Definitions are fixed per episode — zero ongoing token
        // cost beyond the one-time cache write.
        if harnessTier != .off {
            tools.insert(contentsOf: Self.harnessToolDefinitions(tier: harnessTier), at: tools.count - 1)
        }
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
        var system = Self.systemPrompt
        switch harnessTier {
        case .off: break
        case .readOnly: system += "\n\n" + Self.harnessReadOnlyNote
        case .full: system += "\n\n" + Self.harnessReadOnlyNote + "\n\n" + Self.harnessPowerNote
        }
        if let environmentNote { system += "\n\n" + environmentNote }
        // Adaptive thinking is Anthropic's benchmarked setup for computer use on
        // Sonnet 4.6: the model plans before acting, and fewer wrong clicks means
        // fewer retries — it uses fewer total tokens than no-thinking. max_tokens
        // leaves room for thinking ahead of the tool calls.
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 2048,
            "stream": true,
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

        guard let streamed = await streamMessage(request) else {
            return CUStep(actions: [], text: "I couldn't reach Claude just now.", done: true)
        }
        if streamed.aborted {
            // The sink stopped the turn mid-stream (STOP, supersession, or a
            // failed action). The episode is over — the caller's own flags say
            // why; don't extend history with the half turn.
            return CUStep(actions: [], text: "", done: true)
        }
        Self.logUsage(["usage": streamed.usage])

        let content = streamed.content
        messages.append(["role": "assistant", "content": content])
        let stopReason = streamed.stopReason

        var texts: [String] = []
        var actions: [CUAction] = []
        pendingToolIDs = []
        for (index, block) in content.enumerated() {
            switch block["type"] as? String {
            case "text":
                if let text = block["text"] as? String { texts.append(text) }
            case "tool_use":
                if let id = block["id"] as? String { pendingToolIDs.append(id) }
                // Already executed mid-stream — its tool_result is the next
                // screenshot like any other action's; just never run it twice.
                if streamed.deliveredIndices.contains(index) { continue }
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
                case let name? where AgentHarness.isHarnessTool(name):
                    // Resolved in-process like use_skill — search/read/run chains
                    // never touch the screenshot loop. The provider owns audit,
                    // power gating, and STOP.
                    if let id = block["id"] as? String {
                        toolResultOverrides[id] = await harnessProvider?(name, input)
                            ?? "The \(name) tool isn't available in this run."
                    }
                default:
                    if let action = parseAction(input) { actions.append(action) }
                }
            default:
                break
            }
        }
        // A turn that ONLY pulled skills or ran harness tools needs no screen
        // work — answer the tool calls with their text right away and let the
        // model continue, without bouncing through the caller's screenshot loop.
        // Hop-capped (a search→read→read→script chain is legitimate; 8 hops of
        // anything means it's stuck) so the loop falls back to the screen path.
        if !pendingToolIDs.isEmpty, actions.isEmpty,
           pendingToolIDs.allSatisfy({ toolResultOverrides[$0] != nil }),
           inlineHops < 8 {
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
        return CUStep(
            actions: actions,
            text: texts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines),
            done: done,
            streamedActions: streamed.deliveredActions
        )
    }

    /// Tool definitions for the direct-Mac harness. Read-only tools ride every
    /// run; the power trio appears only when the user's Settings toggle is on —
    /// the model is never offered a tool that would be refused.
    private static func harnessToolDefinitions(tier: HarnessTier) -> [[String: Any]] {
        var defs: [[String: Any]] = [
            [
                "name": "search_files",
                "description": "Spotlight-search this Mac for files by name or content. Instant — use it instead of clicking through Finder whenever the task is finding a file or folder. Returns matching paths.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "Words to search for (matches file names and content)"],
                        "folder": ["type": "string", "description": "Optional folder to search under, e.g. ~/Desktop. Defaults to the user's home folder."],
                    ],
                    "required": ["query"],
                ],
            ],
            [
                "name": "list_folder",
                "description": "List the contents of one folder (directories end with /). Instant — use it instead of opening Finder to see what's in a folder.",
                "input_schema": [
                    "type": "object",
                    "properties": ["path": ["type": "string", "description": "Folder path, ~ allowed"]],
                    "required": ["path"],
                ],
            ],
            [
                "name": "read_file",
                "description": "Read a text file's content (bounded; binary files are refused). Instant — use it instead of opening the file on screen when you just need what's inside.",
                "input_schema": [
                    "type": "object",
                    "properties": ["path": ["type": "string", "description": "File path, ~ allowed"]],
                    "required": ["path"],
                ],
            ],
        ]
        guard tier == .full else { return defs }
        defs.append(contentsOf: [
            [
                "name": "run_command",
                "description": "Run one zsh command on this Mac and get its output (25s limit; destructive commands like sudo or rm -rf / are refused; the user sees every command in their audit log). Use it for bulk file work, data processing, or anything a shell does better than clicking.",
                "input_schema": [
                    "type": "object",
                    "properties": ["command": ["type": "string", "description": "The zsh command"]],
                    "required": ["command"],
                ],
            ],
            [
                "name": "run_applescript",
                "description": "Run an AppleScript to drive scriptable apps — Excel, Numbers, Mail, Calendar, Finder, Safari. The change happens in the user's real app. ONE script beats hundreds of clicks for bulk edits (e.g. setting many spreadsheet cells); 30s limit; audited.",
                "input_schema": [
                    "type": "object",
                    "properties": ["script": ["type": "string", "description": "The complete AppleScript source"]],
                    "required": ["script"],
                ],
            ],
            [
                "name": "write_file",
                "description": "Write a text file inside the user's home folder (creates parent folders; overwrites). Use it to save results, drafts, scripts, or data the user asked for.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "Destination path under ~, e.g. ~/Desktop/notes.md"],
                        "content": ["type": "string", "description": "The full file content"],
                    ],
                    "required": ["path", "content"],
                ],
            ],
        ])
        return defs
    }

    /// Everything one streamed reply yields: content blocks reassembled exactly as
    /// the non-streaming API would have returned them (history stays byte-compatible),
    /// plus which blocks the sink already executed.
    private struct StreamedMessage {
        var content: [[String: Any]] = []
        var stopReason: String?
        var usage: [String: Any] = [:]
        /// Indices into `content` whose ACTIONS the sink already executed —
        /// step()'s post-pass must not run them a second time.
        var deliveredIndices: Set<Int> = []
        var deliveredActions = 0
        /// The sink said stop — drop the turn; the caller owns the outcome.
        var aborted = false
    }

    /// One in-flight content block being assembled from deltas.
    struct OpenBlock {
        var header: [String: Any]
        var text = ""       // text_delta / thinking_delta
        var json = ""       // input_json_delta (partial JSON string)
        var signature = ""  // signature_delta (thinking)
    }

    private enum StreamOutcome {
        case success(StreamedMessage)
        case retry(after: Double?)
        case fatal
    }

    /// Sends the request as SSE, retrying once on transport errors, 429, and 5xx
    /// (honoring Retry-After, capped) — a transient blip otherwise aborts the whole
    /// multi-step task. A retry NEVER happens after an action already executed
    /// mid-stream: it would generate a fresh plan against a screen the half-finished
    /// turn already changed.
    private func streamMessage(_ request: URLRequest) async -> StreamedMessage? {
        for attempt in 0..<2 {
            switch await attemptStream(request, canRetry: attempt == 0) {
            case .success(let message): return message
            case .fatal: return nil
            case .retry(let after):
                try? await Task.sleep(for: .seconds(min(after ?? 1.0, 5)))
            }
        }
        return nil
    }

    private func attemptStream(_ request: URLRequest, canRetry: Bool) async -> StreamOutcome {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: request)
        } catch {
            guard canRetry else { return .fatal }
            Self.logger.info("step transport error — retrying once: \(error.localizedDescription, privacy: .public)")
            return .retry(after: nil)
        }
        guard let http = response as? HTTPURLResponse else { return .fatal }
        guard (200..<300).contains(http.statusCode) else {
            guard canRetry, http.statusCode == 429 || http.statusCode >= 500 else {
                Self.logger.error("step failed — HTTP \(http.statusCode)")
                return .fatal
            }
            Self.logger.info("step got HTTP \(http.statusCode) — retrying once")
            return .retry(after: http.value(forHTTPHeaderField: "retry-after").flatMap(Double.init))
        }

        var message = StreamedMessage()
        var open: [Int: OpenBlock] = [:]
        do {
            for try await line in bytes.lines {
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                guard let data = payload.data(using: .utf8),
                      let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let kind = event["type"] as? String else { continue }
                switch kind {
                case "message_start":
                    if let start = event["message"] as? [String: Any],
                       let usage = start["usage"] as? [String: Any] { message.usage = usage }
                case "content_block_start":
                    guard let index = event["index"] as? Int,
                          let header = event["content_block"] as? [String: Any] else { break }
                    open[index] = OpenBlock(header: header)
                case "content_block_delta":
                    guard let index = event["index"] as? Int, var block = open[index],
                          let delta = event["delta"] as? [String: Any] else { break }
                    switch delta["type"] as? String {
                    case "text_delta": block.text += delta["text"] as? String ?? ""
                    case "thinking_delta": block.text += delta["thinking"] as? String ?? ""
                    case "input_json_delta": block.json += delta["partial_json"] as? String ?? ""
                    case "signature_delta": block.signature = delta["signature"] as? String ?? block.signature
                    default: break
                    }
                    open[index] = block
                case "content_block_stop":
                    guard let index = event["index"] as? Int,
                          let block = open.removeValue(forKey: index) else { break }
                    let finished = Self.finishedBlock(block)
                    message.content.append(finished)
                    switch await deliver(finished) {
                    case .skipped:
                        break
                    case .delivered:
                        message.deliveredIndices.insert(message.content.count - 1)
                        message.deliveredActions += 1
                    case .aborted:
                        message.aborted = true
                        return .success(message)
                    }
                case "message_delta":
                    if let delta = event["delta"] as? [String: Any],
                       let stop = delta["stop_reason"] as? String { message.stopReason = stop }
                    if let usage = event["usage"] as? [String: Any] {
                        message.usage.merge(usage) { _, new in new }
                    }
                case "message_stop":
                    return .success(message)
                case "error":
                    Self.logger.error("stream error event: \(payload, privacy: .public)")
                    return salvage(message, canRetry: canRetry)
                default:
                    break  // ping and future event types
                }
            }
            // Stream ended without message_stop.
            return salvage(message, canRetry: canRetry)
        } catch {
            Self.logger.error("stream broke mid-message: \(error.localizedDescription, privacy: .public)")
            return salvage(message, canRetry: canRetry)
        }
    }

    /// A stream died early. Retrying is only safe while nothing acted on the
    /// screen and no tool call completed — otherwise keep the finished blocks
    /// (blocks finish strictly in order, so everything before the one in flight
    /// is whole) and let the loop continue from the next screenshot.
    private func salvage(_ message: StreamedMessage, canRetry: Bool) -> StreamOutcome {
        var message = message
        let hasToolUse = message.content.contains { ($0["type"] as? String) == "tool_use" }
        if message.deliveredActions == 0, !hasToolUse {
            return canRetry ? .retry(after: nil) : .fatal
        }
        if message.stopReason == nil, hasToolUse { message.stopReason = "tool_use" }
        Self.logger.info("salvaged \(message.content.count) blocks from a broken stream")
        return .success(message)
    }

    /// Closes one block: text/thinking/tool_use are reassembled into the exact
    /// dictionaries the non-streaming API returns (thinking keeps its signature —
    /// history must replay byte-faithful); anything else passes through as-is.
    nonisolated static func finishedBlock(_ block: OpenBlock) -> [String: Any] {
        switch block.header["type"] as? String {
        case "text":
            return ["type": "text", "text": block.text]
        case "thinking":
            var out: [String: Any] = ["type": "thinking", "thinking": block.text]
            if !block.signature.isEmpty { out["signature"] = block.signature }
            return out
        case "tool_use":
            var out = block.header
            let json = block.json.isEmpty ? "{}" : block.json
            out["input"] = ((try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]) ?? [:]
            return out
        default:
            return block.header  // redacted_thinking and friends
        }
    }

    private enum Delivery { case skipped, delivered, aborted }

    /// Hands one completed block to the sink if it's immediately actionable.
    /// Narration text streams but is never marked delivered (step()'s post-pass
    /// still collects it for the step text). zoom/screenshot are observation
    /// directives the caller answers with a capture, and use_skill/harness calls
    /// carry audit + gating in the post-pass — none of those stream.
    private func deliver(_ block: [String: Any]) async -> Delivery {
        guard let sink = streamSink else { return .skipped }
        switch block["type"] as? String {
        case "text":
            guard let text = block["text"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .skipped }
            return await sink(.text(text)) ? .skipped : .aborted
        case "tool_use":
            let input = block["input"] as? [String: Any] ?? [:]
            let action: CUAction?
            switch block["name"] as? String {
            case "open_app": action = (input["name"] as? String).map { CUAction.openApp($0) }
            case "open_url": action = (input["url"] as? String).map { CUAction.openURL($0) }
            case "highlight": action = parseHighlight(input)
            case "computer": action = parseAction(input)
            default: return .skipped
            }
            guard let action else { return .skipped }
            if case .zoom = action { return .skipped }
            if case .screenshot = action { return .skipped }
            return await sink(.action(action)) ? .delivered : .aborted
        default:
            return .skipped
        }
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
