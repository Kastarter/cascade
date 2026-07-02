import CoreGraphics
import Foundation

public enum GroundingBenchmarkOutcome: String, Codable, Equatable, Sendable {
    case accept
    case reject
    case miss
    case unlabeled
}

public enum GroundingBenchmarkExpectedKind: String, Codable, Equatable, Sendable {
    case box
    case point
}

public struct GroundingBenchmarkExpected: Codable, Equatable, Sendable {
    public let kind: GroundingBenchmarkExpectedKind
    public let x: Double
    public let y: Double
    public let width: Double?
    public let height: Double?
    public let radius: Double?

    public init(
        kind: GroundingBenchmarkExpectedKind,
        x: Double,
        y: Double,
        width: Double? = nil,
        height: Double? = nil,
        radius: Double? = nil
    ) {
        self.kind = kind
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.radius = radius
    }

    public static func box(_ rect: CGRect) -> GroundingBenchmarkExpected {
        GroundingBenchmarkExpected(
            kind: .box,
            x: rect.minX,
            y: rect.minY,
            width: rect.width,
            height: rect.height
        )
    }

    public static func point(_ point: CGPoint, radius: Double = 24) -> GroundingBenchmarkExpected {
        GroundingBenchmarkExpected(kind: .point, x: point.x, y: point.y, radius: radius)
    }

    public func contains(_ point: CGPoint) -> Bool {
        switch kind {
        case .box:
            guard let width, let height else { return false }
            let rect = CGRect(x: x, y: y, width: width, height: height)
            return rect.contains(point)
        case .point:
            let allowed = radius ?? 24
            return hypot(point.x - x, point.y - y) <= allowed
        }
    }
}

public struct GroundingBenchmarkCase: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let caseID: String
    public let framePath: String
    public let targetText: String?
    public let targetHash: String?
    public let expectedBoxOrPoint: GroundingBenchmarkExpected?
    public let appBundle: String?
    public let appName: String
    public let outcome: GroundingBenchmarkOutcome
    public let sourceAuditEventID: Int64?
    public let contextID: Int64?

    public init(
        schemaVersion: Int = GroundingBenchmarkCase.currentSchemaVersion,
        caseID: String,
        framePath: String,
        targetText: String?,
        targetHash: String?,
        expectedBoxOrPoint: GroundingBenchmarkExpected?,
        appBundle: String?,
        appName: String,
        outcome: GroundingBenchmarkOutcome,
        sourceAuditEventID: Int64? = nil,
        contextID: Int64? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.caseID = caseID
        self.framePath = framePath
        self.targetText = targetText
        self.targetHash = targetHash
        self.expectedBoxOrPoint = expectedBoxOrPoint
        self.appBundle = appBundle
        self.appName = appName
        self.outcome = outcome
        self.sourceAuditEventID = sourceAuditEventID
        self.contextID = contextID
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion = "schema_version"
        case caseID = "case_id"
        case framePath = "frame_path"
        case targetText = "target_text"
        case targetHash = "target_hash"
        case expectedBoxOrPoint = "expected_box_or_point"
        case appBundle = "app_bundle"
        case appName = "app_name"
        case outcome
        case sourceAuditEventID = "source_audit_event_id"
        case contextID = "context_id"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(caseID, forKey: .caseID)
        try container.encode(framePath, forKey: .framePath)
        try Self.encodeNullable(targetText, in: &container, forKey: .targetText)
        try Self.encodeNullable(targetHash, in: &container, forKey: .targetHash)
        try Self.encodeNullable(expectedBoxOrPoint, in: &container, forKey: .expectedBoxOrPoint)
        try Self.encodeNullable(appBundle, in: &container, forKey: .appBundle)
        try container.encode(appName, forKey: .appName)
        try container.encode(outcome, forKey: .outcome)
        try Self.encodeNullable(sourceAuditEventID, in: &container, forKey: .sourceAuditEventID)
        try Self.encodeNullable(contextID, in: &container, forKey: .contextID)
    }

    public func jsonLine() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    private static func encodeNullable<T: Encodable>(
        _ value: T?,
        in container: inout KeyedEncodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws {
        if let value {
            try container.encode(value, forKey: key)
        } else {
            try container.encodeNil(forKey: key)
        }
    }
}

public enum GroundingBenchmarkJSONL {
    public static func load(from url: URL) throws -> [GroundingBenchmarkCase] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return try text
            .split(whereSeparator: \.isNewline)
            .map { try JSONDecoder().decode(GroundingBenchmarkCase.self, from: Data($0.utf8)) }
    }

    public static func write(_ cases: [GroundingBenchmarkCase], to url: URL) throws {
        let body = try cases.map { try $0.jsonLine() }.joined(separator: "\n")
        try body.appending(cases.isEmpty ? "" : "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
