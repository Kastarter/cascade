import CascadeMemory
import Foundation
import ProviderKit
import Testing

@testable import AgentOrchestrator

/// Whole-second dates so the deterministic `.iso8601` JSON dump round-trips
/// Codable-equal (fractional seconds would be lost in decode).
private let ledgerBase = Date(timeIntervalSince1970: 1_900_000_000)

private func ledgerStorePath() -> String {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("FailureLedger-\(UUID().uuidString).sqlite")
        .path
}

// MARK: Production-format fixture details
//
// Every detail below is BYTE-FAITHFUL to what the shipped emitters persist —
// the P7-05/P7-07 sanitizers run BEFORE appendAudit, so a fixture written in
// pre-sanitization form (raw ground logs, raw "INCOMPLETE: …" text) would
// exercise a format that never reaches the user's audit_event table and the
// ledger would go green while dead on live data.

/// Mirrors `CascadeAppModel.groundAuditDetail`: hash/count descriptor plus the
/// structured grounding-source safe-token extracted from the in-agent log.
private func groundDetail(_ raw: String, source: GroundingSource) -> String {
    "\(AuditIdentity.descriptor("ground", raw)) source=\(source.rawValue)"
}

/// Mirrors `BackgroundWebAgent.sandboxGroundAuditDescriptor` (same shape, DOM
/// surface).
private func sandboxGroundDetail(_ raw: String, source: GroundingSource) -> String {
    "status=hit targetChars=\(raw.count) targetHash=\(AuditIdentity.hash(raw)) source=\(source.rawValue)"
}

/// Mirrors `CascadeAppModel.groundingVerifierAuditDetail`.
private func verifierDetail(
    verdict: String, outcome: String, failure: String, confidence: Double,
    candidates: Int, target: String, selectedSource: GroundingSource? = nil
) -> String {
    var parts = [
        "verdict=\(verdict)",
        "outcome=\(outcome)",
        "failure=\(failure)",
        "confidence=\(String(format: "%.2f", confidence))",
        "candidates=\(candidates)",
        AuditIdentity.descriptor("target", target),
    ]
    if let selectedSource { parts.append("selectedSource=\(selectedSource.rawValue)") }
    return parts.joined(separator: " ")
}

/// Builds a temp-file store and appends a fixture stream in the PERSISTED
/// audit format that the real `AgentTraceBuilder` recognizes:
/// episode A (assist, succeeded), episode B (assist, terminated on
/// `status=incomplete` validation), episode D (recipeReplay, escalated — both
/// a `recipe.escalate` row AND an escalate-terminal root, pinning the
/// double-count dedup), episode C (backgroundWeb, closes immediately, with a
/// sanitized `sandbox.ground` row), plus one raw episode-less
/// `recipe.escalate` row.
private func makeFixtureStore() async throws -> CascadeStore {
    let store = try CascadeStore(path: ledgerStorePath())
    var second: TimeInterval = 0
    func append(_ action: String, _ detail: String) async throws {
        second += 1
        _ = try await store.appendAudit(AuditEvent(
            createdAt: ledgerBase.addingTimeInterval(second),
            actor: "agent",
            action: action,
            detail: detail
        ))
    }

    // Episode A: assist run that completes (succeeded). agent.ground rows are
    // the sanitized `CascadeAppModel.groundAuditDetail` shape — hash/count
    // descriptor plus the structured source token, NEVER the raw in-agent log.
    try await append("assist.task", AuditIdentity.descriptor("goal", "make a title slide"))
    try await append("agent.ground", groundDetail(
        "hit \"title field\" source=accessibility confidence=0.92 risk=low @(120,340) alternatives=1",
        source: .accessibility
    ))
    try await append("agent.ground", groundDetail(
        "hit \"subtitle field\" source=accessibility confidence=0.88 risk=low @(120,410) alternatives=0",
        source: .accessibility
    ))
    try await append("agent.ground", groundDetail(
        "hit \"author box\" source=ocr confidence=0.61 risk=low @(120,480) alternatives=2",
        source: .ocr
    ))
    try await append("grounding.verifier", verifierDetail(
        verdict: "accept", outcome: "selected", failure: "none", confidence: 0.91,
        candidates: 3, target: "title field", selectedSource: .accessibility
    ))
    try await append("grounding.verifier", verifierDetail(
        verdict: "accept", outcome: "selected", failure: "none", confidence: 0.87,
        candidates: 2, target: "subtitle field", selectedSource: .accessibility
    ))
    try await append("grounding.verifier", verifierDetail(
        verdict: "reject", outcome: "rejected", failure: "lowEvidence", confidence: 0.22,
        candidates: 4, target: "author box"
    ))
    try await append("agent.run.completed", "agentID=3 \(AuditIdentity.descriptor("label", "make a title slide"))")

    // Episode B: assist run that no-effects then fails validation (terminated).
    // assist.validate is the sanitized `status=incomplete …` token format
    // (CascadeAppModel.assistValidationAuditDetail), NOT the pre-P7 raw
    // "INCOMPLETE: …" prefix.
    try await append("assist.task", AuditIdentity.descriptor("goal", "fill the subtitle"))
    try await append(
        "assist.noeffect",
        "turn=2 status=no-effect noEffectStreak=1 recoveryAction=recapture "
            + "controlCount=not-collected labelsHash=none coordsHash=none ocrLineCount=0 ocrMarksHash=none"
    )
    try await append(
        "assist.validate",
        "status=incomplete recoveryAction=\(RecoveryAction.diagnosticProbe.rawValue) "
            + AuditIdentity.descriptor("missing", "subtitle still empty")
    )

    // Episode D: recipeReplay run that audits `recipe.escalate` AND resolves to
    // an escalate terminal (root failure .noEffect → RecoveryPlan terminal
    // .escalate → ScenarioStatus .escalated). One real-world escalation — the
    // ledger must count it ONCE, not once per signal.
    try await append("recipe.run.started", "agentID=7 steps=2 \(AuditIdentity.descriptor("name", "Invoice sweep"))")
    try await append(
        "recipe.unverified",
        "step=1 kind=click \(AuditIdentity.descriptor("app", "Numbers")) hasPoint=true "
            + "isParameter=false actionKeyHash=ab12cd34ef56 recoveryAction=recapture delta=rootHashChanged"
    )
    try await append(
        "recipe.escalate",
        "agentID=7 \(AuditIdentity.descriptor("name", "Invoice sweep")) "
            + "\(AuditIdentity.descriptor("reason", "the screen no longer matches the recorded steps")) "
            + "failureKind=noEffect recoveryAction=escalate"
    )
    try await append("recipe.run.ended", "status=paused agentID=7 steps=2 \(AuditIdentity.descriptor("name", "Invoice sweep"))")

    // Episode C: backgroundWeb root (closes immediately, no completed outcome),
    // plus a sanitized sandbox.ground row
    // (BackgroundWebAgent.sandboxGroundAuditDescriptor shape).
    try await append("sandbox.task", "outcome=\(AuditIdentity.safeToken("ended without completing")) \(AuditIdentity.descriptor("task", "collect flight prices"))")
    try await append("sandbox.ground", sandboxGroundDetail(
        "hit \"search field\" source=dom confidence=0.95 @(200,80)",
        source: .dom
    ))

    // Raw episode-less escalation row (recipeReplay surface by prefix).
    try await append(
        "recipe.escalate",
        "agentID=9 \(AuditIdentity.descriptor("name", "Inbox triage")) "
            + "\(AuditIdentity.descriptor("reason", "grounding")) recoveryAction=escalate"
    )

    return store
}

private let fixtureWindow = (
    from: ledgerBase,
    to: ledgerBase.addingTimeInterval(1000)
)

@Test
func onPathSnapshotDerivesAssertedNumbersFromRealFixtureRows() async throws {
    let store = try await makeFixtureStore()

    let snapshot = try #require(try await FailureLedger.snapshot(
        store: store,
        from: fixtureWindow.from,
        to: fixtureWindow.to,
        generatedAt: ledgerBase.addingTimeInterval(2000),
        enabled: true
    ))

    #expect(snapshot.schemaVersion == 1)
    #expect(snapshot.eventsScanned == 18)
    #expect(!snapshot.truncated)
    #expect(snapshot.surfaces.map(\.surface) == ["assist", "backgroundWeb", "recipeReplay"])

    let assist = try #require(snapshot.surfaces.first { $0.surface == "assist" })
    #expect(assist.episodes == 2)
    #expect(assist.episodesSucceeded == 1)
    #expect(assist.episodesTerminated == 1)
    #expect(assist.episodesRefusedOrStopped == 0)
    #expect(assist.episodeFailureRate == 0.5)
    #expect(assist.noEffectCount == 1)
    // Shares parse from the sanitized descriptors' structured source token —
    // the format production actually persists (not the raw in-agent log).
    #expect(assist.groundingSourceShares[GroundingSource.accessibility.rawValue] == 2.0 / 3.0)
    #expect(assist.groundingSourceShares[GroundingSource.ocr.rawValue] == 1.0 / 3.0)
    #expect(assist.verifier == FailureLedgerVerifierCounts(accepted: 2, rejected: 1, abstained: 0))
    #expect(assist.failureKindCounts[AgentOrchestrator.AgentFailureKind.noEffect.rawValue] == 1)
    // `status=incomplete` (the sanitized emitter format) must classify — the
    // legacy raw "INCOMPLETE: …" prefix format no longer reaches the store.
    #expect(assist.failureKindCounts[AgentOrchestrator.AgentFailureKind.validatorIncomplete.rawValue] == 1)
    #expect(assist.failureKindCounts[AgentOrchestrator.AgentFailureKind.lowConfidenceGrounding.rawValue] == 1)
    #expect(assist.transportFailures == 0)

    let backgroundWeb = try #require(snapshot.surfaces.first { $0.surface == "backgroundWeb" })
    #expect(backgroundWeb.episodes == 1)
    #expect(backgroundWeb.groundingSourceShares == [GroundingSource.dom.rawValue: 1.0])

    let recipeReplay = try #require(snapshot.surfaces.first { $0.surface == "recipeReplay" })
    #expect(recipeReplay.episodes == 1)
    #expect(recipeReplay.episodesTerminated == 1)
    // TWO real escalations: episode D (escalated trace + its own
    // recipe.escalate row = ONE escalation, not two) and the episode-less raw
    // row. The pre-fix double count would report 3.
    #expect(recipeReplay.escalations == 2)
    #expect(recipeReplay.failureKindCounts[AgentOrchestrator.AgentFailureKind.noEffect.rawValue] == 1)
}

@Test
func deterministicJSONDumpDecodesBackCodableEqual() async throws {
    let store = try await makeFixtureStore()
    let snapshot = try #require(try await FailureLedger.snapshot(
        store: store,
        from: fixtureWindow.from,
        to: fixtureWindow.to,
        generatedAt: ledgerBase.addingTimeInterval(2000),
        enabled: true
    ))

    let json = snapshot.json()
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(FailureLedgerSnapshot.self, from: Data(json.utf8))

    #expect(decoded == snapshot)
    // Deterministic: re-encoding the decoded snapshot reproduces the dump.
    #expect(decoded.json() == json)
}

@Test
func wiringSmokeFlagsOnlyModulesWithZeroRowActions() async throws {
    let store = try await makeFixtureStore()
    let snapshot = try #require(try await FailureLedger.snapshot(
        store: store,
        from: fixtureWindow.from,
        to: fixtureWindow.to,
        expectedWiring: [
            FailureLedgerExpectedModule(module: "groundingVerifier", expectedActions: ["grounding.verifier"]),
            FailureLedgerExpectedModule(module: "episodeKernel", expectedActions: ["kernel.shadow.diverged"]),
        ],
        generatedAt: ledgerBase.addingTimeInterval(2000),
        enabled: true
    ))

    #expect(snapshot.dormant == [
        FailureLedgerDormantFinding(module: "episodeKernel", dormantActions: ["kernel.shadow.diverged"])
    ])
    #expect(!snapshot.dormant.contains { $0.module == "groundingVerifier" })
}

@Test
func offGateReturnsNilWithoutTouchingMetrics() async throws {
    let store = try await makeFixtureStore()
    let snapshot = try await FailureLedger.snapshot(
        store: store,
        from: fixtureWindow.from,
        to: fixtureWindow.to,
        enabled: false
    )
    #expect(snapshot == nil)
}

@Test
func pureCoreDeriveOnEmptyEventsYieldsEmptySnapshotWithoutDivideByZero() {
    let window = FailureLedgerWindow(start: ledgerBase, end: ledgerBase.addingTimeInterval(60))
    let snapshot = FailureLedger.derive(
        events: [],
        window: window,
        generatedAt: ledgerBase.addingTimeInterval(120)
    )

    #expect(snapshot.surfaces.isEmpty)
    #expect(snapshot.dormant.isEmpty)
    #expect(snapshot.eventsScanned == 0)
    #expect(!snapshot.truncated)
}

@Test
func failureRateIsZeroWhenOnlyRefusedOrStoppedEpisodesExist() {
    // A run whose latest failure is a desirable terminal (user stop) must land
    // in refusedOrStopped and stay OUT of the failure-rate denominator.
    let events = [
        AuditEvent(createdAt: ledgerBase.addingTimeInterval(1), actor: "agent", action: "assist.task", detail: AuditIdentity.descriptor("goal", "open notes")),
        AuditEvent(createdAt: ledgerBase.addingTimeInterval(2), actor: "employee", action: "agent.stop", detail: "User pressed STOP"),
    ]
    let window = FailureLedgerWindow(start: ledgerBase, end: ledgerBase.addingTimeInterval(60))
    let snapshot = FailureLedger.derive(events: events, window: window, generatedAt: ledgerBase)

    let assist = snapshot.surfaces.first { $0.surface == "assist" }
    #expect(assist?.episodes == 1)
    #expect(assist?.episodesRefusedOrStopped == 1)
    #expect(assist?.episodesTerminated == 0)
    #expect(assist?.episodeFailureRate == 0)
}
