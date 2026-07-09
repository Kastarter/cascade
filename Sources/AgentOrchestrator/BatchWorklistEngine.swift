import CascadeMemory
import Foundation

public struct BatchFieldValue: Sendable, Equatable {
    public let fieldKeyHash: String
    public let kind: RecipeParameterKind?
    public let rawValue: String

    public init(fieldKeyHash: String, kind: RecipeParameterKind? = nil, rawValue: String) {
        self.fieldKeyHash = fieldKeyHash
        self.kind = kind
        self.rawValue = rawValue
    }

    public var normalizedValue: String {
        Self.normalized(rawValue)
    }

    public var valueHash: String {
        AuditIdentity.hash(rawValue)
    }

    public var normalizedValueHash: String {
        AuditIdentity.hash(normalizedValue)
    }

    public var auditDescriptor: String {
        [
            "fieldKeyHash=\(fieldKeyHash)",
            "kind=\(AuditIdentity.safeToken(kind?.rawValue ?? "unknown"))",
            "valueChars=\(rawValue.count)",
            "valueHash=\(valueHash)"
        ].joined(separator: " ")
    }

    public static func normalized(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct BatchSourceItem: Sendable, Equatable {
    public let ordinal: Int
    public let fields: [BatchFieldValue]

    public init(ordinal: Int, fields: [BatchFieldValue]) {
        self.ordinal = ordinal
        self.fields = fields
    }

    public static func fromObservedFields(
        ordinal: Int,
        bindings: [BatchCompletionFieldBinding],
        observedFields: [String: String]
    ) -> BatchSourceItem {
        let fields = bindings.compactMap { binding -> BatchFieldValue? in
            let raw = observedFields[binding.keyHash] ?? observedFields[binding.label]
            guard let raw else { return nil }
            return BatchFieldValue(fieldKeyHash: binding.keyHash, kind: binding.kind, rawValue: raw)
        }
        return BatchSourceItem(ordinal: ordinal, fields: fields)
    }

    public func fieldValue(for keyHash: String) -> BatchFieldValue? {
        fields.first { $0.fieldKeyHash == keyHash }
    }

    public func normalizedIdentity(for keyHash: String) -> String? {
        fieldValue(for: keyHash)?.normalizedValue
    }

    public func auditDescriptor(identityFieldKeyHash: String) -> String {
        let identity = normalizedIdentity(for: identityFieldKeyHash) ?? ""
        let fieldHash = AuditIdentity.hash(fields.map { "\($0.fieldKeyHash):\($0.valueHash)" }.joined(separator: "|"))
        return [
            "ordinal=\(ordinal)",
            "identityHash=\(AuditIdentity.hash(identity))",
            "identityChars=\(identity.count)",
            "fieldCount=\(fields.count)",
            "fieldHash=\(fieldHash)"
        ].joined(separator: " ")
    }
}

public struct BatchSourceEnumeration: Sendable, Equatable {
    public let items: [BatchSourceItem]
    public let completed: Bool
    public let pagesVisited: Int
    public let issueCode: String?

    public init(items: [BatchSourceItem], completed: Bool = true, pagesVisited: Int = 1, issueCode: String? = nil) {
        self.items = items
        self.completed = completed
        self.pagesVisited = pagesVisited
        self.issueCode = issueCode
    }
}

public struct BatchDestinationSnapshot: Sendable, Equatable {
    public let identityFieldKeyHash: String
    public let normalizedIdentities: [String]

    public init(identityFieldKeyHash: String, existingIdentityValues: [String]) {
        self.identityFieldKeyHash = identityFieldKeyHash
        self.normalizedIdentities = existingIdentityValues.map(BatchFieldValue.normalized)
    }

    public var identityCounts: [String: Int] {
        Dictionary(grouping: normalizedIdentities, by: { $0 }).mapValues(\.count)
    }

    public var auditDescriptor: String {
        let counts = identityCounts
        let duplicateCount = counts.values.filter { $0 > 1 }.count
        return [
            "identityFieldKeyHash=\(identityFieldKeyHash)",
            "identityCount=\(normalizedIdentities.count)",
            "uniqueIdentityCount=\(counts.count)",
            "duplicateIdentityCount=\(duplicateCount)",
            "identityHash=\(AuditIdentity.hash(normalizedIdentities.sorted().joined(separator: "|")))"
        ].joined(separator: " ")
    }
}

public enum BatchItemDecisionStatus: String, Sendable, Codable {
    case alreadyPresent
    case added
    case verified
    case skipped
    case uncertain
}

public struct BatchItemDecision: Sendable, Equatable, Codable {
    public let ordinal: Int
    public let identityHash: String
    public let identityChars: Int
    public let status: BatchItemDecisionStatus
    public let reasonCode: String
    public let fieldCount: Int
    public let fieldHash: String

    public init(
        ordinal: Int,
        identity: String,
        status: BatchItemDecisionStatus,
        reasonCode: String = "none",
        fields: [BatchFieldValue] = []
    ) {
        self.ordinal = ordinal
        self.identityHash = AuditIdentity.hash(identity)
        self.identityChars = identity.count
        self.status = status
        self.reasonCode = AuditIdentity.safeToken(reasonCode)
        self.fieldCount = fields.count
        self.fieldHash = AuditIdentity.hash(fields.map { "\($0.fieldKeyHash):\($0.valueHash)" }.joined(separator: "|"))
    }

    public var progressDescriptor: String {
        [
            "ordinal=\(ordinal)",
            "identityHashPrefix=\(identityHash.prefix(8))",
            "status=\(status.rawValue)",
            "reasonCodeHash=\(AuditIdentity.hash(reasonCode))"
        ].joined(separator: " ")
    }

    public var auditDescriptor: String {
        [
            "ordinal=\(ordinal)",
            "identityHash=\(identityHash)",
            "identityChars=\(identityChars)",
            "status=\(status.rawValue)",
            "reasonCodeHash=\(AuditIdentity.hash(reasonCode))",
            "fieldCount=\(fieldCount)",
            "fieldHash=\(fieldHash)"
        ].joined(separator: " ")
    }
}

public enum BatchRunStatus: String, Sendable, Codable {
    case completed
    case uncertain
    case stoppedFailureLimit
}

public struct BatchRunReport: Sendable, Equatable, Codable {
    public static let schemaVersion = "batch-run-report.v1"

    public let schemaVersion: String
    public let status: BatchRunStatus
    public let totalSeen: Int
    public let alreadyPresent: Int
    public let added: Int
    public let verified: Int
    public let skipped: Int
    public let uncertain: Int
    public let decisions: [BatchItemDecision]

    public init(
        schemaVersion: String = Self.schemaVersion,
        status: BatchRunStatus,
        totalSeen: Int,
        alreadyPresent: Int,
        added: Int,
        verified: Int,
        skipped: Int,
        uncertain: Int,
        decisions: [BatchItemDecision]
    ) {
        self.schemaVersion = schemaVersion
        self.status = status
        self.totalSeen = totalSeen
        self.alreadyPresent = alreadyPresent
        self.added = added
        self.verified = verified
        self.skipped = skipped
        self.uncertain = uncertain
        self.decisions = decisions
    }

    public var reasonCounts: [String: Int] {
        Dictionary(grouping: decisions.map(\.reasonCode), by: { $0 }).mapValues(\.count)
    }

    public var auditDetail: String {
        let reasonSummary = reasonCounts
            .map { "\(AuditIdentity.hash($0.key)):\($0.value)" }
            .sorted()
            .joined(separator: ",")
        return [
            "schema=\(schemaVersion)",
            "status=\(status.rawValue)",
            "totalSeen=\(totalSeen)",
            "alreadyPresent=\(alreadyPresent)",
            "added=\(added)",
            "verified=\(verified)",
            "skipped=\(skipped)",
            "uncertain=\(uncertain)",
            "decisionCount=\(decisions.count)",
            "decisionHash=\(AuditIdentity.hash(decisions.map(\.auditDescriptor).joined(separator: "|")))",
            "reasonCount=\(reasonCounts.count)",
            "reasonCounts=\(reasonSummary)"
        ].joined(separator: " ")
    }

    public var userFacingSummary: String {
        "Batch run: total source records seen \(totalSeen), already present \(alreadyPresent), added \(added), verified \(verified), skipped \(skipped), uncertain \(uncertain)."
    }
}

public struct BatchWorkflowLimits: Sendable, Equatable, Codable {
    public let maxItems: Int
    public let maxPages: Int
    public let maxFailures: Int

    public init(maxItems: Int = 50, maxPages: Int = 20, maxFailures: Int = 3) {
        self.maxItems = max(1, maxItems)
        self.maxPages = max(1, maxPages)
        self.maxFailures = max(1, maxFailures)
    }

    public init(plan: BatchCompletionPlan) {
        self.init(maxItems: plan.maxItems, maxPages: plan.maxPages, maxFailures: plan.maxFailures)
    }
}

public protocol BatchAuditSink: Sendable {
    func recordBatchAudit(action: String, detail: String) async
}

public struct NoopBatchAuditSink: BatchAuditSink {
    public init() {}
    public func recordBatchAudit(action: String, detail: String) async {}
}

public protocol BatchSourceEnumerating: Sendable {
    func enumerateBatchSourceItems(plan: BatchCompletionPlan, limits: BatchWorkflowLimits) async throws -> BatchSourceEnumeration
}

public protocol BatchDestinationMeasuring: Sendable {
    func measureBatchDestination(plan: BatchCompletionPlan, limits: BatchWorkflowLimits) async throws -> BatchDestinationSnapshot
}

public struct BatchApplyResult: Sendable, Equatable, Codable {
    public let status: String
    public let effectHash: String

    public init(status: String = "ok", effectHash: String = "none") {
        self.status = AuditIdentity.safeToken(status)
        self.effectHash = AuditIdentity.safeToken(effectHash)
    }
}

public protocol BatchItemApplying: Sendable {
    func applyBatchItem(_ item: BatchSourceItem, plan: BatchCompletionPlan) async throws -> BatchApplyResult
}

public struct BatchVerificationResult: Sendable, Equatable, Codable {
    public let verified: Bool
    public let reasonCode: String

    public init(verified: Bool, reasonCode: String = "none") {
        self.verified = verified
        self.reasonCode = AuditIdentity.safeToken(reasonCode)
    }
}

public protocol BatchItemVerifying: Sendable {
    func verifyBatchItem(_ item: BatchSourceItem, applyResult: BatchApplyResult, plan: BatchCompletionPlan) async throws -> BatchVerificationResult
}

public struct BatchWorklistEngine: Sendable {
    public init() {}

    public func run(
        plan: BatchCompletionPlan,
        source: any BatchSourceEnumerating,
        destination: any BatchDestinationMeasuring,
        applier: any BatchItemApplying,
        verifier: any BatchItemVerifying,
        audit: any BatchAuditSink = NoopBatchAuditSink()
    ) async throws -> BatchRunReport {
        try BatchCompletionPlanValidator().validate(plan)
        let limits = BatchWorkflowLimits(plan: plan)
        await audit.recordBatchAudit(action: "batch.phase", detail: phaseDetail(.enumerateSource, status: "started"))
        let enumeration = try await source.enumerateBatchSourceItems(plan: plan, limits: limits)
        await audit.recordBatchAudit(
            action: "batch.phase",
            detail: phaseDetail(.enumerateSource, status: enumeration.completed ? "completed" : "uncertain")
        )
        if !enumeration.completed || enumeration.items.count > limits.maxItems || enumeration.pagesVisited > limits.maxPages {
            let reason = enumeration.issueCode
                ?? (enumeration.items.count > limits.maxItems ? "max_items_exceeded" : "enumeration_uncertain")
            let decisions = enumeration.items.prefix(limits.maxItems).map {
                BatchItemDecision(
                    ordinal: $0.ordinal,
                    identity: $0.normalizedIdentity(for: plan.identityFieldKeyHash) ?? "",
                    status: .uncertain,
                    reasonCode: reason,
                    fields: $0.fields
                )
            }
            let report = BatchRunReport(
                status: .uncertain,
                totalSeen: enumeration.items.count,
                alreadyPresent: 0,
                added: 0,
                verified: 0,
                skipped: decisions.count,
                uncertain: decisions.count,
                decisions: decisions
            )
            await audit.recordBatchAudit(action: "batch.run", detail: report.auditDetail)
            return report
        }

        let items = Array(enumeration.items.prefix(limits.maxItems))
        await audit.recordBatchAudit(action: "batch.phase", detail: phaseDetail(.measureDestination, status: "started"))
        let snapshot = try await destination.measureBatchDestination(plan: plan, limits: limits)
        await audit.recordBatchAudit(action: "batch.phase", detail: phaseDetail(.measureDestination, status: "completed") + " \(snapshot.auditDescriptor)")
        await audit.recordBatchAudit(action: "batch.phase", detail: phaseDetail(.diffByIdentity, status: "started"))

        let sourceIdentityCounts = identityCounts(items: items, keyHash: plan.identityFieldKeyHash)
        let destinationIdentityCounts = snapshot.identityCounts
        await audit.recordBatchAudit(action: "batch.phase", detail: phaseDetail(.diffByIdentity, status: "completed"))

        var decisions: [BatchItemDecision] = []
        var alreadyPresent = 0
        var added = 0
        var verified = 0
        var skipped = 0
        var uncertain = 0
        var failures = 0
        var stopped = false

        for item in items {
            let identity = item.normalizedIdentity(for: plan.identityFieldKeyHash) ?? ""
            guard !identity.isEmpty else {
                decisions.append(BatchItemDecision(
                    ordinal: item.ordinal,
                    identity: identity,
                    status: .skipped,
                    reasonCode: "missing_identity",
                    fields: item.fields
                ))
                skipped += 1
                continue
            }
            if (sourceIdentityCounts[identity] ?? 0) > 1 {
                decisions.append(BatchItemDecision(
                    ordinal: item.ordinal,
                    identity: identity,
                    status: .skipped,
                    reasonCode: "duplicate_source_identity",
                    fields: item.fields
                ))
                skipped += 1
                continue
            }
            let destinationCount = destinationIdentityCounts[identity] ?? 0
            if destinationCount > 1 {
                decisions.append(BatchItemDecision(
                    ordinal: item.ordinal,
                    identity: identity,
                    status: .uncertain,
                    reasonCode: "ambiguous_destination_identity",
                    fields: item.fields
                ))
                skipped += 1
                uncertain += 1
                continue
            }
            if destinationCount == 1 {
                decisions.append(BatchItemDecision(
                    ordinal: item.ordinal,
                    identity: identity,
                    status: .alreadyPresent,
                    reasonCode: "destination_match",
                    fields: item.fields
                ))
                alreadyPresent += 1
                continue
            }
            if failures >= limits.maxFailures {
                stopped = true
                decisions.append(BatchItemDecision(
                    ordinal: item.ordinal,
                    identity: identity,
                    status: .skipped,
                    reasonCode: "failure_limit",
                    fields: item.fields
                ))
                skipped += 1
                continue
            }

            await audit.recordBatchAudit(action: "batch.phase", detail: phaseDetail(.applyMissingItems, status: "started") + " \(item.auditDescriptor(identityFieldKeyHash: plan.identityFieldKeyHash))")
            do {
                let applyResult = try await applier.applyBatchItem(item, plan: plan)
                await audit.recordBatchAudit(action: "batch.phase", detail: phaseDetail(.applyMissingItems, status: "completed") + " ordinal=\(item.ordinal) status=\(applyResult.status) effectHash=\(applyResult.effectHash)")
                await audit.recordBatchAudit(action: "batch.phase", detail: phaseDetail(.verifyEachItem, status: "started") + " \(item.auditDescriptor(identityFieldKeyHash: plan.identityFieldKeyHash))")
                let verification = try await verifier.verifyBatchItem(item, applyResult: applyResult, plan: plan)
                if verification.verified {
                    added += 1
                    verified += 1
                    decisions.append(BatchItemDecision(
                        ordinal: item.ordinal,
                        identity: identity,
                        status: .verified,
                        reasonCode: "verified",
                        fields: item.fields
                    ))
                    await audit.recordBatchAudit(action: "batch.phase", detail: phaseDetail(.verifyEachItem, status: "verified") + " ordinal=\(item.ordinal)")
                } else {
                    failures += 1
                    uncertain += 1
                    decisions.append(BatchItemDecision(
                        ordinal: item.ordinal,
                        identity: identity,
                        status: .uncertain,
                        reasonCode: verification.reasonCode,
                        fields: item.fields
                    ))
                    await audit.recordBatchAudit(action: "batch.phase", detail: phaseDetail(.verifyEachItem, status: "uncertain") + " ordinal=\(item.ordinal) reasonCodeHash=\(AuditIdentity.hash(verification.reasonCode))")
                }
            } catch {
                failures += 1
                uncertain += 1
                decisions.append(BatchItemDecision(
                    ordinal: item.ordinal,
                    identity: identity,
                    status: .uncertain,
                    reasonCode: "apply_or_verify_failed",
                    fields: item.fields
                ))
                await audit.recordBatchAudit(action: "batch.phase", detail: phaseDetail(.applyMissingItems, status: "failed") + " ordinal=\(item.ordinal) errorHash=\(AuditIdentity.hash(String(describing: error)))")
            }
            if failures >= limits.maxFailures { stopped = true }
        }

        let report = BatchRunReport(
            status: stopped ? .stoppedFailureLimit : (uncertain > 0 ? .uncertain : .completed),
            totalSeen: items.count,
            alreadyPresent: alreadyPresent,
            added: added,
            verified: verified,
            skipped: skipped,
            uncertain: uncertain,
            decisions: decisions
        )
        await audit.recordBatchAudit(action: "batch.phase", detail: phaseDetail(.reportCounts, status: "completed"))
        await audit.recordBatchAudit(action: "batch.run", detail: report.auditDetail)
        return report
    }

    private func identityCounts(items: [BatchSourceItem], keyHash: String) -> [String: Int] {
        Dictionary(grouping: items.compactMap { item -> String? in
            let identity = item.normalizedIdentity(for: keyHash) ?? ""
            return identity.isEmpty ? nil : identity
        }, by: { $0 }).mapValues(\.count)
    }

    private func phaseDetail(_ phase: BatchCompletionPhase, status: String) -> String {
        "phase=\(phase.rawValue) status=\(AuditIdentity.safeToken(status))"
    }
}
