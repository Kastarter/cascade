import Foundation

public enum FleetPrivacyMode: String, Codable, Equatable, Sendable {
    case aggregateCountersOnly = "aggregate_counters_only"
}

public struct FleetClippingBounds: Codable, Equatable, Sendable {
    public let minimum: Int
    public let maximum: Int

    public init(minimum: Int = 0, maximum: Int = 1_000) {
        self.minimum = minimum
        self.maximum = max(minimum, maximum)
    }

    public func clipped(_ value: Int) -> (value: Int, wasClipped: Bool) {
        let clipped = min(max(value, minimum), maximum)
        return (clipped, clipped != value)
    }
}

public struct FleetMetric: Codable, Equatable, Sendable {
    public let name: String
    public let value: Int
    public let wasClipped: Bool

    public init(name: String, value: Int, wasClipped: Bool) {
        self.name = name
        self.value = value
        self.wasClipped = wasClipped
    }
}

public struct FleetExportManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let generatedAt: Date
    public let privacyMode: FleetPrivacyMode
    public let appBuild: String?
    public let tenantIDHash: String?
    public let periodStart: String?
    public let periodEnd: String?
    public let clippingBounds: FleetClippingBounds
    public let epsilon: Double?
    public let delta: Double?
    public let mechanism: LocalDPMechanism?
    public let omittedFields: [String]
    public let minCohort: Int
    public let sourceAuditHead: AuditHead?
    public let policyVersion: String

    public init(
        schemaVersion: Int,
        generatedAt: Date = Date(),
        privacyMode: FleetPrivacyMode,
        appBuild: String? = nil,
        tenantIDHash: String? = nil,
        periodStart: String? = nil,
        periodEnd: String? = nil,
        clippingBounds: FleetClippingBounds,
        epsilon: Double? = nil,
        delta: Double? = nil,
        mechanism: LocalDPMechanism? = nil,
        omittedFields: [String],
        minCohort: Int,
        sourceAuditHead: AuditHead?,
        policyVersion: String
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.privacyMode = privacyMode
        self.appBuild = appBuild
        self.tenantIDHash = tenantIDHash
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.clippingBounds = clippingBounds
        self.epsilon = epsilon
        self.delta = delta
        self.mechanism = mechanism
        self.omittedFields = omittedFields
        self.minCohort = minCohort
        self.sourceAuditHead = sourceAuditHead
        self.policyVersion = policyVersion
    }
}

public struct FleetAnalyticsExport: Codable, Equatable, Sendable {
    public let manifest: FleetExportManifest
    public let metrics: [FleetMetric]

    public init(manifest: FleetExportManifest, metrics: [FleetMetric]) {
        self.manifest = manifest
        self.metrics = metrics
    }
}

public struct FleetAuditProvenance: Codable, Equatable, Sendable {
    public let generatedAt: Date
    public let appBuild: String
    public let policyVersion: String
    public let periodStart: String
    public let periodEnd: String
    public let auditHead: AuditHead?

    public init(
        generatedAt: Date = Date(),
        appBuild: String,
        policyVersion: String,
        periodStart: String,
        periodEnd: String,
        auditHead: AuditHead?
    ) {
        self.generatedAt = generatedAt
        self.appBuild = appBuild
        self.policyVersion = policyVersion
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.auditHead = auditHead
    }
}

public struct FleetCohortReleaseDecision: Codable, Equatable, Sendable {
    public let observedDevices: Int
    public let minCohort: Int
    public let releasedMetrics: [FleetMetric]
    public let suppressedMetrics: [FleetMetric]

    public init(
        observedDevices: Int,
        minCohort: Int,
        releasedMetrics: [FleetMetric],
        suppressedMetrics: [FleetMetric]
    ) {
        self.observedDevices = max(0, observedDevices)
        self.minCohort = max(1, minCohort)
        self.releasedMetrics = releasedMetrics
        self.suppressedMetrics = suppressedMetrics
    }

    public var isSuppressed: Bool {
        !suppressedMetrics.isEmpty && releasedMetrics.isEmpty
    }
}

public enum FleetMetricInput: Equatable, Sendable {
    case counter(Int)
    case text(String)
    case decimal(Double)
    case boolean(Bool)
    case payload(String)
}

public struct AnalyticsPrivacyPolicy: Sendable {
    public static let defaultPolicyVersion = "fleet-privacy-v1"
    public static let defaultSchemaVersion = 1
    public static let defaultAllowedCounters: Set<String> = [
        "agent.run.completed.count",
        "agent.run.failed.count",
        "agent.value.completed_run.count",
        "agent.value.model_cost_cents.count",
        "agent.value.reclaimed_seconds.count",
        "agent.value.tool_action.count",
        "agent.reclaimed_seconds.count",
        "failure.kind.count",
        "input_event.count",
        "model.call.count",
        "model.token_bucket.count",
        "permission.state.count",
        "recorded_context.count",
        "suggestion.accepted.count",
        "suggestion.dismissed.count",
        "tool.call.count",
        "tool.class.count",
        "trace.duration_bucket.count",
        "trace.duration_ms.count"
    ]

    public let schemaVersion: Int
    public let privacyMode: FleetPrivacyMode
    public let clippingBounds: FleetClippingBounds
    public let minCohort: Int
    public let policyVersion: String
    public let allowedCounters: Set<String>

    public init(
        schemaVersion: Int = Self.defaultSchemaVersion,
        privacyMode: FleetPrivacyMode = .aggregateCountersOnly,
        clippingBounds: FleetClippingBounds = FleetClippingBounds(),
        minCohort: Int = 20,
        policyVersion: String = Self.defaultPolicyVersion,
        allowedCounters: Set<String> = Self.defaultAllowedCounters
    ) {
        self.schemaVersion = schemaVersion
        self.privacyMode = privacyMode
        self.clippingBounds = clippingBounds
        self.minCohort = max(1, minCohort)
        self.policyVersion = policyVersion
        self.allowedCounters = allowedCounters
    }

    public func export(
        candidates: [String: FleetMetricInput],
        sourceAuditHead: AuditHead? = nil,
        appBuild: String? = nil,
        tenantIDHash: String? = nil,
        periodStart: String? = nil,
        periodEnd: String? = nil,
        epsilon: Double? = nil,
        delta: Double? = nil,
        mechanism: LocalDPMechanism? = nil,
        generatedAt: Date = Date()
    ) -> FleetAnalyticsExport {
        var metrics: [FleetMetric] = []
        var omitted = Set<String>()

        for (field, input) in candidates {
            guard allowedCounters.contains(field) else {
                omitted.insert(Self.omissionCategory(for: field))
                continue
            }

            guard case .counter(let rawValue) = input else {
                omitted.insert("non_counter_metric_fields")
                continue
            }

            let clipped = clippingBounds.clipped(rawValue)
            metrics.append(FleetMetric(name: field, value: clipped.value, wasClipped: clipped.wasClipped))
        }

        let manifest = FleetExportManifest(
            schemaVersion: schemaVersion,
            generatedAt: generatedAt,
            privacyMode: privacyMode,
            appBuild: appBuild,
            tenantIDHash: tenantIDHash,
            periodStart: periodStart,
            periodEnd: periodEnd,
            clippingBounds: clippingBounds,
            epsilon: epsilon,
            delta: delta,
            mechanism: mechanism,
            omittedFields: omitted.sorted(),
            minCohort: minCohort,
            sourceAuditHead: sourceAuditHead,
            policyVersion: policyVersion
        )
        return FleetAnalyticsExport(
            manifest: manifest,
            metrics: metrics.sorted { $0.name < $1.name }
        )
    }

    public func serialize(
        candidates: [String: FleetMetricInput],
        sourceAuditHead: AuditHead? = nil,
        appBuild: String? = nil,
        tenantIDHash: String? = nil,
        periodStart: String? = nil,
        periodEnd: String? = nil,
        epsilon: Double? = nil,
        delta: Double? = nil,
        mechanism: LocalDPMechanism? = nil,
        encoder: JSONEncoder = JSONEncoder()
    ) throws -> Data {
        encoder.outputFormatting.formUnion([.sortedKeys])
        return try encoder.encode(export(
            candidates: candidates,
            sourceAuditHead: sourceAuditHead,
            appBuild: appBuild,
            tenantIDHash: tenantIDHash,
            periodStart: periodStart,
            periodEnd: periodEnd,
            epsilon: epsilon,
            delta: delta,
            mechanism: mechanism
        ))
    }

    public func releaseDecision(
        for export: FleetAnalyticsExport,
        observedDevices: Int
    ) -> FleetCohortReleaseDecision {
        let observed = max(0, observedDevices)
        guard observed >= minCohort else {
            return FleetCohortReleaseDecision(
                observedDevices: observed,
                minCohort: minCohort,
                releasedMetrics: [],
                suppressedMetrics: export.metrics
            )
        }

        return FleetCohortReleaseDecision(
            observedDevices: observed,
            minCohort: minCohort,
            releasedMetrics: export.metrics,
            suppressedMetrics: []
        )
    }

    public static func omissionCategory(for field: String) -> String {
        let normalized = field.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if normalized.hasPrefix("http://") || normalized.hasPrefix("https://") || normalized.contains("url") {
            return "url_fields"
        }
        if normalized.hasPrefix("/") || normalized.hasPrefix("~/") || normalized.contains("path") {
            return "path_fields"
        }
        if normalized.contains("ocr") {
            return "ocr_fields"
        }
        if normalized.contains("prompt") {
            return "prompt_fields"
        }
        if normalized.contains("tool") || normalized.contains("payload") {
            return "tool_payload_fields"
        }
        if normalized.contains("recipe") || normalized.contains("step") {
            return "recipe_step_fields"
        }
        if normalized.contains("input") || normalized.contains("event") {
            return "input_event_fields"
        }
        if normalized.contains("trace") || normalized.contains("span") {
            return "trace_span_fields"
        }
        if normalized.contains("recorded") || normalized.contains("context") {
            return "recorded_context_fields"
        }
        return "non_allowlisted_fields"
    }
}
