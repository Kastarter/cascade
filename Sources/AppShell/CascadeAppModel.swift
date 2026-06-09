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
        pushToTalk.onPress = { [weak self] in self?.voice.beginTalking() }
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
            guard let screen,
                  let sample = await ScreenCaptureUtility.captureCursorScreenContext(includeImage: true),
                  let png = sample.imagePNG else {
                conversation.append(QATurn(question: q, answer: "Grant Screen Recording so I can see your screen."))
                return
            }
            let guidance = await elementLocator.guide(
                screenshotPNG: png,
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
        voice.speak("On it. I'll handle that in the background.")
        sandboxBox.show(webView: runtime.sandbox.webView, task: trimmed) { [weak self] in
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
    }

    private func applySandboxUpdate(_ id: UUID, _ update: BackgroundWebAgent.Update) {
        if let index = backgroundAgents.firstIndex(where: { $0.id == id }) {
            backgroundAgents[index].status = update.status
            if let snapshot = update.snapshotPNG { backgroundAgents[index].snapshot = snapshot }
            backgroundAgents[index].done = update.done
            backgroundAgents[index].result = update.result
        }
        sandboxBox.updateStatus(update.status)
        guard update.done else { return }
        sandboxRuntimes[id] = nil
        let task = backgroundAgents.first(where: { $0.id == id })?.task ?? "the task"
        let said = update.result ?? "Finished in the background."

        // Sign-in wall: keep the box open so the user can log in once (it persists),
        // then Continue resumes the task — now authenticated.
        if update.needsLogin {
            teachMessage = said
            voice.speak(said)
            sandboxBox.requestLogin(message: said) { [weak self] in
                self?.createSandboxAgent(task: task)
            }
            return
        }

        teachMessage = "Background agent done — \(said)"
        voice.speak(said)
        Task { _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "sandbox.task", detail: "\(task) → \(said)")) }
        // Leave the box up briefly so the user can glance at the result, then close it.
        Task { try? await Task.sleep(for: .seconds(5)); sandboxBox.hide() }
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
        let wantsAction = Self.isActionRequest(q)
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        teachMessage = wantsAction ? "On it — looking at your screen…" : "Looking at your screen…"
        Task {
            guard let sample = await ScreenCaptureUtility.captureCursorScreenContext(includeImage: true),
                  let png = sample.imagePNG else {
                teachMessage = "Grant Screen Recording so Cascade can see your screen."
                voice.speak("I need Screen Recording permission to see your screen.")
                voice.done()
                return
            }

            // Commands ("open X and do Y") run as a multi-step Computer Use loop so
            // Cascade finishes the whole task, not just the first click. Questions
            // ("where / how / show me X") stay single-shot: point and explain.
            if wantsAction {
                await runAssistTask(goal: q, screen: screen, firstScreenshotPNG: png)
                return
            }

            // "Where do I find/do X" → frame the region with the dashed marquee.
            let region = await elementLocator.locateRegion(
                screenshotPNG: png,
                question: q,
                displayWidthPoints: Int(screen.frame.width),
                displayHeightPoints: Int(screen.frame.height)
            )
            guard let local = region.rect else {
                // Not on the current screen — don't give up. Navigate (open the app/menu/
                // tab, scroll) to surface it, then frame it.
                await findAndReveal(question: q, screen: screen, firstScreenshotPNG: png)
                return
            }

            let globalRect = CGRect(
                x: screen.frame.minX + local.minX, y: screen.frame.minY + local.minY,
                width: local.width, height: local.height
            )
            guidanceOverlay.highlight(globalRect: globalRect)
            guidanceOverlay.present(atGlobalPoint: CGPoint(x: globalRect.midX, y: globalRect.midY), label: "here")
            _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "teach.region", detail: q))
            teachMessage = region.speech
            voice.speak(region.speech)
            voice.done()
            await refreshAll()
        }
    }

    /// Carries out a spoken command across as many steps as it takes — open the app
    /// *and* do the thing — by driving Claude's Computer Use tool with a fresh
    /// screenshot after every action (observe → act → re-observe). The blue
    /// companion cursor flies to each target so you can watch; STOP (and the cap)
    /// keep control with you, and every run is audited.
    private func runAssistTask(goal: String, screen: NSScreen, firstScreenshotPNG: Data) async {
        let agent = ComputerUseAgent(environmentNote: ComputerUseAgent.foregroundBrowserNote)
        driver.runState.reset()
        ScreenCaptureUtility.prewarm()  // warm the capture pipeline for fast re-observes
        dock.show(title: "Cascade is doing it", detail: "\(goal) · press STOP to take control.")
        let maxSteps = 28
        var step = await agent.begin(
            goal: goal,
            screenshotPNG: firstScreenshotPNG,
            displayWidthPoints: Int(screen.frame.width),
            displayHeightPoints: Int(screen.frame.height)
        )
        var count = 0
        while count < maxSteps {
            if driver.runState.isStopRequested {
                teachMessage = "Stopped. Control returned to you."
                dock.show(title: "Stopped", detail: teachMessage)
                break
            }
            if !step.text.isEmpty { teachMessage = step.text }
            if step.done {
                let closing = step.text.isEmpty ? "Done." : step.text
                voice.speak(closing)
                dock.show(title: "Done", detail: closing)
                break
            }

            var failed = false
            for action in step.actions {
                if !(await executeCU(action, on: screen)) { failed = true; break }
                try? await Task.sleep(for: .milliseconds(120))
            }
            if failed { break }
            // Let the UI settle, then re-observe and ask for the next step.
            try? await Task.sleep(for: .milliseconds(260))
            guard let nextShot = await Self.captureScreenPNG() else {
                teachMessage = "I lost sight of the screen — try again."
                break
            }
            step = await agent.proceed(screenshotPNG: nextShot)
            count += 1
        }

        if count >= maxSteps {
            teachMessage = "That ran long — say it again if you want me to keep going."
            voice.speak("I did several steps. Say it again to keep going.")
        }
        guidanceOverlay.hide()
        _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "assist.task", detail: goal))
        voice.done()
        await refreshAll()
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
                try await driver.act(.computerUse(.typeText(text)))
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

    private static func axString(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    private static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    /// Current cursor position in CGEvent global (top-left) coordinates.
    private static func cursorCG() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }

    /// Captures the current screen (own windows excluded) as PNG for the next loop turn.
    private static func captureScreenPNG() async -> Data? {
        await ScreenCaptureUtility.captureCursorScreenContext(includeImage: true)?.imagePNG
    }

    /// "Where can I find/do X" when X isn't on the current screen: navigate (open the
    /// right app/menu/tab, scroll) to bring it into view, then frame it with the marquee.
    /// It reveals — it does NOT click the target itself. STOP-able and capped.
    private func findAndReveal(question: String, screen: NSScreen, firstScreenshotPNG: Data) async {
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
            screenshotPNG: firstScreenshotPNG,
            displayWidthPoints: dw, displayHeightPoints: dh
        )

        let maxSteps = 6
        var count = 0
        while count < maxSteps {
            if driver.runState.isStopRequested { teachMessage = "Stopped."; return }
            var failed = false
            for action in step.actions {
                if !(await executeCU(action, on: screen)) { failed = true; break }
                try? await Task.sleep(for: .milliseconds(80))
            }
            if failed { return }  // executeCU surfaced the permission/STOP reason
            try? await Task.sleep(for: .milliseconds(220))

            guard let shot = await Self.captureScreenPNG() else { break }
            // Detection (is it visible now?) and the next nav step fire concurrently, so
            // each loop turn costs ONE round-trip of wall-clock instead of two. If found,
            // the speculative nav step is just discarded.
            async let regionTask = elementLocator.locateRegion(
                screenshotPNG: shot, question: question, displayWidthPoints: dw, displayHeightPoints: dh
            )
            async let nextStepTask = navigator.proceed(screenshotPNG: shot)

            let region = await regionTask
            if let local = region.rect {
                let g = CGRect(
                    x: screen.frame.minX + local.minX, y: screen.frame.minY + local.minY,
                    width: local.width, height: local.height
                )
                guidanceOverlay.highlight(globalRect: g)
                guidanceOverlay.present(atGlobalPoint: CGPoint(x: g.midX, y: g.midY), label: "here")
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

    /// Heuristic: did the user ask Cascade to *do* something (act) vs *find/show*
    /// something (point only)?
    private static func isActionRequest(_ text: String) -> Bool {
        let t = text.lowercased()
        let teachy = ["where", "how do i", "how can i", "show me", "find ", "what is", "which "]
        if teachy.contains(where: { t.contains($0) }) { return false }
        let verbs = ["open", "click", "press", "tap", "hit", "launch", "go to", "select",
                     "choose", "turn on", "turn off", "enable", "disable", "close",
                     "switch to", "play", "send", "submit", "run ", "do "]
        return verbs.contains { t.contains($0) }
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
                // Grounded re-targeting: a click re-locates its target on the
                // *current* screen via the recorded OCR anchor, so a moved window or
                // shifted layout self-corrects instead of clicking a stale pixel.
                if let x = step.x, let y = step.y,
                   step.kind == .click || step.kind == .doubleClick || step.kind == .rightClick {
                    let target = await regroundedTarget(anchor: step.ocrAnchor, recorded: CGPoint(x: x, y: y))
                    try await driver.act(.computerUse(.move(x: target.x, y: target.y)))
                    try? await Task.sleep(for: .milliseconds(320))
                    if let action = AgentAction(recipeStep: Self.retargeted(step, to: target)) {
                        try await driver.act(action)
                    }
                } else if let action = AgentAction(recipeStep: step) {
                    try await driver.act(action)
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
              let png = await Self.captureScreenPNG(),
              let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else {
            return recorded
        }
        let guidance = await elementLocator.guide(
            screenshotPNG: png,
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
