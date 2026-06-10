import CascadeMemory
import ComputerUseKit
import Foundation
import ProviderKit
import SuggestionEngine

public struct AgentObservation: Sendable {
    public let contexts: [RecordedContext]

    public init(contexts: [RecordedContext]) {
        self.contexts = contexts
    }
}

public enum AgentAction: Sendable, Equatable {
    case computerUse(ComputerUseAction)
    case writeLocalArtifact(title: String, body: String)
}

public extension AgentAction {
    /// Maps a reviewed planner step to an executable agent action. Returns nil for
    /// non-executable steps (`done`, `unsupported`), which the caller audits but
    /// does not run.
    init?(planned: PlannedAction) {
        switch planned {
        case .move(let x, let y): self = .computerUse(.move(x: x, y: y))
        case .click(let x, let y): self = .computerUse(.click(x: x, y: y))
        case .doubleClick(let x, let y): self = .computerUse(.doubleClick(x: x, y: y))
        case .rightClick(let x, let y): self = .computerUse(.rightClick(x: x, y: y))
        case .type(let text): self = .computerUse(.typeText(text))
        case .key(let key, let modifiers): self = .computerUse(.key(key, modifiers: modifiers))
        case .scroll(let deltaX, let deltaY): self = .computerUse(.scroll(deltaX: deltaX, deltaY: deltaY))
        case .openURL(let url): self = .computerUse(.openURL(url))
        case .done, .unsupported: return nil
        }
    }

    /// Maps one step of a recorded agent recipe to an executable action.
    /// `activateApp` returns nil — the run loop handles app activation itself.
    init?(recipeStep step: RecipeStep) {
        switch step.kind {
        case .activateApp:
            return nil
        case .click:
            guard let x = step.x, let y = step.y else { return nil }
            self = .computerUse(.click(x: x, y: y))
        case .doubleClick:
            guard let x = step.x, let y = step.y else { return nil }
            self = .computerUse(.doubleClick(x: x, y: y))
        case .rightClick:
            guard let x = step.x, let y = step.y else { return nil }
            self = .computerUse(.rightClick(x: x, y: y))
        case .type:
            guard let text = step.text else { return nil }
            self = .computerUse(.typeText(text))
        case .key:
            guard let key = step.key else { return nil }
            self = .computerUse(.key(key, modifiers: step.modifiers))
        case .scroll:
            let deltaY = Double(step.modifiers.first ?? "0") ?? 0
            let deltaX = Double(step.modifiers.dropFirst().first ?? "0") ?? 0
            self = .computerUse(.scroll(deltaX: deltaX, deltaY: deltaY))
        }
    }
}

public struct AgentVerification: Sendable, Equatable {
    public let passed: Bool
    public let detail: String

    public init(passed: Bool, detail: String) {
        self.passed = passed
        self.detail = detail
    }
}

public protocol AgentDriver: Sendable {
    func observe() async throws -> AgentObservation
    func act(_ action: AgentAction) async throws
    func verify(goal: String) async throws -> AgentVerification
    func stop() async
    func status() async -> String
}

public actor LocalMacDriver: AgentDriver {
    private let store: CascadeStore
    private let actuator: ComputerUseActuator
    /// Shared STOP signal — immutable and Sendable, so the UI can flip it
    /// synchronously without hopping onto the actor.
    public nonisolated let runState: AgentRunState

    public init(store: CascadeStore, runState: AgentRunState = AgentRunState(), actuator: ComputerUseActuator? = nil) {
        self.store = store
        self.runState = runState
        self.actuator = actuator ?? NativeComputerUseActuator(runState: runState)
    }

    public func observe() async throws -> AgentObservation {
        AgentObservation(contexts: try await store.recentContexts(limit: 40))
    }

    public func act(_ action: AgentAction) async throws {
        switch action {
        case .computerUse(let computerUseAction):
            try await actuator.perform(computerUseAction)
            _ = try await store.appendAudit(AuditEvent(actor: "agent", action: "computer.act", detail: "\(computerUseAction)"))
        case .writeLocalArtifact(let title, let body):
            let url = try Self.writeArtifact(title: title, body: body)
            _ = try await store.appendAudit(AuditEvent(actor: "agent", action: "artifact.write", detail: "\(title) → \(url.path)"))
        }
    }

    /// Writes an agent-produced artifact as Markdown under
    /// `Application Support/Cascade/Artifacts/`, slugged + timestamped so runs
    /// never overwrite each other.
    private static func writeArtifact(title: String, body: String) throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("Cascade/Artifacts", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let slug = title.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { result, char in
                if char != "-" || result.last != "-" { result.append(char) }
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        // Timestamp + short random suffix — same-titled artifacts in the same
        // second must not overwrite each other.
        let stamp = Int(Date().timeIntervalSince1970)
        let nonce = UUID().uuidString.prefix(8)
        let url = dir.appendingPathComponent("\(slug.isEmpty ? "artifact" : String(slug.prefix(60)))-\(stamp)-\(nonce).md")
        try "# \(title)\n\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Did acting visibly land? Passes only when the record shows FRESH context —
    /// something was observed since the run started — not merely that a record
    /// exists at all.
    public func verify(goal: String) async throws -> AgentVerification {
        let contexts = try await store.recentContexts(limit: 12)
        guard let latest = contexts.first else {
            return AgentVerification(passed: false, detail: "No context recorded — nothing to verify against.")
        }
        let age = Date().timeIntervalSince(latest.capturedAt)
        let fresh = age < 60
        let appNames = Set(contexts.map(\.appName))
        return AgentVerification(
            passed: fresh,
            detail: fresh
                ? "Fresh context \(Int(age))s ago in \(latest.appName) (\(contexts.count) samples, \(appNames.count) apps) for goal: \(goal)"
                : "Stale record — latest context is \(Int(age))s old; the screen was not observed after acting on: \(goal)"
        )
    }

    public func stop() async {
        runState.requestStop()
        _ = try? await store.appendAudit(AuditEvent(actor: "employee", action: "agent.stop", detail: "User pressed STOP"))
    }

    public func status() async -> String {
        let health = await actuator.health()
        return health.message
    }
}

public actor CascadeOrchestrator {
    private let store: CascadeStore
    private let localAnswerer: ContextQuestionAnswering
    private let claudeAnswerer: ContextQuestionAnswering
    private let recordAnswerer: RecordAnswering
    private let planner: SingleStepPlanner
    private let suggestionEngine: SuggestionEngine
    private let wasteDetector = WasteDetector()
    private let keyStore: AnthropicKeyStore

    public init(
        store: CascadeStore,
        localAnswerer: ContextQuestionAnswering = LocalGroundedAnswerer(),
        claudeAnswerer: ContextQuestionAnswering = ClaudeGroundedAnswerer(),
        recordAnswerer: RecordAnswering? = nil,
        planner: SingleStepPlanner = ClaudeSingleStepPlanner(),
        suggestionEngine: SuggestionEngine = SuggestionEngine(),
        keyStore: AnthropicKeyStore = AnthropicKeyStore()
    ) {
        self.store = store
        self.localAnswerer = localAnswerer
        self.claudeAnswerer = claudeAnswerer
        self.recordAnswerer = recordAnswerer ?? RecordSearchAnswerer(store: store, keyStore: keyStore)
        self.planner = planner
        self.suggestionEngine = suggestionEngine
        self.keyStore = keyStore
    }

    /// Grounded Q&A. Uses Claude when a key is connected (privacy-filtered context
    /// only) and falls back to the local heuristic answerer otherwise, or on any
    /// provider error.
    public func ask(_ question: String) async throws -> String {
        try await askRecord(question).text
    }

    /// Agentic Q&A: the model hunts through the record (FTS, timeframes,
    /// per-moment inspection) and returns the answer WITH the moments it used.
    /// Falls back to single-shot grounding, then to the local heuristic, so a
    /// missing key or a flaky network never breaks asking.
    public func askRecord(_ question: String, conversation: [(user: String, assistant: String)] = []) async throws -> RecordAnswer {
        if keyStore.hasKey(),
           let answer = try? await recordAnswerer.answer(question: question, conversation: conversation) {
            return answer
        }
        let grounding = try await chatGrounding(for: question)
        if keyStore.hasKey(), let answer = try? await claudeAnswerer.answer(question: question, grounding: grounding) {
            return RecordAnswer(text: answer, citedMomentIDs: [])
        }
        return RecordAnswer(
            text: try await localAnswerer.answer(question: question, grounding: grounding),
            citedMomentIDs: []
        )
    }

    /// Resolves cited moment ids to renderable chips (privacy-filtered).
    public func citedMoments(_ ids: [Int64]) async -> [RecordedContext] {
        var moments: [RecordedContext] = []
        for id in ids {
            if let moment = try? await store.context(id: id), !PrivacyRules.isSensitive(moment) {
                moments.append(moment)
            }
        }
        return moments
    }

    /// Chat grounding, layered so any question about the user's day is answerable:
    /// the whole last-24h timeline (shape of the day), hourly on-screen content
    /// samples plus question-matched moments from the entire record (specifics
    /// seen at any time), and the freshest fully-decoded moments (what just
    /// happened). Privacy-filtered before anything reaches a provider.
    private func chatGrounding(for question: String) async throws -> ChatGrounding {
        let since = Date(timeIntervalSinceNow: -24 * 60 * 60)
        let recent = try await store.recentContexts(limit: 24)
        let timeline = (try? await store.contextTimeline(since: since)) ?? []
        let samples = (try? await store.contentSamples(since: since)) ?? []
        let relevant = (try? await store.relevantContexts(to: question)) ?? []
        return ChatGrounding(
            timeline: timeline.filter { !PrivacyRules.isSensitive($0) },
            samples: samples.filter { !PrivacyRules.isSensitive($0) },
            relevant: relevant.filter { !PrivacyRules.isSensitive($0) },
            recent: recent.filter { !PrivacyRules.isSensitive($0) }
        )
    }

    /// Proposes exactly one reviewed next step toward `goal`, grounded in recent
    /// privacy-filtered context. Requires a connected Claude key.
    public func proposeStep(goal: String) async throws -> ProposedStep {
        let contexts = try await store.recentContexts(limit: 24).filter { !PrivacyRules.isSensitive($0) }
        return try await planner.proposeNextStep(goal: goal, contexts: contexts)
    }

    public func suggestions() async throws -> [AgentSuggestion] {
        suggestionEngine.suggest(from: try await store.recentContexts(limit: 120))
    }

    /// What Cascade detected the user repeating, from recorded input anchored to
    /// the Rewind. Each is a candidate to turn into an agent built from real actions.
    public func detectedWaste(maxResults: Int = 5) async throws -> [DetectedWaste] {
        let contexts = try await store.recentContexts(limit: 400)
        let events = try await store.recentInputEvents(limit: 3000)
        return wasteDetector.detect(contexts: contexts, inputEvents: events, maxResults: maxResults)
    }

    /// Persists (or refreshes) an agent built from a detected workflow.
    @discardableResult
    public func createAgent(from waste: DetectedWaste) async throws -> CascadeAgent {
        try await store.upsertAgent(CascadeAgent(
            name: waste.title,
            source: .detected,
            signature: waste.signature,
            recipe: waste.recipe,
            apps: waste.apps,
            estimatedSeconds: waste.estimatedTotalSeconds,
            estimatedSecondsPerRun: waste.estimatedSecondsPerRun,
            evidenceCount: waste.occurrences
        ))
    }

    public func agents() async throws -> [CascadeAgent] {
        try await store.agents()
    }
}
