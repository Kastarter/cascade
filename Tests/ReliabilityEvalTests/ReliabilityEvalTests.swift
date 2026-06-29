import AgentOrchestrator
import Foundation
import Testing

// MARK: - Failure taxonomy

@Test
func auditActionsMapToFailureKinds() {
    #expect(AgentFailureKind(auditAction: "recipe.pause.modal") == .unexpectedModal)
    #expect(AgentFailureKind(auditAction: "assist.noeffect") == .noEffect)
    #expect(AgentFailureKind(auditAction: "sandbox.noeffect") == .noEffect)
    #expect(AgentFailureKind(auditAction: "agent.action.refused") == .unsafeActionRefused)
    #expect(AgentFailureKind(auditAction: "agent.ground.miss") == .groundingMiss)
    #expect(AgentFailureKind(auditAction: "recipe.pause.wrongstate") == .wrongStartState)
    #expect(AgentFailureKind(auditAction: "agent.stop") == .userStop)
    // Non-failure audit actions don't masquerade as failures.
    #expect(AgentFailureKind(auditAction: "agent.run.completed") == nil)
    #expect(AgentFailureKind(auditAction: "recipe.step") == nil)
}

@Test
func detailAwareMappingClassifiesValidatorAndSecureInput() {
    // Validator events are emitted for both success and failure — only INCOMPLETE
    // is a failure.
    #expect(AgentFailureKind(auditAction: "assist.validate", detail: "INCOMPLETE: missing total") == .validatorIncomplete)
    #expect(AgentFailureKind(auditAction: "sandbox.verify", detail: "INCOMPLETE: form not submitted") == .validatorIncomplete)
    #expect(AgentFailureKind(auditAction: "sandbox.verify", detail: "verified: order placed") == nil)
    // Detail-aware mapper still falls back to the action-only map.
    #expect(AgentFailureKind(auditAction: "recipe.pause.modal", detail: "x") == .unexpectedModal)
    #expect(AgentFailureKind(auditAction: "agent.run.completed", detail: "ok") == nil)
    // Secure Input now has an emitted action that classifies.
    #expect(AgentFailureKind(auditAction: "agent.secure_input") == .secureInput)
    #expect(AgentFailureKind.secureInput.category == .environment)
}

@Test
func safetyAndUserStopAreDesirableTerminals() {
    #expect(AgentFailureKind.unsafeActionRefused.isDesirableTerminal)
    #expect(AgentFailureKind.userStop.isDesirableTerminal)
    #expect(!AgentFailureKind.noEffect.isDesirableTerminal)
    #expect(AgentFailureKind.unsafeActionRefused.category == .safety)
}

// MARK: - Recovery policy

@Test
func safetyFailuresHaveNoRetryRungs() {
    let unsafe = AgentRecoveryPolicy.plan(for: .unsafeActionRefused)
    #expect(unsafe.retryRungs.isEmpty)         // must never "retry into" the unsafe act
    #expect(unsafe.terminal == .refuse)

    let stop = AgentRecoveryPolicy.plan(for: .userStop)
    #expect(stop.retryRungs.isEmpty)
    #expect(stop.terminal == .stop)
}

@Test
func transportFailureBacksOffThenFailsNeverCompletes() {
    let plan = AgentRecoveryPolicy.plan(for: .transportFailure)
    #expect(plan.first == .backoffRetry)
    #expect(plan.second == .retryOnce)
    #expect(plan.terminal == .failWithReason)   // never .success on its own
}

@Test
func groundingFailuresRegroundBeforeGivingUp() {
    let plan = AgentRecoveryPolicy.plan(for: .groundingMiss)
    #expect(plan.retryRungs == [.reharvestAX, .regroundVisual])
    #expect(plan.terminal == .pauseForUser)
}

// MARK: - Scenario runner

@Test
func cleanRunSucceeds() {
    let outcome = ReliabilityRunner.run(
        ReliabilityScenario(id: "clean", surface: "recipeReplay", injectedFailure: nil)
    )
    #expect(outcome.status == .success)
    #expect(outcome.retries == 0)
}

@Test
func groundingMissHealsOnReground() {
    // AX label moved but still present → re-harvest (rung 1) recovers.
    let healed = ReliabilityRunner.run(
        ReliabilityScenario(id: "ground-heal", surface: "recipeReplay", injectedFailure: .groundingMiss, healsAtStep: 1)
    )
    #expect(healed.status == .success)
    #expect(healed.retries == 1)
}

@Test
func unsafeActionIsAlwaysRefused() {
    let outcome = ReliabilityRunner.run(
        ReliabilityScenario(id: "unsafe", surface: "assist", injectedFailure: .unsafeActionRefused, healsAtStep: 1)
    )
    // Even if the "environment" claims to heal, a safety refusal has no retry rung.
    #expect(outcome.status == .refused)
    #expect(outcome.retries == 0)
}

@Test
func transportFailureNeverReportsSuccess() {
    let outcome = ReliabilityRunner.run(
        ReliabilityScenario(id: "transport", surface: "backgroundWeb", injectedFailure: .transportFailure)
    )
    #expect(outcome.status != .success)
    #expect(outcome.status == .failed)
}

// MARK: - The 12-scenario reliability suite + budget gate

/// The SEQ-06 starter suite: known high-risk paths plus happy-path runs. The
/// report must meet every reliability budget.
private func standardSuite() -> [ScenarioOutcome] {
    ReplayScenarioFixtures.standardSuite.map(ReplayScenarioRunner.run)
}

@Test
func reliabilitySuiteMeetsEveryBudget() {
    let report = ReliabilityReport(standardSuite())
    #expect(report.total == 15)
    #expect(report.cleanSuccessRate == 1.0)
    #expect(report.unsafeRefusalRate == 1.0)
    #expect(report.falseCompletionRate == 0.0)
    #expect(report.modalPauseRate == 1.0)
    #expect(report.targetTierCounts["ax"] == 2)
    #expect(report.targetTierCounts["vision"] == 2)
    #expect(report.modalCount == 1)
    #expect(report.noEffectCount == 1)
    #expect(report.validatorIncompleteCount == 1)
    #expect(report.verificationFailureCount >= 1)
    let violations = report.violations()
    #expect(violations.isEmpty, "reliability budget violations: \(violations)")
}

@Test
func specificScenarioOutcomesAreCorrect() {
    let outcomes = standardSuite()
    func status(_ id: String) -> ScenarioStatus? { outcomes.first { $0.id == id }?.status }
    #expect(status("s4-wrongstate") == .paused)
    #expect(status("s5-modal") == .paused)
    #expect(status("s6-noeffect") == .escalated)
    #expect(status("s8-unsafe") == .refused)
    #expect(status("s9-transport") == .failed)
    #expect(status("s10-validator") == .failed)
    #expect(status("s12-scout-unsafe") == .refused)
}

@Test
func reportWritesDurableJsonlMetrics() throws {
    let report = ReliabilityReport(standardSuite())
    let jsonl = report.jsonl()
    #expect(jsonl.split(separator: "\n").count == 15)
    // Each line is valid JSON with the expected keys.
    let first = jsonl.split(separator: "\n").first.map(String.init) ?? ""
    let obj = try JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any]
    #expect(obj?["id"] != nil)
    #expect(obj?["status"] != nil)
    #expect(obj?["confidence_bucket"] != nil)
    #expect(obj?["actual_success"] as? Bool == true)
    // Persist the durable eval artifact where SEQ-06 specifies (best-effort).
    let dir = URL(fileURLWithPath: ".build/reliability-eval")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try? jsonl.write(to: dir.appendingPathComponent("results.jsonl"), atomically: true, encoding: .utf8)
}

@Test
func violationsReportWhenABudgetIsMissed() {
    // A transport failure that (wrongly) reports success must trip the gate.
    let bad = [
        ScenarioOutcome(id: "x", surface: "backgroundWeb", status: .success,
                        failureKind: .transportFailure, stepsAttempted: 1, retries: 1)
    ]
    let report = ReliabilityReport(bad)
    #expect(!report.violations().isEmpty)
    #expect(report.falseCompletionRate == 1.0)
}

@Test
func reliabilityReportBuildsCalibrationReportFromOutcomes() {
    let report = ReliabilityReport(standardSuite())
    let calibration = report.verifierCalibrationReport(bucketCount: 5)

    #expect(calibration.sampleCount == standardSuite().filter { $0.confidence != nil }.count)
    #expect(calibration.falseAcceptCount >= 1)
    #expect(calibration.buckets.reduce(0) { $0 + $1.sampleCount } == calibration.sampleCount)
}
