import Foundation

public struct ModelCallCacheRecord: Sendable, Equatable {
    public let keySHA256: String
    public let model: String
    public let callsite: String
    public let promptVersion: String
    public let schemaVersion: String
    public let requestJSONSHA256: String
    public let responseJSON: String?
    public let validatedPayloadJSON: String
    public let usageJSON: String?
    public let requestID: String?
    public let createdAt: Date
    public let expiresAt: Date

    public init(
        keySHA256: String,
        model: String,
        callsite: String,
        promptVersion: String,
        schemaVersion: String,
        requestJSONSHA256: String,
        responseJSON: String? = nil,
        validatedPayloadJSON: String,
        usageJSON: String? = nil,
        requestID: String? = nil,
        createdAt: Date = Date(),
        expiresAt: Date
    ) {
        self.keySHA256 = keySHA256
        self.model = model
        self.callsite = callsite
        self.promptVersion = promptVersion
        self.schemaVersion = schemaVersion
        self.requestJSONSHA256 = requestJSONSHA256
        self.responseJSON = responseJSON
        self.validatedPayloadJSON = validatedPayloadJSON
        self.usageJSON = usageJSON
        self.requestID = requestID
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }
}

public struct ModelCallCacheStoredEntry: Sendable, Equatable {
    public let record: ModelCallCacheRecord
    public let hitCount: Int
    public let lastHitAt: Date?

    public init(record: ModelCallCacheRecord, hitCount: Int, lastHitAt: Date?) {
        self.record = record
        self.hitCount = hitCount
        self.lastHitAt = lastHitAt
    }
}

public enum ModelRequestAttemptStatus: String, Codable, Sendable, Equatable {
    case started
    case succeeded
    case failed
}

public struct ModelRequestAttemptRecord: Sendable, Equatable {
    public let keySHA256: String
    public let attempt: Int
    public let startedAt: Date
    public let finishedAt: Date?
    public let status: ModelRequestAttemptStatus
    public let requestID: String?
    public let errorType: String?

    public init(
        keySHA256: String,
        attempt: Int,
        startedAt: Date,
        finishedAt: Date? = nil,
        status: ModelRequestAttemptStatus,
        requestID: String? = nil,
        errorType: String? = nil
    ) {
        self.keySHA256 = keySHA256
        self.attempt = attempt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.status = status
        self.requestID = requestID
        self.errorType = errorType
    }
}

public protocol ModelRequestAttemptRecording: Sendable {
    func nextModelRequestAttemptNumber(for keySHA256: String) async throws -> Int
    func recordModelRequestAttempt(_ record: ModelRequestAttemptRecord) async throws
}

public actor InMemoryModelRequestAttemptLedger: ModelRequestAttemptRecording {
    private var attemptsByKey: [String: [ModelRequestAttemptRecord]] = [:]

    public init() {}

    public func nextModelRequestAttemptNumber(for keySHA256: String) async throws -> Int {
        (attemptsByKey[keySHA256]?.map(\.attempt).max() ?? 0) + 1
    }

    public func recordModelRequestAttempt(_ record: ModelRequestAttemptRecord) async throws {
        var records = attemptsByKey[record.keySHA256] ?? []
        if let index = records.firstIndex(where: { $0.attempt == record.attempt }) {
            records[index] = record
        } else {
            records.append(record)
        }
        attemptsByKey[record.keySHA256] = records.sorted { $0.attempt < $1.attempt }
    }

    public func attempts(for keySHA256: String) -> [ModelRequestAttemptRecord] {
        attemptsByKey[keySHA256] ?? []
    }
}

extension CascadeStore: ModelRequestAttemptRecording {}
