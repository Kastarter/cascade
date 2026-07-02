import CoreGraphics
import Foundation
import GroundingBench
import ProviderKit
import Testing

struct GroundingBenchmarkRunnerTests {
    @Test
    func runnerScoresBoxesPointsPerAppAndSkipsUnlabeledCases() async throws {
        let directory = try temporaryDirectory("GroundingBenchmarkRunner")
        let frame = try #require(GroundingBenchFixtures.generate(into: directory).first?.framePath)
        let cases = [
            benchmarkCase(id: "box-hit", frame: frame, target: "box-hit", expected: .box(CGRect(x: 10, y: 10, width: 40, height: 40)), bundle: "app.one", app: "One"),
            benchmarkCase(id: "box-miss", frame: frame, target: "box-miss", expected: .box(CGRect(x: 10, y: 10, width: 40, height: 40)), bundle: "app.one", app: "One"),
            benchmarkCase(id: "point-hit", frame: frame, target: "point-hit", expected: .point(CGPoint(x: 90, y: 90), radius: 12), bundle: "app.two", app: "Two"),
            benchmarkCase(id: "point-miss", frame: frame, target: "point-miss", expected: .point(CGPoint(x: 90, y: 90), radius: 12), bundle: "app.two", app: "Two"),
            benchmarkCase(id: "unlabeled", frame: frame, target: "later", expected: nil, bundle: "app.two", app: "Two"),
            benchmarkCase(id: "missing-target", frame: frame, target: nil, expected: .point(CGPoint(x: 10, y: 10)), bundle: "app.two", app: "Two"),
        ]
        let report = try await GroundingBenchmarkRunner().run(
            cases: cases,
            grounder: StubGrounder(results: [
                "box-hit": result(point: CGPoint(x: 20, y: 20), latency: 0.10),
                "box-miss": result(point: CGPoint(x: 80, y: 80), latency: 0.20),
                "point-hit": result(point: CGPoint(x: 95, y: 95), latency: 0.30),
                "point-miss": result(point: CGPoint(x: 130, y: 130), latency: 0.40),
            ])
        )

        #expect(report.totalCases == 6)
        #expect(report.scoredCases == 4)
        #expect(report.hits == 2)
        #expect(report.misses == 2)
        #expect(report.skippedUnlabeled == 1)
        #expect(report.skippedMissingTarget == 1)
        #expect(report.accuracy == 0.5)
        #expect(report.perApp["app.one"]?.scored == 2)
        #expect(report.perApp["app.one"]?.accuracy == 0.5)
        #expect(report.perApp["app.two"]?.scored == 2)
        #expect(report.perApp["app.two"]?.accuracy == 0.5)
    }

    @Test
    func percentileMathIsDeterministic() {
        let values = [0.10, 0.20, 0.30, 0.40]

        #expect(abs((GroundingBenchmarkRunner.percentile(values, 0.50) ?? 0) - 0.25) < 0.000_001)
        #expect(abs((GroundingBenchmarkRunner.percentile(values, 0.95) ?? 0) - 0.385) < 0.000_001)
        #expect(GroundingBenchmarkRunner.percentile([0.42], 0.95) == 0.42)
    }
}

struct StubGrounder: VisualGrounder {
    let results: [String: GroundingResult]

    func ground(
        screenshot: Data,
        target: String,
        displayWidthPoints: Int,
        displayHeightPoints: Int
    ) async -> CGPoint? {
        results[target]?.selectedPoint
    }

    func groundResult(
        screenshot: Data,
        target: String,
        displayWidthPoints: Int,
        displayHeightPoints: Int
    ) async -> GroundingResult {
        results[target] ?? GroundingResult()
    }
}

private func benchmarkCase(
    id: String,
    frame: String,
    target: String?,
    expected: GroundingBenchmarkExpected?,
    bundle: String,
    app: String
) -> GroundingBenchmarkCase {
    GroundingBenchmarkCase(
        caseID: id,
        framePath: frame,
        targetText: target,
        targetHash: "hash-\(id)",
        expectedBoxOrPoint: expected,
        appBundle: bundle,
        appName: app,
        outcome: expected == nil ? .unlabeled : .accept
    )
}

func result(point: CGPoint, latency: TimeInterval) -> GroundingResult {
    GroundingResult(
        candidates: [
            GroundingCandidate(
                point: point,
                confidence: 0.92,
                source: .visualModel,
                coordinateSpace: .displayLocalAppKitPoints,
                latency: latency
            )
        ],
        selectedIndex: 0
    )
}

func temporaryDirectory(_ name: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
