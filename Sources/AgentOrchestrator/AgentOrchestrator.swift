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

    public init(store: CascadeStore, actuator: ComputerUseActuator = NativeComputerUseActuator()) {
        self.store = store
        self.actuator = actuator
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

    public func stop() async {}

    public func status() async -> String {
        let health = await actuator.health()
        return health.message
    }
}

public actor CascadeOrchestrator {
    private let store: CascadeStore
    private let answerer: ContextQuestionAnswering
    private let suggestionEngine: SuggestionEngine

    public init(
        store: CascadeStore,
        answerer: ContextQuestionAnswering = LocalGroundedAnswerer(),
        suggestionEngine: SuggestionEngine = SuggestionEngine()
    ) {
        self.store = store
        self.answerer = answerer
        self.suggestionEngine = suggestionEngine
    }

    public func ask(_ question: String) async throws -> String {
        let contexts = try await store.recentContexts(limit: 24)
        return try await answerer.answer(question: question, contexts: contexts)
    }

    public func suggestions() async throws -> [AgentSuggestion] {
        suggestionEngine.suggest(from: try await store.recentContexts(limit: 120))
    }
}
