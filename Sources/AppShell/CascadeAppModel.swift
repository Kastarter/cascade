import AgentOrchestrator
import AppKit
import ApplicationServices
import CascadeMemory
import Combine
import ComputerUseKit
import Foundation
import MacContextKit
import ProviderKit
import SandboxKit
import SuggestionEngine

/// One real Q&A turn over local context — drives the Reel "Ask about this moment" thread.
public struct QATurn: Identifiable, Sendable {
    public let id = UUID()
    public let question: String
    public let answer: String
}

/// A background agent running in the isolated web sandbox.
public struct BackgroundAgentRun: Identifiable, Sendable {
    public let id: UUID
    public let task: String
    public var status: String
    public var snapshot: Data?
    public var done: Bool
    public var result: String?
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
    @Published public var prefersDark = true
    @Published public private(set) var dismissedSuggestions: Set<UUID> = []
    @Published private var dismissedWasteSignatures: Set<String> = []
    @Published public private(set) var managerCascades: [AgentSuggestion] = []
    @Published public private(set) var contexts: [RecordedContext] = []
    @Published public private(set) var searchResults: [RecordedContext] = []
    @Published public private(set) var searchQuery: String = ""
    @Published public private(set) var audit: [AuditEvent] = []
    @Published public private(set) var suggestions: [AgentSuggestion] = []
    @Published public private(set) var detectedWaste: [DetectedWaste] = []
    @Published public private(set) var agents: [CascadeAgent] = []
    @Published public private(set) var answer: String = "Ask Cascade what happened in the local record."
    @Published public private(set) var conversation: [QATurn] = []
    @Published public private(set) var thinking = false
    @Published public private(set) var statusLine: String = "Starting Cascade."
    @Published public private(set) var hasAnthropicKey = false
    @Published public private(set) var keyMessage = "Claude key is not connected."
    @Published public private(set) var hasOpenAIKey = false
    @Published public private(set) var openAIKeyMessage = "OpenAI key is not connected (for GPT-Realtime voice)."
    @Published public private(set) var permissionDiagnostics = PermissionProbe.diagnostics()
    @Published public private(set) var screenAgentReady = false
    @Published public private(set) var screenAgentMessage = "Checking real-screen driver health."
    @Published public private(set) var agentRunning = false
    @Published public private(set) var agentMessage = "Connect a Claude key and a goal, then watch Cascade use this Mac."
    @Published public private(set) var teachMessage = "Ask “where do I find X” and Cascade points at it on your screen."

    public let store: CascadeStore
    public let driver: LocalMacDriver
    public let recorder: ContextRecorder
    public let dock: ControlDockModel
    public let hotkey: UseDeviceHotkeyMonitor
    private let orchestrator: CascadeOrchestrator
    private let keyStore = AnthropicKeyStore()
    private let openAIKeyStore = OpenAIKeyStore()
    public let guidanceOverlay = GuidanceOverlayController()
    public let voice = RealtimeVoice()
    public let pushToTalk = PushToTalkMonitor()
    /// Background agents running in the isolated web sandbox.
    @Published public private(set) var backgroundAgents: [BackgroundAgentRun] = []
    private var sandboxRuntimes: [UUID: BackgroundWebAgent] = [:]
    private let sandboxBox = SandboxBoxController()
    private let elementLocator = ElementLocator()
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

    public init() throws {
        let store = try CascadeStore()
        self.store = store
        recorder = ContextRecorder(store: store)
        dock = ControlDockModel()
        hotkey = UseDeviceHotkeyMonitor()
        orchestrator = CascadeOrchestrator(store: store)
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
        hotkey.start()
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
            // pipeline now so the screenshot is cheap when they finish speaking.
            ScreenCaptureUtility.prewarm()
        }
        pushToTalk.onRelease = { [weak self] in self?.voice.endTalking() }
        pushToTalk.start()
        dock.onStop = { [weak self] in
            guard let self else { return }
            self.driver.runState.requestStop()
            self.agentMessage = "Stopped. Control returned to you."
            Task { await self.driver.stop() }
        }
        refreshKeyStatus()
        Task { await refreshAll() }
    }

    public func refreshAll() async {
        do {
            refreshPermissionState()
            await refreshComputerUseHealth()
            contexts = try await store.recentContexts(limit: 80)
            audit = try await store.recentAudit(limit: 80)
            suggestions = try await orchestrator.suggestions()
            agents = try await orchestrator.agents()
            detectedWaste = try await orchestrator.detectedWaste()
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
        guard !userPaused,
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

        answer = "Thinking…"
        thinking = true
        Task {
            let result: String
            do {
                result = Self.brief(try await orchestrator.ask(trimmed))
            } catch {
                result = error.localizedDescription
            }
            answer = result
            conversation.append(QATurn(question: trimmed, answer: result))
            thinking = false
        }
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
                displayHeightPoints: Int(screen.frame.height)
            )
            if let local = guidance.point {
                let global = CGPoint(x: screen.frame.minX + local.x, y: screen.frame.minY + local.y)
                guidanceOverlay.present(atGlobalPoint: global, label: "this one")
                _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "reel.point", detail: q))
            } else {
                guidanceOverlay.hide()
            }
            conversation.append(QATurn(question: q, answer: Self.brief(guidance.speech)))
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
            title: "Cascade is ready",
            detail: "Teach or approve the next step before Cascade uses this Mac."
        )
        Task {
            _ = try? await store.appendAudit(AuditEvent(actor: "employee", action: "device.intent", detail: source))
            await refreshAll()
        }
    }

    /// Autonomously works toward `goal`: observe the screen → plan one step with
    /// Claude → act (visibly moving the cursor) → repeat, until done, STOP, or the
    /// step cap. No per-step approval — STOP is the take-control valve, the run is
    /// capped, and every action is audited.
    public func runAgent(goal: String) {
        let trimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { agentMessage = "Enter a goal to run."; return }
        guard hasAnthropicKey else {
            agentMessage = "Connect your Claude key in Settings first."
            showSettings = true
            return
        }
        guard !agentRunning else { return }
        driver.runState.reset()
        agentRunning = true
        agentMessage = "Cascade is using this Mac…"
        dock.show(title: "Cascade is working", detail: "Goal: \(trimmed) · press STOP to take control.")
        Task { await runLoop(goal: trimmed) }
    }

    private func runLoop(goal: String) async {
        let maxSteps = 20
        defer { agentRunning = false }
        for step in 1...maxSteps {
            if driver.runState.isStopRequested {
                agentMessage = "Stopped. Control returned to you."
                dock.show(title: "Stopped", detail: agentMessage)
                break
            }
            _ = await recorder.captureNow()
            do {
                let proposed = try await orchestrator.proposeStep(goal: goal)
                dock.show(title: "Step \(step): \(proposed.action.shortLabel)", detail: proposed.rationale)
                _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "step.auto", detail: proposed.action.shortLabel))
                guard let action = AgentAction(planned: proposed.action) else {
                    switch proposed.action {
                    case .done(let summary): agentMessage = "Done — \(summary)"
                    default: agentMessage = "Stopped — unsupported step (\(proposed.action.shortLabel))."
                    }
                    dock.show(title: "Done", detail: agentMessage)
                    break
                }
                // Visibly move the cursor to the target before clicking.
                if let point = proposed.action.targetPoint {
                    try await driver.act(.computerUse(.move(x: point.x, y: point.y)))
                    try? await Task.sleep(for: .milliseconds(450))
                }
                try await driver.act(action)
                agentMessage = "Step \(step): \(proposed.action.shortLabel)"
                try? await Task.sleep(for: .milliseconds(700))
            } catch {
                agentMessage = "Stopped: \(error.localizedDescription)"
                dock.show(title: "Stopped", detail: agentMessage)
                break
            }
            if step == maxSteps {
                agentMessage = "Reached the \(maxSteps)-step limit. Run again to continue."
                dock.show(title: "Paused", detail: agentMessage)
            }
        }
        await refreshAll()
    }

    /// Captures the current screen (excluding Cascade's own windows), asks Claude's
    /// Computer Use tool *where* the target is, and flies the blue companion cursor
    /// to it. If the request was a command ("open / click / do X"), it also
    /// **performs the click** (gated on Accessibility + Input Monitoring); otherwise
    /// it just points and explains ("where / how / show me X").
    /// Spawns a background agent that carries out `task` inside the isolated web
    /// sandbox (its own hidden browser), streaming progress to a small watch box —
    /// the user keeps using their Mac while it works.
    public func createSandboxAgent(task: String) {
        let trimmed = task.trimmingCharacters(in: .whitespacesAndNewlines)
        // Too vague to act on — ask rather than letting the agent wander (e.g. off
        // googling "how to create an agent").
        if trimmed.count < 5 || trimmed.split(separator: " ").count < 2 {
            teachMessage = "What should the background agent actually do? e.g. \"in the background, find the cheapest flight to Tokyo next month.\""
            voice.speak("What should the background agent do?")
            return
        }
        guard hasAnthropicKey else {
            teachMessage = "Connect your Claude key in Settings first."
            showSettings = true
            return
        }
        let id = UUID()
        let runtime = BackgroundWebAgent()
        sandboxRuntimes[id] = runtime
        backgroundAgents.insert(
            BackgroundAgentRun(id: id, task: trimmed, status: "Starting…", snapshot: nil, done: false, result: nil),
            at: 0
        )
        teachMessage = "Running in the background: \(trimmed)"
        assistMemory.remember(user: trimmed, assistant: "Started a background agent on it.")
        voice.speak("On it. I'll handle that in the background.")
        sandboxBox.show(id, webView: runtime.sandbox.webView, task: trimmed) { [weak self] in
            self?.stopSandboxAgent(id)
        }
        Task {
            await runtime.run(task: trimmed) { [weak self] update in
                self?.applySandboxUpdate(id, update)
            }
        }
    }

    public func stopSandboxAgent(_ id: UUID) {
        sandboxRuntimes[id]?.stop()
        sandboxRuntimes[id] = nil
        if let index = backgroundAgents.firstIndex(where: { $0.id == id }) {
            backgroundAgents[index].done = true
            backgroundAgents[index].status = "Stopped."
        }
        sandboxBox.hide(id)
    }

    private func applySandboxUpdate(_ id: UUID, _ update: BackgroundWebAgent.Update) {
        if let index = backgroundAgents.firstIndex(where: { $0.id == id }) {
            backgroundAgents[index].status = update.status
            if let snapshot = update.snapshotPNG { backgroundAgents[index].snapshot = snapshot }
            backgroundAgents[index].done = update.done
            backgroundAgents[index].result = update.result
        }
        sandboxBox.updateStatus(id, update.status)
        guard update.done else { return }
        let task = backgroundAgents.first(where: { $0.id == id })?.task ?? "the task"
        let said = update.result ?? "Finished in the background."

        // Sign-in wall: keep the box AND the runtime so Continue resumes at the
        // pending part of the plan — earlier parts' findings intact — instead of
        // redoing the whole job from scratch.
        if update.needsLogin {
            teachMessage = said
            voice.speak(said)
            sandboxBox.requestLogin(id, message: said) { [weak self] in
                guard let self, let runtime = self.sandboxRuntimes[id] else { return }
                if let index = self.backgroundAgents.firstIndex(where: { $0.id == id }) {
                    self.backgroundAgents[index].done = false
                    self.backgroundAgents[index].status = "Continuing…"
                }
                Task { await runtime.resume { [weak self] update in self?.applySandboxUpdate(id, update) } }
            }
            return
        }

        sandboxRuntimes[id] = nil
        teachMessage = "Background agent done — \(said)"
        assistMemory.remember(user: "[background agent finished: \(task)]", assistant: said)
        voice.speak(said)
        Task { _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "sandbox.task", detail: "\(task) → \(said)")) }
        // Leave the box up briefly so the user can glance at the result, then close it.
        Task { try? await Task.sleep(for: .seconds(5)); sandboxBox.hide(id) }
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
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { teachMessage = "Ask where something is, or what to do."; return }
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
            let region = await elementLocator.locateRegion(
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
        agentDidHighlight = false
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
            plan = await AgentTaskPlanner(model: AnthropicModel.haiku).plan(
                for: goal, in: .onScreen, conversationContext: assistMemory.contextMemo()
            )
        }
        var findings: [(task: String, result: String)] = []
        var ranLongOn: String?
        var interrupted = false
        var shot: Data? = firstScreenshotPNG

        // All frames in this run are captured at the model resolution as JPEG and
        // pass through to base64 untouched.
        let res = AgentResolution.best(forWidth: Int(screen.frame.width), height: Int(screen.frame.height))
        func freshShot() async -> Data? {
            await ScreenCaptureUtility.captureCursorScreenJPEG(width: res.w, height: res.h)
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
            let summary = AgentTaskPlanner.summary(findings: findings, skipped: [], ranLongOn: ranLongOn)
            teachMessage = summary
            voice.speak(summary)
            dock.show(title: ranLongOn == nil ? "Done" : "Paused", detail: summary)
            assistMemory.remember(user: goal, assistant: summary)
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
        case stopped
        case stepLimit
        case failed
    }

    /// Steps one Computer Use episode through a single part: observe → act →
    /// re-observe until the model finishes, the user stops it, or the step budget
    /// runs out. Returns the model's closing line plus whether it acted at all.
    private func runAssistEpisode(
        goal: String, prefix: String, screen: NSScreen, firstScreenshotPNG: Data, gen: Int
    ) async -> AssistEpisodeOutcome {
        let agent = ComputerUseAgent(environmentNote: ComputerUseAgent.foregroundBrowserNote)
        let maxSteps = 28
        var step = await agent.begin(
            goal: goal,
            screenshot: firstScreenshotPNG,
            displayWidthPoints: Int(screen.frame.width),
            displayHeightPoints: Int(screen.frame.height),
            conversation: assistMemory.historyForAPI(),
            note: Self.groundingNote()
        )
        var acted = false
        var count = 0
        while count < maxSteps {
            if assistGeneration != gen { return .stopped }  // superseded by a newer turn
            if driver.runState.isStopRequested {
                teachMessage = "Stopped. Control returned to you."
                dock.show(title: "Stopped", detail: teachMessage)
                return .stopped
            }
            if !step.text.isEmpty { teachMessage = prefix + step.text }
            if step.done {
                return .finished(step.text.isEmpty ? "Done." : step.text, acted: acted)
            }

            if !step.actions.isEmpty { acted = true }
            // Zoom is answered with the cropped frame, not a regular screenshot —
            // pull it out and run everything else first.
            var zoomRegion: CGRect?
            var actedThisTurn = false
            for action in step.actions {
                if case .zoom(let nx, let ny, let nw, let nh) = action {
                    zoomRegion = CGRect(x: nx, y: ny, width: nw, height: nh)
                    continue
                }
                actedThisTurn = true
                if !(await executeCU(action, on: screen)) { return .failed }
                try? await Task.sleep(for: .milliseconds(120))
            }

            if let zoomRegion {
                // Native-resolution crop so the model can actually read small text.
                if actedThisTurn { try? await Task.sleep(for: .milliseconds(260)) }
                if let crop = await ScreenCaptureUtility.captureCursorScreenZoomJPEG(normalizedRect: zoomRegion) {
                    step = await agent.proceed(screenshot: crop, note: Self.groundingNote(), zoomResult: true)
                    count += 1
                    continue
                }
                // Crop failed — fall through to the regular re-observe.
            }
            // Let the UI settle, then re-observe and ask for the next step. Capturing
            // at the agent's resolution as JPEG skips the PNG round-trip and OCR.
            try? await Task.sleep(for: .milliseconds(260))
            let size = agent.captureSize
            guard let nextShot = await ScreenCaptureUtility.captureCursorScreenJPEG(width: size.width, height: size.height) else {
                teachMessage = "I lost sight of the screen — try again."
                return .failed
            }
            step = await agent.proceed(screenshot: nextShot, note: Self.groundingNote())
            count += 1
        }
        return .stepLimit
    }

    /// One line of text grounding sent with every frame: which app and window are
    /// frontmost. ~15 tokens that prevent which-app-am-I-in mistakes.
    private static func groundingNote() -> String? {
        let snapshot = AppWindowObserver.snapshot()
        guard snapshot.appName != "Unknown app" else { return nil }
        if let title = snapshot.windowTitle, !title.isEmpty {
            return "Frontmost app: \(snapshot.appName) — “\(title)”"
        }
        return "Frontmost app: \(snapshot.appName)"
    }

    /// Performs one Computer Use action, flying the companion cursor to pointer
    /// targets first. Returns `false` (and surfaces why) if the actuator is blocked
    /// — e.g. Accessibility / Input Monitoring not granted — so the loop can stop.
    @discardableResult
    private func executeCU(_ action: CUAction, on screen: NSScreen) async -> Bool {
        func globalAppKit(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: screen.frame.minX + x, y: screen.frame.minY + y)
        }
        func cg(_ x: Double, _ y: Double) -> CGPoint { Self.toCGGlobal(globalAppKit(x, y)) }
        do {
            switch action {
            case .move(let x, let y):
                // Blue companion only — the user's real pointer never moves.
                guidanceOverlay.navigate(toGlobalPoint: globalAppKit(x, y))
            case .click(let x, let y):
                guidanceOverlay.navigate(toGlobalPoint: globalAppKit(x, y))
                try? await Task.sleep(for: .milliseconds(150))  // let the cursor reach the target
                guidanceOverlay.press()
                try? await Task.sleep(for: .milliseconds(55))   // show the press dip
                let p = cg(x, y)
                if !Self.axActivate(atCG: p) {
                    try await clickRestoringCursor { try await driver.act(.computerUse(.click(x: p.x, y: p.y))) }
                }
            case .doubleClick(let x, let y):
                guidanceOverlay.navigate(toGlobalPoint: globalAppKit(x, y))
                try? await Task.sleep(for: .milliseconds(150))
                guidanceOverlay.press()
                try? await Task.sleep(for: .milliseconds(55))
                let p = cg(x, y)
                try await clickRestoringCursor { try await driver.act(.computerUse(.doubleClick(x: p.x, y: p.y))) }
            case .tripleClick(let x, let y):
                guidanceOverlay.navigate(toGlobalPoint: globalAppKit(x, y))
                try? await Task.sleep(for: .milliseconds(150))
                guidanceOverlay.press()
                try? await Task.sleep(for: .milliseconds(55))
                let p = cg(x, y)
                try await clickRestoringCursor { try await driver.act(.computerUse(.tripleClick(x: p.x, y: p.y))) }
            case .drag(let fromX, let fromY, let toX, let toY):
                // The companion cursor traces the drag so the user sees the motion.
                guidanceOverlay.navigate(toGlobalPoint: globalAppKit(fromX, fromY))
                try? await Task.sleep(for: .milliseconds(150))
                guidanceOverlay.press()
                guidanceOverlay.navigate(toGlobalPoint: globalAppKit(toX, toY))
                let from = cg(fromX, fromY)
                let to = cg(toX, toY)
                try await clickRestoringCursor {
                    try await driver.act(.computerUse(.drag(fromX: from.x, fromY: from.y, toX: to.x, toY: to.y)))
                }
            case .rightClick(let x, let y):
                guidanceOverlay.navigate(toGlobalPoint: globalAppKit(x, y))
                try? await Task.sleep(for: .milliseconds(150))
                guidanceOverlay.press()
                try? await Task.sleep(for: .milliseconds(55))
                let p = cg(x, y)
                if !Self.axActivate(atCG: p, showMenu: true) {
                    try await clickRestoringCursor { try await driver.act(.computerUse(.rightClick(x: p.x, y: p.y))) }
                }
            case .type(let text):
                // Tiered text entry (tiptour-macos ActionExecutor pattern): AX
                // selected-text insertion (instant, never dropped) → clipboard
                // paste with restore → paced synthetic keystrokes. Catalyst and
                // Electron apps (WhatsApp, Slack) drop fast synthetic typing, so
                // keystrokes are the LAST resort, not the default.
                if driver.runState.isStopRequested { throw ComputerUseError.stopped }
                if Self.axInsertText(text) {
                    _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "computer.type.ax", detail: String(text.prefix(60))))
                } else if await pasteText(text) {
                    _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "computer.type.paste", detail: String(text.prefix(60))))
                } else {
                    try await driver.act(.computerUse(.typeText(text)))
                }
            case .key(let combo):
                let (key, modifiers) = Self.parseKey(combo)
                try await driver.act(.computerUse(.key(key, modifiers: modifiers)))
            case .scroll(let x, let y, let direction, let amount):
                guidanceOverlay.navigate(toGlobalPoint: globalAppKit(x, y))
                let p = cg(x, y)
                let (dx, dy) = Self.scrollDelta(direction: direction, amount: amount)
                let origin = Self.cursorCG()
                CGWarpMouseCursorPosition(p)
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
                // Instant programmatic launch — no Dock hunting, no cursor. Wait (up to
                // ~2.5s) for the app to actually come frontmost so the next screenshot
                // shows it rather than the launch animation.
                dock.show(title: "Opening \(name)", detail: "")
                if await Self.openApp(named: name) {
                    for _ in 0..<10 {
                        if NSWorkspace.shared.frontmostApplication?.localizedName?
                            .caseInsensitiveCompare(name) == .orderedSame { break }
                        try? await Task.sleep(for: .milliseconds(250))
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

    /// Runs a CGEvent click body, then snaps the real cursor back to exactly where
    /// it was — the fallback for targets Accessibility can't press. The actuator
    /// checks health/STOP *before* posting, so on throw the cursor hasn't moved and
    /// we just rethrow.
    private func clickRestoringCursor(_ body: () async throws -> Void) async throws {
        let origin = Self.cursorCG()
        try await body()
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
    private func pasteText(_ text: String) async -> Bool {
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
            try await driver.act(.computerUse(.key("v", modifiers: ["command"])))
            // Let the app consume the pasteboard before we restore it.
            try? await Task.sleep(for: .milliseconds(180))
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
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        let appRef = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appRef, 0.3)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appRef, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        let element = focused as! AXUIElement
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success
    }

    private static func axString(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return ref as? String
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

        let maxSteps = 6
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
            async let regionTask = elementLocator.locateRegion(
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
    private static func isActionRequest(_ text: String) -> Bool {
        let t = text.lowercased()
        // Highlight/mark requests go to the acting agent — it owns the highlight
        // tool and can navigate/scroll to surface the target first. This wins even
        // over question-y phrasing ("show me X and highlight them").
        if t.contains("highlight") || t.contains("point out") || t.contains(" mark ") || t.hasPrefix("mark ") {
            return true
        }
        let teachy = ["where", "how do i", "how can i", "show me", "find ", "what is", "what's",
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

    /// Manager-cascaded helpers the employee hasn't dismissed.
    public var visibleSuggestions: [AgentSuggestion] {
        suggestions.filter { !dismissedSuggestions.contains($0.id) }
    }

    /// "DEPLOY" a reviewed helper: plan its first step for approval.
    public func deploySuggestion(_ suggestion: AgentSuggestion) {
        runAgent(goal: suggestion.title)
    }

    // MARK: - Agents built from recorded workflows

    /// Detected workflows still awaiting the manager's review — excludes ones
    /// already approved (an agent exists) or declined.
    public var pendingDetectedWaste: [DetectedWaste] {
        let approved = Set(agents.map(\.signature))
        return detectedWaste.filter { !approved.contains($0.signature) && !dismissedWasteSignatures.contains($0.signature) }
    }

    /// Manager approves a detected workflow: builds the agent (from the user's real
    /// actions) and sends it to the employee's Cascades tab.
    public func approveWaste(_ waste: DetectedWaste) {
        Task {
            do {
                _ = try await orchestrator.createAgent(from: waste)
                _ = try? await store.appendAudit(AuditEvent(actor: "manager", action: "agent.approved", detail: waste.title))
                agentMessage = "Approved “\(waste.title)” — sent to the employee's Cascades."
            } catch {
                agentMessage = "Could not approve: \(error.localizedDescription)"
            }
            await refreshAll()
        }
    }

    /// Manager declines a detected workflow: it won't be surfaced again.
    public func declineWaste(_ waste: DetectedWaste) {
        dismissedWasteSignatures.insert(waste.signature)
        Task { _ = try? await store.appendAudit(AuditEvent(actor: "manager", action: "agent.declined", detail: waste.title)) }
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

    /// Runs a saved agent by replaying its recorded recipe on the real Mac — visible
    /// cursor, STOP valve, step cap, every action audited.
    public func deployAgent(_ agent: CascadeAgent) {
        guard !agentRunning else { return }
        guard !agent.recipe.steps.isEmpty else {
            agentMessage = "“\(agent.name)” has no recorded steps yet."
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
            do {
                if let x = step.x, let y = step.y,
                   step.kind == .click || step.kind == .doubleClick || step.kind == .rightClick {
                    let recorded = CGPoint(x: x, y: y)
                    // Tier 1: re-find the element by its recorded AX label in the
                    // live tree. Tier 2: Claude vision via the OCR anchor. Tier 3:
                    // the recorded pixel. The tier lands in the step's audit row so
                    // a drifting recipe is diagnosable from the log.
                    let target: CGPoint
                    let tier: String
                    if let axTarget = await Self.resolveByAX(step: step, recorded: recorded) {
                        target = axTarget
                        tier = "ax"
                    } else {
                        // Falls back to `recorded` itself when there's no anchor/key.
                        target = await regroundedTarget(anchor: step.ocrAnchor, recorded: recorded)
                        tier = target == recorded ? "recorded" : "vision"
                    }
                    _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "recipe.target", detail: "\(Self.recipeLabel(step)) via \(tier)"))
                    try await driver.act(.computerUse(.move(x: target.x, y: target.y)))
                    try? await Task.sleep(for: .milliseconds(320))

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
                                agentMessage = "Paused “\(agent.name)” — the screen no longer matches the recorded steps. Take over, or re-record the workflow."
                                dock.show(title: "Paused", detail: agentMessage)
                                stoppedEarly = true
                                break
                            }
                        }
                    }
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
        }
        try? await store.markAgentRun(id: agent.id)
        await refreshAll()
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
    private static func resolveByAX(step: RecipeStep, recorded: CGPoint) async -> CGPoint? {
        let label = step.text ?? step.ocrAnchor
        guard let label, !label.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return await Task.detached(priority: .userInitiated) {
            AXElementResolver.find(label: label, near: recorded)?.center
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
            if front?.bundleIdentifier == bundle || front?.localizedName == name { return }
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
            ocrAnchor: step.ocrAnchor
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

    public func declineSuggestion(_ suggestion: AgentSuggestion) {
        dismissedSuggestions.insert(suggestion.id)
        Task { _ = try? await store.appendAudit(AuditEvent(actor: "employee", action: "cascade.declined", detail: suggestion.title)) }
    }

    public func toggleTheme() {
        prefersDark.toggle()
    }

    /// Manager-cascaded agents the employee hasn't dismissed.
    public var visibleManagerCascades: [AgentSuggestion] {
        managerCascades.filter { !dismissedSuggestions.contains($0.id) }
    }

    /// The manager cascades a plain-English automation to this employee. It lands
    /// in the employee's Cascades inbox to review and deploy. (In this local
    /// prototype the manager and employee share one device; a real deployment
    /// would deliver this over the privacy-safe manager channel.)
    public func cascadeFromManager(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let cascade = AgentSuggestion(
            title: trimmed,
            summary: "Cascaded by your manager for you to review and deploy.",
            kind: .reviewQueue,
            confidence: 1.0,
            evidence: ["Sent from the Manager dashboard"],
            doable: true
        )
        managerCascades.insert(cascade, at: 0)
        Task { _ = try? await store.appendAudit(AuditEvent(actor: "manager", action: "cascade.sent", detail: trimmed)) }
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
