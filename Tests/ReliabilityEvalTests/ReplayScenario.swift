import AgentOrchestrator
import Foundation

struct ReplayState: Sendable, Equatable, Codable {
    var appName: String
    var url: String
    var domText: String
    var fingerprint: String
    var modalTitle: String?
    var highlightedTarget: String?
    var targetTier: String?
    var verified: Bool
    var verificationFailures: Int

    init(
        appName: String = "Cascade",
        url: String = "app://cascade/start",
        domText: String = "Ready",
        fingerprint: String = "initial",
        modalTitle: String? = nil,
        highlightedTarget: String? = nil,
        targetTier: String? = nil,
        verified: Bool = false,
        verificationFailures: Int = 0
    ) {
        self.appName = appName
        self.url = url
        self.domText = domText
        self.fingerprint = fingerprint
        self.modalTitle = modalTitle
        self.highlightedTarget = highlightedTarget
        self.targetTier = targetTier
        self.verified = verified
        self.verificationFailures = verificationFailures
    }
}

enum ReplayEffect: Sendable, Equatable, Codable {
    case setApp(String)
    case setURL(String)
    case setDOMText(String)
    case appendDOMText(String)
    case setFingerprint(String)
    case showModal(String)
    case dismissModal
    case highlight(String)
    case setTargetTier(String)
    case markVerified
    case markVerificationFailure
    case wrongStartState
    case noEffect
}

struct ReplayRecipeStep: Sendable, Equatable, Codable {
    let id: String
    let action: String
    let effects: [ReplayEffect]

    init(id: String, action: String, effects: [ReplayEffect]) {
        self.id = id
        self.action = action
        self.effects = effects
    }
}

enum ReplayAssertion: Sendable, Equatable, Codable {
    case domContains(String)
    case urlContains(String)
    case fingerprintChanged
    case modalAbsent
    case highlighted(String)
    case targetTier(String)
    case verified
}

struct ReplayScenario: Sendable, Equatable, Codable {
    let id: String
    let surface: String
    let goal: String
    let initialState: ReplayState
    let recipe: [ReplayRecipeStep]
    let assertions: [ReplayAssertion]
    let injectedFailure: AgentFailureKind?
    let healsOnRecovery: RecoveryAction?
    let allowedFailureKinds: [AgentFailureKind]
    let confidence: Double?
    let calibrationOutcome: VerifierCalibrationOutcome?
    let subgoalCount: Int
    let subgoalsSucceeded: Int?
    let redundantStepCount: Int
    let wrongStartStateCount: Int

    init(
        id: String,
        surface: String,
        goal: String,
        initialState: ReplayState = ReplayState(),
        recipe: [ReplayRecipeStep],
        assertions: [ReplayAssertion],
        injectedFailure: AgentFailureKind? = nil,
        healsOnRecovery: RecoveryAction? = nil,
        allowedFailureKinds: [AgentFailureKind] = [],
        confidence: Double? = nil,
        calibrationOutcome: VerifierCalibrationOutcome? = nil,
        subgoalCount: Int = 0,
        subgoalsSucceeded: Int? = nil,
        redundantStepCount: Int = 0,
        wrongStartStateCount: Int = 0
    ) {
        self.id = id
        self.surface = surface
        self.goal = goal
        self.initialState = initialState
        self.recipe = recipe
        self.assertions = assertions
        self.injectedFailure = injectedFailure
        self.healsOnRecovery = healsOnRecovery
        self.allowedFailureKinds = allowedFailureKinds
        self.confidence = confidence
        self.calibrationOutcome = calibrationOutcome
        self.subgoalCount = max(0, subgoalCount)
        self.subgoalsSucceeded = subgoalsSucceeded
        self.redundantStepCount = max(0, redundantStepCount)
        self.wrongStartStateCount = max(0, wrongStartStateCount)
    }
}
