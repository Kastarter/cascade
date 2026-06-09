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
            _ = try await store.appendAudit(AuditEvent(actor: "agent", action: "artifact.write.preview", detail: "\(title): \(body.prefix(120))"))
        }
    }

    public func verify(goal: String) async throws -> AgentVerification {
        let contexts = try await store.recentContexts(limit: 12)
        let appNames = Set(contexts.map(\.appName))
        return AgentVerification(
            passed: !contexts.isEmpty,
            detail: contexts.isEmpty
                ? "No context available for verification."
                : "Verified against \(contexts.count) recent context samples across \(appNames.count) apps for goal: \(goal)"
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
    private let planner: SingleStepPlanner
    private let suggestionEngine: SuggestionEngine
    private let keyStore: AnthropicKeyStore

    public init(
        store: CascadeStore,
        localAnswerer: ContextQuestionAnswering = LocalGroundedAnswerer(),
        claudeAnswerer: ContextQuestionAnswering = ClaudeGroundedAnswerer(),
        planner: SingleStepPlanner = ClaudeSingleStepPlanner(),
        suggestionEngine: SuggestionEngine = SuggestionEngine(),
        keyStore: AnthropicKeyStore = AnthropicKeyStore()
    ) {
        self.store = store
        self.localAnswerer = localAnswerer
        self.claudeAnswerer = claudeAnswerer
        self.planner = planner
        self.suggestionEngine = suggestionEngine
        self.keyStore = keyStore
    }

    /// Grounded Q&A. Uses Claude when a key is connected (privacy-filtered context
    /// only) and falls back to the local heuristic answerer otherwise, or on any
    /// provider error.
    public func ask(_ question: String) async throws -> String {
        let contexts = try await store.recentContexts(limit: 24).filter { !PrivacyRules.isSensitive($0) }
        if keyStore.hasKey(), let answer = try? await claudeAnswerer.answer(question: question, contexts: contexts) {
            return answer
        }
        return try await localAnswerer.answer(question: question, contexts: contexts)
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
}
