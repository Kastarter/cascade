import CoreGraphics
import Foundation

public struct GroundingEvalCase: Codable, Equatable, Sendable {
    public let id: String
    public let target: String
    public let screenshotBase64: String?
    public let expectedPoint: CGPoint
    public let tolerance: Double
    public let coordinateSpace: GroundingCoordinateSpace

    public init(
        id: String,
        target: String,
        screenshotBase64: String? = nil,
        expectedPoint: CGPoint,
        tolerance: Double = 32,
        coordinateSpace: GroundingCoordinateSpace = .displayLocalAppKitPoints
    ) {
        self.id = id
        self.target = target
        self.screenshotBase64 = screenshotBase64
        self.expectedPoint = expectedPoint
        self.tolerance = tolerance
        self.coordinateSpace = coordinateSpace
    }
}

public struct GroundingEvalObservation: Equatable, Sendable {
    public let id: String
    public let source: GroundingSource
    public let hit: Bool
    public let latency: TimeInterval?
    public let dispersion: Double?
    public let missType: String?
    public let coordinateSpaceCorrect: Bool

    public init(
        id: String,
        source: GroundingSource,
        hit: Bool,
        latency: TimeInterval?,
        dispersion: Double?,
        missType: String?,
        coordinateSpaceCorrect: Bool
    ) {
        self.id = id
        self.source = source
        self.hit = hit
        self.latency = latency
        self.dispersion = dispersion
        self.missType = missType
        self.coordinateSpaceCorrect = coordinateSpaceCorrect
    }
}

public struct GroundingEvalSummary: Equatable, Sendable {
    public let total: Int
    public let hitRateBySource: [GroundingSource: Double]
    public let medianLatency: TimeInterval?
    public let medianDispersion: Double?
    public let missTypes: [String: Int]
    public let coordinateSpaceCorrectRate: Double

    public init(
        total: Int,
        hitRateBySource: [GroundingSource: Double],
        medianLatency: TimeInterval?,
        medianDispersion: Double?,
        missTypes: [String: Int],
        coordinateSpaceCorrectRate: Double
    ) {
        self.total = total
        self.hitRateBySource = hitRateBySource
        self.medianLatency = medianLatency
        self.medianDispersion = medianDispersion
        self.missTypes = missTypes
        self.coordinateSpaceCorrectRate = coordinateSpaceCorrectRate
    }
}

public enum GroundingEval {
    public static func loadJSONL(path: String) throws -> [GroundingEvalCase] {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        return try text.split(whereSeparator: \.isNewline).map { line in
            try JSONDecoder().decode(GroundingEvalCase.self, from: Data(line.utf8))
        }
    }

    public static func casesFromEnvironment(_ key: String = "CASCADE_GROUNDING_EVAL_JSONL") -> [GroundingEvalCase] {
        guard let path = ProcessInfo.processInfo.environment[key], !path.isEmpty else { return [] }
        return (try? loadJSONL(path: path)) ?? []
    }

    public static func run(
        cases: [GroundingEvalCase],
        grounder: any VisualGrounder,
        displayWidthPoints: Int,
        displayHeightPoints: Int,
        options: GroundingRequestOptions = .default
    ) async -> [GroundingEvalObservation] {
        var observations: [GroundingEvalObservation] = []
        for fixture in cases {
            let screenshot = fixture.screenshotBase64.flatMap { Data(base64Encoded: $0) } ?? Data()
            let result = await grounder.groundResult(
                screenshot: screenshot,
                target: fixture.target,
                displayWidthPoints: displayWidthPoints,
                displayHeightPoints: displayHeightPoints,
                options: options
            )
            observations.append(observe(fixture, result: result))
        }
        return observations
    }

    public static func observe(_ fixture: GroundingEvalCase, result: GroundingResult) -> GroundingEvalObservation {
        guard let candidate = result.selectedCandidate else {
            return GroundingEvalObservation(
                id: fixture.id,
                source: .unknown,
                hit: false,
                latency: nil,
                dispersion: nil,
                missType: result.abstainReason ?? "no_selection",
                coordinateSpaceCorrect: false
            )
        }
        let distance = candidate.point.map {
            hypot($0.x - fixture.expectedPoint.x, $0.y - fixture.expectedPoint.y)
        }
        let hit = distance.map { $0 <= fixture.tolerance } ?? false
        let coordinateSpaceCorrect = candidate.coordinateSpace == fixture.coordinateSpace
            || (hit && candidate.coordinateSpace == .displayLocalAppKitPoints)
        return GroundingEvalObservation(
            id: fixture.id,
            source: candidate.source,
            hit: hit,
            latency: candidate.latency,
            dispersion: candidate.dispersion,
            missType: hit ? nil : (result.abstainReason ?? candidate.reason ?? "miss"),
            coordinateSpaceCorrect: coordinateSpaceCorrect
        )
    }

    public static func summarize(_ observations: [GroundingEvalObservation]) -> GroundingEvalSummary {
        let grouped = Dictionary(grouping: observations, by: \.source)
        let hitRate = grouped.mapValues { rows in
            guard !rows.isEmpty else { return 0.0 }
            return Double(rows.filter { $0.hit }.count) / Double(rows.count)
        }
        let missTypes = observations.reduce(into: [String: Int]()) { acc, row in
            if let missType = row.missType { acc[missType, default: 0] += 1 }
        }
        let coordRate = observations.isEmpty
            ? 0
            : Double(observations.filter { $0.coordinateSpaceCorrect }.count) / Double(observations.count)
        return GroundingEvalSummary(
            total: observations.count,
            hitRateBySource: hitRate,
            medianLatency: median(observations.compactMap(\.latency)),
            medianDispersion: median(observations.compactMap(\.dispersion)),
            missTypes: missTypes,
            coordinateSpaceCorrectRate: coordRate
        )
    }

    public static func cropLocalPointToDisplay(_ point: CGPoint, cropDisplayBounds: CGRect) -> CGPoint {
        CGPoint(x: point.x + cropDisplayBounds.minX, y: point.y + cropDisplayBounds.minY)
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }
}
