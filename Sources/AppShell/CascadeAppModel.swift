import AgentOrchestrator
import AppKit
import ApplicationServices
import CascadeMemory
import Combine
import ComputerUseKit
import Foundation
import ImageIO
import MacContextKit
import ProviderKit
import SandboxKit
import WasteDetection

/// One real Q&A turn over local context — drives the Reel "Ask about this moment" thread.
/// A moment an answer was grounded in — rendered as a proof chip under the
/// reply; clicking it jumps the Reel to that exact point in time.
public struct CitedMoment: Identifiable, Sendable, Equatable {
    public let id: Int64
    public let appName: String
    public let capturedAt: Date
    public let imagePath: String?

    public init(id: Int64, appName: String, capturedAt: Date, imagePath: String?) {
        self.id = id
        self.appName = appName
        self.capturedAt = capturedAt
        self.imagePath = imagePath
    }
}

public struct QATurn: Identifiable, Sendable {
    public let id = UUID()
    public let question: String
    public let answer: String
    public var citations: [CitedMoment] = []
}

/// A background agent running in the isolated web sandbox.
public struct BackgroundAgentRun: Identifiable, Sendable {
    public let id: UUID
    public let task: String
    /// Set when this run deploys a saved agent — completion feeds its run count.
    public var agentID: Int64?
    // No status/snapshot/done/result: the live watch box renders the agent's own
    // WKWebView, so those were write-only — the snapshot in particular retained a
    // PNG per step that no view ever read.
}

@MainActor
public final class CascadeAppModel: ObservableObject {
    public enum Tab: String, CaseIterable, Identifiable {
        case reel = "Reel"
        case cascades = "Cascades"
        case manager = "Manager"

        public var id: String { rawValue }
    }

    @Published public var selectedTab: Tab = .reel
    @Published public var showSettings = false
    /// First-run setup: permissions + keys, shown once over everything until
    /// dismissed (reopenable from Settings). Without it a new user lands on an
    /// empty Reel with no idea why nothing records.
    @Published public var showOnboarding: Bool
    @Published public var prefersDark = true
    /// Declined workflow signatures — "no" must survive a relaunch (persisted).
    @Published private var dismissedWasteSignatures: Set<String> {
        didSet { Self.persist(dismissedWasteSignatures, key: Self.dismissedWasteKey, defaults: defaultsStore) }
    }
    private static let dismissedWasteKey = "cascade.dismissedWaste"

    private static func persist(_ values: Set<String>, key: String, defaults: UserDefaults) {
        // Capped so years of declines can't grow the defaults plist unbounded.
        defaults.set(Array(values.suffix(300)), forKey: key)
    }

    private static func restoreSet(key: String, defaults: UserDefaults) -> Set<String> {
        Set(defaults.stringArray(forKey: key) ?? [])
    }
    @Published public private(set) var contexts: [RecordedContext] = []
    @Published public private(set) var searchResults: [RecordedContext] = []
    @Published public private(set) var searchQuery: String = ""
    @Published public private(set) var audit: [AuditEvent] = []
    /// The raw recall layer: every repeated sequence the detector found, before the
    /// automatable filter and curation. Kept observable so the pipeline is testable.
    @Published public private(set) var detectedWaste: [DetectedWaste] = []
    /// The curated, judged, human-named view of `detectedWaste` — what the manager's
    /// review queue shows (the only place detected workflows surface to a person).
    @Published public private(set) var curatedWaste: [CuratedAgent] = []
    @Published public private(set) var agents: [CascadeAgent] = []
    @Published public private(set) var answer: String = "Ask Cascade what happened in the local record."
    @Published public private(set) var conversation: [QATurn] = []
    @Published public private(set) var thinking = false
    @Published public private(set) var statusLine: String = "Starting Cascade."
    @Published public private(set) var hasAnthropicKey = false
    @Published public private(set) var keyMessage = "Claude key is not connected."
    @Published public private(set) var hasOpenAIKey = false
    @Published public private(set) var openAIKeyMessage = "OpenAI key is not connected (for GPT-Realtime voice)."
    @Published public private(set) var hasGroqKey = false
    @Published public private(set) var groqKeyMessage = "Groq key is not connected (for the cheaper Groq models)."
    @Published public private(set) var hasOpenRouterKey = false
    @Published public private(set) var openRouterKeyMessage = "OpenRouter key is not connected (runs the Qwen3.7 Plus Scout brain + hosted UI-TARS grounding)."
    @Published public private(set) var permissionDiagnostics = PermissionProbe.diagnostics()
    @Published public private(set) var screenAgentReady = false
    @Published public private(set) var screenAgentMessage = "Checking real-screen driver health."
    @Published public private(set) var agentRunning = false
    @Published public private(set) var agentMessage = "Connect a Claude key and a goal, then watch Cascade use this Mac."
    @Published public private(set) var teachMessage = "Ask “where do I find X” and Cascade points at it on your screen."
    /// Teach-once: true while the user is demonstrating a task by hand for Cascade to
    /// turn into an agent. Recording is already always-on — this only BRACKETS a time
    /// range and reroutes any narration into the intent buffer.
    @Published public private(set) var teachingMode = false
    /// The live teaching banner ("Teaching — do the task…", "Saving…", or the
    /// nothing-repeatable result). Kept separate from `teachMessage` so the assist
    /// agent's status and the demonstration status never clobber each other.
    @Published public private(set) var teachStatus: String?
    /// The curated agent built from the last demonstration, awaiting the user's review
    /// in the preview sheet (nil = no sheet). They pick "Add to my agents" or "Send to
    /// manager" from there.
    @Published public var teachPreview: CuratedAgent?
    /// Demonstrations the employee chose to route to the MANAGER instead of adding
    /// directly — they surface in the manager's review queue alongside auto-detected
    /// workflows. In-memory for v1 (a taught recipe has no repeated waste behind it,
    /// so unlike auto-detected proposals it does not re-derive on relaunch).
    @Published public private(set) var taughtForReview: [CuratedAgent] = []
    /// When the demonstration started; the bracket's lower bound.
    private var teachStartedAt: Date?
    /// Everything the user narrated during the demonstration, in order — joined into
    /// the curator's `statedIntent` (their own words = the best naming signal).
    private var teachIntentBuffer: [String] = []

    /// The companion-cursor colorway (cursor, trail, ripple, and highlight marquee
    /// all follow it). Picked from the notch; persists across launches.
    @Published public var cursorTheme: CursorTheme {
        didSet {
            guidanceOverlay.setTheme(cursorTheme)
            defaultsStore.set(cursorTheme.rawValue, forKey: Self.cursorThemeKey)
        }
    }
    private static let cursorThemeKey = "cascade.cursorTheme"

    /// Power harness: lets the assist agent run shell commands, AppleScript, and
    /// file writes directly (read-only file tools are always on). Explicit
    /// Settings opt-in, default OFF; every call is audited verbatim and the
    /// destructive-command deny-list applies regardless.
    @Published public var powerHarnessEnabled: Bool {
        didSet { defaultsStore.set(powerHarnessEnabled, forKey: Self.powerHarnessKey) }
    }
    private static let powerHarnessKey = "cascade.powerHarness"

    /// Thinking effort for the on-screen cursor agent — "medium" (Anthropic's
    /// benchmarked CU default) or "low". A runtime toggle, not a recompile, so
    /// the long-deferred low-vs-medium A/B is one switch in Settings; the new
    /// TTFT + assist.timing telemetry is what makes that A/B measurable. Default
    /// "medium" → zero behaviour change until the user flips it.
    @Published public var cuEffort: String {
        didSet { defaultsStore.set(cuEffort, forKey: Self.cuEffortKey) }
    }
    private static let cuEffortKey = "cascade.cuEffort"

    /// On-screen agent backend: "claude" (Opus computer-use) or "scout" (Llama 4
    /// Scout via Groq + the grounder). Read by `onScreenBackendIsScout()`.
    @Published public var onScreenBackend: String {
        didSet { defaultsStore.set(onScreenBackend, forKey: "cascade.onScreenBackend") }
    }
    /// Per-region Hamming threshold for "this action changed nothing on screen" —
    /// much tighter than the recorder's blink-tolerant dedup (`regionSkipThreshold`
    /// = 5). A dead click yields a near byte-identical frame; any real change
    /// shifts many bits, so a tight bound keeps a small SUCCESSFUL change from
    /// being mislabeled no-effect (the false positive that would make the agent
    /// undo/redo a step that actually worked).
    static let noEffectThreshold = 2

    public let store: CascadeStore
    public let driver: LocalMacDriver
    public let recorder: ContextRecorder
    public let dock: ControlDockModel
    public let hotkey: UseDeviceHotkeyMonitor
    /// ⌥⌃T starts/stops a Teach-once demonstration — the same monitor type as the
    /// use-device hotkey, just a different chord.
    public let teachHotkey: UseDeviceHotkeyMonitor
    private let orchestrator: CascadeOrchestrator
    private let keyStore = AnthropicKeyStore()
    private let openAIKeyStore = OpenAIKeyStore()
    private let groqKeyStore = GroqKeyStore()
    private let openRouterKeyStore = OpenRouterKeyStore()
    public let guidanceOverlay = GuidanceOverlayController()
    public let voice = RealtimeVoice()
    public let pushToTalk = PushToTalkMonitor()
    /// Background agents running in the isolated web sandbox.
    @Published public private(set) var backgroundAgents: [BackgroundAgentRun] = []
    private var sandboxRuntimes: [UUID: BackgroundWebAgent] = [:]
    /// How many background web agents may run at once (each = a WKWebView + a CU loop).
    static let maxConcurrentSandboxAgents = 8
    private let sandboxBox = SandboxBoxController()
    private let elementLocator = ElementLocator()
    /// Per-app cheat sheets (tiptour-macos Markdown App Skills port): prompt
    /// instructions plus runtime policies, matched against the frontmost app.
    /// User files at App Support/Cascade/Skills override the bundled ones.
    private var appSkills = AppSkillRegistry.load()
    /// Rolling conversation memory for the voice/hotkey assistant — follow-up
    /// questions resolve against it ("now reply to the first one").
    public let assistMemory = AssistMemory()
    /// Where the previous teach turn went, so a referential follow-up ("the second
    /// one too") inherits the route instead of being re-classified from scratch.
    private enum TeachRoute { case action, locate }
    private var lastTeachRoute: TeachRoute?
    /// Bumped by every new teach turn. Running assist loops check it each
    /// iteration and stand down when superseded — without this, the new turn's
    /// `runState.reset()` could revive a loop the barge-in just stopped, leaving
    /// two loops fighting over the same cursor.
    private var assistGeneration = 0
    /// Set when the agent used its highlight tool during the current run, so the
    /// end-of-task cleanup doesn't erase the box the user asked to see (it fades
    /// on the overlay's own timer instead).
    private var agentDidHighlight = false
    private var cancellables: Set<AnyCancellable> = []
    private var lastSettingsOpen = Date.distantPast
    /// Tracks an explicit Pause so always-on auto-start doesn't immediately undo it.
    private var userPaused = false
    /// False in tests/headless: the model is built with an injected store +
    /// orchestrator and starts NO hardware — no CGEvent taps, no screen capture, no
    /// scheduler, no audio I/O — so the orchestration logic can be exercised in
    /// isolation. Production leaves it true and everything starts as before.
    private let startsSubsystems: Bool
    /// Injectable so tests get an ephemeral suite instead of polluting (and reading
    /// stale state from) the real `.standard` defaults. Production uses `.standard`.
    private let defaultsStore: UserDefaults

    public init(
        store injectedStore: CascadeStore? = nil,
        orchestrator injectedOrchestrator: CascadeOrchestrator? = nil,
        defaults: UserDefaults = .standard,
        startsSubsystems: Bool = true
    ) throws {
        self.startsSubsystems = startsSubsystems
        self.defaultsStore = defaults
        let store = try injectedStore ?? CascadeStore()
        self.store = store
        cursorTheme = defaults.string(forKey: Self.cursorThemeKey)
            .flatMap(CursorTheme.init(rawValue:)) ?? .green
        powerHarnessEnabled = defaults.bool(forKey: Self.powerHarnessKey)
        // The "Cursor agent speed" picker was removed and CLAUDE.md puts effort:low
        // "off the table" (it makes the agent dumb), so pin medium — ignoring any
        // stale `cascade.cuEffort = "low"` a prior build's picker may have persisted.
        cuEffort = "medium"
        onScreenBackend = defaults.string(forKey: "cascade.onScreenBackend") ?? "claude"
        dismissedWasteSignatures = Self.restoreSet(key: Self.dismissedWasteKey, defaults: defaults)
        showOnboarding = !defaults.bool(forKey: Self.onboardedKey)
        recorder = ContextRecorder(store: store)
        dock = ControlDockModel()
        hotkey = UseDeviceHotkeyMonitor()
        teachHotkey = UseDeviceHotkeyMonitor(hotkey: UseDeviceHotkey(
            keyCode: 17, requiredModifiers: [.control, .option], label: "Control-Option-T"))
        orchestrator = injectedOrchestrator ?? CascadeOrchestrator(store: store)
        driver = LocalMacDriver(store: store)
        recorder.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // Stream newly recorded moments into the Reel live as the continuous
        // recorder captures them, without re-querying the whole table.
        recorder.$status
            .compactMap(\.latestContext)
            .removeDuplicates { $0.id == $1.id }
            .sink { [weak self] context in self?.ingestLiveMoment(context) }
            .store(in: &cancellables)
        dock.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        hotkey.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        hotkey.pressed
            .sink { [weak self] in
                self?.beginUseDeviceIntent(source: "hotkey")
            }
            .store(in: &cancellables)
        teachHotkey.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        teachHotkey.pressed
            .sink { [weak self] in
                self?.toggleTeaching()
            }
            .store(in: &cancellables)
        if startsSubsystems { hotkey.start(); teachHotkey.start() }
        // didSet doesn't fire during init — hand the restored theme to the overlay.
        guidanceOverlay.setTheme(cursorTheme)
        voice.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        voice.onUtterance = { [weak self] phrase in
            self?.teach(question: phrase)
        }
        // Barge-in: the user talking over the agent halts whatever it's doing.
        voice.onInterrupt = { [weak self] in
            self?.driver.runState.requestStop()
            self?.guidanceOverlay.hide()
        }
        pushToTalk.onPress = { [weak self] in
            self?.voice.beginTalking()
            // The user is about to ask for something on screen — warm the capture
            // pipeline AND the TLS connection to the API now, so neither the
            // screenshot nor the first model request pays a cold start when they
            // finish speaking.
            ScreenCaptureUtility.prewarm()
            AnthropicWarmup.prewarm()
        }
        pushToTalk.onRelease = { [weak self] in self?.voice.endTalking() }
        if startsSubsystems {
            pushToTalk.start()
            startScheduler()
        }
        dock.onStop = { [weak self] in
            guard let self else { return }
            self.driver.runState.requestStop()
            self.agentMessage = "Stopped. Control returned to you."
            Task { await self.driver.stop() }
        }
        refreshKeyStatus()
        if startsSubsystems { Task { await refreshAll() } }
    }

    public func refreshAll() async {
        do {
            refreshPermissionState()
            await refreshComputerUseHealth()
            contexts = try await store.recentContexts(limit: 80)
            audit = try await store.recentAudit(limit: 80)
            agents = try await orchestrator.agents()
            detectedWaste = try await orchestrator.detectedWaste(webAppIdentity: Self.webAppIdentity)
            // Only genuinely repeated, time-saving workflows (the automatable filter)
            // reach the curator and the manager's review queue.
            curatedWaste = await orchestrator.curate(detectedWaste.filter(Self.isAutomatable))
            statusLine = recorder.status.message
        } catch {
            statusLine = error.localizedDescription
        }
    }

    public func startRecording() {
        userPaused = false
        refreshPermissionState()
        recorder.start()
        Task { await refreshAll() }
    }

    public func pauseRecording() {
        userPaused = true
        recorder.pause()
        Task { await refreshAll() }
    }

    /// Always-on: begin recording automatically whenever Screen Recording is
    /// granted (on launch and right after the user grants it), unless the user has
    /// explicitly paused. `recorder.start()` is idempotent, so repeated calls are
    /// safe.
    private func autoStartIfPermitted() {
        guard startsSubsystems, !userPaused,
              recorder.status.permissions.canRecordContext,
              !recorder.status.running else { return }
        recorder.start()
    }

    public func captureOnce() {
        refreshPermissionState()
        recorder.captureOnce()
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            await refreshAll()
        }
    }

    /// The Reel chat. Replies briefly. Questions that refer to the current screen
    /// ("where is the send button", "show me X") point the companion cursor at the
    /// element AND reply; everything else is a brief grounded answer about the record.
    public func ask(_ question: String) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if Self.refersToScreen(trimmed) {
            showOnScreen(trimmed)
            return
        }

        answer = "Searching your record…"
        thinking = true
        // Recent turns let "and after that?" follow-ups inherit context.
        let history = conversation.suffix(4).map { (user: $0.question, assistant: $0.answer) }
        Task {
            var result: String
            var citations: [CitedMoment] = []
            var answered = true
            do {
                let recordAnswer = try await orchestrator.askRecord(trimmed, conversation: Array(history))
                // Show the FULL answer in the text thread. brief() is the ~280-char
                // SPOKEN cap (voice replies stay short) — applying it here chopped
                // multi-item summaries mid-word ("2. **Keyn…") even though the chat
                // bubble is scrollable and has no line limit.
                result = recordAnswer.text.trimmingCharacters(in: .whitespacesAndNewlines)
                citations = await orchestrator.citedMoments(recordAnswer.citedMomentIDs).map {
                    CitedMoment(id: $0.id, appName: $0.appName, capturedAt: $0.capturedAt, imagePath: $0.imagePath)
                }
            } catch {
                result = error.localizedDescription
                answered = false
            }
            answer = result
            conversation.append(QATurn(question: trimmed, answer: result, citations: citations))
            // One brain: the voice agent sees what was said in chat, and vice
            // versa. Errors stay short-lived context, never archived.
            assistMemory.remember(user: trimmed, assistant: result, ok: answered)
            thinking = false
        }
    }

    // MARK: - Citation → Reel jump

    /// When set, the Reel scrubs to the moment nearest this time (then clears).
    @Published public var reelJumpTarget: Date?

    /// Click a proof chip → see the actual recorded moment in the Reel.
    public func jumpToMoment(_ citation: CitedMoment) {
        searchQuery = ""
        selectedTab = .reel
        reelJumpTarget = citation.capturedAt
        Task { _ = try? await store.appendAudit(AuditEvent(actor: "employee", action: "reel.jump", detail: "citation #\(citation.id)")) }
    }

    /// Jump the Reel to a recorded time — the Teach-once provenance chip's "show me
    /// the recording this agent was built from".
    public func jumpToReel(at date: Date) {
        searchQuery = ""
        selectedTab = .reel
        reelJumpTarget = date
        Task { _ = try? await store.appendAudit(AuditEvent(actor: "employee", action: "reel.jump", detail: "teach provenance")) }
    }

    /// Captures the current screen, points the blue companion cursor at the element
    /// the user asked about, and adds a brief reply to the chat. Falls back to a text
    /// answer when there's no key or no screen access.
    private func showOnScreen(_ q: String) {
        thinking = true
        answer = "Looking at your screen…"
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        Task {
            defer { thinking = false }
            guard hasAnthropicKey else {
                await answerAsText(q)
                return
            }
            guard let screen else {
                conversation.append(QATurn(question: q, answer: "Grant Screen Recording so I can see your screen."))
                return
            }
            let res = AgentResolution.best(forWidth: Int(screen.frame.width), height: Int(screen.frame.height))
            guard let shot = await ScreenCaptureUtility.captureCursorScreenJPEG(width: res.w, height: res.h) else {
                conversation.append(QATurn(question: q, answer: "Grant Screen Recording so I can see your screen."))
                return
            }
            let guidance = await elementLocator.guide(
                screenshot: shot,
                question: q,
                displayWidthPoints: Int(screen.frame.width),
                displayHeightPoints: Int(screen.frame.height),
                conversation: assistMemory.historyForAPI()
            )
            if let local = guidance.point {
                let global = CGPoint(x: screen.frame.minX + local.x, y: screen.frame.minY + local.y)
                guidanceOverlay.present(atGlobalPoint: global, label: "this one")
                assistMemory.rememberPointed(label: q, globalPoint: global)
                _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "reel.point", detail: q))
            } else {
                guidanceOverlay.hide()
            }
            conversation.append(QATurn(question: q, answer: Self.brief(guidance.speech)))
            // One brain: chat pointing lands in the same memory the voice agent uses.
            assistMemory.remember(user: q, assistant: Self.brief(guidance.speech), ok: guidance.point != nil)
        }
    }

    private func answerAsText(_ q: String) async {
        let result = (try? await orchestrator.ask(q)) ?? "I couldn't answer that from the local record."
        conversation.append(QATurn(question: q, answer: Self.brief(result)))
    }

    /// Whether a chat question is about the *current screen* (point the cursor) vs.
    /// the *recorded past* (answer as text). Retrospective phrasing wins so that
    /// "what did I do today" is never mistaken for a screen command.
    private static func refersToScreen(_ text: String) -> Bool {
        let t = text.lowercased()
        let retrospective = ["what did", "what was", "what have", "did i ", "summar", "recap",
                             "today", "yesterday", "earlier", "this week", "last week", "history", "happened"]
        if retrospective.contains(where: { t.contains($0) }) { return false }
        let screenReferring = ["where", "show me", "show the", "find ", "which ", "point", "take me to",
                              "locate", "highlight", "how do i", "how can i", "open ", "click", "button",
                              "menu", "icon", " tab", "field", "on screen", "on my screen", "this screen"]
        return screenReferring.contains { t.contains($0) }
    }

    /// Caps a reply so the chat stays brief even if a provider rambles.
    private static func brief(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 280 else { return trimmed }
        return String(trimmed.prefix(280)).trimmingCharacters(in: .whitespaces) + "…"
    }

    public func beginUseDeviceIntent(source: String = "manual") {
        selectedTab = .reel
        dock.show(
            title: "Cascade is listening",
            detail: "Say or type what you want done — Esc stops it at any time."
        )
        Task {
            _ = try? await store.appendAudit(AuditEvent(actor: "employee", action: "device.intent", detail: source))
            await refreshAll()
        }
    }

    /// Captures the current screen (excluding Cascade's own windows), asks Claude's
    /// Computer Use tool *where* the target is, and flies the blue companion cursor
    /// to it. If the request was a command ("open / click / do X"), it also
    /// **performs the click** (gated on Accessibility + Input Monitoring); otherwise
    /// it just points and explains ("where / how / show me X").
    /// Spawns a background agent that carries out `task` inside the isolated web
    /// sandbox (its own hidden browser), streaming progress to a small watch box —
    /// the user keeps using their Mac while it works.
    /// Returns true if a background agent actually started — false if the request was
    /// refused (too vague, no key, or the concurrency cap). The scheduler relies on
    /// this so a cap-refusal doesn't consume the agent's daily slot.
    @discardableResult
    public func createSandboxAgent(task: String, forAgent agentID: Int64? = nil) -> Bool {
        let trimmed = task.trimmingCharacters(in: .whitespacesAndNewlines)
        // Too vague to act on — ask rather than letting the agent wander (e.g. off
        // googling "how to create an agent"). Also catch a topic-LESS request — a bare
        // verb ending in a dangling preposition ("research about", "look up", "find")
        // where the voice trailed off — which otherwise runs and "completes" instantly.
        let words = trimmed.lowercased().split(separator: " ")
        let danglingTail: Set<String> = ["about", "for", "on", "regarding", "of", "at", "into", "to", "the", "a", "an", "up", "out"]
        let topicless = words.count < 2 || (words.last.map { danglingTail.contains(String($0)) } ?? true)
        if trimmed.count < 5 || topicless {
            teachMessage = "What should the background agent actually do? e.g. \"in the background, find the cheapest flight to Tokyo next month.\""
            voice.speak("What should the background agent research or do?")
            return false
        }
        guard hasAnthropicKey else {
            teachMessage = "Connect your Claude key in Settings first."
            showSettings = true
            return false
        }
        // Each agent owns a live WKWebView + a Computer Use loop; cap how many run at
        // once so the box stack and resource use stay sane. Refuse rather than queue —
        // the user can stop one and retry.
        guard sandboxRuntimes.count < Self.maxConcurrentSandboxAgents else {
            teachMessage = "Already running \(sandboxRuntimes.count) background agents — stop one before starting another."
            voice.speak("I'm already running a few background agents. Stop one first.")
            return false
        }
        let id = UUID()
        let runtime = BackgroundWebAgent()
        sandboxRuntimes[id] = runtime
        // The agent's pointer drives the box's native cursor overlay.
        runtime.onCursor = { [weak self] point in self?.sandboxBox.moveCursor(id, toPagePoint: point) }
        // Tag every audited row with this run's id so concurrent background agents (up to
        // the cap) can be told apart in the one shared audit log — without it parallel
        // runs' rows interleave with no way to attribute them.
        runtime.auditTag = String(id.uuidString.prefix(8))
        // Record every web action/turn so the background run is auditable, not a black box.
        runtime.onAudit = { [weak self] action, detail in
            guard let self else { return }
            Task { _ = try? await self.store.appendAudit(AuditEvent(actor: "agent", action: action, detail: String(detail.prefix(240)))) }
        }
        // Give the background Scout the SAME in-process harness the on-screen agent
        // has — file/shell tools + record recall — so a background run can reach the
        // user's local files and recorded screen history, not just the web. Pure
        // execution here; the agent applies its own STOP gate + audit. Power tools
        // stay behind the user's Power-harness opt-in; recall is read-only.
        runtime.harnessTier = powerHarnessEnabled ? .full : .readOnly
        runtime.recallEnabled = true
        runtime.harnessProvider = { [weak self] name, input in
            guard let self else { return "Cascade is shutting down — stop." }
            if RecordRecall.isRecallTool(name) {
                return await RecordRecall(store: self.store).perform(RecordRecall.Call(name: name, input: input))
            }
            guard let call = HarnessCall(name: name, input: input) else { return "Unknown harness tool “\(name)”." }
            return await AgentHarness.perform(call, powerEnabled: self.powerHarnessEnabled)
        }
        backgroundAgents.insert(BackgroundAgentRun(id: id, task: trimmed, agentID: agentID), at: 0)
        teachMessage = "Running in the background: \(trimmed)"
        assistMemory.remember(user: trimmed, assistant: "Started a background agent on it.")
        voice.speak("On it. I'll handle that in the background.")
        sandboxBox.show(id, webView: runtime.sandbox.webView, task: trimmed, onStop: { [weak self] in
            self?.stopSandboxAgent(id)
        }, onSteer: { [weak self] message in
            guard let self else { return }
            self.sandboxRuntimes[id]?.steer(message)
            // Audit the steer so its timing vs the agent's reaction is on the record.
            Task { _ = try? await self.store.appendAudit(AuditEvent(actor: "employee", action: "sandbox.steer", detail: String(message.prefix(160)))) }
        })
        Task {
            await runtime.run(task: trimmed) { [weak self] update in
                self?.applySandboxUpdate(id, update)
            }
        }
        return true
    }

    public func stopSandboxAgent(_ id: UUID) {
        // No-op if the run already finalized (e.g. Stop tapped during the box's brief
        // post-completion window) — otherwise we'd log a false "user stopped" against
        // a run that actually completed. The box is hidden by the tap handler anyway.
        guard sandboxRuntimes[id] != nil || backgroundAgents.contains(where: { $0.id == id }) else { return }
        sandboxRuntimes[id]?.stop()
        sandboxRuntimes[id] = nil
        // Drop the entry now: a late "Stopped." update then finds no entry and is a
        // no-op, so the stop is never re-announced or mis-counted.
        backgroundAgents.removeAll { $0.id == id }
        sandboxBox.hide(id)
        Task { _ = try? await store.appendAudit(AuditEvent(actor: "employee", action: "sandbox.stopped", detail: "user stopped a background agent")) }
    }

    private func applySandboxUpdate(_ id: UUID, _ update: BackgroundWebAgent.Update) {
        sandboxBox.updateStatus(id, update.status)
        guard update.done else { return }
        // The entry's presence is the "still live, not yet finalized" sentinel: a
        // stop removes it, so a late terminal update finds nothing and bails — no
        // double-report, no double-count.
        guard let entry = backgroundAgents.first(where: { $0.id == id }) else { return }
        let task = entry.task

        // Sign-in wall: keep the entry AND the runtime so Continue resumes at the
        // pending part of the plan — earlier parts' findings intact.
        if update.needsLogin {
            let said = update.result ?? "Sign-in needed — open the box and log in."
            teachMessage = said
            voice.speak(said)
            sandboxBox.requestLogin(id, message: said) { [weak self] in
                guard let self, let runtime = self.sandboxRuntimes[id] else { return }
                Task { await runtime.resume { [weak self] update in self?.applySandboxUpdate(id, update) } }
            }
            return
        }

        // Terminal: finalize once, then drop the entry so `backgroundAgents` stays
        // bounded across a long session.
        sandboxRuntimes[id] = nil
        backgroundAgents.removeAll { $0.id == id }
        // Stop, failure, or running out of steps report honestly and count NOTHING;
        // only a genuine completion says "done" and feeds the reclaimed-time math.
        let message = Self.sandboxCompletionMessage(for: update)
        teachMessage = message
        assistMemory.remember(user: "[background agent: \(task)]", assistant: message)
        voice.speak(message)
        let deployedAgentID = entry.agentID
        Task {
            await recordSandboxCompletion(deployedAgentID: deployedAgentID, update: update, task: task)
            if update.completed, deployedAgentID != nil { await refreshAll() }
        }
        // Leave the box up briefly so the user can glance at the result, then close it.
        Task { try? await Task.sleep(for: .seconds(5)); sandboxBox.hide(id) }
    }

    /// The honest user-facing line for a finished/aborted background run: a genuine
    /// completion is announced as done; a stop, failure, or step-limit shows its own
    /// status instead of a fake "Finished in the background."
    static func sandboxCompletionMessage(for update: BackgroundWebAgent.Update) -> String {
        let detail = update.result.flatMap { $0.isEmpty ? nil : $0 } ?? update.status
        return update.completed ? "Background agent done — \(detail)" : detail
    }

    /// Records a background run's end. ONLY a genuine completion increments the run
    /// counter + audits `agent.run.completed` — a stop / failure / step-limit must
    /// never inflate the reclaimed-time math (the on-screen replay path, which gates
    /// `markAgentRun` on `!stoppedEarly`, counts the same way).
    func recordSandboxCompletion(deployedAgentID: Int64?, update: BackgroundWebAgent.Update, task: String) async {
        if update.completed, let deployedAgentID {
            try? await store.markAgentRun(id: deployedAgentID)
            _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "agent.run.completed", detail: task))
        }
        let outcome = update.completed ? "completed" : "ended without completing"
        _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "sandbox.task", detail: "\(task) — \(outcome)"))
    }

    /// Did the user ask for a background agent ("create an agent…", "in the background",
    /// "in the sandbox")?
    private static func isBackgroundRequest(_ text: String) -> Bool {
        let t = text.lowercased()
        if t.range(of: #"\b(create|make|build|spin\s*up|run|start|set\s*up)\b.{0,16}\bagent\b"#,
                   options: .regularExpression) != nil { return true }
        return t.contains("in the background") || t.contains("background agent")
            || t.contains("in the sandbox") || t.contains("in a sandbox") || t.contains("local sandbox")
    }

    /// Recovers the actual task from a "create an agent that …" style request, robust
    /// to phrasing ("create me a background agent to …", "build an agent that …"). The
    /// trigger words must NOT leak into the task, or the agent ends up *researching*
    /// "how to create an agent" instead of doing the work.
    private static func backgroundTask(from text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip the leading "(please) create/make/build (me) a(n) (background)(computer-use)
        // agent (that/to/which/for/and)" preamble, keeping everything after it.
        let preamble = #"^(?:hey\s+)?(?:cascade[,\s]+)?(?:can you\s+|could you\s+|please\s+|i(?:'?d like| want)(?:\syou)?\sto\s+|go ahead and\s+)?(?:create|make|build|spin\s*up|run|start|set\s*up)\s+(?:me\s+)?(?:a|an)?\s*(?:new\s+)?(?:background\s+)?(?:computer[-\s]?use\s+)?agent\b\s*(?:that\s+(?:can\s+|will\s+)?|to\s+|which\s+(?:can\s+|will\s+)?|for\s+|and\s+|:\s*)?"#
        if let range = t.range(of: preamble, options: [.regularExpression, .caseInsensitive]) {
            t = String(t[range.upperBound...])
        }
        // Also strip the verb-less request form — "let / have / tell / get the agent
        // (to / that / which) …" — which the create-preamble above doesn't cover, so the
        // goal doesn't carry "let the agent …" cruft.
        let agentLet = #"^(?:hey\s+)?(?:cascade[,\s]+)?(?:can you\s+|could you\s+|please\s+|go ahead and\s+)?(?:let|have|tell|get|ask)\s+(?:the\s+|your\s+|our\s+)?agent\b\s*(?:to\s+|that\s+(?:can\s+|will\s+|should\s+)?|which\s+(?:can\s+|will\s+|should\s+)?|should\s+|and\s+)?"#
        if let range = t.range(of: agentLet, options: [.regularExpression, .caseInsensitive]) {
            t = String(t[range.upperBound...])
        }
        // Remove sandbox/background qualifiers wherever they appear.
        let qualifiers = [
            "and let it work in the background", "let it work in the background",
            "run in the background", "in the background", "as a background agent", "background agent",
            "in the local sandbox", "in a local sandbox", "in the sandbox", "in a sandbox", "local sandbox",
        ]
        for phrase in qualifiers {
            t = t.replacingOccurrences(of: phrase, with: " ", options: .caseInsensitive)
        }
        let cleaned = t
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,")))
        return cleaned
    }

    public func teach(question: String) {
        var q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { teachMessage = "Ask where something is, or what to do."; return }
        // Teach-once: while demonstrating, the user narrates what they're doing.
        // Those words are the agent's INTENT — captured for the curator, never run as
        // a command. Buffer them and stand down; nothing launches mid-demonstration.
        if teachingMode {
            teachIntentBuffer.append(q)
            teachStatus = "Teaching — heard “\(q.prefix(48))”. Press ⌥⌃T to finish."
            Task { _ = try? await store.appendAudit(AuditEvent(actor: "employee", action: "teach.intent", detail: String(q.prefix(120)))) }
            voice.done()
            return
        }
        // Voice gives us everything the user says — including acknowledgments
        // ("Sure!", "Ok.") and stop requests. Neither is a goal: an ack must not
        // supersede (and kill) a running task, and "stop" means STOP, not a new
        // run named "Stop". The audit log showed both arriving as tasks.
        let bare = q.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        if Self.stopPhrases.contains(bare) {
            if assistTaskRunning {
                driver.runState.requestStop()
                teachMessage = "Stopped. Control returned to you."
                dock.show(title: "Stopped", detail: teachMessage)
            } else {
                teachMessage = "Nothing is running."
            }
            voice.done()
            return
        }
        if Self.acknowledgmentPhrases.contains(bare) {
            if !assistTaskRunning { teachMessage = q }
            voice.done()
            return
        }
        // Transcription noise gate, structural: the mic hands teach() everything
        // it hears, and one-word interjections / filler sentences kept spawning
        // full runs — each superseding (killing) the real task ("Iii!" murdered
        // the 13:28Z Keynote run). Fragments are ignored; dangling lead-in
        // filler ("And create…") is stripped so the command underneath survives.
        switch VoiceFragmentGate.classify(q) {
        case .noise:
            if !assistTaskRunning { teachMessage = "I heard “\(q.prefix(60))” — tell me the full task." }
            Task { _ = try? await store.appendAudit(AuditEvent(actor: "system", action: "voice.fragment.ignored", detail: String(q.prefix(80)))) }
            voice.done()
            return
        case .goal(let cleaned):
            q = cleaned
        }
        guard hasAnthropicKey else {
            teachMessage = "Connect your Claude key in Settings first."
            showSettings = true
            return
        }
        // "create an agent that … in the background" → run it in the isolated web
        // sandbox instead of taking over the screen.
        if Self.isBackgroundRequest(q) {
            createSandboxAgent(task: Self.backgroundTask(from: q))
            return
        }
        // A re-fired identical/near-identical command while a run is in flight is the
        // voice re-triggering the SAME goal — it must NOT supersede (kill) the run.
        // (Stop is handled above; a genuinely different command still supersedes.)
        // The audit showed the same "Open Keynote and design…" task re-firing ~4s in
        // and restarting the run at the chooser every time.
        if assistTaskRunning, let active = assistTaskGoal, Self.isSameGoal(q, active) {
            teachMessage = "Already on it — “\(active.prefix(40))”."
            Task { _ = try? await store.appendAudit(AuditEvent(actor: "system", action: "voice.duplicate.ignored", detail: String(q.prefix(80)))) }
            voice.done()
            return
        }
        // Every new turn supersedes whatever an earlier turn is still doing. The
        // token is captured HERE, synchronously, so a stale task suspended in an
        // await can never pick up the newer generation after resuming.
        assistGeneration += 1
        let gen = assistGeneration
        // "Click that / open it" right after Cascade pointed at something: act on
        // the remembered element instantly — no vision round-trip (openclicky's
        // last-pointed-element pattern).
        if Self.isBareReferentialClick(q), let pointed = assistMemory.freshPointed() {
            clickRememberedElement(pointed, utterance: q, gen: gen)
            return
        }
        // "What did I do today?" → answer from the local record; no screen driving.
        if Self.isRetrospective(q) {
            teachMessage = "Checking your record…"
            Task {
                let answer = Self.brief((try? await orchestrator.ask(q)) ?? "I couldn't answer that from the local record.")
                guard assistGeneration == gen else { return }
                assistMemory.remember(user: q, assistant: answer)
                teachMessage = answer
                voice.speak(answer)
                voice.done()
            }
            return
        }
        // A referential follow-up inside a live conversation keeps the previous
        // turn's route: "now do the second one" after an action stays an action even
        // though the words alone wouldn't classify as one.
        let referential = Self.isReferential(q) && assistMemory.isFollowUpWindowOpen()
        let wantsAction = Self.isActionRequest(q) || (referential && lastTeachRoute == .action)
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        teachMessage = wantsAction ? "On it — looking at your screen…" : "Looking at your screen…"
        Task {
            // Capture once, directly at the model resolution, as JPEG — no OCR, no
            // full-resolution PNG. Every consumer (locator, agent episodes) declares
            // this exact size, so the frame passes through to base64 untouched.
            let res = AgentResolution.best(forWidth: Int(screen.frame.width), height: Int(screen.frame.height))
            guard let shot = await ScreenCaptureUtility.captureCursorScreenJPEG(width: res.w, height: res.h) else {
                teachMessage = "Grant Screen Recording so Cascade can see your screen."
                voice.speak("I need Screen Recording permission to see your screen.")
                voice.done()
                return
            }
            guard assistGeneration == gen else { return }  // superseded while capturing

            // Commands ("open X and do Y") run as a multi-step Computer Use loop so
            // Cascade finishes the whole task, not just the first click. Questions
            // ("where / how / show me X") stay single-shot: point and explain.
            if wantsAction {
                lastTeachRoute = .action
                await runAssistTask(goal: q, screen: screen, firstScreenshotPNG: shot, gen: gen)
                return
            }
            lastTeachRoute = .locate

            // "Where do I find/do X" → frame the region with the dashed marquee.
            let region = await locateRegionGrounded(
                screenshot: shot,
                question: q,
                displayWidthPoints: Int(screen.frame.width),
                displayHeightPoints: Int(screen.frame.height),
                conversation: assistMemory.historyForAPI()
            )
            guard assistGeneration == gen else { return }  // superseded while locating
            guard let local = region.rect else {
                // Not on the current screen — don't give up. Navigate (open the app/menu/
                // tab, scroll) to surface it, then frame it.
                await findAndReveal(question: q, screen: screen, firstScreenshotPNG: shot, gen: gen)
                return
            }

            let globalRect = CGRect(
                x: screen.frame.minX + local.minX, y: screen.frame.minY + local.minY,
                width: local.width, height: local.height
            )
            guidanceOverlay.highlight(globalRect: globalRect)
            guidanceOverlay.present(atGlobalPoint: CGPoint(x: globalRect.midX, y: globalRect.midY), label: "here")
            assistMemory.rememberPointed(label: q, globalPoint: CGPoint(x: globalRect.midX, y: globalRect.midY))
            assistMemory.remember(user: q, assistant: region.speech)
            _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "teach.region", detail: q))
            teachMessage = region.speech
            voice.speak(region.speech)
            voice.done()
            await refreshAll()
        }
    }

    /// Clicks the element Cascade just pointed at — the "click that" fast path.
    private func clickRememberedElement(_ pointed: AssistMemory.PointedElement, utterance: String, gen: Int) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointed.globalPoint) }) ?? NSScreen.main else { return }
        let working = "Clicking what I pointed at…"
        teachMessage = working
        Task {
            guard assistGeneration == gen else { return }  // superseded
            driver.runState.reset()
            let local = CGPoint(x: pointed.globalPoint.x - screen.frame.minX, y: pointed.globalPoint.y - screen.frame.minY)
            let said: String
            let clicked = await executeCU(.click(x: local.x, y: local.y), on: screen)
            if clicked {
                said = "Done — clicked it."
            } else {
                // executeCU surfaces permission failures into teachMessage; STOP
                // leaves it untouched.
                said = teachMessage == working ? "Stopped." : teachMessage
            }
            assistMemory.remember(user: utterance, assistant: said, ok: clicked)
            _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "teach.clickPointed", detail: "\(utterance) → \(pointed.label)"))
            teachMessage = said
            voice.speak(said)
            voice.done()
        }
    }

    /// "Click that / open it / press that one" — referential commands that act on
    /// the element Cascade last pointed at, with no new target named.
    private static func isBareReferentialClick(_ text: String) -> Bool {
        let t = text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " .,!"))
        let patterns = ["click that", "click it", "click there", "click this", "click that one",
                        "press that", "press it", "press that one", "open that", "open it",
                        "select that", "select it", "yes click", "tap that", "tap it"]
        return patterns.contains { t == $0 || t.hasSuffix($0) } && t.count <= 28
    }

    /// Does the utterance lean on the conversation ("it", "that one", "the first
    /// one", "now …") rather than naming its own target?
    private static func isReferential(_ text: String) -> Bool {
        let t = " " + text.lowercased() + " "
        let markers = [" it ", " that ", " them ", " those ", " this one", " that one",
                       " the first", " the second", " the third", " the last one",
                       " same ", " again ", " too ", " also ", " what about", " and the "]
        if markers.contains(where: { t.contains($0) }) { return true }
        return t.hasPrefix(" now ") || t.hasPrefix(" then ")
    }

    /// True while a screen-driving assist run is in flight — used to keep
    /// non-goals (acknowledgments) from superseding it and to route spoken
    /// stop requests to STOP instead of a new task.
    private var assistTaskRunning = false
    /// The goal of the in-flight run, so a re-fired identical command (the voice
    /// re-triggering the SAME task) doesn't supersede and restart it.
    private var assistTaskGoal: String?

    /// Whether two goals are the SAME command (an exact-ish voice re-fire of a
    /// running task), by word-set overlap. Only guards against a literally-identical
    /// command re-firing while a run is in flight; transcription-drift variants are
    /// NOT treated as the same (that "wording" approach was the wrong lever — the
    /// sudden stops aren't a re-fire problem). Both need ≥3 words. Pure + pinned.
    nonisolated static func isSameGoal(_ a: String, _ b: String) -> Bool {
        func words(_ s: String) -> Set<String> {
            Set(s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
        }
        let sa = words(a), sb = words(b)
        guard sa.count >= 3, sb.count >= 3 else { return false }
        let union = sa.union(sb).count
        return union > 0 && Double(sa.intersection(sb).count) / Double(union) >= 0.8
    }

    /// Utterances that mean "halt the run", never a goal.
    private static let stopPhrases: Set<String> = [
        "stop", "stop it", "stop that", "cancel", "cancel that", "never mind", "nevermind",
    ]

    /// Bare acknowledgments — conversational filler, never a task. The audit
    /// log showed "Sure!" and "Ok." arriving as goals and killing live runs.
    private static let acknowledgmentPhrases: Set<String> = [
        "ok", "okay", "k", "sure", "yes", "yep", "yeah", "thanks", "thank you",
        "cool", "nice", "good", "great", "perfect", "awesome", "alright", "all right",
    ]

    /// Carries out a spoken command across as many steps as it takes — open the app
    /// *and* do the thing — by driving Claude's Computer Use tool with a fresh
    /// screenshot after every action (observe → act → re-observe). Multi-part
    /// commands ("do X, then Y in another app") are split up front; each part runs
    /// as its own episode with its own step budget, and every finished part hands
    /// its one-line result to the next, so the orchestrator — not the model's stop
    /// reason — decides when the whole job is done. The blue companion cursor flies
    /// to each target so you can watch; STOP (and the caps) keep control with you,
    /// and every run is audited.
    private func runAssistTask(goal: String, screen: NSScreen, firstScreenshotPNG: Data, gen: Int) async {
        driver.runState.reset()
        assistTaskRunning = true
        assistTaskGoal = goal
        defer { assistTaskRunning = false; assistTaskGoal = nil }
        agentDidHighlight = false
        episodeAppActions = [:]
        ScreenCaptureUtility.prewarm()  // warm the capture pipeline for fast re-observes
        dock.show(title: "Cascade is doing it", detail: "\(goal) · press STOP to take control.")

        // Haiku keeps the up-front planning round-trip short, and trivially simple
        // commands skip the round-trip entirely — a one-part plan runs exactly like
        // the old single loop. The conversation memo lets the planner split
        // follow-ups ("now reply to the first one") against what just happened.
        let plan: [AgentSubtask]
        if Self.isSinglePartCommand(goal) {
            plan = [AgentSubtask(task: goal)]
        } else {
            // Downgraded helper task: Groq llama-3.3-70b when a key is set, else
            // Anthropic haiku. Planning is text-only, so no Claude needed.
            let h = TextHelperModel.resolve()
            plan = await AgentTaskPlanner(client: h.client, model: h.model).plan(
                for: goal, in: .onScreen, conversationContext: assistMemory.contextMemo()
            )
        }
        var findings: [(task: String, result: String)] = []
        var ranLongOn: String?
        var stalledOn: String?
        var interrupted = false
        var shot: Data? = firstScreenshotPNG

        // All frames in this run are captured at the model resolution as JPEG and
        // pass through to base64 untouched.
        let res = AgentResolution.best(forWidth: Int(screen.frame.width), height: Int(screen.frame.height))
        func freshShot() async -> Data? {
            await ScreenCaptureUtility.captureCursorScreenJPEG(width: res.w, height: res.h)
        }

        // Beginning-latency fix (2026-06-11m forensics): single-part goals skip
        // the planner and lose the parts loop's app pre-open below — the model
        // then spent two turns (~8s) opening the app its own goal names. Open it
        // before the first frame instead, so turn 1 already sees it frontmost.
        if let first = plan.first, first.app.isEmpty,
           let named = appSkills.appNamed(inGoal: goal) {
            await executeCU(.openApp(named), on: screen)
            if let fresh = await freshShot() { shot = fresh }
        }

        parts: for (index, sub) in plan.enumerated() {
            if driver.runState.isStopRequested || assistGeneration != gen { interrupted = true; break }
            let prefix = plan.count > 1 ? "Part \(index + 1)/\(plan.count) — " : ""

            // Jump straight to the part's app or site — instant, no vision round-trip.
            if !sub.app.isEmpty {
                await executeCU(.openApp(sub.app), on: screen)
                shot = nil
            } else if !sub.startURL.isEmpty {
                await executeCU(.openURL(sub.startURL), on: screen)
                shot = nil
            }
            if shot == nil {
                try? await Task.sleep(for: .milliseconds(260))
                shot = await freshShot()
            }
            guard let episodeShot = shot else {
                teachMessage = "I lost sight of the screen — try again."
                interrupted = true
                break
            }

            var attempt = await runAssistEpisode(
                goal: AgentTaskPlanner.goal(for: sub, index: index, total: plan.count, job: goal, findings: findings, firmer: false),
                prefix: prefix, screen: screen, firstScreenshotPNG: episodeShot, gen: gen
            )
            // The model replied without doing anything — usually narration or a
            // question. One firmer retry on a fresh frame; its answer stands.
            if case .finished(_, let acted) = attempt, !acted, !driver.runState.isStopRequested, assistGeneration == gen,
               let retryShot = await freshShot() {
                attempt = await runAssistEpisode(
                    goal: AgentTaskPlanner.goal(for: sub, index: index, total: plan.count, job: goal, findings: findings, firmer: true),
                    prefix: prefix, screen: screen, firstScreenshotPNG: retryShot, gen: gen
                )
            }

            switch attempt {
            case .finished(let text, _):
                findings.append((task: sub.task, result: text))
            case .stalled(let text):
                // The part did NOT complete — moving on to the next part would
                // build on a missing foundation. Stop here and say so honestly.
                findings.append((task: sub.task, result: text))
                stalledOn = sub.task
                break parts
            case .stopped, .failed:
                interrupted = true  // the episode already surfaced why
                break parts
            case .stepLimit:
                ranLongOn = sub.task
                break parts
            }
            shot = nil  // every later part observes a fresh frame
        }

        if !interrupted {
            let summary = AgentTaskPlanner.summary(findings: findings, skipped: [], ranLongOn: ranLongOn, stalledOn: stalledOn)
            teachMessage = summary
            // Don't say the same sentence twice — if the last progress line IS
            // the summary, the user already heard it.
            if summary.caseInsensitiveCompare(lastNarratedLine) != .orderedSame {
                voice.speak(summary)
            }
            lastNarratedLine = ""
            dock.show(title: ranLongOn == nil && stalledOn == nil ? "Done" : "Paused", detail: summary)
            assistMemory.remember(user: goal, assistant: summary)
            // A clean run in an app with no skill yet is exactly the material
            // skills are made of — draft one for the user to review.
            if ranLongOn == nil && stalledOn == nil { maybeDistillSkill(goal: goal, findings: findings) }
        } else {
            assistMemory.remember(user: goal, assistant: teachMessage, ok: false)
        }
        // Keep the agent's highlight up — erasing it at "Done" would defeat the
        // point of asking for it. The overlay fades it on its own timer.
        if !agentDidHighlight { guidanceOverlay.hide() }
        _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "assist.task", detail: goal))
        voice.done()
        await refreshAll()
    }

    private enum AssistEpisodeOutcome {
        case finished(String, acted: Bool)
        /// The model talked itself out (three idle turns) without declaring the
        /// part done. NOT success: later parts must not run on top of it.
        case stalled(String)
        case stopped
        case stepLimit
        case failed
    }

    /// Steps one Computer Use episode through a single part: observe → act →
    /// re-observe until the model finishes, the user stops it, or the step budget
    /// runs out. Returns the model's closing line plus whether it acted at all.
    /// Builds an on-screen assist agent at a given model. Factored out of
    /// `runAssistEpisode` so drift can rebuild on a stronger model mid-episode
    /// without duplicating the skill/harness/recall wiring. Handlers
    /// (streamSink / onThinkingPulse / onActionRefused) are set by the caller —
    /// they capture episode-local state.
    /// Skill provider shared by the Opus + Scout on-screen paths: resolve a skill by
    /// name, deny scripting playbooks unless the goal asks (the structural gate), and
    /// audit each pull.
    private func assistSkillProvider(goal: String) -> (String) -> String? {
        { [appSkills, store] name in
            guard let skill = appSkills.skill(named: name) else { return nil }
            if skill.explicitAskOnly && !AppSkill.goalAsksForScript(goal) {
                Task { _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "agent.skill.denied", detail: name)) }
                return """
                Skill \(skill.name) is unavailable for this task: it is a scripting \
                playbook and the user did not ask for a script. Do the work on \
                screen in the app's own UI — pull the app's other listed skills \
                instead. Do not write or run any script for this task: no script \
                editors, no shell, no writing files to open in the app.
                """
            }
            Task { _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "agent.skill", detail: name)) }
            return skill.promptBlock
        }
    }

    /// Harness + recall provider shared by both on-screen paths: recall tools route
    /// to performRecall (read-only memory); everything else to performHarness
    /// (file/shell, gated + audited).
    private func assistHarnessProvider(goal: String, gen: Int) -> @MainActor (String, [String: Any]) async -> String {
        { [weak self] name, input in
            guard let self else { return "Cascade is shutting down — stop." }
            if RecordRecall.isRecallTool(name) {
                return await self.performRecall(name: name, input: input, gen: gen)
            }
            return await self.performHarness(name: name, input: input, goal: goal, gen: gen)
        }
    }

    private func makeAssistAgent(model: String, goal: String, gen: Int) -> ComputerUseAgent {
        // Structural grounding split: when a grounder is configured (hosted UI-TARS
        // via OpenRouter, or Claude), Opus drives the screen by NAMING targets and
        // the runtime grounds each — the model never emits pixel coordinates. The
        // proven coordinate computer-tool path runs whenever no grounder is present
        // (no OpenRouter key) or the user opts out, so existing behaviour is intact.
        let grounder = assistGrounder()
        let mode: ComputerUseAgent.GroundingMode =
            (grounder != nil && Self.structuralGroundingEnabled()) ? .structural : .coordinate
        let agent = ComputerUseAgent(
            model: model,
            effort: cuEffort,
            environmentNote: ComputerUseAgent.foregroundBrowserNote + "\n\n" + AgentDateContext.line(),
            skillProvider: assistSkillProvider(goal: goal),
            // Direct-Mac tools beside the computer tool: find/read is always on;
            // run/script/write only with the user's Power harness opt-in.
            harnessTier: powerHarnessEnabled ? .full : .readOnly,
            harnessProvider: assistHarnessProvider(goal: goal, gen: gen),
            // Let the agent recall what the user already saw on screen — the whole
            // point of a context recorder. The same in-process tools the Ask panel
            // hunts the record with, so a retrospective goal resolves before acting.
            recallEnabled: true,
            // Grounding split: the grounder locates named targets. In structural
            // mode it backs click_target/fill_target/scroll (the model never emits
            // coordinates); in coordinate mode it backs the optional fill_target aid.
            grounder: grounder,
            groundingMode: mode
        )
        // Pre-action safety gate (default OFF): refuse irreversible quit/trash keys
        // unless the goal asks. Set here so it re-applies when escalation rebuilds
        // the agent on Opus. Opt in via `cascade.guardIrreversibleActions`.
        agent.guardIrreversibleActions = Self.guardIrreversibleEnabled()
        return agent
    }

    /// Whether the structural grounding split is the active on-screen mode. ON by
    /// default whenever a grounder is configured (Opus names targets, the grounder
    /// locates) — opt out with `cascade.onScreenGrounding = "coordinate"` to A/B
    /// against the proven computer-tool path. See [[cascade-cu-downgrade-research]].
    static func structuralGroundingEnabled() -> Bool {
        UserDefaults.standard.string(forKey: "cascade.onScreenGrounding") != "coordinate"
    }

    /// Whether the pre-action irreversible-key gate is armed — refuse quit /
    /// force-quit / log-out / empty-Trash keys (unless the goal itself asks for
    /// them). OFF by default; opt in with `cascade.guardIrreversibleActions = true`.
    /// Best suited to unattended / scheduled runs where no one is watching to hit
    /// STOP and a stray cmd+Q silently abandons the task. See `irreversibleRefusal`.
    static func guardIrreversibleEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: "cascade.guardIrreversibleActions")
    }

    /// Builds the on-screen grounder. ON by default — opt out with
    /// `cascade.visualGrounder = false`. Backend defaults to "uitars": **hosted
    /// UI-TARS-1.5-7B over OpenRouter** (OpenAI-compatible), so end users never run
    /// a 7B model locally. Authenticates with the OpenRouter key in the Keychain;
    /// with no key it returns nil — the agent then runs the proven coordinate
    /// computer-tool path, never broken. Set `cascade.visualGrounder.backend =
    /// "claude"` to ground with the cloud ElementLocator instead (zero setup, costs
    /// a Claude call per locate). The grounder MODEL is swappable without a rebuild
    /// via `cascade.visualGrounder.model` (e.g. UI-Venus-1.5 / Holo1.5 once a host
    /// serves them — see docs/AGENT_FAILURE_RATE_RESEARCH.md), with an explicit
    /// `…endpoint` (a NEW key — the old `…uitarsURL` once inherited a stale
    /// dead-localhost value and stalled every run) and a `…coordSpace`
    /// (smartResize | sent | normalized) for models that don't share UI-TARS's
    /// Qwen2.5-VL space. All default to the proven hosted UI-TARS over OpenRouter.
    /// See [[cascade-cu-downgrade-research]].
    ///
    /// The chosen visual grounder is wrapped in a `MixtureGrounder` (AX-first, ON by
    /// default; `cascade.mixtureGrounding = false` to disable) so labeled chrome
    /// controls resolve structurally — free, exact, no transport flakiness — and only
    /// canvas/custom elements fall through to the visual model. Instance method so it
    /// can pass the live `appSkills` registry (the mixture grounder skips AX on the
    /// apps that registry flags `axUnreliable`).
    func assistGrounder() -> VisualGrounder? {
        let d = UserDefaults.standard
        // Default ON: unset → enabled; explicit false → disabled.
        let enabled = (d.object(forKey: "cascade.visualGrounder") as? Bool) ?? true
        guard enabled else { return nil }
        let base: VisualGrounder
        switch d.string(forKey: "cascade.visualGrounder.backend") {
        case "claude":
            base = ClaudeVisualGrounder()
        default:
            // Default (and explicit "uitars"): hosted UI-TARS over OpenRouter.
            // Requires the key; without it return nil → coordinate fallback.
            guard let key = OpenRouterKeyStore().readKey(), !key.isEmpty else { return nil }
            // The grounder is SWAPPABLE without a rebuild — point `…model` at
            // UI-Venus-1.5 / Holo1.5 the moment a host serves them (OpenRouter doesn't
            // yet; UI-TARS is the proven default). A swapped Qwen3-VL model emits in a
            // different coord space → set `…coordSpace = "sent"` (or "normalized") and
            // confirm with a live probe; a wrong space misses every click. The endpoint
            // override is a NEW key, deliberately set: the old `…uitarsURL` once
            // inherited a stale dead-localhost value and stalled every run.
            let model = d.string(forKey: "cascade.visualGrounder.model") ?? GUIGrounderModel.uiTars15_7b
            let endpoint = d.string(forKey: "cascade.visualGrounder.endpoint")
                .flatMap { $0.isEmpty ? nil : $0 } ?? "https://openrouter.ai/api/v1/chat/completions"
            guard let url = URL(string: endpoint) else { return nil }
            let space = UITARSGrounder.CoordSpace(
                rawValue: d.string(forKey: "cascade.visualGrounder.coordSpace") ?? ""
            ) ?? .smartResize
            base = UITARSGrounder(baseURL: url, model: model, apiKey: key, coordSpace: space)
        }
        // Default ON: unset → enabled; explicit false → disabled (pure visual A/B).
        let mixture = (d.object(forKey: "cascade.mixtureGrounding") as? Bool) ?? true
        return mixture ? MixtureGrounder(base: base, skills: appSkills) : base
    }

    /// Region locator for the "where is X" highlight: the configured grounder
    /// (UI-TARS — free/local) first, falling back to the proven Claude
    /// ElementLocator on any miss (grounder off, unreachable, or not found). So the
    /// highlight stops paying for Claude whenever UI-TARS is serving, and never
    /// breaks when it isn't. See [[cascade-cu-downgrade-research]].
    private func locateRegionGrounded(
        screenshot: Data, question: String,
        displayWidthPoints: Int, displayHeightPoints: Int,
        conversation: [(user: String, assistant: String)]
    ) async -> ElementRegion {
        if let grounder = assistGrounder(),
           let region = await grounder.groundRegion(
               screenshot: screenshot, target: question,
               displayWidthPoints: displayWidthPoints, displayHeightPoints: displayHeightPoints
           ) {
            return region
        }
        return await elementLocator.locateRegion(
            screenshot: screenshot, question: question,
            displayWidthPoints: displayWidthPoints, displayHeightPoints: displayHeightPoints,
            conversation: conversation
        )
    }

    /// On-screen backend: Scout (Qwen3.7 Plus plans + grounder) vs the Opus
    /// computer-use loop. ONE BRAIN: Scout is the DEFAULT whenever it's fully set up —
    /// an OpenRouter key is present, which powers BOTH the Qwen3.7 Plus planner and
    /// the UI-TARS grounder. Force either way with `cascade.onScreenBackend` =
    /// "scout" / "opus"; with no key it falls back to the proven Opus path, so a
    /// keyless setup is never broken. (Qwen3.7 Plus is multimodal — it sees the
    /// screenshot plus the AX + OCR text marks; see `runScoutEpisode`.)
    static func onScreenBackendIsScout() -> Bool {
        switch UserDefaults.standard.string(forKey: "cascade.onScreenBackend") {
        case "scout": return true
        case "opus", "claude": return false
        default: return OpenRouterKeyStore().hasKey()
        }
    }

    /// The Tier 2 on-screen loop: Scout (Qwen3.7 Plus, multimodal) plans the next
    /// action and names its target — it SEES the screenshot and is also handed the
    /// screen as TEXT (AX controls + OCR Set-of-Marks, injected every turn) as naming
    /// hints; UI-TARS grounds the named target to a coordinate from the screenshot;
    /// the result is the same CUAction batch the Opus path produces, executed by the
    /// same `executeCU` under the same generation/STOP gates, with the same no-effect
    /// / stall / validator harness. Additive, opt-in, so the Opus loop is untouched.
    /// RUNTIME-UNVERIFIED (needs the planner + UI-TARS serving).
    private func runScoutEpisode(
        goal: String, prefix: String, screen: NSScreen, firstScreenshotPNG: Data, gen: Int
    ) async -> AssistEpisodeOutcome {
        // Scout grounds EVERY click, so it can't run without a working grounder.
        // Fail clearly rather than fall back to a dead localhost endpoint (the old
        // `?? UITARSGrounder()` silently pointed at :8000 and every click missed).
        guard let grounder = assistGrounder() else {
            teachMessage = "The Scout backend needs a grounder — connect an OpenRouter key in Settings → Model Keys to use it."
            dock.show(title: "Scout needs a grounder", detail: "Add an OpenRouter key in Settings.")
            _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "assist.timing", detail: "no-grounder · scout · 0 turns"))
            return .stalled("The Scout backend needs a grounder — connect an OpenRouter key (Settings → Model Keys), or switch the on-screen engine back to Claude.")
        }
        // Same in-process tool harness as the Opus path: use_skill (pull), the
        // file/shell harness, and record recall — shared providers, so Scout can
        // reach for them too (it may underuse pull-tools, but the capability is here).
        let agent = ScoutAgent(
            // Planner is Qwen3.7 Plus over OpenRouter (multimodal, 1M ctx) — it SEES
            // the screenshot AND gets the AX + OCR text marks (injected below) to name
            // targets; the grounder clicks. Model / endpoint / vision are swappable
            // without a rebuild via `cascade.scout.model` / `.endpoint` / `.vision`
            // (set `.vision false` for a text-only model like GLM-5.2).
            planner: ScoutPlannerClient(endpoint: ScoutPlannerClient.scoutEndpoint()),
            grounder: grounder,
            model: ScoutPlannerClient.scoutModel(),
            visionCapable: ScoutPlannerClient.visionEnabled(),
            // The SAME environment context Opus gets — foreground-browser behavior note
            // + today's date — so the planner is told everything Opus is told (parity).
            environmentNote: ComputerUseAgent.foregroundBrowserNote + "\n\n" + AgentDateContext.line(),
            skillProvider: assistSkillProvider(goal: goal),
            skillIndex: appSkills.indexText,
            harnessProvider: assistHarnessProvider(goal: goal, gen: gen),
            harnessTier: powerHarnessEnabled ? .full : .readOnly,
            recallEnabled: true
        )
        let dw = Int(screen.frame.width), dh = Int(screen.frame.height)
        let res = AgentResolution.best(forWidth: dw, height: dh)
        let maxSteps = 60
        var acted = false
        var idleTurns = 0
        // Observability: the Scout loop used to return from many paths (failed,
        // superseded, capture-fail, step-limit) with NO audit, so a sudden stop left
        // nothing in the log to explain it. Track timing and log EVERY exit + reason.
        let episodeStart = ContinuousClock.now
        var count = 0
        var modelTime = Duration.zero
        func scoutEnd(_ outcome: AssistEpisodeOutcome, _ why: String) async -> AssistEpisodeOutcome {
            let total = episodeStart.duration(to: .now)
            _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "assist.timing",
                detail: "\(why) · scout · \(count) turns · total \(Int(total / .milliseconds(1)))ms · model \(Int(modelTime / .milliseconds(1)))ms"))
            return outcome
        }
        // No-effect detection — ported from the Opus path (`runAssistEpisode`). Scout
        // is cheap and weak at perceiving change, so without this it re-clicks/
        // re-pastes the same dead spot (audited: the SAME 20 chars pasted 7× at one
        // point). Diff the frame with the recorder's grid hash (zero extra model
        // calls); on a no-op acting turn, nudge with the controls actually on screen,
        // and stop after 3 in a row. This is the single biggest harness Scout lacked.
        var noEffectTurns = 0
        var lastFrameHashes = Self.gridHashes(ofJPEG: firstScreenshotPNG)
        var nudge: String?

        // Parity with the Opus path's harness: seed cross-turn memory, push the
        // frontmost app's skill (Scout can't pull), and inject the screen AS TEXT
        // (AX controls + OCR) — the text-only planner is blind on turn 1 without it.
        var modelStart = ContinuousClock.now
        var step = await agent.begin(
            goal: goal, screenshot: firstScreenshotPNG, displayWidthPoints: dw, displayHeightPoints: dh,
            screenText: await scoutScreenText(forFrame: firstScreenshotPNG),
            conversation: assistMemory.historyForAPI(),
            skill: scoutSkillPush(goal: goal)
        )
        modelTime += modelStart.duration(to: .now); count += 1
        for _ in 0..<maxSteps {
            if assistGeneration != gen { return await scoutEnd(.stopped, "superseded") }
            if driver.runState.isStopRequested {
                agentMessage = "Stopped. Control returned to you."
                dock.show(title: "Stopped", detail: agentMessage)
                return await scoutEnd(.stopped, "user-stop")
            }
            if step.failed { return await scoutEnd(.failed, "planner-failed: \(step.text.prefix(90))") }
            if !step.text.isEmpty {
                teachMessage = prefix + step.text
                // Speak the turn's intent aloud like the Opus path, so the agent is
                // audibly alive during the run instead of silent — a silent Scout
                // reads as "stopped" even while it's working. When it actually spoke
                // AND this turn acts, give the voice a 450ms head start before the
                // actions land (mirrors runAssistEpisode's batch narration). The
                // done turn is skipped here — its summary is spoken by the caller.
                if !step.done, narrateProgress(step.text), !step.actions.isEmpty {
                    try? await Task.sleep(for: .milliseconds(450))
                }
            }
            if step.done {
                let claimed = step.text.isEmpty ? "Done." : step.text
                if acted, let missing = await validateAssistCompletion(goal: goal, claimed: claimed, screen: screen) {
                    _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "assist.validate", detail: "INCOMPLETE: \(missing.prefix(80))"))
                    return await scoutEnd(.stalled("I'm not sure that finished — \(missing)"), "validate-incomplete")
                }
                return await scoutEnd(.finished(claimed, acted: acted), "finished")
            }

            // Grounding visibility: log where each grounded click landed (or that it
            // found nothing) so the audit shows the WHERE-to-click decisions.
            if let g = agent.lastGroundLog {
                _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "agent.ground", detail: String(g.prefix(100))))
            }
            // Fresh nudge each turn; the idle / no-effect branches below may set it.
            nudge = nil
            // Stall guard with observation-only accounting (parity with the Opus
            // path): a turn with NO executable actions (grounding miss / unparseable
            // plan) OR one that only waits is the planner staring, not working — count
            // it toward the guard. (A wait-only turn no longer trips no-effect after
            // the predicted-effect gate, so without this it could loop unchecked.)
            // Tolerate 1, nudge at 2, stop at 3.
            var actedThisTurn = false
            let observationOnly = !step.actions.isEmpty && step.actions.allSatisfy {
                if case .wait = $0 { return true } else { return false }
            }
            if step.actions.isEmpty || observationOnly {
                idleTurns += 1
                if idleTurns >= 3 {
                    _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "assist.stalled", detail: "scout: " + String(step.text.prefix(100))))
                    return await scoutEnd(.stalled(step.text.isEmpty ? "I couldn't make progress on this." : step.text), "idle-stall")
                }
                if idleTurns == 2 {
                    nudge = "You've now spent two turns without acting on the screen. Act NOW — name a control to click or fill — or, if the task is already done or can't be done, set action to \"done\" and say why. Do not just narrate."
                }
            } else {
                idleTurns = 0
            }
            // Execute whatever the turn produced (a lone wait still settles the UI);
            // an idle/empty turn simply has nothing to run.
            for action in step.actions {
                if assistGeneration != gen { return await scoutEnd(.stopped, "superseded") }
                if driver.runState.isStopRequested { return await scoutEnd(.stopped, "user-stop") }
                let ok = await executeCU(action, on: screen)
                if !ok { return await scoutEnd(.failed, "action-failed") }  // executeCU surfaced why
                acted = true
                actedThisTurn = true
                try? await Task.sleep(for: .milliseconds(120))   // pace gap between actions
            }
            if actedThisTurn { try? await Task.sleep(for: .milliseconds(260)) }   // let the UI settle before re-observing

            guard let shot0 = await ScreenCaptureUtility.captureCursorScreenJPEG(width: res.w, height: res.h) else { return await scoutEnd(.failed, "capture-failed") }
            if assistGeneration != gen { return await scoutEnd(.stopped, "superseded") }

            // No-effect check (with the same slow-render re-check the Opus path uses).
            // Predicted-effect gate (VeriGUI): a turn that only copied or waited
            // legitimately leaves the screen unchanged — don't charge it as a failure.
            let expectsChange = Self.turnExpectsVisibleChange(step.actions)
            var observedShot = shot0
            var observedHashes = Self.gridHashes(ofJPEG: shot0)
            if actedThisTurn, expectsChange, let last = lastFrameHashes, let first = observedHashes,
               PerceptualHash.isDuplicateGrid(first, of: last, threshold: Self.noEffectThreshold) {
                try? await Task.sleep(for: .milliseconds(400))
                if let recheck = await ScreenCaptureUtility.captureCursorScreenJPEG(width: res.w, height: res.h) {
                    observedShot = recheck
                    observedHashes = Self.gridHashes(ofJPEG: recheck)
                }
                if let confirmed = observedHashes,
                   !PerceptualHash.isDuplicateGrid(confirmed, of: last, threshold: Self.noEffectThreshold) {
                    noEffectTurns = 0  // the effect just rendered late — it DID work
                } else {
                    noEffectTurns += 1
                    if noEffectTurns >= 3 {
                        _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "assist.noeffect", detail: "scout — 3rd no-effect, stopping"))
                        return await scoutEnd(.stalled("My actions aren't changing anything on screen, so I've stopped — please take over or tell me another way."), "noeffect-stall")
                    }
                    // The controls list is PUSHED proactively into turnNote below
                    // (harvested once), so the nudge just steers — no second AX walk.
                    nudge = "Your last action did NOT change the screen at all — do NOT repeat that same action; pick a DIFFERENT control from the on-screen text above, open the right menu/panel, or set action to \"done\" if it truly can't be done."
                    _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "assist.noeffect", detail: "scout no-effect turn \(count)"))
                }
            } else if actedThisTurn, expectsChange {
                noEffectTurns = 0
            }
            // A copy-only/wait-only turn (acted but expectsChange == false) leaves
            // noEffectTurns untouched: it neither failed nor proved progress.
            if let observedHashes { lastFrameHashes = observedHashes }
            // Proactive Set-of-Marks push (the literature's grounding>reasoning
            // finding + Cascade's "push controls, never a pull tool" lesson): harvest
            // the controls actually on screen ONCE per turn and PUSH them to the weak
            // planner EVERY turn — not only on a failure — so it names targets that
            // exist and the grounder (AX-first, then visual) hits them. Bounded AX
            // walk (≤24, ≤0.3s); empty on canvas/Electron apps that expose nothing.
            let controls = AXElementResolver.interactables(limit: 24)
            let controlSummary = AXElementResolver.interactableSummary(controls)
            // Grounding-miss feedback — fires on ANY missed target this turn, idle OR
            // a partially-grounded batch (where step.actions is non-empty so the idle
            // path above is skipped). Tells Scout to re-describe instead of silently
            // re-naming an un-findable target, and audits what was actually on screen.
            if let missed = agent.lastGroundMiss {
                let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
                _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "agent.ground.miss", detail: "“\(missed)” — frontmost \(front); on screen: \(String((controlSummary ?? "(no AX controls)").prefix(200)))"))
                let missNote = "Couldn't locate “\(missed)” on screen — that may be the text you want to ENTER rather than a control. Name a VISIBLE field, button, or placeholder from the on-screen text above (or the text already shown in it), not the text you intend to type. If you have ALREADY clicked into the field, use the type action with NO target."
                nudge = [nudge, missNote].compactMap { $0 }.joined(separator: " ")
            }
            // Refresh the grounding line + the proactive controls list + app skill
            // every turn (the frontmost app changes once Scout opens the target),
            // merged with any nudge above.
            // Canvas perception: when AX is sparse (Keynote slide canvas, Blender),
            // OCR the live frame and hand Scout the on-screen text as nameable targets
            // so it stops ASSUMING what's on the page. Mirrors the AX controls push —
            // structural, gated to sparse-AX turns, off-main so it doesn't stall the loop.
            let ocrMarks = await ocrSetOfMarks(forFrame: observedShot, axControlCount: controls.count)
            // Screen-as-text is the planner's VIEW (it has no image); the nudge is
            // separate steering. Both rebuilt every turn — the frontmost app changes
            // once Scout opens the target.
            let screenText = [scoutGroundingNote(), scoutControlsLine(controlSummary), ocrMarks].compactMap { $0 }.joined(separator: "\n")
            modelStart = ContinuousClock.now
            step = await agent.proceed(
                screenshot: observedShot,
                screenText: screenText.isEmpty ? nil : screenText,
                note: nudge,
                skill: scoutSkillPush(goal: goal)
            )
            modelTime += modelStart.duration(to: .now); count += 1
        }
        return await scoutEnd(.stepLimit, "step-limit")
    }

    private func runAssistEpisode(
        goal: String, prefix: String, screen: NSScreen, firstScreenshotPNG: Data, gen: Int
    ) async -> AssistEpisodeOutcome {
        // Tier 2 downgrade: when selected, the cheap on-screen brain (Scout plans,
        // UI-TARS grounds) replaces the Opus computer-use loop. This guard is the
        // ONLY change to the Opus path — default is Claude, so behaviour is
        // unchanged unless the user opts in. See [[cascade-cu-downgrade-research]].
        if Self.onScreenBackendIsScout() {
            return await runScoutEpisode(goal: goal, prefix: prefix, screen: screen, firstScreenshotPNG: firstScreenshotPNG, gen: gen)
        }
        // Pull-based skills: the agent gets a one-line index and fetches a
        // skill's full instructions itself via the use_skill tool. Content
        // never rides the prompt (token cost stays flat as the library grows).
        //
        // On-screen assist runs on Opus 4.8 (the most capable model that still
        // supports the computer-use-2025-11-24 beta). Slower per turn than Sonnet,
        // but its stronger planning does the work in far fewer turns — and the
        // 2026-06-22 audit confirmed turns, not per-turn latency, dominate
        // wall-clock (Sonnet-first ballooned the same Keynote task from ~10 turns
        // to 15 and over-thought; reverted). Effort stays medium — CU default.
        let cuModel = AnthropicModel.opus
        let agent = makeAssistAgent(model: cuModel, goal: goal, gen: gen)
        // Structural mode: the model names targets and the grounder locates them —
        // it emits NO coordinates, so the flail nudge below must push target NAMES
        // (to re-describe via click_target), never click coordinates it can't use.
        let structuralGrounding = agent.isStructural
        // Runaway backstop, not a budget. The episode's real terminators are the
        // model finishing, STOP / barge-in, stall detection, or a newer turn
        // superseding this one — a low cap here just killed long honest tasks.
        let maxSteps = 80
        let episodeStart = ContinuousClock.now
        var modelTime = Duration.zero
        var actionTime = Duration.zero
        // Streamed execution: the reply arrives as SSE and each completed tool
        // call runs HERE while the rest is still generating — the cursor starts
        // moving seconds into the round trip instead of after it. Narration is
        // buffered until the turn's first action (an action-less turn is a
        // closing/idle line, which episode paths narrate). Same gates as the
        // batch path below: generation + STOP before every action, pace gap
        // between actions, executeCU failures end the episode.
        var streamActed = false               // an action ran mid-stream this turn
        var streamFailed = false              // executeCU refused — episode is over
        var streamActionTime = Duration.zero  // this turn's in-stream action time
        var streamExpectedChange = false      // a streamed action this turn expected a visible change
        var pendingNarration: String?         // clause buffered until the turn proves it has actions
        // Wiring captures the episode-local state above, so escalation re-applies
        // it to the rebuilt Opus agent by calling this again.
        func wire(_ agent: ComputerUseAgent) {
            agent.onActionRefused = { [weak self] detail in
                guard let self else { return }
                Task { _ = try? await self.store.appendAudit(AuditEvent(actor: "agent", action: "agent.action.refused", detail: detail)) }
            }
            // A long think used to look like a hang — the dock kept showing the
            // previous turn's line for 30+ seconds. The pulse carries the thinking
            // summary's tail, so the user watches the deliberation happen instead.
            agent.onThinkingPulse = { [weak self] tail in
                guard let self, self.assistGeneration == gen else { return }
                // Keep the companion cursor visibly alive (sonar pulse) through the
                // round-trip freeze, not just the dock text.
                self.guidanceOverlay.setThinking(true)
                self.dock.show(title: "Cascade is thinking…", detail: tail)
            }
            agent.streamSink = { [weak self] item in
                guard let self, self.assistGeneration == gen, !self.driver.runState.isStopRequested else { return false }
                switch item {
                case .text(let line):
                    self.teachMessage = prefix + line
                    // Buffer instead of speaking: a turn that ends with no actions
                    // is the model's closing or idle line, and those are narrated by
                    // the episode's own paths (final summary, stall handling) —
                    // voicing them here too would say everything twice at task end.
                    pendingNarration = line
                    return true
                case .action(let action):
                    if let line = pendingNarration {
                        pendingNarration = nil
                        // Same head start the batch path gave: the user hears
                        // "writing the poem now" BEFORE the typing starts.
                        if self.narrateProgress(line) {
                            try? await Task.sleep(for: .milliseconds(450))
                        }
                    }
                    if streamActed { try? await Task.sleep(for: .milliseconds(120)) }  // pace gap between actions
                    let start = ContinuousClock.now
                    guard await self.executeCU(action, on: screen) else {
                        streamFailed = true
                        return false
                    }
                    let spent = start.duration(to: .now)
                    streamActionTime += spent
                    actionTime += spent
                    streamActed = true
                    if Self.expectsVisibleChange(action) { streamExpectedChange = true }
                    return true
                }
            }
        }
        wire(agent)
        var step = await agent.begin(
            goal: goal,
            screenshot: firstScreenshotPNG,
            displayWidthPoints: Int(screen.frame.width),
            displayHeightPoints: Int(screen.frame.height),
            conversation: assistMemory.historyForAPI(),
            note: groundingNote(),
            skillIndex: appSkills.indexText
        )
        // begin() IS the first model turn; in-stream action time isn't model time.
        modelTime += episodeStart.duration(to: .now) - streamActionTime
        var acted = false
        var count = 0
        // Stall guard: a turn with no actions and no done is the model talking
        // instead of working. One is tolerated (thinking out loud), the second
        // gets a firm nudge, the third ends the episode — never a spam loop to
        // the step cap repeating the same line.
        var idleTurns = 0
        var nudge: String?
        // "No state change after an action" — the cheapest, most universal failure
        // signal in the GUI-agent literature (WILBUR / VeriGUI / AgentRR check
        // functions): if an acting turn leaves EVERY screen region unchanged, the
        // action had no effect (a dead/disabled control, a missed target, a click
        // that hit nothing). The stall guard can't catch this — a dead click is a
        // real action, so it resets idleTurns and the agent re-clicks the same
        // point forever (the audited 657,675 ×2 and 569→570→572 loops). We diff
        // frames with the recorder's existing grid hash (zero extra model calls)
        // and tell the model to change approach. `lastFrameHashes` is the
        // fingerprint of the frame the current `step` was generated from.
        var noEffectTurns = 0
        var lastFrameHashes = Self.gridHashes(ofJPEG: firstScreenshotPNG)
        func auditTiming(outcome: String) {
            let total = episodeStart.duration(to: .now)
            let detail = "\(outcome) · \(count + 1) turns · total \(Int(total / .milliseconds(1)))ms · model \(Int(modelTime / .milliseconds(1)))ms · actions \(Int(actionTime / .milliseconds(1)))ms · effort \(cuEffort) · \(cuModel)"
            Task { _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "assist.timing", detail: detail)) }
        }
        while count < maxSteps {
            if assistGeneration != gen {
                auditTiming(outcome: "superseded")  // a newer voice turn took over
                return .stopped
            }
            if driver.runState.isStopRequested {
                auditTiming(outcome: "stopped")
                teachMessage = "Stopped. Control returned to you."
                dock.show(title: "Stopped", detail: teachMessage)
                return .stopped
            }
            if streamFailed {
                auditTiming(outcome: "failed-action")  // executeCU already surfaced why mid-stream
                return .failed
            }
            if !step.text.isEmpty {
                teachMessage = prefix + step.text
                // Turns that streamed actions already narrated their clause at
                // the first action — re-narrating the joined text here would
                // double-speak once the 4s throttle expires on long turns.
                if !step.done, step.streamedActions == 0, narrateProgress(step.text), !step.actions.isEmpty {
                    // Give the spoken line a head start so the user hears
                    // "writing the poem now" BEFORE the typing starts, not after.
                    try? await Task.sleep(for: .milliseconds(450))
                }
            }
            if step.done {
                let claimed = step.text.isEmpty ? "Done." : step.text
                // Validator stage: a run that DID work and claims done is checked
                // against fresh on-screen evidence (gated off by default → nil, no
                // overhead). A clear mismatch is reported honestly instead of a
                // false "done".
                if acted, let missing = await validateAssistCompletion(goal: goal, claimed: claimed, screen: screen) {
                    auditTiming(outcome: "incomplete")
                    _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "assist.validate", detail: "INCOMPLETE: \(missing.prefix(80))"))
                    return .stalled("I'm not sure that finished — \(missing)")
                }
                auditTiming(outcome: "finished")
                return .finished(claimed, acted: acted)
            }

            // A turn that only LOOKED — screenshot/wait requests, nothing else —
            // is staring, not acting: it must count toward the stall guard, not
            // reset it. Four consecutive look-only turns rode out the 31s
            // thinking burst un-nudged on 2026-06-11 because .screenshot lands
            // in step.actions. Zoom stays a real action (it reads new pixels).
            let observationOnly = step.streamedActions == 0 && !step.actions.isEmpty
                && step.actions.allSatisfy { action in
                    if case .screenshot = action { return true }
                    if case .wait = action { return true }
                    return false
                }
            if (step.actions.isEmpty && step.streamedActions == 0) || observationOnly {
                idleTurns += 1
                if idleTurns >= 3 {
                    auditTiming(outcome: "stalled")
                    _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "assist.stalled", detail: String(step.text.prefix(120))))
                    return .stalled(step.text.isEmpty ? "I couldn't make progress on this." : step.text)
                }
                if idleTurns == 2 {
                    nudge = "You have now spent two turns looking or talking without acting. Either make the tool calls that do the work RIGHT NOW, or — if the task is already complete or impossible — say so and stop. Do not repeat yourself."
                }
            } else {
                idleTurns = 0
                nudge = nil
                acted = true
            }
            // Zoom is answered with the cropped frame, not a regular screenshot —
            // pull it out and run everything else first.
            var zoomRegion: CGRect?
            var actedThisTurn = streamActed
            for (actionIndex, action) in step.actions.enumerated() {
                // Re-check between every action — a barge-in or newer turn must
                // halt mid-batch, not after the batch finishes.
                if assistGeneration != gen || driver.runState.isStopRequested {
                    auditTiming(outcome: "stopped")
                    return .stopped
                }
                if case .zoom(let nx, let ny, let nw, let nh) = action {
                    zoomRegion = CGRect(x: nx, y: ny, width: nw, height: nh)
                    // Zoom turns execute no screen action and change nothing visible —
                    // without this row a zoom LOOP is indistinguishable from a hang
                    // (the 2026-06-11 46s Keynote stall was unattributable).
                    Task { _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "computer.zoom", detail: String(format: "region %.2f,%.2f %.2f×%.2f", nx, ny, nw, nh))) }
                    continue
                }
                actedThisTurn = true
                let actionStart = ContinuousClock.now
                if !(await executeCU(action, on: screen)) {
                    auditTiming(outcome: "failed-action")
                    return .failed
                }
                actionTime += actionStart.duration(to: .now)
                // The pace gap matters BETWEEN actions; after the last one the
                // settle sleep below covers it — no double wait.
                if actionIndex < step.actions.count - 1 {
                    try? await Task.sleep(for: .milliseconds(120))
                }
            }

            if let zoomRegion {
                // Native-resolution crop so the model can actually read small text.
                if actedThisTurn { try? await Task.sleep(for: .milliseconds(260)) }
                if let crop = await ScreenCaptureUtility.captureCursorScreenZoomJPEG(normalizedRect: zoomRegion) {
                    streamActed = false
                    streamActionTime = .zero
                    streamExpectedChange = false
                    pendingNarration = nil
                    let modelStart = ContinuousClock.now
                    step = await agent.proceed(screenshot: crop, note: episodeNote(nudge), zoomResult: true)
                    modelTime += modelStart.duration(to: .now) - streamActionTime
                    count += 1
                    continue
                }
                // Crop failed — fall through to the regular re-observe.
            }
            // Let the UI settle, then re-observe and ask for the next step. Capturing
            // at the agent's resolution as JPEG skips the PNG round-trip and OCR.
            // A turn that did nothing changed nothing — skip the settle entirely.
            if actedThisTurn { try? await Task.sleep(for: .milliseconds(260)) }
            let size = agent.captureSize
            guard let nextShot = await ScreenCaptureUtility.captureCursorScreenJPEG(width: size.width, height: size.height) else {
                auditTiming(outcome: "failed-capture")
                teachMessage = "I lost sight of the screen — try again."
                return .failed
            }
            // No-effect detection (hardened against false positives): an acting
            // turn whose every screen region is unchanged did nothing — don't let
            // the model re-click the dead spot. Two guards keep a SUCCESSFUL action
            // from being mislabeled "no effect": (1) `noEffectThreshold` is far
            // tighter than the recorder's blink dedup — a dead click is near
            // byte-identical, a real change shifts many bits; (2) a delayed
            // RE-CHECK — a theme still downloading, an app still launching, or an
            // animation can finish AFTER the 260ms settle, so on a suspected
            // no-effect we wait and re-capture once before concluding (and use that
            // fresher frame). The extra wait costs time only on the rare flail path.
            // Predicted-effect gate (VeriGUI): a turn whose only acting was a
            // clipboard copy or a wait legitimately changed nothing — exempt it so an
            // honest no-op doesn't accrue toward the no-effect stall.
            let expectsChange = streamExpectedChange || Self.turnExpectsVisibleChange(step.actions)
            var observedShot = nextShot
            var observedHashes = Self.gridHashes(ofJPEG: nextShot)
            if actedThisTurn, !observationOnly, expectsChange, let last = lastFrameHashes, let first = observedHashes,
               PerceptualHash.isDuplicateGrid(first, of: last, threshold: Self.noEffectThreshold) {
                try? await Task.sleep(for: .milliseconds(400))
                if let recheck = await ScreenCaptureUtility.captureCursorScreenJPEG(width: size.width, height: size.height) {
                    observedShot = recheck
                    observedHashes = Self.gridHashes(ofJPEG: recheck)
                }
                if let confirmed = observedHashes,
                   !PerceptualHash.isDuplicateGrid(confirmed, of: last, threshold: Self.noEffectThreshold) {
                    // The effect just rendered late — the action DID work.
                    noEffectTurns = 0
                    _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "assist.noeffect", detail: "turn \(count + 1) re-check cleared (slow render)"))
                } else {
                    noEffectTurns += 1
                    if noEffectTurns >= 3 {
                        _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "assist.noeffect", detail: "turn \(count + 1) — 3rd no-effect, stopping"))
                        auditTiming(outcome: "stalled-noeffect")
                        return .stalled("My actions aren't changing anything on screen, so I've stopped — please take over or tell me another way.")
                    }
                    nudge = "Your last action did NOT change the screen at all — it had no effect (the control isn't where you clicked, is disabled, or needs a different gesture). Do NOT repeat that same click."
                    // Flail-moment grounding push (Cascade's "push elements at a
                    // flail moment, never a pull tool" lesson + the literature's
                    // grounding>reasoning finding): hand the model the controls that
                    // ARE actually on screen so it re-grounds on real elements
                    // instead of re-guessing the same dead pixel.
                    let controls = AXElementResolver.interactables()
                    if structuralGrounding {
                        // Structural mode names targets — pushing coordinates would be
                        // useless (it can't emit them). Push the control LABELS and
                        // tell it to re-aim with click_target by name.
                        if let summary = AXElementResolver.interactableSummary(controls) {
                            nudge! += " The controls actually on screen right now are: \(summary). Name one of THESE with click_target (by its label or role) — if what you wanted isn't listed, it isn't a clickable control here, so open the right menu/panel or take another route."
                            _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "assist.noeffect", detail: "turn \(count + 1) pushed \(controls.count) labels (structural): \(String(summary.prefix(700)))"))
                        } else {
                            nudge! += " Choose a DIFFERENT control, menu, or approach — or, if this can't be done, say so and stop."
                            _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "assist.noeffect", detail: "turn \(count + 1) left the screen unchanged (no AX controls, structural)"))
                        }
                    } else if let located = Self.groundingControls(controls, display: Self.displayBounds(of: screen), resW: size.width, resH: size.height) {
                        // Coordinate-level grounding: the model is poor at producing
                        // click coordinates but fine choosing from given ones (the
                        // GUI-agent grounding>reasoning finding) — so hand it the
                        // exact x,y of each real control to click directly.
                        nudge! += " The controls actually on screen right now, with their click coordinates, are: \(located). Click one of THESE coordinates directly instead of guessing — if what you wanted isn't listed, it isn't a clickable control here, so open the right menu/panel or take another route."
                        // Diagnostic: log the VERBATIM controls (labels + coords),
                        // not just the count — so the audit reveals whether canvas
                        // placeholders (e.g. a Keynote subtitle box) are actually in
                        // the AX list, which decides whether structural snap-on-no-
                        // effect is viable or the canvas needs a real visual grounder.
                        _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "assist.noeffect", detail: "turn \(count + 1) pushed \(controls.count) w/ coords: \(String(located.prefix(700)))"))
                    } else if let summary = AXElementResolver.interactableSummary(controls) {
                        nudge! += " The controls actually clickable on screen right now are: \(summary). Aim for one of these by sight — if what you wanted isn't in this list, it isn't clickable here, so open the right menu/panel or take another route."
                        _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "assist.noeffect", detail: "turn \(count + 1) pushed \(controls.count) labels: \(String(summary.prefix(700)))"))
                    } else {
                        nudge! += " Choose a DIFFERENT control, menu, or approach — or, if this can't be done, say so and stop."
                        _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "assist.noeffect", detail: "turn \(count + 1) left the screen unchanged (no AX controls to push)"))
                    }
                    // Canvas perception parity with Scout: when AX is blind (Keynote
                    // slide canvas, Blender), OCR the frame and hand Opus the on-screen
                    // TEXT as nameable targets too — gated to sparse-AX NATIVE surfaces
                    // (browsers excluded) inside ocrSetOfMarks.
                    if let ocr = await ocrSetOfMarks(forFrame: observedShot, axControlCount: controls.count) {
                        nudge! += "\n" + ocr
                    }
                }
            } else if actedThisTurn, !observationOnly, expectsChange {
                noEffectTurns = 0
            }
            // A copy-only/wait-only acting turn leaves noEffectTurns untouched.
            if let observedHashes { lastFrameHashes = observedHashes }
            streamActed = false
            streamActionTime = .zero
            streamExpectedChange = false
            pendingNarration = nil
            let modelStart = ContinuousClock.now
            step = await agent.proceed(screenshot: observedShot, note: episodeNote(nudge))
            modelTime += modelStart.duration(to: .now) - streamActionTime
            count += 1
        }
        auditTiming(outcome: "step-limit")
        return .stepLimit
    }

    /// Runs one recall tool call for the assist agent: STOP/supersession gate,
    /// an audit row with the verbatim query/timeframe/id, then the read-only
    /// lookup against the local record via the shared `RecordRecall`. No
    /// file/shell deny-list or one-lane gate applies — this only reads what the
    /// user already saw on screen, the same surface the Ask panel searches.
    private func performRecall(name: String, input: [String: Any], gen: Int) async -> String {
        guard assistGeneration == gen, !driver.runState.isStopRequested else {
            return "The user stopped this task. Do not continue — end now."
        }
        // Parse the Sendable call HERE (on the main actor) so the untyped
        // dictionary never crosses into RecordRecall's nonisolated executor.
        let call = RecordRecall.Call(name: name, input: input)
        dock.show(title: "Cascade is remembering", detail: call.auditDetail)
        _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "agent.recall", detail: call.auditDetail))
        return await RecordRecall(store: store).perform(call)
    }

    /// Runs one harness tool call for the assist agent: STOP/supersession gate
    /// first, then an audit row with the verbatim query/path/command, then the
    /// actual execution (which applies the power-tier gate and the destructive
    /// deny-list). The dock shows each call as it runs, so the user supervises
    /// scripts the same way they supervise clicks.
    private func performHarness(name: String, input: [String: Any], goal: String, gen: Int) async -> String {
        guard assistGeneration == gen, !driver.runState.isStopRequested else {
            return "The user stopped this task. Do not continue — end now."
        }
        guard let call = HarnessCall(name: name, input: input) else {
            return "Unknown harness tool “\(name)”."
        }
        // ONE-LANE enforcement, structural: scripting an app whose UI this task
        // has already been working on screen abandons work the user is watching
        // (the Keynote title-page incident, 2026-06-11 — prompt rules alone
        // didn't survive failure pressure). Script-FIRST bulk work in an app
        // the agent never touched on screen stays allowed, and the user's own
        // ask for a script overrides.
        if name == "run_applescript" || name == "run_command" {
            let source = (input["script"] as? String) ?? (input["command"] as? String) ?? ""
            let isScripting = name == "run_applescript" || source.lowercased().contains("osascript")
            if isScripting, !AppSkill.goalAsksForScript(goal) {
                let watched = AgentHarness.scriptedAppTargets(in: source).first { target in
                    episodeAppActions.contains { app, count in
                        count >= 3 && (app.lowercased().contains(target.lowercased())
                            || target.lowercased().contains(app.lowercased()))
                    }
                }
                if let watched {
                    dock.show(title: "Blocked a script", detail: "\(name) targeting \(watched) — the task stays on screen.")
                    _ = try? await store.appendAudit(AuditEvent(
                        actor: "agent", action: "harness.denied.watched-app", detail: "\(name) → \(watched)"
                    ))
                    return """
                    Blocked: you have been doing this task in \(watched)'s own UI on screen, \
                    and the user is watching that work — scripting the same app now abandons \
                    it mid-flight (one lane per artifact). Finish on screen with clicks, \
                    fields, and shortcuts; if an edit went wrong, fix it on screen too. A \
                    script here is only allowed when the user's own words ask for one.
                    """
                }
            }
        }
        let summary = call.auditSummary
        if name == "run_applescript" {
            // First AppleScript touch of an app blocks on a macOS Automation
            // consent dialog — without this hint the agent just looks frozen.
            dock.show(title: "Cascade is doing it", detail: "\(name): \(summary) · approve the permission prompt if macOS shows one.")
        } else {
            dock.show(title: "Cascade is doing it", detail: "\(name): \(summary) · press STOP to take control.")
        }
        // Audit BEFORE executing (the audit-first invariant), then flag slow
        // calls in a second row — that's how a consent-dialog stall or a
        // crawling script shows up in the log instead of being invisible.
        _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "harness.\(name)", detail: summary))
        let started = ContinuousClock.now
        let result = await AgentHarness.perform(call, powerEnabled: powerHarnessEnabled)
        let ms = Int(started.duration(to: .now) / .milliseconds(1))
        if ms >= 800 {
            _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "harness.slow", detail: "\(name) took \(ms)ms — \(summary)"))
        }
        return result
    }

    /// The per-turn grounding note plus, when the stall guard fired, the firm
    /// "act now or stop" nudge appended so the model can't keep idling.
    private func episodeNote(_ nudge: String?) -> String? {
        guard let nudge else { return groundingNote() }
        return [groundingNote(), nudge].compactMap { $0 }.joined(separator: "\n")
    }

    /// Validator stage (Phase 1) — a fresh-evidence second opinion on the model's
    /// "done", ported from the background agent's `verifyCompletion`. The model's
    /// claim is NOT trusted on its own (the audited "declared done but didn't"
    /// case); a fresh screenshot is OCR'd and a cheap verifier judges ONLY that
    /// evidence — never the agent's narration (narration-judges over-report). On a
    /// CLEAR mismatch the run is downgraded to `.stalled` and the user is told what's
    /// missing; doubt leans accept so genuine wins still pass.
    ///
    /// Gated OFF by default (`cascade.assistValidator`): it adds a capture + OCR +
    /// model round trip to the END of a finished run, which is latency on the
    /// watched success path Opus rarely needs. It is the reliability net for a
    /// downgraded thinker (Phase 3), which false-completes far more — build it now,
    /// switch it on then. See [[cascade-cu-downgrade-research]].
    private func validateAssistCompletion(goal: String, claimed: String, screen: NSScreen) async -> String? {
        guard UserDefaults.standard.bool(forKey: "cascade.assistValidator"), hasAnthropicKey else { return nil }
        let res = AgentResolution.best(forWidth: Int(screen.frame.width), height: Int(screen.frame.height))
        guard let shot = await ScreenCaptureUtility.captureCursorScreenJPEG(width: res.w, height: res.h) else { return nil }
        let onScreen = await ScreenTextRecognizer.recognize(inPNG: shot)
        // Can't judge a screen we couldn't read (sparse OCR / canvas app) → accept
        // rather than false-fail a real win.
        if onScreen.trimmingCharacters(in: .whitespacesAndNewlines).count < 8 { return nil }
        let user = """
        An on-screen assistant was asked to: \(goal)
        When it claimed DONE it said: \(claimed)
        The text now visible on the user's screen:
        \(onScreen.prefix(2800))

        Judging ONLY by what's on screen, did it ACTUALLY accomplish the task — is the \
        result the task wanted genuinely there (the slide built and filled, the message \
        sent, the value entered, the file shown)? If yes, or if you're not sure, reply \
        exactly: VERIFIED. Only if the screen CLEARLY shows it is not done reply: \
        INCOMPLETE: <one short line on what's missing>
        """
        // Downgraded helper task: Groq llama-3.3-70b when a key is set, else
        // Anthropic haiku. The validator judges OCR TEXT, so no vision is needed.
        let h = TextHelperModel.resolve()
        guard let reply = try? await h.client.complete(
            system: "You verify whether an on-screen assistant truly finished its task, judging only by what is visible on screen now. Lean VERIFIED unless it's clearly not done.",
            user: user, model: h.model, maxTokens: 120
        ) else { return nil }  // verifier unavailable → never block a completion
        return Self.parseAssistVerdict(reply)
    }

    /// Parses the validator's reply: an INCOMPLETE reason, or nil to accept
    /// (VERIFIED / unclear / empty all accept). Pure + pinned. Mirrors the
    /// background agent's verdict parse.
    nonisolated static func parseAssistVerdict(_ reply: String) -> String? {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.uppercased().hasPrefix("INCOMPLETE") else { return nil }
        let reason = trimmed.dropFirst("INCOMPLETE".count)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".:")))
        return reason.isEmpty ? "the screen doesn't show the task was completed" : reason
    }

    /// One line of text grounding sent with every frame: which app and window are
    /// frontmost. ~15 tokens that prevent which-app-am-I-in mistakes. When a skill
    /// covers the frontmost app, a one-line nudge points at it — the content itself
    /// is pulled by the agent through use_skill, never pushed.
    private func groundingNote() -> String? {
        let snapshot = AppWindowObserver.snapshot()
        guard snapshot.appName != "Unknown app" else { return nil }
        var note: String
        if let title = snapshot.windowTitle, !title.isEmpty {
            note = "Frontmost app: \(snapshot.appName) — “\(title)”"
        } else {
            note = "Frontmost app: \(snapshot.appName)"
        }
        if let skill = appSkills.skill(appName: snapshot.appName, bundleIdentifier: snapshot.bundleIdentifier) {
            note += "\nSkill “\(skill.name)” covers this app — pull it with use_skill before acting here, if you haven't already."
        }
        return note
    }

    /// Frontmost app + window line for the Scout path. Unlike `groundingNote()` it
    /// omits the use_skill nudge — Scout has no use_skill tool (its matched skill is
    /// PUSHED into the prompt), and dangling "use_skill" text would waste a turn.
    private func scoutGroundingNote() -> String? {
        let snapshot = AppWindowObserver.snapshot()
        guard snapshot.appName != "Unknown app" else { return nil }
        if let title = snapshot.windowTitle, !title.isEmpty {
            return "Frontmost app: \(snapshot.appName) — “\(title)”"
        }
        return "Frontmost app: \(snapshot.appName)"
    }

    /// Formats the proactive Set-of-Marks controls push from a harvested summary.
    /// nil when there's nothing on screen (canvas/Electron). Shared by the first
    /// turn (`scoutContextNote`) and each subsequent turn so the listing is identical.
    private func scoutControlsLine(_ summary: String?) -> String? {
        summary.map { "Controls on screen now (name one of these to click or fill, or open a menu/panel to reveal others): \($0)" }
    }

    /// The screen rendered AS TEXT for the GLM (text-only) Scout planner: frontmost
    /// app/window + the AX controls on screen + (on sparse-AX / canvas surfaces) an
    /// OCR Set-of-Marks of the visible text. This is the planner's entire view of the
    /// screen — there is no image. Used for the FIRST turn; subsequent turns rebuild
    /// the same shape inline alongside the no-effect/miss feedback. `async` because
    /// the OCR pass runs off-main.
    private func scoutScreenText(forFrame frame: Data) async -> String? {
        let controls = AXElementResolver.interactables(limit: 24)
        let controlSummary = AXElementResolver.interactableSummary(controls)
        let ocrMarks = await ocrSetOfMarks(forFrame: frame, axControlCount: controls.count)
        let parts = [scoutGroundingNote(), scoutControlsLine(controlSummary), ocrMarks].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    /// OCR Set-of-Marks for the planner on canvas / sparse-AX surfaces. When the AX
    /// walk found few controls (Keynote slide canvas, Blender, design tools), OCR the
    /// current frame OFF-MAIN and hand Scout the on-screen TEXT as nameable targets —
    /// the structural fix for "the planner assumes what's on the page". ON by default
    /// (it fires only where AX is blind, so it's purely additive there); disable with
    /// `cascade.ocrSetOfMarks = false`. Audited as `scout.ocr.marks`.
    private func ocrSetOfMarks(forFrame frame: Data, axControlCount: Int) async -> String? {
        // Browsers are text-heavy and DOM-native (the background agent owns the web),
        // so OCR there dumps page text as noise. Fire only on canvas / non-AX NATIVE
        // surfaces (Keynote slide canvas, Blender) where the planner is truly blind.
        let front = NSWorkspace.shared.frontmostApplication?.localizedName
        let isBrowser = front.map { Self.runsInBackground(apps: [$0]) } ?? false
        guard (UserDefaults.standard.object(forKey: "cascade.ocrSetOfMarks") as? Bool) ?? true,
              Self.shouldOcrSetOfMarks(axControlCount: axControlCount, isBrowser: isBrowser) else { return nil }
        let boxes = await Task.detached { ScreenTextRecognizer.recognizeBoxes(inImageData: frame) }.value
        guard let marks = ScreenTextRecognizer.setOfMarks(boxes) else { return nil }
        _ = try? await store.appendAudit(AuditEvent(
            actor: "agent", action: "scout.ocr.marks",
            detail: "AX sparse (\(axControlCount) controls) → \(boxes.count) OCR lines: \(String(marks.prefix(360)))"))
        return marks
    }

    /// AX is "sparse" — a canvas / non-AX surface where the accessibility tree
    /// exposed almost nothing to name, so the planner needs OCR text marks instead
    /// of assuming. Pure + pinned.
    nonisolated static func axIsSparse(controlCount: Int, threshold: Int = 8) -> Bool {
        controlCount < threshold
    }

    /// Whether to supplement the planner with OCR text marks this turn: AX is sparse
    /// (canvas / non-AX surface) AND the frontmost app is NOT a browser. Browsers are
    /// text-heavy and DOM-native (the background agent owns the web), so OCR there is
    /// page-text noise, not nameable targets. Pure + pinned.
    nonisolated static func shouldOcrSetOfMarks(axControlCount: Int, isBrowser: Bool) -> Bool {
        axIsSparse(controlCount: axControlCount) && !isBrowser
    }

    /// Performs one Computer Use action, flying the companion cursor to pointer
    /// targets first. Returns `false` (and surfaces why) if the actuator is blocked
    /// — e.g. Accessibility / Input Monitoring not granted — so the loop can stop.
    @discardableResult
    /// Grid perceptual hash of a JPEG frame — the recorder's change-aware
    /// fingerprint, reused to tell whether an acting turn changed the screen.
    /// nil if the frame can't be decoded (then no-effect detection is skipped).
    nonisolated static func gridHashes(ofJPEG data: Data) -> [UInt64]? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return PerceptualHash.gridHashes(image)
    }

    /// Whether an action is EXPECTED to change what's visible on screen — the
    /// predicted-effect signal (VeriGUI's Thinking-Verification-Action-Expectation
    /// cycle). No-effect detection rests on "an action that changed nothing failed",
    /// but a few actions legitimately leave the screen unchanged: a clipboard copy
    /// (cmd+c / cmd+x), an explicit wait, or a pure observation. A turn made ONLY of
    /// those must NOT be charged as a no-effect failure, or the agent stalls on
    /// honest no-ops. Made STRUCTURAL (the runtime classifies by action kind) rather
    /// than model-reported on purpose — a self-declared "no change expected" would
    /// let a weak planner switch OFF its own safety net by mislabelling a dead click.
    nonisolated static func expectsVisibleChange(_ action: CUAction) -> Bool {
        switch action {
        case .wait, .screenshot, .zoom: return false
        case .key(let combo): return !ComputerUseAgent.isCopyCombo(combo)
        default: return true
        }
    }

    /// A turn is expected to change the screen if ANY of its acting actions is — so a
    /// mixed turn (copy THEN click) still expects change, but a copy-only or
    /// wait-only turn is exempt from no-effect counting.
    nonisolated static func turnExpectsVisibleChange(_ actions: [CUAction]) -> Bool {
        actions.contains(where: expectsVisibleChange)
    }

    /// Maps an element's CG-global center (top-left origin, from AX) into the
    /// model's screenshot-pixel space (resW×resH, top-left). AX positions and
    /// `CGDisplayBounds` share the same CG-global coordinate system, so this is a
    /// plain subtract-and-scale — no AppKit Y-flip. Returns nil when the element
    /// is off the captured display (so we never push a coordinate the model's
    /// screenshot doesn't actually contain). Pure + unit-tested: a wrong number
    /// here would send the agent clicking into empty space.
    nonisolated static func modelPixel(forCGGlobal point: CGPoint, in display: CGRect, resW: Int, resH: Int) -> CGPoint? {
        guard display.width > 0, display.height > 0 else { return nil }
        let fx = (point.x - display.minX) / display.width
        let fy = (point.y - display.minY) / display.height
        guard fx >= -0.002, fx <= 1.002, fy >= -0.002, fy <= 1.002 else { return nil }
        return CGPoint(x: min(max(fx, 0), 1) * Double(resW), y: min(max(fy, 0), 1) * Double(resH))
    }

    /// The flail-moment grounding push WITH coordinates: each on-screen control
    /// rendered as `"label" (role) at x,y` in the model's pixel space, so it can
    /// click the exact spot instead of guessing. Drops controls off the captured
    /// display. nil when nothing maps (caller falls back to labels-only, then a
    /// plain nudge). Pure given the harvested matches + display geometry.
    nonisolated static func groundingControls(
        _ matches: [AXElementResolver.Match], display: CGRect, resW: Int, resH: Int, limit: Int = 40
    ) -> String? {
        let entries = matches.prefix(limit).compactMap { match -> String? in
            guard let pixel = modelPixel(forCGGlobal: match.center, in: display, resW: resW, resH: resH) else { return nil }
            let role = match.role.hasPrefix("AX") ? String(match.role.dropFirst(2)).lowercased() : match.role.lowercased()
            return "“\(match.title)” (\(role)) at \(Int(pixel.x.rounded())),\(Int(pixel.y.rounded()))"
        }
        return entries.isEmpty ? nil : entries.joined(separator: "; ")
    }

    /// CG-global bounds (top-left origin) of the display a screen represents —
    /// the coordinate system AX element positions live in.
    nonisolated static func displayBounds(of screen: NSScreen) -> CGRect {
        let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        return CGDisplayBounds(id ?? CGMainDisplayID())
    }

    private func executeCU(_ action: CUAction, on screen: NSScreen) async -> Bool {
        // An action means the thinking freeze is over — drop the sonar pulse so the
        // cursor's flight/press reads cleanly (the next turn re-arms it).
        guidanceOverlay.setThinking(false)
        func globalAppKit(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: screen.frame.minX + x, y: screen.frame.minY + y)
        }
        func cg(_ x: Double, _ y: Double) -> CGPoint { Self.toCGGlobal(globalAppKit(x, y)) }
        // Skill auto-learning: tally which app this run actually worked in.
        if let app = NSWorkspace.shared.frontmostApplication?.localizedName,
           app.caseInsensitiveCompare("Cascade") != .orderedSame {
            episodeAppActions[app, default: 0] += 1
        }
        // Pointer-routed apps (Blender): hotkeys act on the editor under the
        // physical pointer, so the pointer must STAY where the agent clicks
        // instead of being restored to the user's parked position.
        let skill = frontmostSkill()
        let keepPointer = skill?.keysFollowPointer == true
        do {
            switch action {
            case .move(let x, let y):
                // Blue companion only — the user's real pointer never STAYS moved.
                // Pointer-routed apps need a real move EVENT (they track the
                // pointer from events; a warp is invisible to them), but the
                // restore is a warp for exactly that reason: the app keeps acting
                // at the hovered point while the user's cursor returns home.
                guidanceOverlay.navigate(toGlobalPoint: globalAppKit(x, y))
                if keepPointer {
                    let p = cg(x, y)
                    lastPointerRoutedPoint = p
                    try await clickRestoringCursor(settleMs: 30) { try await driver.act(.computerUse(.move(x: p.x, y: p.y))) }
                }
            case .click(let x, let y):
                let flight = guidanceOverlay.navigate(toGlobalPoint: globalAppKit(x, y))
                try? await Task.sleep(for: .milliseconds(Int(flight * 1000)))  // press only after the cursor ARRIVES
                guidanceOverlay.press()
                try? await Task.sleep(for: .milliseconds(55))   // show the press dip
                let p = cg(x, y)
                if keepPointer {
                    // The press itself needs the real pointer (move event + click),
                    // but afterwards the cursor goes back to the user — the app's
                    // learned position stays at p because warps emit no events.
                    lastPointerRoutedPoint = p
                    try await clickRestoringCursor(settleMs: 30) { try await driver.act(.computerUse(.click(x: p.x, y: p.y))) }
                } else if skill?.axUnreliable == true || !Self.axActivate(atCG: p) {
                    try await clickRestoringCursor { try await driver.act(.computerUse(.click(x: p.x, y: p.y))) }
                }
            case .doubleClick(let x, let y):
                let flight = guidanceOverlay.navigate(toGlobalPoint: globalAppKit(x, y))
                try? await Task.sleep(for: .milliseconds(Int(flight * 1000)))
                guidanceOverlay.press()
                try? await Task.sleep(for: .milliseconds(55))
                let p = cg(x, y)
                if keepPointer { lastPointerRoutedPoint = p }
                try await clickRestoringCursor(settleMs: keepPointer ? 30 : 0) {
                    try await driver.act(.computerUse(.doubleClick(x: p.x, y: p.y)))
                }
            case .tripleClick(let x, let y):
                let flight = guidanceOverlay.navigate(toGlobalPoint: globalAppKit(x, y))
                try? await Task.sleep(for: .milliseconds(Int(flight * 1000)))
                guidanceOverlay.press()
                try? await Task.sleep(for: .milliseconds(55))
                let p = cg(x, y)
                if keepPointer { lastPointerRoutedPoint = p }
                try await clickRestoringCursor(settleMs: keepPointer ? 30 : 0) {
                    try await driver.act(.computerUse(.tripleClick(x: p.x, y: p.y)))
                }
            case .drag(let fromX, let fromY, let toX, let toY):
                // The companion cursor traces the drag so the user sees the motion —
                // and like clicks, the press waits for it to actually ARRIVE.
                let flight = guidanceOverlay.navigate(toGlobalPoint: globalAppKit(fromX, fromY))
                try? await Task.sleep(for: .milliseconds(Int(flight * 1000)))
                guidanceOverlay.press()
                guidanceOverlay.navigate(toGlobalPoint: globalAppKit(toX, toY))
                let from = cg(fromX, fromY)
                let to = cg(toX, toY)
                if keepPointer { lastPointerRoutedPoint = to }
                try await clickRestoringCursor(settleMs: keepPointer ? 30 : 0) {
                    try await driver.act(.computerUse(.drag(fromX: from.x, fromY: from.y, toX: to.x, toY: to.y)))
                }
            case .rightClick(let x, let y):
                let flight = guidanceOverlay.navigate(toGlobalPoint: globalAppKit(x, y))
                try? await Task.sleep(for: .milliseconds(Int(flight * 1000)))
                guidanceOverlay.press()
                try? await Task.sleep(for: .milliseconds(55))
                let p = cg(x, y)
                if keepPointer {
                    lastPointerRoutedPoint = p
                    try await clickRestoringCursor(settleMs: 30) { try await driver.act(.computerUse(.rightClick(x: p.x, y: p.y))) }
                } else if skill?.axUnreliable == true || !Self.axActivate(atCG: p, showMenu: true) {
                    try await clickRestoringCursor { try await driver.act(.computerUse(.rightClick(x: p.x, y: p.y))) }
                }
            case .type(let text):
                // Tiered text entry (tiptour-macos ActionExecutor pattern): AX
                // selected-text insertion (instant, never dropped) → clipboard
                // paste with restore → paced synthetic keystrokes. Catalyst and
                // Electron apps (WhatsApp, Slack) drop fast synthetic typing, so
                // keystrokes are the LAST resort, not the default.
                if driver.runState.isStopRequested { throw ComputerUseError.stopped }
                // Audit the mechanism and size only — never the text itself (the
                // agent may type sensitive content the user dictated).
                if let skill, skill.shouldTypePhysicalKeys(text),
                   let keys = AppSkillRegistry.physicalKeySequence(for: text) {
                    // Modal numeric input (Blender): the app ignores AX insertion,
                    // paste, and unicode-string events — only real per-key events
                    // register. Paced so the modal operator sees each key.
                    if keepPointer { await establishPointerRoutedPosition() }
                    for key in keys {
                        try await driver.act(.computerUse(.key(key, modifiers: [])))
                        try? await Task.sleep(for: .milliseconds(30))
                    }
                    _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "computer.type.keys", detail: "chars=\(text.count) skill=\(skill.name)"))
                } else if skill?.axUnreliable != true, Self.axInsertText(text) {
                    // Skipped for axUnreliable apps: their AX tree can accept the
                    // write and report success while nothing visible changes.
                    _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "computer.type.ax", detail: "chars=\(text.count)"))
                } else if await pasteText(text, pointerRouted: keepPointer) {
                    _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "computer.type.paste", detail: "chars=\(text.count)"))
                } else {
                    try await driver.act(.computerUse(.typeText(text)))
                }
            case .key(let combo):
                // Pointer-routed apps act where they last saw the pointer —
                // re-teach them the agent's working point before the key.
                if keepPointer { await establishPointerRoutedPosition() }
                let (key, modifiers) = Self.parseKey(combo)
                try await driver.act(.computerUse(.key(key, modifiers: modifiers)))
            case .scroll(let x, let y, let direction, let amount):
                guidanceOverlay.navigate(toGlobalPoint: globalAppKit(x, y))
                let p = cg(x, y)
                let (dx, dy) = Self.scrollDelta(direction: direction, amount: amount)
                let origin = Self.cursorCG()
                // A real move event (not a warp) so pointer-tracking apps
                // apply the scroll at the target; the restore stays a silent
                // warp to avoid hover side-effects at the user's parked spot.
                if keepPointer { lastPointerRoutedPoint = p }
                try await driver.act(.computerUse(.move(x: p.x, y: p.y)))
                do { try await driver.act(.computerUse(.scroll(deltaX: dx, deltaY: dy))) }
                catch { CGWarpMouseCursorPosition(origin); throw error }
                CGWarpMouseCursorPosition(origin)
            case .wait:
                try? await Task.sleep(for: .milliseconds(700))
            case .screenshot:
                break
            case .zoom:
                break  // handled inside the episode loop (needs the cropped frame back)
            case .highlight(let x, let y, let width, let height, let label):
                // The agent showing the user something — Cascade's own overlay.
                let g = CGRect(x: screen.frame.minX + x, y: screen.frame.minY + y, width: width, height: height)
                guidanceOverlay.highlight(globalRect: g)
                guidanceOverlay.present(atGlobalPoint: CGPoint(x: g.midX, y: g.midY), label: label)
                assistMemory.rememberPointed(label: label, globalPoint: CGPoint(x: g.midX, y: g.midY))
                agentDidHighlight = true
                _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "agent.highlight", detail: label))
            case .openApp(let name):
                // Instant programmatic launch — no Dock hunting, no cursor. Heavy apps
                // (Word, Photoshop) take seconds to boot AND keep painting after they're
                // technically frontmost — a too-early screenshot made the model repeat
                // new-document actions ("4 untitled documents"). Wait until frontmost
                // (up to ~8s), then give a cold launch a beat to finish drawing.
                dock.show(title: "Opening \(name)", detail: "")
                let wasAlreadyRunning = NSWorkspace.shared.runningApplications
                    .contains { $0.localizedName?.caseInsensitiveCompare(name) == .orderedSame }
                if await Self.openApp(named: name) {
                    for _ in 0..<32 {
                        // Containment, not equality: the asked-for name and the
                        // app's display name routinely differ ("Keynote" vs
                        // "Keynote Creator Studio") — exact compare never matched
                        // and silently burned the full 8s poll every open.
                        if let front = NSWorkspace.shared.frontmostApplication?.localizedName,
                           front.localizedCaseInsensitiveContains(name)
                            || name.localizedCaseInsensitiveContains(front) { break }
                        try? await Task.sleep(for: .milliseconds(250))
                    }
                    if !wasAlreadyRunning {
                        try? await Task.sleep(for: .milliseconds(1200))
                    }
                }
                // On failure the next screenshot shows nothing changed and Claude
                // falls back to the visual path.
            case .openURL(let urlString):
                // http(s) only — the agent must not trigger arbitrary URL schemes.
                if let url = URL(string: urlString), url.scheme == "https" || url.scheme == "http" {
                    dock.show(title: "Opening \(url.host() ?? "page")", detail: "")
                    NSWorkspace.shared.open(url)
                    // Give the browser a beat to come forward and start loading.
                    try? await Task.sleep(for: .milliseconds(900))
                }
            }
            return true
        } catch ComputerUseError.stopped {
            return false
        } catch {
            teachMessage = "I need Accessibility + Input Monitoring to control the Mac."
            voice.speak("I need Accessibility and Input Monitoring permission to do that.")
            return false
        }
    }

    private var lastNarrationAt = Date.distantPast
    private var lastNarratedLine = ""

    /// Keeps the agent talky while it works: the model's short progress lines
    /// ("writing the poem now") go to the dock and — on voice — are spoken.
    /// Throttled, and consecutive repeats are never spoken twice ("he repeats
    /// what he says"). Returns true when a line was actually spoken so the
    /// caller can give the speech a head start before the actions land.
    @discardableResult
    private func narrateProgress(_ text: String) -> Bool {
        let line = String(text.split(separator: "\n").first ?? "").trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return false }
        dock.show(title: "Cascade is working", detail: String(line.prefix(120)))
        guard line.count <= 120,
              line.caseInsensitiveCompare(lastNarratedLine) != .orderedSame,
              Date().timeIntervalSince(lastNarrationAt) >= 4 else { return false }
        lastNarrationAt = Date()
        lastNarratedLine = line
        voice.speak(line)
        return true
    }

    /// The app skill matching whatever app is frontmost right now, if any.
    private func frontmostSkill() -> AppSkill? {
        let front = NSWorkspace.shared.frontmostApplication
        return appSkills.skill(appName: front?.localizedName, bundleIdentifier: front?.bundleIdentifier)
    }

    /// The full skill text to PUSH into Scout this turn: the frontmost app's skill
    /// PLUS its related task/recipe skills. The Opus path reaches the recipe skills
    /// (e.g. `keynote-consulting` — how to actually build a good deck) via the
    /// use_skill tool; Scout has no pull, so they must be pushed. Related skills are
    /// found by the `<app>-<task>` naming convention (the app skill's name is their
    /// prefix), so it generalizes to any app pack without hardcoding. Scripting
    /// playbooks (`explicitAskOnly`) are included only when the goal asks for a
    /// script — the same gate the Opus skillProvider applies. nil when no app skill
    /// matches (so applySkill leaves the prompt unchanged). See [[cascade-cu-downgrade-research]].
    private func scoutSkillPush(goal: String) -> String? {
        guard let app = frontmostSkill() else { return nil }
        let asksScript = AppSkill.goalAsksForScript(goal)
        let related = appSkills.skills.filter { skill in
            (skill.name == app.name || skill.name.hasPrefix(app.name + "-"))
                && (!skill.explicitAskOnly || asksScript)
        }
        let blocks = related.map(\.promptBlock)
        return blocks.isEmpty ? nil : blocks.joined(separator: "\n\n---\n\n")
    }

    /// Pointer-routed apps (Blender) send hotkeys to the editor at the position
    /// they last LEARNED from a mouse-move event — not at the visible cursor
    /// (warps are invisible to them). Before bare keys/typing/paste, re-teach
    /// the app the point the agent is working at (its last click/hover, else
    /// the frontmost window's centre) with a real move event, give the queue a
    /// beat to deliver it, then warp the user's cursor straight back: the app
    /// keeps acting at the agent's point while the user's cursor never stays
    /// hijacked. Always re-teach — the visible cursor says nothing about the
    /// app's learned position once restores are in play. Uses CGWindowList,
    /// not AX — these apps are the ones whose AX trees can't be trusted.
    private func establishPointerRoutedPosition() async {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                  as? [[String: Any]] else { return }
        for info in infos {
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == app.processIdentifier,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { continue }
            let origin = Self.cursorCG()
            let target: CGPoint
            if let last = lastPointerRoutedPoint, bounds.contains(last) {
                target = last
            } else {
                target = CGPoint(x: bounds.midX, y: bounds.midY)
            }
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: target, mouseButton: .left)?
                .post(tap: .cghidEventTap)
            // Let the queued event deliver before warping back — processed
            // after the warp it would drag the visible cursor to the target.
            try? await Task.sleep(for: .milliseconds(40))
            CGWarpMouseCursorPosition(origin)
            return
        }
    }

    /// Where the agent last clicked/hovered in a pointer-routed app — the point
    /// its hotkeys should keep acting at after the cursor restore.
    private var lastPointerRoutedPoint: CGPoint?

    /// Runs a CGEvent click body, then snaps the real cursor back to exactly where
    /// it was — the fallback for targets Accessibility can't press. The actuator
    /// checks health/STOP *before* posting, so on throw the cursor hasn't moved and
    /// we just rethrow. `settleMs` waits before the restore so every queued event
    /// is delivered first (a move processed after the warp would drag the visible
    /// cursor back out to the click point).
    private func clickRestoringCursor(settleMs: Int = 0, _ body: () async throws -> Void) async throws {
        let origin = Self.cursorCG()
        try await body()
        if settleMs > 0 { try? await Task.sleep(for: .milliseconds(settleMs)) }
        CGWarpMouseCursorPosition(origin)
    }

    /// Presses the UI element at a global top-left point through the Accessibility
    /// API — a real activation with **zero cursor movement**. Focuses text inputs so
    /// a following `type` lands. Returns false if nothing actionable is there (the
    /// caller then falls back to a cursor-restoring CGEvent click).
    private static func axActivate(atCG point: CGPoint, showMenu: Bool = false) -> Bool {
        let system = AXUIElementCreateSystemWide()
        var ref: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &ref) == .success,
              let element = ref else { return false }

        if !showMenu, let role = axString(element, kAXRoleAttribute), textRoles.contains(role) {
            // Multi-line editors are clicked to PLACE THE CARET at the click
            // point. AX focus lands the element but never moves the caret — the
            // click would "succeed" while typing lands at the old insertion
            // point. Only a real CGEvent click positions the caret.
            if role == "AXTextArea" { return false }
            if AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success {
                return true
            }
        }

        var namesRef: CFArray?
        let names = (AXUIElementCopyActionNames(element, &namesRef) == .success ? namesRef as? [String] : nil) ?? []
        let wanted = showMenu ? [kAXShowMenuAction] : [kAXPressAction, kAXConfirmAction, kAXPickAction]
        for action in wanted where names.contains(action) {
            if AXUIElementPerformAction(element, action as CFString) == .success { return true }
        }
        return false
    }

    /// Pastes text via the clipboard (cmd+V), restoring the user's previous
    /// clipboard afterwards — tiptour-macos's fallback for apps whose fields
    /// don't take AX insertion. Returns false if the paste keystroke fails.
    /// Pointer-routed apps (Blender) need three deviations: the pointer must be
    /// inside the app's window (keys route to the editor under it), the chord is
    /// ctrl+V (the literal keymap binding — cmd is only an alias layer), and the
    /// clipboard must stay ours much longer: the app reads it when its main loop
    /// runs the paste operator, easily later than the keystroke itself.
    private func pasteText(_ text: String, pointerRouted: Bool = false) async -> Bool {
        if pointerRouted { await establishPointerRoutedPosition() }
        let pasteboard = NSPasteboard.general
        // Snapshot what the user had so the agent never eats their clipboard.
        let previous = pasteboard.pasteboardItems?.map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        } ?? []
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        defer {
            pasteboard.clearContents()
            if !previous.isEmpty { pasteboard.writeObjects(previous) }
        }
        do {
            if pointerRouted {
                // Pointer-routed apps' only paste targets are FIELDS (hex colors,
                // names, search boxes) — and Blender fields keep their old text:
                // pasting without a selection APPENDS ("FFFFFFCFCBC3" hex soup,
                // per the audit log). Select-all first makes the paste REPLACE;
                // on an empty field it's a no-op. ctrl, not cmd: the literal
                // Blender binding for both chords.
                try await driver.act(.computerUse(.key("a", modifiers: ["control"])))
                try? await Task.sleep(for: .milliseconds(60))
            }
            try await driver.act(.computerUse(.key("v", modifiers: [pointerRouted ? "control" : "command"])))
            // Let the app consume the pasteboard before we restore it.
            try? await Task.sleep(for: .milliseconds(pointerRouted ? 900 : 180))
            return true
        } catch {
            return false
        }
    }

    /// Inserts text at the caret of the frontmost app's focused element by setting
    /// `AXSelectedText` (the tiptour-macos `ActionExecutor` pattern — see
    /// docs/THIRD_PARTY_NOTICES.md). Returns false when there's no focused,
    /// settable text element — the caller falls back to synthetic keystrokes.
    private static func axInsertText(_ text: String) -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication,
              // Never AX-insert into Cascade's OWN focused element — if Cascade is
              // frontmost the insert "succeeds" silently and the text never reaches
              // the target app (the audited phantom "can't type"). Fall through to
              // paste / keystrokes, which follow real keyboard focus.
              app.bundleIdentifier != "com.humain.cascade" else { return false }
        let appRef = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appRef, 0.3)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appRef, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        let element = focused as! AXUIElement
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue,
              AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success
        else { return false }
        // VERIFY the insert actually took. Web <input>/combobox elements (Google
        // Flights, most sites) ACCEPT the set and report .success while the value
        // never changes — the phantom write behind the audited "can't type"
        // (computer.type.ax → no-effect, while the SAME field+text via paste worked).
        // Read the value back; only claim success if it now reflects the text, else
        // return false so the caller falls to paste/keystrokes, which DO land. A
        // field that doesn't expose its value reads nil → also falls through (paste
        // is reliable, so an occasional unnecessary paste is harmless).
        let after = axString(element, kAXValueAttribute as String)
            ?? axString(element, kAXSelectedTextAttribute as String)
        return after?.contains(text) ?? false
    }

    private nonisolated static func axString(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    /// The title of a sheet or modal dialog currently focused in the frontmost
    /// app, or nil when the UI is in its normal state. Off-main — AX calls block.
    private static func unexpectedModal() async -> String? {
        await Task.detached { () -> String? in
            guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.isActive }) else { return nil }
            let appRef = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(appRef, 0.3)
            var focusedRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &focusedRef) == .success,
                  let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else { return nil }
            let window = focusedRef as! AXUIElement
            let role = axString(window, kAXRoleAttribute) ?? ""
            let subrole = axString(window, kAXSubroleAttribute) ?? ""
            guard role == "AXSheet" || subrole == "AXDialog" || subrole == "AXSystemDialog" else { return nil }
            let title = axString(window, kAXTitleAttribute) ?? ""
            return title.isEmpty ? (role == "AXSheet" ? "sheet" : "dialog") : title
        }.value
    }

    private static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    /// Current cursor position in CGEvent global (top-left) coordinates.
    private static func cursorCG() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }

    /// "Where can I find/do X" when X isn't on the current screen: navigate (open the
    /// right app/menu/tab, scroll) to bring it into view, then frame it with the marquee.
    /// It reveals — it does NOT click the target itself. STOP-able and capped.
    private func findAndReveal(question: String, screen: NSScreen, firstScreenshotPNG: Data, gen: Int) async {
        driver.runState.reset()
        teachMessage = "Let me find that for you…"
        voice.speak("One moment — let me find that.")
        let dw = Int(screen.frame.width), dh = Int(screen.frame.height)

        let navigator = ComputerUseAgent(effort: "low", environmentNote: """
        The user is trying to FIND or REACH "\(question)" but it is not on the screen yet. \
        Navigate this Mac to bring it into view — open the relevant app, menu, or tab, or \
        scroll. Take the most DIRECT path and use as few steps as possible. One action at a \
        time. Do NOT click or activate the target itself; just surface it so it becomes \
        visible. Once it is visible on screen, stop.
        """)
        var step = await navigator.begin(
            goal: "Surface on screen where the user can find or do: \(question)",
            screenshot: firstScreenshotPNG,
            displayWidthPoints: dw, displayHeightPoints: dh,
            conversation: assistMemory.historyForAPI()
        )

        // Backstop only — surfacing an element is a bounded task, but 6 nav steps
        // wasn't enough to open an app, switch a tab, and scroll to the target.
        let maxSteps = 14
        var count = 0
        while count < maxSteps {
            if assistGeneration != gen { return }  // superseded by a newer turn
            if driver.runState.isStopRequested { teachMessage = "Stopped."; return }
            var failed = false
            for action in step.actions {
                if !(await executeCU(action, on: screen)) { failed = true; break }
                try? await Task.sleep(for: .milliseconds(80))
            }
            if failed { return }  // executeCU surfaced the permission/STOP reason
            try? await Task.sleep(for: .milliseconds(220))

            // Capture once at the agent's resolution as JPEG — both consumers below
            // accept it as-is, skipping the PNG round-trip, OCR, and re-encodes.
            let size = navigator.captureSize
            guard let shot = await ScreenCaptureUtility.captureCursorScreenJPEG(width: size.width, height: size.height) else { break }
            // Detection (is it visible now?) and the next nav step fire concurrently, so
            // each loop turn costs ONE round-trip of wall-clock instead of two. If found,
            // the speculative nav step is just discarded.
            async let regionTask = locateRegionGrounded(
                screenshot: shot, question: question, displayWidthPoints: dw, displayHeightPoints: dh,
                conversation: assistMemory.historyForAPI()
            )
            async let nextStepTask = navigator.proceed(screenshot: shot)

            let region = await regionTask
            if let local = region.rect {
                let g = CGRect(
                    x: screen.frame.minX + local.minX, y: screen.frame.minY + local.minY,
                    width: local.width, height: local.height
                )
                guidanceOverlay.highlight(globalRect: g)
                guidanceOverlay.present(atGlobalPoint: CGPoint(x: g.midX, y: g.midY), label: "here")
                assistMemory.rememberPointed(label: question, globalPoint: CGPoint(x: g.midX, y: g.midY))
                assistMemory.remember(user: question, assistant: region.speech)
                teachMessage = region.speech
                voice.speak(region.speech)
                voice.done()
                _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "teach.reveal", detail: question))
                await refreshAll()
                return
            }
            let next = await nextStepTask
            if next.done { break }
            step = next
            count += 1
        }

        guidanceOverlay.hide()
        teachMessage = "I opened a few things but couldn't surface that — it may not be here."
        assistMemory.remember(user: question, assistant: teachMessage, ok: false)
        voice.speak("I couldn't bring that on screen.")
        voice.done()
    }

    /// Splits a Computer Use key string ("Return", "cmd+space", "ctrl+c") into a
    /// key name + modifier list the native actuator understands.
    private static func parseKey(_ combo: String) -> (String, [String]) {
        let parts = combo.split(whereSeparator: { $0 == "+" || $0 == "-" })
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard let last = parts.last, !last.isEmpty else { return (combo.lowercased(), []) }
        let modifiers = parts.dropLast().map { $0 == "super" || $0 == "win" ? "command" : $0 }
        let key: String
        switch last {
        case "enter", "\u{000A}": key = "return"
        case "esc": key = "escape"
        case "del", "backspace": key = "delete"
        case "spc": key = "space"
        default: key = last
        }
        return (key, modifiers)
    }

    /// Maps a Computer Use scroll direction + click count to pixel deltas for the
    /// native scroll actuator (wheel1 = vertical, positive = up).
    private static func scrollDelta(direction: String, amount: Int) -> (Double, Double) {
        let step = Double(max(1, amount)) * 40
        switch direction.lowercased() {
        case "up": return (0, step)
        case "down": return (0, -step)
        case "left": return (step, 0)
        case "right": return (-step, 0)
        default: return (0, -step)
        }
    }

    /// Commands with no multi-part connectors skip the planner round-trip — a
    /// single Computer Use episode handles them (exactly the pre-planner behavior),
    /// saving ~a second of up-front latency on the most common short commands.
    private static func isSinglePartCommand(_ text: String) -> Bool {
        guard text.count < 60 else { return false }
        let t = " " + text.lowercased() + " "
        let connectors = [" then ", " after that ", " and then ", "; ", ", and ", " followed by "]
        return !connectors.contains { t.contains($0) }
    }

    /// Heuristic: did the user ask Cascade to *do* something (act) vs *find/show*
    /// something (point only)? Imperatives ACT by default — a whitelist of verbs
    /// kept failing open-ended requests ("design me a landing page" was coached
    /// instead of done). Only clearly question-shaped asks stay point-only.
    nonisolated static func isActionRequest(_ text: String) -> Bool {
        let t = text.lowercased()
        // Highlight/mark requests go to the acting agent — it owns the highlight
        // tool and can navigate/scroll to surface the target first. This wins even
        // over question-y phrasing ("show me X and highlight them").
        if t.contains("highlight") || t.contains("point out") || t.contains(" mark ") || t.hasPrefix("mark ") {
            return true
        }
        // The find-vs-where-is split: "where is X" / "where can I find X" / "show me X"
        // POINT at the target (highlight); a bare imperative "find X" / "find it for me"
        // means GO DO IT — navigate / open / surface it. So "find" is NOT a point
        // trigger; only the locational "where…" is (which still catches "where can I
        // find X"). Previously "find " sat here and sent every "find …" to point-only.
        let teachy = ["where", "how do i", "how can i", "show me", "what is", "what's",
                      "which ", "who ", "is there", "are there", "can i ", "does "]
        if teachy.contains(where: { t.contains($0) }) { return false }
        return true
    }

    /// Questions about the recorded past ("what did I do today?") — answered from
    /// the local record, never by driving the screen.
    private static func isRetrospective(_ text: String) -> Bool {
        let t = text.lowercased()
        let markers = ["what did", "what was", "what have", "did i ", "summar", "recap",
                       "yesterday", "this morning", "this week", "last week", "earlier today"]
        return markers.contains { t.contains($0) }
    }

    /// Global AppKit (bottom-left, primary-display origin) → CGEvent global
    /// (top-left) coordinates for the native actuator.
    private static func toCGGlobal(_ appkit: CGPoint) -> CGPoint {
        let primaryHeight = (NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main)?.frame.height ?? appkit.y
        return CGPoint(x: appkit.x, y: primaryHeight - appkit.y)
    }

    // MARK: - Teach-once (demonstrate a task → agent)

    /// How far before the finishing ⌥⌃T press the bracket ends — enough to exclude
    /// the recorded hotkey combo without dropping real work (the user is mid-keystroke
    /// reaching for the chord, not acting in the app).
    private static let teachFinishGuard: TimeInterval = 0.3

    /// ⌥⌃T toggles a demonstration: first press starts the bracket, second press ends
    /// it and curates the recording into an agent.
    public func toggleTeaching() {
        if teachingMode { endTeaching() } else { beginTeaching() }
    }

    /// The banner dismiss (×). The persistent "Teaching…"/"Saving…" states move on by
    /// themselves; this is for the terminal result lines.
    public func dismissTeachStatus() { teachStatus = nil }

    private var teachStatusToken = 0

    /// A terminal teach status that fades on its own (added/sent/nothing-found/error),
    /// unless a newer one supersedes it or a demonstration is in progress.
    private func flashTeachStatus(_ text: String) {
        teachStatusToken += 1
        let token = teachStatusToken
        teachStatus = text
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, self.teachStatusToken == token, !self.teachingMode else { return }
            self.teachStatus = nil
        }
    }

    /// Start a demonstration. Recording is already always-on, so this only stamps the
    /// lower bound of the time range and reroutes narration into the intent buffer —
    /// nothing new is captured. Refuses while an agent is acting (those events would
    /// be the agent's, not the user's hand).
    public func beginTeaching() {
        guard !teachingMode else { return }
        guard !assistTaskRunning, !agentRunning else {
            flashTeachStatus("Finish the running task before teaching.")
            return
        }
        teachStartedAt = Date()
        teachIntentBuffer.removeAll()
        teachingMode = true
        teachStatus = "Teaching — do the task, narrate if you like, then press ⌥⌃T to finish."
        Task { _ = try? await store.appendAudit(AuditEvent(actor: "employee", action: "teach.started", detail: "")) }
    }

    /// End the demonstration and turn the bracketed range into a curated agent (shown
    /// in the preview sheet). The curation rides the SAME spine as auto-detection —
    /// `curateRange` → `DetectedWaste` → `curateOne` → the existing `createAgent`.
    public func endTeaching() {
        guard teachingMode, let start = teachStartedAt else { return }
        // The finishing ⌥⌃T press is itself recorded (control+option = a structural
        // key combo), so end the bracket just BEFORE it — otherwise it becomes a
        // spurious recipe step that on replay would re-trigger teaching. (The start
        // press is already excluded: it lands before `teachStartedAt` was stamped.)
        // The guard only drops the fraction of a second around the hotkey, where the
        // user is reaching for keys, never doing the task.
        let end = max(start, Date().addingTimeInterval(-Self.teachFinishGuard))
        teachingMode = false
        teachStartedAt = nil
        let intent = teachIntentBuffer.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        teachIntentBuffer.removeAll()
        teachStatus = "Saving your demonstration…"
        Task { _ = try? await store.appendAudit(AuditEvent(actor: "employee", action: "teach.stopped", detail: intent.isEmpty ? "(silent)" : String(intent.prefix(120)))) }
        Task { await buildTaughtAgent(from: start, to: end, statedIntent: intent.isEmpty ? nil : intent) }
    }

    private func buildTaughtAgent(from start: Date, to end: Date, statedIntent: String?) async {
        // Let the always-on recorder's 1s drain flush the bracketed events AND attach
        // AX click labels before we read them — the drain defers unlabeled clicks
        // <0.35s old, and those labels are the strongest replay anchor, so a forced
        // immediate flush would lose them. ~1.5s is a safe settle.
        try? await Task.sleep(for: .milliseconds(1500))
        do {
            let curated = try await orchestrator.curateRange(
                from: start, to: end,
                statedIntent: statedIntent,
                webAppIdentity: Self.webAppIdentity
            )
            if let curated {
                teachStatus = nil
                teachPreview = curated
            } else {
                flashTeachStatus("Nothing repeatable in that demonstration yet — try the task again.")
            }
        } catch {
            flashTeachStatus("Couldn't build an agent from that: \(error.localizedDescription)")
        }
    }

    /// "Add to my agents": the employee self-serves the taught recipe straight into
    /// their Cascades, ready to deploy — the same `createAgent` the manager path uses.
    public func createTaughtAgent(_ curated: CuratedAgent) {
        teachPreview = nil
        Task {
            do {
                _ = try await orchestrator.createAgent(from: curated)
                _ = try? await store.appendAudit(AuditEvent(actor: "employee", action: "agent.taught", detail: curated.name))
                selectedTab = .cascades
                flashTeachStatus("Added “\(curated.name)” to your agents.")
            } catch {
                flashTeachStatus("Couldn't add “\(curated.name)”: \(error.localizedDescription)")
            }
            await refreshAll()
        }
    }

    /// "Send to manager": the taught recipe joins the manager's review queue
    /// (`pendingCuratedAgents`) instead of being created directly — the manager
    /// approves or declines it like any auto-detected workflow.
    public func sendTaughtAgentToManager(_ curated: CuratedAgent) {
        teachPreview = nil
        if !taughtForReview.contains(where: { $0.signature == curated.signature }) {
            taughtForReview.insert(curated, at: 0)
        }
        flashTeachStatus("Sent “\(curated.name)” to your manager for review.")
        Task { _ = try? await store.appendAudit(AuditEvent(actor: "employee", action: "teach.sentToManager", detail: curated.name)) }
    }

    /// Drop a taught proposal from the review queue once it's been acted on (approved
    /// → it's a real agent now; declined → it's dismissed).
    private func clearTaughtForReview(signature: String) {
        taughtForReview.removeAll { $0.signature == signature }
    }

    // MARK: - Agents built from recorded workflows

    /// The curated proposals still awaiting review — the review surface's source of
    /// truth (R1). Auto-detected workflows plus the demonstrations the employee sent
    /// up for review (taught-once); same approved/declined filter, keyed by signature.
    /// Taught proposals lead — they're the freshest, most intentional candidates.
    public var pendingCuratedAgents: [CuratedAgent] {
        let approved = Set(agents.map(\.signature))
        var seen = Set<String>()
        return (taughtForReview + curatedWaste).filter { candidate in
            guard !approved.contains(candidate.signature),
                  !dismissedWasteSignatures.contains(candidate.signature),
                  !seen.contains(candidate.signature) else { return false }
            seen.insert(candidate.signature)
            return true
        }
    }

    /// A transient confirmation for the Manager's review queue — approve/decline
    /// happen on the Manager tab, so the only feedback (the new agent landing in the
    /// Cascades tab) is somewhere the manager isn't looking. This banner closes that
    /// gap. It auto-clears, superseded by the next review action.
    @Published public private(set) var managerReviewNote: String?
    private var managerReviewNoteToken = 0

    private func flashManagerReviewNote(_ text: String) {
        managerReviewNoteToken += 1
        let token = managerReviewNoteToken
        managerReviewNote = text
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, self.managerReviewNoteToken == token else { return }
            self.managerReviewNote = nil
        }
    }

    /// The MANAGER approves a curated proposal from the review queue: it builds the
    /// agent from the recorded recipe but keeps the curator's human name, and the
    /// approved agent lands in the employee's Cascades tab ("Your agents"), ready to
    /// deploy (in the background sandbox for web work, on-screen for native).
    public func approveCurated(_ curated: CuratedAgent) {
        clearTaughtForReview(signature: curated.signature)
        Task {
            do {
                _ = try await orchestrator.createAgent(from: curated)
                _ = try? await store.appendAudit(AuditEvent(actor: "manager", action: "agent.approved", detail: curated.name))
                flashManagerReviewNote("Approved “\(curated.name)” — it's now in the employee's Cascades, ready to deploy.")
            } catch {
                flashManagerReviewNote("Couldn't approve “\(curated.name)”: \(error.localizedDescription)")
            }
            await refreshAll()
        }
    }

    /// The manager dismisses a curated proposal — hides its underlying workflow for
    /// good, so it never returns to the review queue.
    public func declineCurated(_ curated: CuratedAgent) {
        clearTaughtForReview(signature: curated.signature)
        dismissedWasteSignatures.insert(curated.signature)
        flashManagerReviewNote("Dismissed “\(curated.name)” — you won't see it again.")
        Task { _ = try? await store.appendAudit(AuditEvent(actor: "manager", action: "agent.declined", detail: curated.name)) }
    }

    public func setAgentEnabled(_ agent: CascadeAgent, enabled: Bool) {
        Task {
            try? await store.setAgentEnabled(id: agent.id, enabled: enabled)
            await refreshAll()
        }
    }

    public func deleteAgent(_ agent: CascadeAgent) {
        Task {
            try? await store.deleteAgent(id: agent.id)
            await refreshAll()
        }
    }

    /// Whether a workflow's apps are all web browsers — those agents deploy in the
    /// BACKGROUND sandbox (your screen stays yours, saved sign-ins reused).
    /// "Browser" is decided by CAPABILITY, not a brand list: any app the system
    /// registers to open https URLs qualifies, so every browser the user actually
    /// has — today or one installed later — counts, with nothing hardcoded.
    public nonisolated static func runsInBackground(apps: [String]) -> Bool {
        !apps.isEmpty && apps.allSatisfy { webBrowserNames.contains($0.lowercased()) }
    }

    /// How many non-overlapping repeats a detected workflow needs before it is
    /// worth a manager's attention. The detector recalls anything seen twice (it
    /// powers the Manager's "where the time goes" insight), but turning something
    /// into a reviewable agent demands a genuine HABIT — three or more.
    nonisolated static let minRepeatsToAutomate = 3

    /// The minimum observed time (seconds, across all repeats) a workflow must
    /// represent before it's worth a manager's review. The model's WORTH judgment
    /// (the curator) refines this, but the curator falls back to keeping everything
    /// without a key — so a deterministic floor keeps trivial sub-minute habits out
    /// of the queue regardless. "Really save time" starts here.
    nonisolated static let minSecondsToReview = 30

    /// A real habit — repeated often enough to be worth automating, not a one-off.
    /// Browser-independent, so it can be pinned without the machine's browser list.
    nonisolated static func meetsRepetitionBar(_ waste: DetectedWaste) -> Bool {
        waste.occurrences >= minRepeatsToAutomate
    }

    /// Represents real time — the cumulative observed seconds clear the floor, so a
    /// trivial sub-minute habit never reaches the queue even when the curator (which
    /// refines WORTH) is unavailable and would otherwise keep everything.
    nonisolated static func representsRealTime(_ waste: DetectedWaste) -> Bool {
        waste.estimatedTotalSeconds >= minSecondsToReview
    }

    /// The product bar for promoting a detected repetition into an agent the
    /// manager reviews: a real, time-saving habit — repeated enough to be a habit and
    /// representing real time. App identity does NOT gate this: a browser-only
    /// workflow deploys to the background sandbox, a native-app one replays on-screen
    /// (and escalates to the full cursor-class runtime on drift), so every kind of
    /// repeated work can become an agent. `deployAgent` routes by app at deploy time.
    nonisolated static func isAutomatable(_ waste: DetectedWaste) -> Bool {
        meetsRepetitionBar(waste) && representsRealTime(waste)
    }

    /// The web app inside a browser an event happened on (Gmail, Notion, Figma…), so a
    /// browser workflow is detected and named as THAT app, not the browser shell.
    /// Native-app events return nil — their app name already is the app. Passed to the
    /// detector so two web apps in one browser become two distinct agents.
    nonisolated static func webAppIdentity(for event: InputEvent) -> String? {
        guard webBrowserNames.contains(event.appName.lowercased()) else { return nil }
        return WebAppIdentity.from(windowTitle: event.windowTitle)
    }

    /// The app to SHOW for a recorded moment in the Reel: the web app inside the
    /// browser (Gmail, Notion…) when identifiable, else the macOS app — so the Rewind
    /// timeline reads like the user's actual workspace instead of "Google Chrome" for
    /// everything. Native moments return their own name unchanged.
    nonisolated static func displayApp(appName: String, windowTitle: String?) -> String {
        guard webBrowserNames.contains(appName.lowercased()) else { return appName }
        return WebAppIdentity.from(windowTitle: windowTitle) ?? appName
    }

    /// Installed https-handling apps (i.e. the user's browsers), in every name form
    /// the recorder might have captured them under — filename stem, localized display
    /// name, and bundle display/name keys. Queried once from LaunchServices and cached
    /// (`runsInBackground` is called from view bodies, so it must stay a set lookup).
    /// Empty — e.g. LaunchServices unavailable — degrades safely: agents simply deploy
    /// on-screen instead of in the sandbox.
    private nonisolated static let webBrowserNames: Set<String> = {
        guard let https = URL(string: "https://example.com") else { return [] }
        var names = Set<String>()
        for url in NSWorkspace.shared.urlsForApplications(toOpen: https) {
            names.insert(url.deletingPathExtension().lastPathComponent.lowercased())
            names.insert(FileManager.default.displayName(atPath: url.path).lowercased())
            if let info = Bundle(url: url)?.infoDictionary {
                for key in ["CFBundleDisplayName", "CFBundleName"] {
                    if let name = info[key] as? String { names.insert(name.lowercased()) }
                }
            }
        }
        return names
    }()

    /// The natural-language task a recorded web workflow becomes in the sandbox:
    /// the agent there acts from intent (it has its own browser), not from
    /// recorded screen coordinates that mean nothing inside the box.
    static func sandboxTask(for agent: CascadeAgent) -> String {
        // Prefer the curator's plain-language goal — it's the intent written for
        // exactly this task. Recorded pixels mean nothing inside the sandbox; fall
        // back to the agent name only when there's no goal.
        let trimmedGoal = agent.goal?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let intent = trimmedGoal.isEmpty ? agent.name : trimmedGoal
        var task = "Do this recurring web task the user normally does by hand: \(intent)."
        if let hint = agent.recipe.steps.compactMap(\.windowTitleHint).first(where: { !$0.isEmpty }) {
            task += " It normally happens on the page “\(String(hint.prefix(80)))”."
        }
        let steps = agent.recipe.humanSteps.filter { $0 != "type" && $0 != "scroll" }.prefix(6).joined(separator: ", ")
        if !steps.isEmpty { task += " The user's recorded steps look like: \(steps)." }
        task += " Carry it out and report the result."
        return task
    }

    /// Runs a saved agent. Web workflows deploy as a BACKGROUND sandbox agent —
    /// the work happens in a floating box while the user keeps their screen.
    /// Everything else replays the recorded recipe on the real Mac — visible
    /// cursor, STOP valve, step cap, every action audited.
    public func deployAgent(_ agent: CascadeAgent) {
        guard !agentRunning else { return }
        guard !agent.recipe.steps.isEmpty else {
            agentMessage = "“\(agent.name)” has no recorded steps yet."
            return
        }
        if Self.runsInBackground(apps: agent.apps) {
            agentMessage = "Running “\(agent.name)” in the background sandbox."
            createSandboxAgent(task: Self.sandboxTask(for: agent), forAgent: agent.id)
            return
        }
        driver.runState.reset()
        agentRunning = true
        agentMessage = "Deploying \(agent.name)…"
        dock.show(title: "Cascade is working", detail: "Running “\(agent.name)” · press STOP to take control.")
        Task { await runAgentRecipe(agent) }
    }

    private func runAgentRecipe(_ agent: CascadeAgent) async {
        defer { agentRunning = false }
        let steps = agent.recipe.steps.sorted { $0.order < $1.order }
        var stoppedEarly = false
        // Clicks whose effect could not be confirmed in a row. One is tolerated
        // (some clicks legitimately change nothing the AX tree shows); two in a row
        // means the recipe has drifted from the live UI — pause instead of plowing
        // on blind (the tiptour-macos pattern).
        var unverifiedStreak = 0
        var verifyUnavailableLogged = false
        var skillVerifySkipLogged = false
        // Pre-replay state gate (JARVIS-1): before the FIRST click we confirm we're
        // actually in the app the recipe expects. If not, escalate to the goal-driven
        // assist loop immediately rather than clicking blind into the wrong screen
        // until two dead clicks trip the drift guard.
        var startStateChecked = false
        for (index, step) in steps.enumerated() {
            if driver.runState.isStopRequested {
                agentMessage = "Stopped. Control returned to you."
                dock.show(title: "Stopped", detail: agentMessage)
                stoppedEarly = true
                break
            }
            if step.kind == .activateApp {
                dock.show(title: "Open \(step.appName)", detail: step.windowTitleHint ?? "")
                await activateAndConfirm(name: step.appName, bundle: step.bundleIdentifier)
                continue
            }
            // Per-step precondition: a parameter (per-run-varying) value can't be
            // replayed from the recording. Hand the rest to the assist runtime,
            // which supplies the current value — never retype the stale one.
            if Self.recipeStepNeedsLiveValue(step) {
                _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "recipe.parameter", detail: Self.recipeLabel(step)))
                await escalateRecipeToAssist(agent, reason: "this step enters a value that changes each run, and I need the current one")
                stoppedEarly = true
                break
            }
            do {
                // A sheet/dialog the recording never saw is up — recorded
                // coordinates would click straight into it (tiptour's modal
                // pause). Hand control back instead of plowing on.
                if step.kind == .click || step.kind == .doubleClick || step.kind == .rightClick {
                    // One-time pre-flight: are we even in the right app before the first
                    // click? Catches activate-failed / wrong-app-stole-focus before we
                    // click into the void (activateAndConfirm gives up silently).
                    if !startStateChecked {
                        startStateChecked = true
                        if let reason = Self.startStateMismatch(step: step) {
                            _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "recipe.pause.wrongstate", detail: reason))
                            await escalateRecipeToAssist(agent, reason: reason)
                            stoppedEarly = true
                            break
                        }
                    }
                    if let modalTitle = await Self.unexpectedModal() {
                        _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "recipe.pause.modal", detail: modalTitle))
                        await escalateRecipeToAssist(agent, reason: "an unexpected dialog (“\(modalTitle)”) appeared")
                        stoppedEarly = true
                        break
                    }
                }
                if let x = step.x, let y = step.y,
                   step.kind == .click || step.kind == .doubleClick || step.kind == .rightClick {
                    let recorded = CGPoint(x: x, y: y)
                    // Canvas apps (Blender) have an AX tree that never reflects
                    // their visible UI — the skill flags them so replay skips the
                    // AX tier and fingerprint verification instead of false-pausing.
                    let stepSkill = appSkills.skill(appName: step.appName, bundleIdentifier: step.bundleIdentifier)
                    let axUnreliable = stepSkill?.axUnreliable == true
                    // Re-grounding cascade. Tier 1 (ax): re-find the element by its
                    // recorded AX label in the live tree. Tier 2 (ocr): B4's ON-DEVICE
                    // OCR grounder — find the recorded target's text on the live frame
                    // via Apple Vision, no model round-trip, and it sees canvas/Electron
                    // text the AX tree can't. Tier 3 (vision): Claude vision via the OCR
                    // anchor. Tier 4 (recorded): the recorded pixel. The tier lands in
                    // the step's audit row so a drifting recipe is diagnosable.
                    let target: CGPoint
                    let tier: String
                    if !axUnreliable, let axTarget = await Self.resolveByAX(step: step, recorded: recorded) {
                        target = axTarget
                        tier = "ax"
                    } else if let ocrTarget = await regroundedByOCR(anchor: step.ocrAnchor ?? step.text) {
                        target = ocrTarget
                        tier = "ocr"
                    } else {
                        // Falls back to `recorded` itself when there's no anchor/key.
                        target = await regroundedTarget(anchor: step.ocrAnchor, recorded: recorded)
                        tier = target == recorded ? "recorded" : "vision"
                    }
                    _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "recipe.target", detail: "\(Self.recipeLabel(step)) via \(tier)"))
                    try await driver.act(.computerUse(.move(x: target.x, y: target.y)))
                    try? await Task.sleep(for: .milliseconds(320))

                    if axUnreliable {
                        // Leave unverifiedStreak untouched — a streak from normal
                        // apps should still pause; these steps just don't count.
                        if !skillVerifySkipLogged {
                            skillVerifySkipLogged = true
                            _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "recipe.verify.skipped-skill", detail: stepSkill?.name ?? step.appName))
                        }
                        try await clickAction(step, at: target)
                    } else {
                        let before = await Self.uiFingerprint()
                        if before == 0, !verifyUnavailableLogged {
                            verifyUnavailableLogged = true
                            _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "recipe.verify.unavailable", detail: "AX fingerprint unavailable — steps run unverified"))
                        }
                        try await clickAction(step, at: target)
                        if await Self.uiChanged(after: before) {
                            unverifiedStreak = 0
                        } else {
                            // One corrective retry at the recorded coordinate (if the
                            // resolved target differed), then count the step unverified.
                            if target != recorded {
                                try await clickAction(step, at: recorded)
                            }
                            if await Self.uiChanged(after: before) {
                                unverifiedStreak = 0
                            } else {
                                unverifiedStreak += 1
                                _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "recipe.unverified", detail: Self.recipeLabel(step)))
                                if unverifiedStreak >= 2 {
                                    await escalateRecipeToAssist(agent, reason: "the screen no longer matches the recorded steps")
                                    stoppedEarly = true
                                    break
                                }
                            }
                        }
                    }
                } else if step.kind == .type, let text = step.text,
                          appSkills.skill(appName: step.appName, bundleIdentifier: step.bundleIdentifier)?
                              .shouldTypePhysicalKeys(text) == true,
                          let keys = AppSkillRegistry.physicalKeySequence(for: text) {
                    // Recorded modal numeric input (Blender) — the unicode-string
                    // typeText path is silently dropped there; replay as real keys.
                    for key in keys {
                        try await driver.act(.computerUse(.key(key, modifiers: [])))
                        try? await Task.sleep(for: .milliseconds(30))
                    }
                    unverifiedStreak = 0
                } else if let action = AgentAction(recipeStep: step) {
                    try await driver.act(action)
                    unverifiedStreak = 0
                }
                dock.show(title: "Step \(index + 1) of \(steps.count)", detail: Self.recipeLabel(step))
                _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "recipe.step", detail: Self.recipeLabel(step)))
                try? await Task.sleep(for: .milliseconds(500))
            } catch {
                agentMessage = "Stopped: \(error.localizedDescription)"
                dock.show(title: "Stopped", detail: agentMessage)
                stoppedEarly = true
                break
            }
        }
        if !stoppedEarly {
            agentMessage = "Done — ran “\(agent.name)”."
            dock.show(title: "Done", detail: agentMessage)
            // Only COMPLETED runs count — the reclaimed-time math multiplies
            // seconds-per-run by this counter, and a stopped run saved nothing.
            try? await store.markAgentRun(id: agent.id)
            _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "agent.run.completed", detail: agent.name))
        }
        await refreshAll()
    }

    /// The natural-language goal a deployed on-screen workflow hands to the assist
    /// runtime: the curator's intent (or the agent name) plus the user's recorded
    /// steps as guidance — so the cursor-class agent reproduces the workflow with the
    /// full kit (skills, harness, streaming) instead of replaying brittle pixels.
    static func deployGoal(for agent: CascadeAgent) -> String {
        let intent = agent.goal?.trimmingCharacters(in: .whitespacesAndNewlines)
        var goal = (intent?.isEmpty == false) ? intent! : agent.name
        let steps = agent.recipe.humanSteps.filter { $0 != "type" && $0 != "scroll" }.prefix(8).joined(separator: ", ")
        if !steps.isEmpty { goal += "\n(The user normally does this as: \(steps).)" }
        return goal
    }

    /// Recipe replay drifted from the live UI — instead of pausing, hand the rest of
    /// the job to the FULL assist runtime (skills, harness, streaming) from the current
    /// screen. The "fast deterministic replay, escalate to cursor-class on drift"
    /// model: fast when the UI matches, intelligent when it doesn't. Mirrors the
    /// hotkey/voice setup (bump generation, capture, supersession guard) so a barge-in
    /// still stands the escalated agent down. agentRunning stays true (the caller owns it).
    private func escalateRecipeToAssist(_ agent: CascadeAgent, reason: String) async {
        // Honor a pending STOP: runAssistTask resets runState on entry, which would
        // otherwise swallow an abort the user pressed just as drift triggered.
        guard !driver.runState.isStopRequested else {
            agentMessage = "Stopped. Control returned to you."
            dock.show(title: "Stopped", detail: agentMessage)
            return
        }
        _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "recipe.escalate", detail: "\(agent.name) — \(reason)"))
        let mouse = NSEvent.mouseLocation
        guard hasAnthropicKey, let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else {
            agentMessage = "Paused “\(agent.name)” — \(reason), and I can't take over without a Claude key. Take over, or re-record."
            dock.show(title: "Paused", detail: agentMessage)
            return
        }
        dock.show(title: "Adapting…", detail: "“\(agent.name)” — \(reason); finishing it intelligently.")
        assistGeneration += 1
        let gen = assistGeneration
        let res = AgentResolution.best(forWidth: Int(screen.frame.width), height: Int(screen.frame.height))
        guard let shot = await ScreenCaptureUtility.captureCursorScreenJPEG(width: res.w, height: res.h) else {
            agentMessage = "Paused “\(agent.name)” — couldn't capture the screen to take over."
            dock.show(title: "Paused", detail: agentMessage)
            return
        }
        guard assistGeneration == gen else { return } // a barge-in superseded us
        await runAssistTask(goal: Self.deployGoal(for: agent), screen: screen, firstScreenshotPNG: shot, gen: gen)
        agentMessage = teachMessage
    }

    /// Performs the step's click kind at a CG global point.
    private func clickAction(_ step: RecipeStep, at point: CGPoint) async throws {
        if let action = AgentAction(recipeStep: Self.retargeted(step, to: point)) {
            try await driver.act(action)
        }
    }

    /// Tier-1 target resolution: the element matching the step's recorded AX label
    /// (stored in `text` for click steps), nearest to the recorded point. Runs off
    /// the main actor — AX tree walks take tens of milliseconds.
    /// Whether the frontmost app is the one a recipe step expects. Bundle id match
    /// wins outright; otherwise display-name containment EITHER direction — a recorded
    /// "Keynote" must still match a live "Keynote Creator Studio" (the exact-equality
    /// blind spot in `activateAndConfirm`). Pure + unit-pinned.
    /// Per-step precondition for parameterized replay (Phase 1, AWM-style). A
    /// `.type` step flagged `isParameter` typed a value that VARIED across the
    /// recorded occurrences — an order number, a date, a name that changes each
    /// run. Deterministic replay only has the STALE recorded value, so its
    /// precondition ("I have the current value") fails: replay must hand off to the
    /// assist runtime, whose deploy goal is written parameter-aware and supplies
    /// the right value from context — never blindly retype last run's. Fixed steps
    /// and pre-`isParameter` recipes return false and replay normally. Pure +
    /// pinned. See [[cascade-cu-downgrade-research]].
    nonisolated static func recipeStepNeedsLiveValue(_ step: RecipeStep) -> Bool {
        step.kind == .type && step.isParameter
    }

    nonisolated static func appMatches(frontmostName: String?, frontmostBundle: String?, expectedName: String, expectedBundle: String?) -> Bool {
        if let expectedBundle, !expectedBundle.isEmpty, let frontmostBundle, !frontmostBundle.isEmpty,
           expectedBundle == frontmostBundle {
            return true
        }
        guard let frontmostName, !frontmostName.isEmpty, !expectedName.isEmpty else { return false }
        let live = frontmostName.lowercased(), expected = expectedName.lowercased()
        return live == expected || live.contains(expected) || expected.contains(live)
    }

    /// The reason the live screen doesn't match a click step's expected app, or nil
    /// when it does. The pre-replay state gate (JARVIS-1): escalate to goal-driven
    /// assist rather than click blind on the wrong screen.
    private static func startStateMismatch(step: RecipeStep) -> String? {
        let front = NSWorkspace.shared.frontmostApplication
        if appMatches(frontmostName: front?.localizedName, frontmostBundle: front?.bundleIdentifier,
                      expectedName: step.appName, expectedBundle: step.bundleIdentifier) {
            return nil
        }
        return "expected “\(step.appName)” in front but “\(front?.localizedName ?? "no app")” is — the screen isn’t where the recording started"
    }

    private static func resolveByAX(step: RecipeStep, recorded: CGPoint) async -> CGPoint? {
        let label = (step.text ?? step.ocrAnchor) ?? ""
        let (role, identifier, container) = AXTargetDescriptor.decode(step.targetDescriptor)
        // Need a label or a stable identifier to re-find the element by identity.
        guard !label.trimmingCharacters(in: .whitespaces).isEmpty || (identifier?.isEmpty == false) else { return nil }
        let descriptor = AXElementResolver.Descriptor(label: label, role: role, identifier: identifier, container: container)
        return await Task.detached(priority: .userInitiated) {
            AXElementResolver.find(descriptor: descriptor, near: recorded)?.center
        }.value
    }

    private static func uiFingerprint() async -> Int {
        await Task.detached(priority: .userInitiated) { AXElementResolver.frontmostFingerprint() }.value
    }

    /// Polls (5 × 80ms) for the frontmost AX tree to differ from `before`. A zero
    /// `before` means AX was unavailable — verification is skipped, not failed.
    private static func uiChanged(after before: Int) async -> Bool {
        guard before != 0 else { return true }
        for _ in 0..<5 {
            try? await Task.sleep(for: .milliseconds(80))
            if await uiFingerprint() != before { return true }
        }
        return false
    }

    /// Activates an app and waits (up to ~2s) until it is actually frontmost, so the
    /// next step runs against the right window — a lightweight verify between steps.
    private func activateAndConfirm(name: String, bundle: String?) async {
        activateApp(name: name, bundle: bundle)
        for _ in 0..<8 {
            if driver.runState.isStopRequested { return }
            try? await Task.sleep(for: .milliseconds(250))
            let front = NSWorkspace.shared.frontmostApplication
            // Containment, not equality: a recorded "Keynote" must confirm against a
            // live "Keynote Creator Studio" instead of burning the full 2s poll (and
            // then the B3 state gate would needlessly escalate). Shared matcher.
            if Self.appMatches(frontmostName: front?.localizedName, frontmostBundle: front?.bundleIdentifier,
                               expectedName: name, expectedBundle: bundle) { return }
        }
    }

    /// Re-locates a click target on the current screen using its recorded OCR anchor
    /// (needs a Claude key). Falls back to the recorded global coordinate when there
    /// is no anchor, no key, or the locator can't find it.
    private func regroundedTarget(anchor: String?, recorded: CGPoint) async -> CGPoint {
        guard hasAnthropicKey, let anchor, !anchor.isEmpty,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else {
            return recorded
        }
        let res = AgentResolution.best(forWidth: Int(screen.frame.width), height: Int(screen.frame.height))
        guard let shot = await ScreenCaptureUtility.captureCursorScreenJPEG(width: res.w, height: res.h) else {
            return recorded
        }
        let guidance = await elementLocator.guide(
            screenshot: shot,
            question: "Where is \(anchor)?",
            displayWidthPoints: Int(screen.frame.width),
            displayHeightPoints: Int(screen.frame.height)
        )
        guard let local = guidance.point else { return recorded }
        let appKitGlobal = CGPoint(x: screen.frame.minX + local.x, y: screen.frame.minY + local.y)
        return Self.toCGGlobal(appKitGlobal)
    }

    /// B4 on-device OCR grounder: re-locate a click target by finding its recorded
    /// text on the live screen via Apple Vision — NO model round-trip and NO
    /// Accessibility, so it grounds canvas/Electron text the AX tier is blind to, and
    /// spares the Claude-vision tier (the freeze) when the target carries text.
    /// Returns nil (caller falls through to Claude vision, then the recorded pixel)
    /// when there's no anchor or no confident text match. The coordinate conversion
    /// mirrors `regroundedTarget` EXACTLY: a Vision bounding box is normalized
    /// lower-left, the same origin as the AppKit display points `local` uses, so the
    /// box centre maps straight through with no Y-flip.
    private func regroundedByOCR(anchor: String?) async -> CGPoint? {
        guard let anchor, !anchor.trimmingCharacters(in: .whitespaces).isEmpty,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else {
            return nil
        }
        let res = AgentResolution.best(forWidth: Int(screen.frame.width), height: Int(screen.frame.height))
        guard let shot = await ScreenCaptureUtility.captureCursorScreenJPEG(width: res.w, height: res.h) else { return nil }
        let boxes = await Task.detached(priority: .userInitiated) {
            ScreenTextRecognizer.recognizeBoxes(inImageData: shot)
        }.value
        guard let match = ScreenTextRecognizer.bestMatch(anchor: anchor, in: boxes) else { return nil }
        let local = CGPoint(x: match.boundingBox.midX * screen.frame.width,
                            y: match.boundingBox.midY * screen.frame.height)
        let appKitGlobal = CGPoint(x: screen.frame.minX + local.x, y: screen.frame.minY + local.y)
        return Self.toCGGlobal(appKitGlobal)
    }

    private static func retargeted(_ step: RecipeStep, to point: CGPoint) -> RecipeStep {
        RecipeStep(
            order: step.order,
            kind: step.kind,
            x: point.x,
            y: point.y,
            text: step.text,
            key: step.key,
            modifiers: step.modifiers,
            appName: step.appName,
            bundleIdentifier: step.bundleIdentifier,
            windowTitleHint: step.windowTitleHint,
            ocrAnchor: step.ocrAnchor,
            targetDescriptor: step.targetDescriptor,
            isParameter: step.isParameter
        )
    }

    private func activateApp(name: String, bundle: String?) {
        if let bundle, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        } else if let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }) {
            app.activate()
        }
    }

    /// Launches (or activates) an app by name via `/usr/bin/open -a`, which resolves
    /// the name through LaunchServices — handles apps that aren't running yet and
    /// localized names, unlike a runningApplications scan. Returns whether `open`
    /// accepted the name.
    private static func openApp(named name: String) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-a", name]
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus == 0) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: false)
            }
        }
    }

    private static func recipeLabel(_ step: RecipeStep) -> String {
        switch step.kind {
        case .activateApp: "open \(step.appName)"
        case .click: "click in \(step.appName)"
        case .doubleClick: "double-click in \(step.appName)"
        case .rightClick: "right-click in \(step.appName)"
        case .type: "type “\(step.text.map { String($0.prefix(24)) } ?? "")”"
        case .key: (step.modifiers + [step.key ?? ""]).joined(separator: "+")
        case .scroll: "scroll in \(step.appName)"
        }
    }

    // MARK: - Skill auto-learning (the library compounds with usage)

    /// A skill draft distilled from a successful assist run, awaiting the
    /// user's review in Cascades. Approving moves it into the live library.
    public struct LearnedSkill: Identifiable, Sendable, Equatable {
        public let id = UUID()
        public let appName: String
        public let slug: String
        public let markdown: String
        public let sourceTask: String
    }

    @Published public private(set) var pendingLearnedSkills: [LearnedSkill] = []
    /// Per-app action tally for the current assist run (reset per task).
    private var episodeAppActions: [String: Int] = [:]

    /// After a successful run: if the work concentrated in one app that has no
    /// skill yet, distill what worked into a draft SKILL.md for review.
    private func maybeDistillSkill(goal: String, findings: [(task: String, result: String)]) {
        let totalActions = episodeAppActions.values.reduce(0, +)
        guard totalActions >= 6, hasAnthropicKey,
              let (app, count) = episodeAppActions.max(by: { $0.value < $1.value }),
              Double(count) / Double(totalActions) >= 0.7,
              appSkills.skill(appName: app, bundleIdentifier: nil) == nil,
              !pendingLearnedSkills.contains(where: { $0.appName == app })
        else { return }
        let memo = findings.map { "\($0.task) → \($0.result)" }.joined(separator: "\n")
        Task { await distillSkill(app: app, goal: goal, findingsMemo: memo, actionCount: count) }
    }

    private func distillSkill(app: String, goal: String, findingsMemo: String, actionCount: Int) async {
        let user = """
        App: \(app)
        Task the agent just completed there (\(actionCount) on-screen actions): \(goal)
        What each part accomplished:
        \(findingsMemo)
        """
        guard let markdown = try? await AnthropicClient().complete(
            system: Self.skillAuthorPrompt, user: user, model: AnthropicModel.sonnet, maxTokens: 900
        ), markdown.hasPrefix("---"), markdown.contains("appMatchers") else { return }
        let slug = "learned-" + app.lowercased().replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        let learned = LearnedSkill(appName: app, slug: slug, markdown: markdown, sourceTask: goal)
        pendingLearnedSkills.append(learned)
        _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "skill.learned.draft", detail: "\(app) — from “\(String(goal.prefix(80)))”"))
    }

    private static let skillAuthorPrompt = """
    You distill a completed computer-use run into a Cascade app skill: a SKILL.md \
    the agent will pull next time it works in this app. Output ONLY the file content.

    Format, exactly:
    ---
    name: <short-kebab-name>
    description: <one line>
    useWhen: <one line — when the agent should pull this skill>
    ---

    # <Title>

    - 5–9 short, imperative bullets with what actually works in this app: the \
    reliable entry points, shortcuts, gotchas, and the order that worked. Only \
    include things evidenced by the run — no generic advice.

    ```cascade-runtime-hints
    {"appMatchers": {"names": ["<App Name>"]}}
    ```
    """

    /// Moves a reviewed draft into the live skill library (user skills dir).
    public func approveLearnedSkill(_ skill: LearnedSkill) {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let dir = appSupport.appendingPathComponent("Cascade/Skills/\(skill.slug)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try skill.markdown.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        } catch {
            teachMessage = "Couldn't save the skill: \(error.localizedDescription)"
            return
        }
        pendingLearnedSkills.removeAll { $0.id == skill.id }
        appSkills = AppSkillRegistry.load()
        Task { _ = try? await store.appendAudit(AuditEvent(actor: "employee", action: "skill.learned.approved", detail: skill.appName)) }
    }

    public func discardLearnedSkill(_ skill: LearnedSkill) {
        pendingLearnedSkills.removeAll { $0.id == skill.id }
        Task { _ = try? await store.appendAudit(AuditEvent(actor: "employee", action: "skill.learned.discarded", detail: skill.appName)) }
    }

    // MARK: - Agent scheduling

    private var schedulerTask: Task<Void, Never>?
    private var firedScheduleKeys: Set<String> = []

    /// "daily@HH:mm" check every 30s. Background (sandbox) agents fire for
    /// real; on-screen agents only get a reminder — Cascade never takes the
    /// user's screen unprompted.
    func startScheduler() {
        guard schedulerTask == nil else { return }
        schedulerTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.fireDueSchedules()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private func fireDueSchedules() async {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        let nowSlot = formatter.string(from: Date())
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let today = dayFormatter.string(from: Date())

        for agent in agents where agent.enabled {
            guard agent.schedule == "daily@\(nowSlot)" else { continue }
            let key = "\(agent.id)@\(today)@\(nowSlot)"
            guard !firedScheduleKeys.contains(key) else { continue }
            if Self.runsInBackground(apps: agent.apps) {
                // Only consume the daily slot if it actually started — if the cap
                // refused, leave the key unset so a later tick (this minute) retries.
                guard createSandboxAgent(task: Self.sandboxTask(for: agent), forAgent: agent.id) else { continue }
                firedScheduleKeys.insert(key)
                _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "agent.schedule.fired", detail: agent.name))
                agentMessage = "Scheduled: running “\(agent.name)” in the background."
            } else {
                firedScheduleKeys.insert(key)
                _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "agent.schedule.due", detail: agent.name))
                dock.show(title: "Scheduled agent is due", detail: "“\(agent.name)” is ready — deploy it from Cascades whenever you want.")
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(8))
                    if self?.agentRunning != true { self?.dock.dismiss() }
                }
            }
        }
        if firedScheduleKeys.count > 500 { firedScheduleKeys.removeAll() }
    }

    public func setAgentSchedule(_ agent: CascadeAgent, schedule: String?) {
        Task {
            try? await store.setAgentSchedule(id: agent.id, schedule: schedule)
            _ = try? await store.appendAudit(AuditEvent(actor: "employee", action: "agent.schedule.set", detail: "\(agent.name) → \(schedule ?? "off")"))
            await refreshAll()
        }
    }

    private static let onboardedKey = "cascade.onboarded"

    /// Closes the first-run guide for good (Settings can reopen it).
    public func finishOnboarding() {
        showOnboarding = false
        defaultsStore.set(true, forKey: Self.onboardedKey)
        refreshPermissionState()
        startRecording()
    }

    public func toggleTheme() {
        prefersDark.toggle()
    }

    public func refreshKeyStatus() {
        hasAnthropicKey = keyStore.hasKey()
        keyMessage = hasAnthropicKey
            ? "Claude key connected in macOS Keychain."
            : "Paste your Anthropic API key to enable Claude-backed Q&A and agent generation."
        hasOpenAIKey = openAIKeyStore.hasKey()
        openAIKeyMessage = hasOpenAIKey
            ? "OpenAI key connected — GPT-Realtime voice enabled."
            : "Paste your OpenAI API key to enable the GPT-Realtime voice (talk + spoken replies)."
        hasGroqKey = groqKeyStore.hasKey()
        groqKeyMessage = hasGroqKey
            ? "Groq key connected — the task planner and completion validators run on Groq (Llama 3.3 70B)."
            : "Paste your Groq API key to run the cheap text helpers (Llama 3.3 70B planner + validators)."
        hasOpenRouterKey = openRouterKeyStore.hasKey()
        openRouterKeyMessage = hasOpenRouterKey
            ? "OpenRouter key connected — runs the Scout brain (Qwen3.7 Plus) and grounds its clicks with hosted UI-TARS."
            : "Paste your OpenRouter API key to run the Scout brain (Qwen3.7 Plus) and ground its clicks with hosted UI-TARS. Without it, the on-screen agent runs on Claude (Opus)."
    }

    public func saveAnthropicKey(_ key: String) {
        do {
            try keyStore.save(key)
            refreshKeyStatus()
        } catch {
            keyMessage = error.localizedDescription
        }
    }

    public func clearAnthropicKey() {
        do {
            try keyStore.delete()
            refreshKeyStatus()
        } catch {
            keyMessage = error.localizedDescription
        }
    }

    public func saveOpenAIKey(_ key: String) {
        do {
            try openAIKeyStore.save(key)
            refreshKeyStatus()
        } catch {
            openAIKeyMessage = error.localizedDescription
        }
    }

    public func clearOpenAIKey() {
        do {
            try openAIKeyStore.delete()
            refreshKeyStatus()
        } catch {
            openAIKeyMessage = error.localizedDescription
        }
    }

    public func saveGroqKey(_ key: String) {
        do {
            try groqKeyStore.save(key)
            refreshKeyStatus()
        } catch {
            groqKeyMessage = error.localizedDescription
        }
    }

    public func clearGroqKey() {
        do {
            try groqKeyStore.delete()
            refreshKeyStatus()
        } catch {
            groqKeyMessage = error.localizedDescription
        }
    }

    public func saveOpenRouterKey(_ key: String) {
        do {
            try openRouterKeyStore.save(key)
            refreshKeyStatus()
        } catch {
            openRouterKeyMessage = error.localizedDescription
        }
    }

    public func clearOpenRouterKey() {
        do {
            try openRouterKeyStore.delete()
            refreshKeyStatus()
        } catch {
            openRouterKeyMessage = error.localizedDescription
        }
    }

    public func refreshPermissionState() {
        recorder.refreshPermissions()
        permissionDiagnostics = PermissionProbe.diagnostics()
        autoStartIfPermitted()
        statusLine = recorder.status.message
    }

    /// Prepends a freshly recorded moment to the Reel, newest-first, capped so the
    /// in-memory list stays bounded.
    private func ingestLiveMoment(_ context: RecordedContext) {
        guard !contexts.contains(where: { $0.id == context.id }) else { return }
        contexts.insert(context, at: 0)
        if contexts.count > 200 {
            contexts.removeLast(contexts.count - 200)
        }
    }

    /// Full-text search over recorded moments. Empty query clears results and the
    /// Reel falls back to the recent timeline.
    public func search(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchQuery = trimmed
        guard !trimmed.isEmpty else {
            searchResults = []
            return
        }
        Task {
            let results = (try? await store.searchContexts(query: trimmed)) ?? []
            // Ignore stale responses if the query moved on while we awaited.
            guard searchQuery == trimmed else { return }
            searchResults = results
        }
    }

    public func requestScreenRecording() {
        _ = PermissionProbe.requestScreenRecordingPrompt()
        refreshPermissionState()
    }

    public func requestAccessibility() {
        PermissionProbe.request(.accessibility)
        refreshPermissionState()
    }

    public func requestInputMonitoring() {
        PermissionProbe.request(.inputMonitoring)
        refreshPermissionState()
    }

    public func refreshComputerUseHealth() async {
        let health = await NativeComputerUseActuator().health()
        screenAgentReady = health.ready
        screenAgentMessage = health.message
    }

    public func refreshComputerUseHealthFromUI() {
        Task { await refreshComputerUseHealth() }
    }

    public func openSystemSettings() {
        let now = Date()
        guard now.timeIntervalSince(lastSettingsOpen) > 1.0 else { return }
        lastSettingsOpen = now
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        if let bundleURL = Bundle.main.bundleURL as URL? {
            NSWorkspace.shared.activateFileViewerSelecting([bundleURL])
        }
    }
}
