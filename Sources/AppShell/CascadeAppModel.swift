import AgentOrchestrator
import AppKit
import CascadeMemory
import Combine
import ComputerUseKit
import Foundation
import MacContextKit
import ProviderKit
import SuggestionEngine

/// One real Q&A turn over local context — drives the Reel "Ask about this moment" thread.
public struct QATurn: Identifiable, Sendable {
    public let id = UUID()
    public let question: String
    public let answer: String
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
    @Published public private(set) var managerCascades: [AgentSuggestion] = []
    @Published public private(set) var contexts: [RecordedContext] = []
    @Published public private(set) var searchResults: [RecordedContext] = []
    @Published public private(set) var searchQuery: String = ""
    @Published public private(set) var audit: [AuditEvent] = []
    @Published public private(set) var suggestions: [AgentSuggestion] = []
    @Published public private(set) var answer: String = "Ask Cascade what happened in the local record."
    @Published public private(set) var conversation: [QATurn] = []
    @Published public private(set) var thinking = false
    @Published public private(set) var statusLine: String = "Starting Cascade."
    @Published public private(set) var hasAnthropicKey = false
    @Published public private(set) var keyMessage = "Claude key is not connected."
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
    public let guidanceOverlay = GuidanceOverlayController()
    public let voice = VoiceListener()
    public let pushToTalk = PushToTalkMonitor()
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

    public func ask(_ question: String) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        answer = "Thinking from local context…"
        thinking = true
        Task {
            let result: String
            do {
                result = try await orchestrator.ask(trimmed)
            } catch {
                result = error.localizedDescription
            }
            answer = result
            conversation.append(QATurn(question: trimmed, answer: result))
            thinking = false
        }
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
        let maxSteps = 10
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
    public func teach(question: String) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { teachMessage = "Ask where something is, or what to do."; return }
        guard hasAnthropicKey else {
            teachMessage = "Connect your Claude key in Settings first."
            showSettings = true
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

            let guidance = await elementLocator.guide(
                screenshotPNG: png,
                question: q,
                displayWidthPoints: Int(screen.frame.width),
                displayHeightPoints: Int(screen.frame.height)
            )
            guard let local = guidance.point else {
                guidanceOverlay.hide()
                teachMessage = guidance.speech
                voice.speak(guidance.speech)
                voice.done()
                return
            }

            let global = CGPoint(x: screen.frame.minX + local.x, y: screen.frame.minY + local.y)
            guidanceOverlay.present(atGlobalPoint: global, label: "this one")
            _ = try? await store.appendAudit(AuditEvent(actor: "agent", action: "teach.point", detail: q))
            teachMessage = guidance.speech
            voice.speak(guidance.speech)
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
        let agent = ComputerUseAgent()
        driver.runState.reset()
        dock.show(title: "Cascade is doing it", detail: "\(goal) · press STOP to take control.")
        let maxSteps = 14
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
                try? await Task.sleep(for: .milliseconds(450))
            }
            if failed { break }
            // Let the UI settle, then re-observe and ask for the next step.
            try? await Task.sleep(for: .milliseconds(400))
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
                guidanceOverlay.present(atGlobalPoint: globalAppKit(x, y), label: "")
                let p = cg(x, y)
                try await driver.act(.computerUse(.move(x: p.x, y: p.y)))
            case .click(let x, let y):
                guidanceOverlay.present(atGlobalPoint: globalAppKit(x, y), label: "")
                let p = cg(x, y)
                try await driver.act(.computerUse(.move(x: p.x, y: p.y)))
                try? await Task.sleep(for: .milliseconds(220))
                try await driver.act(.computerUse(.click(x: p.x, y: p.y)))
            case .doubleClick(let x, let y):
                guidanceOverlay.present(atGlobalPoint: globalAppKit(x, y), label: "")
                let p = cg(x, y)
                try await driver.act(.computerUse(.doubleClick(x: p.x, y: p.y)))
            case .rightClick(let x, let y):
                guidanceOverlay.present(atGlobalPoint: globalAppKit(x, y), label: "")
                let p = cg(x, y)
                try await driver.act(.computerUse(.rightClick(x: p.x, y: p.y)))
            case .type(let text):
                try await driver.act(.computerUse(.typeText(text)))
            case .key(let combo):
                let (key, modifiers) = Self.parseKey(combo)
                try await driver.act(.computerUse(.key(key, modifiers: modifiers)))
            case .scroll(let x, let y, let direction, let amount):
                guidanceOverlay.present(atGlobalPoint: globalAppKit(x, y), label: "")
                let p = cg(x, y)
                try await driver.act(.computerUse(.move(x: p.x, y: p.y)))
                let (dx, dy) = Self.scrollDelta(direction: direction, amount: amount)
                try await driver.act(.computerUse(.scroll(deltaX: dx, deltaY: dy)))
            case .wait:
                try? await Task.sleep(for: .milliseconds(700))
            case .screenshot:
                break
            }
            return true
        } catch {
            teachMessage = "I need Accessibility + Input Monitoring to control the Mac."
            voice.speak("I need Accessibility and Input Monitoring permission to do that.")
            return false
        }
    }

    /// Captures the current screen (own windows excluded) as PNG for the next loop turn.
    private static func captureScreenPNG() async -> Data? {
        await ScreenCaptureUtility.captureCursorScreenContext(includeImage: true)?.imagePNG
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
