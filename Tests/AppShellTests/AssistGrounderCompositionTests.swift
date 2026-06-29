import AgentOrchestrator
import CascadeMemory
import CoreGraphics
import Foundation
import ProviderKit
import Testing

@testable import AppShell

@MainActor
private func makeAssistGrounderModel(
    verifierEnabled: Bool?,
    baseResult: GroundingResult
) throws -> (model: CascadeAppModel, store: CascadeStore) {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("CascadeAssistGrounder-\(UUID().uuidString).sqlite").path
    let store = try CascadeStore(path: path)
    let defaults = UserDefaults(suiteName: "CascadeAssistGrounder-\(UUID().uuidString)")!
    defaults.set(true, forKey: "cascade.mixtureGrounding")
    if let verifierEnabled {
        defaults.set(verifierEnabled, forKey: CascadeAppModel.experimentalGroundingVerifierKey)
    }
    let model = try CascadeAppModel(
        store: store,
        orchestrator: CascadeOrchestrator(store: store),
        defaults: defaults,
        startsSubsystems: false,
        appSkills: .init(),
        visualGrounderOverride: AssistGrounderStub(result: baseResult)
    )
    return (model, store)
}

@MainActor @Test
func assistGrounderExplicitOptOutLeavesVerifierOffAndReturnsLegacyPoint() async throws {
    let oldPoint = CGPoint(x: 1_200, y: 320)
    let (model, store) = try makeAssistGrounderModel(
        verifierEnabled: false,
        baseResult: groundingResult([
            groundingCandidate(point: oldPoint, rawModel: "Send")
        ])
    )

    let grounder = try #require(model.assistGrounder())
    let selected = await grounder.ground(
        screenshot: Data(),
        target: "Send",
        displayWidthPoints: 1_000,
        displayHeightPoints: 700
    )
    let audit = try await store.recentAudit()

    #expect(selected == oldPoint)
    #expect(!audit.contains { $0.action == "grounding.verifier" })
}

@MainActor @Test
func assistGrounderDefaultEnablesVerifierWhenMixtureIsActive() async throws {
    let (model, store) = try makeAssistGrounderModel(
        verifierEnabled: nil,
        baseResult: groundingResult([
            groundingCandidate(point: CGPoint(x: 1_200, y: 320), rawModel: "Send")
        ])
    )

    let grounder = try #require(model.assistGrounder())
    let result = await grounder.groundResult(
        screenshot: Data(),
        target: "Send",
        displayWidthPoints: 1_000,
        displayHeightPoints: 700
    )
    let audit = try await store.recentAudit()

    #expect(result.selectedPoint == nil)
    #expect(audit.first?.action == "grounding.verifier")
    #expect(audit.first?.detail.contains("verdict=reject") == true)
}

@MainActor @Test
func assistGrounderFlagOnRejectsOffDisplayCandidateAndAuditsVerifierOutcome() async throws {
    let (model, store) = try makeAssistGrounderModel(
        verifierEnabled: true,
        baseResult: groundingResult([
            groundingCandidate(point: CGPoint(x: 1_200, y: 320), rawModel: "Send")
        ])
    )

    let grounder = try #require(model.assistGrounder())
    let result = await grounder.groundResult(
        screenshot: Data(),
        target: "Send",
        displayWidthPoints: 1_000,
        displayHeightPoints: 700
    )
    let audit = try await store.recentAudit()

    #expect(result.selectedPoint == nil)
    #expect(audit.count == 1)
    #expect(audit.first?.action == "grounding.verifier")
    #expect(audit.first?.detail.contains("verdict=reject") == true)
    #expect(audit.first?.detail.contains("failure=offscreen") == true)
}

@MainActor @Test
func assistGrounderFlagOnAbstainsOnConflictingCandidatesAndAuditsVerifierOutcome() async throws {
    let (model, store) = try makeAssistGrounderModel(
        verifierEnabled: true,
        baseResult: groundingResult([
            groundingCandidate(point: CGPoint(x: 420, y: 320), rawModel: "Send"),
            groundingCandidate(point: CGPoint(x: 470, y: 320), rawModel: "Send"),
        ])
    )

    let grounder = try #require(model.assistGrounder())
    let result = await grounder.groundResult(
        screenshot: Data(),
        target: "Send",
        displayWidthPoints: 1_000,
        displayHeightPoints: 700
    )
    let audit = try await store.recentAudit()

    #expect(result.selectedPoint == nil)
    #expect(audit.count == 1)
    #expect(audit.first?.action == "grounding.verifier")
    #expect(audit.first?.detail.contains("verdict=abstain") == true)
    #expect(audit.first?.detail.contains("failure=ambiguous") == true)
}

private func groundingResult(_ candidates: [GroundingCandidate]) -> GroundingResult {
    GroundingResult(candidates: candidates, selectedIndex: candidates.isEmpty ? nil : 0)
}

private func groundingCandidate(
    point: CGPoint,
    rawModel: String,
    confidence: Double = 0.95,
    dispersion: Double? = 4
) -> GroundingCandidate {
    GroundingCandidate(
        point: point,
        confidence: confidence,
        source: .ocr,
        coordinateSpace: .displayLocalAppKitPoints,
        rawModel: rawModel,
        dispersion: dispersion
    )
}

private struct AssistGrounderStub: VisualGrounder {
    let result: GroundingResult

    func ground(
        screenshot: Data,
        target: String,
        displayWidthPoints: Int,
        displayHeightPoints: Int
    ) async -> CGPoint? {
        result.selectedPoint
    }

    func groundResult(
        screenshot: Data,
        target: String,
        displayWidthPoints: Int,
        displayHeightPoints: Int
    ) async -> GroundingResult {
        result
    }
}
