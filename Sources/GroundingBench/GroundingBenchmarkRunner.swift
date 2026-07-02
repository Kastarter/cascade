import CoreGraphics
import Foundation
import ImageIO
import ProviderKit

public enum GroundingBenchmarkRunnerError: Error, Equatable, CustomStringConvertible {
    case unreadableFrame(String)
    case missingImageDimensions(String)

    public var description: String {
        switch self {
        case .unreadableFrame(let path):
            return "Unable to read benchmark frame at \(path)"
        case .missingImageDimensions(let path):
            return "Unable to decode benchmark frame dimensions at \(path)"
        }
    }
}

public enum GroundingBenchmarkObservationStatus: String, Codable, Equatable, Sendable {
    case hit
    case miss
    case skippedUnlabeled = "skipped_unlabeled"
    case skippedMissingTarget = "skipped_missing_target"
}

public struct GroundingBenchmarkObservation: Codable, Equatable, Sendable {
    public let caseID: String
    public let appKey: String
    public let status: GroundingBenchmarkObservationStatus
    public let predictedX: Double?
    public let predictedY: Double?
    public let latency: TimeInterval?

    public init(
        caseID: String,
        appKey: String,
        status: GroundingBenchmarkObservationStatus,
        predictedX: Double? = nil,
        predictedY: Double? = nil,
        latency: TimeInterval? = nil
    ) {
        self.caseID = caseID
        self.appKey = appKey
        self.status = status
        self.predictedX = predictedX
        self.predictedY = predictedY
        self.latency = latency
    }
}

public struct GroundingBenchmarkAppBreakdown: Codable, Equatable, Sendable {
    public let appBundle: String?
    public let appName: String
    public let scored: Int
    public let hits: Int
    public let misses: Int
    public let accuracy: Double
}

public struct GroundingBenchmarkReport: Codable, Equatable, Sendable {
    public let totalCases: Int
    public let scoredCases: Int
    public let hits: Int
    public let misses: Int
    public let skippedUnlabeled: Int
    public let skippedMissingTarget: Int
    public let accuracy: Double
    public let p50Latency: TimeInterval?
    public let p95Latency: TimeInterval?
    public let perApp: [String: GroundingBenchmarkAppBreakdown]
    public let observations: [GroundingBenchmarkObservation]

    public func jsonString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

public struct GroundingBenchmarkRunner: Sendable {
    public let options: GroundingRequestOptions

    public init(options: GroundingRequestOptions = .default) {
        self.options = options
    }

    public func run(jsonlURL: URL, grounder: any VisualGrounder) async throws -> GroundingBenchmarkReport {
        try await run(cases: GroundingBenchmarkJSONL.load(from: jsonlURL), grounder: grounder)
    }

    public func run(cases: [GroundingBenchmarkCase], grounder: any VisualGrounder) async throws -> GroundingBenchmarkReport {
        var observations: [GroundingBenchmarkObservation] = []
        var scoredRows: [(GroundingBenchmarkCase, GroundingBenchmarkObservation)] = []

        for benchmarkCase in cases {
            let appKey = Self.appKey(for: benchmarkCase)
            guard let target = benchmarkCase.targetText, !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                observations.append(GroundingBenchmarkObservation(
                    caseID: benchmarkCase.caseID,
                    appKey: appKey,
                    status: .skippedMissingTarget
                ))
                continue
            }
            guard let expected = benchmarkCase.expectedBoxOrPoint else {
                observations.append(GroundingBenchmarkObservation(
                    caseID: benchmarkCase.caseID,
                    appKey: appKey,
                    status: .skippedUnlabeled
                ))
                continue
            }

            let frameURL = URL(fileURLWithPath: benchmarkCase.framePath)
            let data = try Data(contentsOf: frameURL)
            let dimensions = try Self.imageDimensions(data: data, path: benchmarkCase.framePath)
            let started = ContinuousClock.now
            let result = await grounder.groundResult(
                screenshot: data,
                target: target,
                displayWidthPoints: dimensions.width,
                displayHeightPoints: dimensions.height,
                options: options
            )
            let measuredLatency = started.duration(to: .now).timeInterval
            let predicted = result.selectedPoint
            let latency = result.selectedCandidate?.latency ?? measuredLatency
            let hit = predicted.map { expected.contains($0) } ?? false
            let observation = GroundingBenchmarkObservation(
                caseID: benchmarkCase.caseID,
                appKey: appKey,
                status: hit ? .hit : .miss,
                predictedX: predicted.map { Double($0.x) },
                predictedY: predicted.map { Double($0.y) },
                latency: latency
            )
            observations.append(observation)
            scoredRows.append((benchmarkCase, observation))
        }

        return Self.report(cases: cases, observations: observations, scoredRows: scoredRows)
    }

    public static func report(
        cases: [GroundingBenchmarkCase],
        observations: [GroundingBenchmarkObservation],
        scoredRows: [(GroundingBenchmarkCase, GroundingBenchmarkObservation)]
    ) -> GroundingBenchmarkReport {
        let hits = observations.filter { $0.status == .hit }.count
        let misses = observations.filter { $0.status == .miss }.count
        let scored = hits + misses
        let latencies = observations.compactMap(\.latency)
        let grouped = Dictionary(grouping: scoredRows) { Self.appKey(for: $0.0) }
        let perApp = grouped.mapValues { rows in
            let appCase = rows[0].0
            let appHits = rows.filter { $0.1.status == .hit }.count
            let appMisses = rows.filter { $0.1.status == .miss }.count
            let appScored = appHits + appMisses
            return GroundingBenchmarkAppBreakdown(
                appBundle: appCase.appBundle,
                appName: appCase.appName,
                scored: appScored,
                hits: appHits,
                misses: appMisses,
                accuracy: appScored == 0 ? 0 : Double(appHits) / Double(appScored)
            )
        }
        return GroundingBenchmarkReport(
            totalCases: cases.count,
            scoredCases: scored,
            hits: hits,
            misses: misses,
            skippedUnlabeled: cases.filter { $0.expectedBoxOrPoint == nil }.count,
            skippedMissingTarget: cases.filter { ($0.targetText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count,
            accuracy: scored == 0 ? 0 : Double(hits) / Double(scored),
            p50Latency: percentile(latencies, 0.50),
            p95Latency: percentile(latencies, 0.95),
            perApp: perApp,
            observations: observations
        )
    }

    public static func percentile(_ values: [Double], _ percentile: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        guard sorted.count > 1 else { return sorted[0] }
        let clamped = max(0, min(1, percentile))
        let rank = clamped * Double(sorted.count - 1)
        let lower = Int(rank.rounded(.down))
        let upper = Int(rank.rounded(.up))
        guard lower != upper else { return sorted[lower] }
        let weight = rank - Double(lower)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * weight
    }

    public static func appKey(for benchmarkCase: GroundingBenchmarkCase) -> String {
        benchmarkCase.appBundle ?? benchmarkCase.appName
    }

    private static func imageDimensions(data: Data, path: String) throws -> (width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw GroundingBenchmarkRunnerError.unreadableFrame(path)
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw GroundingBenchmarkRunnerError.missingImageDimensions(path)
        }
        return (width, height)
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
