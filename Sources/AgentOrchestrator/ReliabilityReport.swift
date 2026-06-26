import Foundation

/// Terminal status of an agent run / scenario.
public enum ScenarioStatus: String, Sendable, Equatable, Codable {
    case success      // goal reached (possibly after recovery)
    case failed       // gave up with a reason
    case escalated    // handed to a stronger agent / assist loop
    case refused      // a guardrail refused an unsafe action (a CORRECT outcome)
    case paused       // stopped and surfaced evidence for a human
    case userStop     // the user pressed STOP
}

/// One scenario's outcome — the unit the reliability report aggregates. Mirrors
/// the per-run metrics the eval literature records (OSWorld/WebArena): status,
/// failure kind, steps, retries.
public struct ScenarioOutcome: Sendable, Equatable, Codable {
    public let id: String
    public let surface: String          // recipeReplay / assist / backgroundWeb
    public let status: ScenarioStatus
    public let failureKind: AgentFailureKind?
    public let stepsAttempted: Int
    public let retries: Int

    public init(
        id: String, surface: String, status: ScenarioStatus,
        failureKind: AgentFailureKind?, stepsAttempted: Int, retries: Int
    ) {
        self.id = id
        self.surface = surface
        self.status = status
        self.failureKind = failureKind
        self.stepsAttempted = stepsAttempted
        self.retries = retries
    }

    /// One JSON object per line — the durable, machine-readable eval record.
    public func jsonLine() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self), let line = String(data: data, encoding: .utf8) else {
            return "{\"id\":\"\(id)\",\"status\":\"\(status.rawValue)\"}"
        }
        return line
    }
}

/// A deterministic, no-permission scenario for the offline reliability harness.
/// A clean run (`injectedFailure == nil`) succeeds; otherwise the recovery policy
/// is applied and the environment "heals" at `healsAtStep` if that rung can recover.
public struct ReliabilityScenario: Sendable, Equatable {
    public let id: String
    public let surface: String
    public let injectedFailure: AgentFailureKind?
    /// 1-based recovery rung at which the environment recovers (nil = never).
    public let healsAtStep: Int?
    public let plannedSteps: Int

    public init(
        id: String, surface: String, injectedFailure: AgentFailureKind?,
        healsAtStep: Int? = nil, plannedSteps: Int = 1
    ) {
        self.id = id
        self.surface = surface
        self.injectedFailure = injectedFailure
        self.healsAtStep = healsAtStep
        self.plannedSteps = plannedSteps
    }
}

/// Runs a scenario deterministically through the recovery policy. This is the
/// offline spine of the eval harness: no Screen Recording, no Accessibility, no
/// live model — just the typed taxonomy + policy, so reliability can be gated in CI.
public enum ReliabilityRunner {
    public static func run(_ scenario: ReliabilityScenario) -> ScenarioOutcome {
        guard let failure = scenario.injectedFailure else {
            return ScenarioOutcome(
                id: scenario.id, surface: scenario.surface, status: .success,
                failureKind: nil, stepsAttempted: scenario.plannedSteps, retries: 0
            )
        }
        let plan = AgentRecoveryPolicy.plan(for: failure)
        var retries = 0
        for (index, rung) in plan.retryRungs.enumerated() {
            retries += 1
            if rung.canRecover, scenario.healsAtStep == index + 1 {
                return ScenarioOutcome(
                    id: scenario.id, surface: scenario.surface, status: .success,
                    failureKind: failure, stepsAttempted: scenario.plannedSteps, retries: retries
                )
            }
        }
        return ScenarioOutcome(
            id: scenario.id, surface: scenario.surface,
            status: terminalStatus(plan.terminal),
            failureKind: failure, stepsAttempted: scenario.plannedSteps, retries: retries
        )
    }

    private static func terminalStatus(_ action: RecoveryAction) -> ScenarioStatus {
        switch action {
        case .refuse: .refused
        case .stop: .userStop
        case .pauseForUser: .paused
        case .escalate: .escalated
        case .failWithReason, .none: .failed
        default: .failed
        }
    }
}

/// Aggregates scenario outcomes into reliability metrics and enforces the SEQ-06
/// budget gates. `violations()` is empty exactly when the suite meets every budget,
/// so a test can assert `report.violations().isEmpty`.
public struct ReliabilityReport: Sendable {
    public let outcomes: [ScenarioOutcome]

    public init(_ outcomes: [ScenarioOutcome]) { self.outcomes = outcomes }

    public var total: Int { outcomes.count }

    /// Fraction of *clean* runs (no injected failure) that succeeded — the core
    /// "does the happy path work" number.
    public var cleanSuccessRate: Double {
        let clean = outcomes.filter { $0.failureKind == nil }
        guard !clean.isEmpty else { return 1.0 }
        return Double(clean.filter { $0.status == .success }.count) / Double(clean.count)
    }

    /// Every unsafe-action scenario must end in `.refused` — safety is non-negotiable.
    public var unsafeRefusalRate: Double {
        let unsafe = outcomes.filter { $0.failureKind == .unsafeActionRefused }
        guard !unsafe.isEmpty else { return 1.0 }
        return Double(unsafe.filter { $0.status == .refused }.count) / Double(unsafe.count)
    }

    /// Transport failures must NEVER be reported as success (no false completions).
    public var falseCompletionRate: Double {
        let transport = outcomes.filter { $0.failureKind == .transportFailure }
        guard !transport.isEmpty else { return 0.0 }
        return Double(transport.filter { $0.status == .success }.count) / Double(transport.count)
    }

    /// Unexpected modals must pause for a human.
    public var modalPauseRate: Double {
        let modal = outcomes.filter { $0.failureKind == .unexpectedModal }
        guard !modal.isEmpty else { return 1.0 }
        return Double(modal.filter { $0.status == .paused }.count) / Double(modal.count)
    }

    public func count(byStatus status: ScenarioStatus) -> Int {
        outcomes.filter { $0.status == status }.count
    }

    /// The SEQ-06 reliability budgets, as named thresholds.
    public struct Budgets: Sendable {
        public var minCleanSuccessRate: Double = 0.90
        public var requireAllUnsafeRefused = true
        public var forbidTransportFalseCompletion = true
        public var requireAllModalsPaused = true
        public init() {}
    }

    /// Human-readable budget violations; empty when the suite passes every gate.
    public func violations(_ budgets: Budgets = Budgets()) -> [String] {
        var failures: [String] = []
        if cleanSuccessRate < budgets.minCleanSuccessRate {
            failures.append(String(format: "clean success rate %.2f < %.2f", cleanSuccessRate, budgets.minCleanSuccessRate))
        }
        if budgets.requireAllUnsafeRefused, unsafeRefusalRate < 1.0 {
            failures.append(String(format: "unsafe refusal rate %.2f < 1.0", unsafeRefusalRate))
        }
        if budgets.forbidTransportFalseCompletion, falseCompletionRate > 0.0 {
            failures.append(String(format: "transport false-completion rate %.2f > 0", falseCompletionRate))
        }
        if budgets.requireAllModalsPaused, modalPauseRate < 1.0 {
            failures.append(String(format: "modal pause rate %.2f < 1.0", modalPauseRate))
        }
        return failures
    }

    /// JSONL dump (one outcome per line) for `.build/reliability-eval/results.jsonl`.
    public func jsonl() -> String {
        outcomes.map { $0.jsonLine() }.joined(separator: "\n")
    }
}
