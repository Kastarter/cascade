import CoreGraphics
import Foundation
import GroundingBench
import ProviderKit
import Testing

struct GroundingAblationRunnerTests {
    /// End-to-end through the REAL path: fixtures -> JSONL on disk -> decode -> runner ->
    /// report. Going through the file (not in-memory cases) pins the encodeIfPresent line in
    /// GroundingBenchmarkCase.encode(to:) -- forgetting it would silently drop candidates on
    /// the round trip and this test would throw noAblationCases.
    @Test
    func fixtureAblationDivergesPerArmAndHybridWins() throws {
        let directory = try temporaryDirectory("GroundingAblationRunner")
        let jsonl = directory.appendingPathComponent("ablation-fixture.jsonl")
        _ = try GroundingBenchFixtures.generate(into: directory, jsonlURL: jsonl)
        let loaded = try GroundingBenchmarkJSONL.load(from: jsonl)

        let report = try GroundingAblationRunner().run(cases: loaded)

        #expect(report.totalCases == 4)
        #expect(report.scoredCases == 3)
        // The unlabeled fixture case (nil target) is skipped, never scored.
        #expect(report.skippedMissingTarget == 1)
        #expect(report.skippedUnlabeled == 0)
        #expect(report.skippedNoCandidates == 0)

        let ax = try #require(report.arms.first { $0.arm == .axOnly })
        let vision = try #require(report.arms.first { $0.arm == .visionOnly })
        let hybrid = try #require(report.arms.first { $0.arm == .hybrid })

        // axOnly fails exactly the search case (no AX candidate -> abstain).
        #expect(ax.scored == 3)
        #expect(ax.hits == 2)
        #expect(ax.misses == 0)
        #expect(ax.abstains == 1)
        #expect(ax.misses + ax.abstains == 1)

        // visionOnly fails exactly the save case (off-target vision candidate -> miss).
        #expect(vision.scored == 3)
        #expect(vision.hits == 2)
        #expect(vision.misses == 1)
        #expect(vision.abstains == 0)
        #expect(vision.misses + vision.abstains == 1)

        // Hybrid (AX-first, vision fallback) hits everything on the fixtures.
        #expect(hybrid.scored == 3)
        #expect(hybrid.hits == 3)
        #expect(report.hybridFailureRate == 0.0)
        #expect(abs(report.axOnlyFailureRate - 1.0 / 3.0) < 0.000_001)
        #expect(abs(report.visionOnlyFailureRate - 1.0 / 3.0) < 0.000_001)
    }

    /// Pins the SS6 gate field names in the printed JSON.
    @Test
    func reportJSONCarriesHybridFailureRateKey() throws {
        let directory = try temporaryDirectory("GroundingAblationReportJSON")
        let cases = try GroundingBenchFixtures.generate(into: directory)
        let report = try GroundingAblationRunner().run(cases: cases)
        let json = try report.jsonString()

        #expect(json.contains("\"hybrid_failure_rate\""))
        #expect(json.contains("\"ax_only_failure_rate\""))
        #expect(json.contains("\"vision_only_failure_rate\""))
    }

    /// Pure pins on the one policy function: AX-first is structural, not a confidence race.
    @Test
    func selectPolicyIsAXFirst() throws {
        let lowConfidenceAX = GroundingAblationCandidate(source: .accessibility, x: 10, y: 10, confidence: 0.30)
        let highConfidenceVision = GroundingAblationCandidate(source: .uiTars, x: 90, y: 90, confidence: 0.99)
        let mixed = [highConfidenceVision, lowConfidenceAX]

        // Hybrid picks AX even when a vision candidate has higher confidence.
        #expect(GroundingAblationRunner.select(arm: .hybrid, candidates: mixed) == lowConfidenceAX)
        // Hybrid falls to vision only when no AX candidate exists.
        #expect(GroundingAblationRunner.select(arm: .hybrid, candidates: [highConfidenceVision]) == highConfidenceVision)
        // visionOnly never returns an AX candidate.
        #expect(GroundingAblationRunner.select(arm: .visionOnly, candidates: [lowConfidenceAX]) == nil)
        #expect(GroundingAblationRunner.select(arm: .visionOnly, candidates: mixed) == highConfidenceVision)
        // axOnly never returns a vision candidate; empty pool -> nil -> abstain.
        #expect(GroundingAblationRunner.select(arm: .axOnly, candidates: [highConfidenceVision]) == nil)
        #expect(GroundingAblationRunner.select(arm: .axOnly, candidates: []) == nil)

        // arm.allows pins the source partition.
        #expect(GroundingAblationArm.axOnly.allows(.accessibility))
        #expect(!GroundingAblationArm.axOnly.allows(.uiTars))
        #expect(GroundingAblationArm.visionOnly.allows(.uiTars))
        #expect(GroundingAblationArm.visionOnly.allows(.claude))
        #expect(GroundingAblationArm.visionOnly.allows(.visualModel))
        #expect(GroundingAblationArm.visionOnly.allows(.ocr))
        #expect(!GroundingAblationArm.visionOnly.allows(.accessibility))
        #expect(GroundingAblationArm.hybrid.allows(.accessibility))
        #expect(GroundingAblationArm.hybrid.allows(.uiTars))

        // An arm with no candidate ABSTAINS: counted in failureRate, but reported as
        // abstain, never conflated with a miss (degrade to MISSED, never FALSE).
        let directory = try temporaryDirectory("GroundingAblationAbstain")
        let frame = try #require(GroundingBenchFixtures.generate(into: directory).first?.framePath)
        let visionOnlyCase = GroundingBenchmarkCase(
            caseID: "vision-only-candidates",
            framePath: frame,
            targetText: "Thing",
            targetHash: nil,
            expectedBoxOrPoint: .point(CGPoint(x: 90, y: 90), radius: 12),
            appBundle: "com.cascade.fixture",
            appName: "Fixture",
            outcome: .accept,
            ablationCandidates: [highConfidenceVision]
        )
        let report = try GroundingAblationRunner().run(cases: [visionOnlyCase])
        let axObservation = try #require(report.observations.first { $0.arm == .axOnly })
        #expect(axObservation.status == .abstain)
        #expect(axObservation.predictedX == nil)
        let axSummary = try #require(report.arms.first { $0.arm == .axOnly })
        #expect(axSummary.abstains == 1)
        #expect(axSummary.misses == 0)
        #expect(axSummary.failureRate == 1.0)
        #expect(report.hybridFailureRate == 0.0)
    }

    /// Legacy schema-v2 lines with no ablation_candidates key still decode, and an all-legacy
    /// input fails fast instead of printing a hollow report.
    @Test
    func legacyCaseLinesWithoutAblationFieldStillDecodeAndAreSkipped() throws {
        let legacyLine = """
        {"app_bundle":null,"app_name":"Legacy","case_id":"legacy-1","context_id":null,\
        "display_height_points":null,"display_width_points":null,\
        "expected_box_or_point":{"height":40,"kind":"box","width":40,"x":10,"y":10},\
        "frame_path":"/tmp/legacy.png","outcome":"accept","schema_version":2,\
        "source_audit_event_id":null,"target_hash":null,"target_text":"Legacy"}
        """
        let decoded = try JSONDecoder().decode(GroundingBenchmarkCase.self, from: Data(legacyLine.utf8))
        #expect(decoded.ablationCandidates == nil)
        #expect(decoded.schemaVersion == 2)
        // Round trip stays byte-compatible: nil never writes the ablation_candidates key.
        #expect(!(try decoded.jsonLine()).contains("ablation_candidates"))

        #expect(throws: GroundingAblationRunnerError.noAblationCases) {
            try GroundingAblationRunner().run(cases: [decoded])
        }
        #expect(throws: GroundingAblationRunnerError.noAblationCases) {
            try GroundingAblationRunner().run(cases: [])
        }
    }
}
