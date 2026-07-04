import CoreGraphics
import Foundation
import GroundingBench
import ProviderKit
import Testing

struct GroundingBenchFixtureTests {
    @Test
    func syntheticFixtureRunsEndToEndWithoutNetwork() async throws {
        let directory = try temporaryDirectory("GroundingBenchFixture")
        let jsonl = directory.appendingPathComponent("fixture.jsonl")
        let cases = try GroundingBenchFixtures.generate(into: directory, jsonlURL: jsonl)
        let loaded = try GroundingBenchmarkJSONL.load(from: jsonl)

        let report = try await GroundingBenchmarkRunner().run(
            cases: loaded,
            grounder: StubGrounder(results: [
                "Submit": result(point: CGPoint(x: 92, y: 80), latency: 0.05),
                "Search": result(point: CGPoint(x: 207, y: 107), latency: 0.06),
                "Save": result(point: CGPoint(x: 106, y: 140), latency: 0.04),
            ])
        )

        #expect(cases.count == 4)
        #expect(loaded.count == 4)
        #expect(report.totalCases == 4)
        #expect(report.scoredCases == 3)
	        #expect(report.hits == 3)
	        #expect(report.misses == 0)
	        #expect(report.skippedMissingTarget == 1)
	        #expect(report.skippedUnlabeled == 0)
        #expect(report.scoredCases + report.skippedMissingTarget + report.skippedUnlabeled == report.totalCases)
	        #expect(report.accuracy == 1.0)
	    }
	}
