import Foundation

public enum LocalDPMechanism: String, Codable, Equatable, Sendable {
    case laplaceBoundedCount = "laplace_bounded_count"
    case laplaceBoundedSum = "laplace_bounded_sum"
    case kAryRandomizedResponse = "k_ary_randomized_response"
    case optimizedLocalHashing = "optimized_local_hashing"
}

public enum LocalDPCategoryDisclosure: String, Codable, Equatable, Sendable {
    case hash
    case omit
}

public enum LocalDifferentialPrivacyError: Error, Equatable, Sendable {
    case invalidEpsilon
    case invalidDelta
    case emptyDomain
    case categoryOutsideDomain
    case invalidBucketCount
    case monthlyBudgetExceeded
}

public struct LocalDPDoubleBounds: Codable, Equatable, Sendable {
    public let minimum: Double
    public let maximum: Double

    public init(minimum: Double = 0, maximum: Double = 1_000) {
        self.minimum = minimum
        self.maximum = max(minimum, maximum)
    }

    public func clipped(_ value: Double) -> (value: Double, wasClipped: Bool) {
        let clipped = min(max(value, minimum), maximum)
        return (clipped, clipped != value)
    }

    public var sensitivity: Double {
        max(1, maximum - minimum)
    }
}

public struct LocalDPPrivacyParameters: Codable, Equatable, Sendable {
    public let epsilon: Double
    public let delta: Double
    public let mechanism: LocalDPMechanism

    public init(epsilon: Double, delta: Double = 0, mechanism: LocalDPMechanism) throws {
        guard epsilon.isFinite && epsilon > 0 else {
            throw LocalDifferentialPrivacyError.invalidEpsilon
        }
        guard delta.isFinite && delta >= 0 else {
            throw LocalDifferentialPrivacyError.invalidDelta
        }
        self.epsilon = epsilon
        self.delta = delta
        self.mechanism = mechanism
    }
}

public struct LocalDPMetricRecord: Codable, Equatable, Sendable {
    public let name: String
    public let value: Double?
    public let clippedValue: Double?
    public let wasClipped: Bool
    public let epsilon: Double
    public let delta: Double
    public let mechanism: LocalDPMechanism
    public let reportedCategoryHash: String?
    public let domainSize: Int?

    public init(
        name: String,
        value: Double?,
        clippedValue: Double?,
        wasClipped: Bool,
        epsilon: Double,
        delta: Double,
        mechanism: LocalDPMechanism,
        reportedCategoryHash: String? = nil,
        domainSize: Int? = nil
    ) {
        self.name = name
        self.value = value
        self.clippedValue = clippedValue
        self.wasClipped = wasClipped
        self.epsilon = epsilon
        self.delta = delta
        self.mechanism = mechanism
        self.reportedCategoryHash = reportedCategoryHash
        self.domainSize = domainSize
    }
}

public struct LocalDPReleasedMetric: Codable, Equatable, Sendable {
    public let name: String
    public let value: Double?
    public let epsilon: Double
    public let delta: Double
    public let mechanism: LocalDPMechanism
    public let reportedCategoryHash: String?
    public let domainSize: Int?

    public init(
        name: String,
        value: Double?,
        epsilon: Double,
        delta: Double,
        mechanism: LocalDPMechanism,
        reportedCategoryHash: String? = nil,
        domainSize: Int? = nil
    ) {
        self.name = name
        self.value = value
        self.epsilon = epsilon
        self.delta = delta
        self.mechanism = mechanism
        self.reportedCategoryHash = reportedCategoryHash
        self.domainSize = domainSize
    }

    init(record: LocalDPMetricRecord) {
        self.init(
            name: record.name,
            value: record.value,
            epsilon: record.epsilon,
            delta: record.delta,
            mechanism: record.mechanism,
            reportedCategoryHash: record.reportedCategoryHash,
            domainSize: record.domainSize
        )
    }
}

public struct FleetDPBudgetSpend: Codable, Equatable, Sendable {
    public let tenantIDHash: String
    public let period: String
    public let metricFamily: String
    public let epsilon: Double
    public let delta: Double
    public let mechanism: LocalDPMechanism
    public let reservedAt: Date?

    public init(
        tenantIDHash: String = "local",
        period: String,
        metricFamily: String,
        epsilon: Double,
        delta: Double,
        mechanism: LocalDPMechanism,
        reservedAt: Date? = nil
    ) {
        self.tenantIDHash = tenantIDHash
        self.period = period
        self.metricFamily = metricFamily
        self.epsilon = epsilon
        self.delta = delta
        self.mechanism = mechanism
        self.reservedAt = reservedAt
    }
}

public struct FleetDPMonthlyBudget: Codable, Equatable, Sendable {
    public let tenantIDHash: String
    public let period: String
    public let epsilonCap: Double
    public let deltaCap: Double
    public private(set) var spends: [FleetDPBudgetSpend]

    public init(
        tenantIDHash: String = "local",
        period: String,
        epsilonCap: Double,
        deltaCap: Double = 1,
        spends: [FleetDPBudgetSpend] = []
    ) {
        self.tenantIDHash = tenantIDHash
        self.period = period
        self.epsilonCap = max(0, epsilonCap)
        self.deltaCap = max(0, deltaCap)
        self.spends = spends.filter { $0.tenantIDHash == tenantIDHash && $0.period == period }
    }

    public var spentEpsilon: Double {
        spends.reduce(0) { $0 + $1.epsilon }
    }

    public var spentDelta: Double {
        spends.reduce(0) { $0 + $1.delta }
    }

    public mutating func reserve(
        metricFamily: String,
        parameters: LocalDPPrivacyParameters,
        reservedAt: Date? = nil
    ) throws -> FleetDPBudgetSpend {
        let nextEpsilon = spentEpsilon + parameters.epsilon
        let nextDelta = spentDelta + parameters.delta
        guard nextEpsilon <= epsilonCap && nextDelta <= deltaCap else {
            throw LocalDifferentialPrivacyError.monthlyBudgetExceeded
        }

        let spend = FleetDPBudgetSpend(
            tenantIDHash: tenantIDHash,
            period: period,
            metricFamily: metricFamily,
            epsilon: parameters.epsilon,
            delta: parameters.delta,
            mechanism: parameters.mechanism,
            reservedAt: reservedAt
        )
        spends.append(spend)
        return spend
    }
}

public struct LocalDPHeavyHitterReport: Codable, Equatable, Sendable {
    public let name: String
    public let reportedBucket: Int
    public let bucketCount: Int
    public let epsilon: Double
    public let delta: Double
    public let mechanism: LocalDPMechanism
    public let cohortIDHash: String?

    public init(
        name: String,
        reportedBucket: Int,
        bucketCount: Int,
        epsilon: Double,
        delta: Double = 0,
        mechanism: LocalDPMechanism = .optimizedLocalHashing,
        cohortIDHash: String? = nil
    ) {
        self.name = name
        self.reportedBucket = reportedBucket
        self.bucketCount = bucketCount
        self.epsilon = epsilon
        self.delta = delta
        self.mechanism = mechanism
        self.cohortIDHash = cohortIDHash
    }
}

public struct LocalDPHeavyHitterEstimate: Codable, Equatable, Sendable {
    public let categoryHash: String
    public let estimatedCount: Double
    public let reportCount: Int
    public let bucket: Int
    public let minReportsSatisfied: Bool

    public init(
        categoryHash: String,
        estimatedCount: Double,
        reportCount: Int,
        bucket: Int,
        minReportsSatisfied: Bool
    ) {
        self.categoryHash = categoryHash
        self.estimatedCount = estimatedCount
        self.reportCount = reportCount
        self.bucket = bucket
        self.minReportsSatisfied = minReportsSatisfied
    }
}

public struct LocalDPFleetExport: Codable, Equatable, Sendable {
    public let manifest: FleetExportManifest
    public let metrics: [LocalDPReleasedMetric]
    public let budgetSpends: [FleetDPBudgetSpend]

    public init(
        manifest: FleetExportManifest,
        metrics: [LocalDPReleasedMetric],
        budgetSpends: [FleetDPBudgetSpend] = []
    ) {
        self.manifest = manifest
        self.metrics = metrics
        self.budgetSpends = budgetSpends
    }
}

public enum LocalDifferentialPrivacy {
    public static func clippedNoisyCount<RNG: RandomNumberGenerator>(
        name: String,
        rawValue: Int,
        bounds: FleetClippingBounds,
        epsilon: Double,
        delta: Double = 0,
        rng: inout RNG
    ) throws -> LocalDPMetricRecord {
        let parameters = try LocalDPPrivacyParameters(
            epsilon: epsilon,
            delta: delta,
            mechanism: .laplaceBoundedCount
        )
        let clipped = bounds.clipped(rawValue)
        let scale = Double(max(1, bounds.maximum - bounds.minimum)) / epsilon
        let noise = sampleLaplace(scale: scale, rng: &rng)
        return LocalDPMetricRecord(
            name: name,
            value: Double(clipped.value) + noise,
            clippedValue: Double(clipped.value),
            wasClipped: clipped.wasClipped,
            epsilon: parameters.epsilon,
            delta: parameters.delta,
            mechanism: parameters.mechanism
        )
    }

    public static func clippedNoisySum<RNG: RandomNumberGenerator>(
        name: String,
        rawValue: Double,
        bounds: LocalDPDoubleBounds,
        epsilon: Double,
        delta: Double = 0,
        rng: inout RNG
    ) throws -> LocalDPMetricRecord {
        let parameters = try LocalDPPrivacyParameters(
            epsilon: epsilon,
            delta: delta,
            mechanism: .laplaceBoundedSum
        )
        let clipped = bounds.clipped(rawValue)
        let noise = sampleLaplace(scale: bounds.sensitivity / epsilon, rng: &rng)
        return LocalDPMetricRecord(
            name: name,
            value: clipped.value + noise,
            clippedValue: clipped.value,
            wasClipped: clipped.wasClipped,
            epsilon: parameters.epsilon,
            delta: parameters.delta,
            mechanism: parameters.mechanism
        )
    }

    public static func randomizedResponse<RNG: RandomNumberGenerator>(
        name: String,
        category: String,
        domain: [String],
        epsilon: Double,
        delta: Double = 0,
        disclosure: LocalDPCategoryDisclosure,
        hashSalt: String,
        rng: inout RNG
    ) throws -> LocalDPMetricRecord {
        let parameters = try LocalDPPrivacyParameters(
            epsilon: epsilon,
            delta: delta,
            mechanism: .kAryRandomizedResponse
        )
        let normalizedDomain = Array(NSOrderedSet(array: domain).compactMap { $0 as? String })
        guard !normalizedDomain.isEmpty else {
            throw LocalDifferentialPrivacyError.emptyDomain
        }
        guard let trueIndex = normalizedDomain.firstIndex(of: category) else {
            throw LocalDifferentialPrivacyError.categoryOutsideDomain
        }

        let selectedIndex = randomizedResponseIndex(
            trueIndex: trueIndex,
            domainSize: normalizedDomain.count,
            epsilon: epsilon,
            rng: &rng
        )
        let reportedCategoryHash: String?
        switch disclosure {
        case .hash:
            reportedCategoryHash = stableHash(category: normalizedDomain[selectedIndex], salt: hashSalt)
        case .omit:
            reportedCategoryHash = nil
        }

        return LocalDPMetricRecord(
            name: name,
            value: nil,
            clippedValue: nil,
            wasClipped: false,
            epsilon: parameters.epsilon,
            delta: parameters.delta,
            mechanism: parameters.mechanism,
            reportedCategoryHash: reportedCategoryHash,
            domainSize: normalizedDomain.count
        )
    }

    public static func optimizedLocalHashingReport<RNG: RandomNumberGenerator>(
        name: String,
        category: String,
        bucketCount: Int,
        epsilon: Double,
        delta: Double = 0,
        hashSalt: String,
        cohortIDHash: String? = nil,
        rng: inout RNG
    ) throws -> LocalDPHeavyHitterReport {
        let parameters = try LocalDPPrivacyParameters(
            epsilon: epsilon,
            delta: delta,
            mechanism: .optimizedLocalHashing
        )
        guard bucketCount > 1 else {
            throw LocalDifferentialPrivacyError.invalidBucketCount
        }

        let trueBucket = stableBucket(category: category, salt: hashSalt, bucketCount: bucketCount)
        let truthfulProbability = optimizedLocalHashingTruthfulProbability(epsilon: epsilon)
        let reportedBucket: Int
        if nextUnitInterval(rng: &rng) < truthfulProbability {
            reportedBucket = trueBucket
        } else {
            let offset = Int(nextUnitInterval(rng: &rng) * Double(bucketCount - 1))
            reportedBucket = offset >= trueBucket ? offset + 1 : offset
        }

        return LocalDPHeavyHitterReport(
            name: name,
            reportedBucket: reportedBucket,
            bucketCount: bucketCount,
            epsilon: parameters.epsilon,
            delta: parameters.delta,
            cohortIDHash: cohortIDHash
        )
    }

    public static func estimateHeavyHitters(
        name: String,
        reports: [LocalDPHeavyHitterReport],
        candidateCategories: [String],
        hashSalt: String,
        minReports: Int = 50,
        limit: Int = 10
    ) -> [LocalDPHeavyHitterEstimate] {
        let usable = reports.filter {
            $0.name == name && $0.mechanism == .optimizedLocalHashing && $0.bucketCount > 1 && $0.epsilon > 0
        }
        guard let first = usable.first, !candidateCategories.isEmpty else { return [] }
        let matchingReports = usable.filter {
            $0.bucketCount == first.bucketCount && abs($0.epsilon - first.epsilon) < 0.000001
        }
        guard !matchingReports.isEmpty else { return [] }

        let bucketCount = first.bucketCount
        let p = optimizedLocalHashingTruthfulProbability(epsilon: first.epsilon)
        let q = (1 - p) / Double(bucketCount - 1)
        let denominator = max(0.000001, p - q)
        let reportCount = matchingReports.count
        let uniqueCandidates = Array(NSOrderedSet(array: candidateCategories).compactMap { $0 as? String })
        let estimates = uniqueCandidates.map { category in
            let bucket = stableBucket(category: category, salt: hashSalt, bucketCount: bucketCount)
            let observed = matchingReports.filter { $0.reportedBucket == bucket }.count
            let estimate = max(0, (Double(observed) - Double(reportCount) * q) / denominator)
            return LocalDPHeavyHitterEstimate(
                categoryHash: stableHash(category: category, salt: hashSalt),
                estimatedCount: estimate,
                reportCount: reportCount,
                bucket: bucket,
                minReportsSatisfied: reportCount >= minReports
            )
        }
        return estimates
            .sorted {
                if abs($0.estimatedCount - $1.estimatedCount) > 0.000001 {
                    return $0.estimatedCount > $1.estimatedCount
                }
                return $0.categoryHash < $1.categoryHash
            }
            .prefix(max(0, limit))
            .map { $0 }
    }

    public static func truthfulProbability(epsilon: Double, domainSize: Int) throws -> Double {
        guard epsilon.isFinite && epsilon > 0 else {
            throw LocalDifferentialPrivacyError.invalidEpsilon
        }
        guard domainSize > 0 else {
            throw LocalDifferentialPrivacyError.emptyDomain
        }
        let expEpsilon = exp(epsilon)
        return expEpsilon / (expEpsilon + Double(domainSize - 1))
    }

    public static func hashedCategory(_ category: String, salt: String) -> String {
        stableHash(category: category, salt: salt)
    }

    public static func privatizedCounterExport<RNG: RandomNumberGenerator>(
        policy: AnalyticsPrivacyPolicy,
        candidates: [String: FleetMetricInput],
        epsilon: Double,
        delta: Double = 0,
        sourceAuditHead: AuditHead? = nil,
        budgetSpends: [FleetDPBudgetSpend] = [],
        rng: inout RNG
    ) throws -> LocalDPFleetExport {
        let base = policy.export(
            candidates: candidates,
            sourceAuditHead: sourceAuditHead,
            epsilon: epsilon,
            delta: delta,
            mechanism: .laplaceBoundedCount
        )
        let metrics = try base.metrics.map { metric in
            var localRNG = rng
            let record = try clippedNoisyCount(
                name: metric.name,
                rawValue: metric.value,
                bounds: policy.clippingBounds,
                epsilon: epsilon,
                delta: delta,
                rng: &localRNG
            )
            rng = localRNG
            return LocalDPReleasedMetric(record: record)
        }
        return LocalDPFleetExport(
            manifest: base.manifest,
            metrics: metrics,
            budgetSpends: budgetSpends
        )
    }

    public static func privatizedCounterExport<RNG: RandomNumberGenerator>(
        policy: AnalyticsPrivacyPolicy,
        candidates: [String: FleetMetricInput],
        metricFamily: String,
        budget: inout FleetDPMonthlyBudget,
        epsilon: Double,
        delta: Double = 0,
        sourceAuditHead: AuditHead? = nil,
        rng: inout RNG
    ) throws -> LocalDPFleetExport {
        let parameters = try LocalDPPrivacyParameters(epsilon: epsilon, delta: delta, mechanism: .laplaceBoundedCount)
        let spend = try budget.reserve(metricFamily: metricFamily, parameters: parameters)
        return try privatizedCounterExport(
            policy: policy,
            candidates: candidates,
            epsilon: epsilon,
            delta: delta,
            sourceAuditHead: sourceAuditHead,
            budgetSpends: [spend],
            rng: &rng
        )
    }

    public static func serialize(
        export: LocalDPFleetExport,
        encoder: JSONEncoder = JSONEncoder()
    ) throws -> Data {
        encoder.outputFormatting.formUnion([.sortedKeys])
        return try encoder.encode(export)
    }

    private static func randomizedResponseIndex<RNG: RandomNumberGenerator>(
        trueIndex: Int,
        domainSize: Int,
        epsilon: Double,
        rng: inout RNG
    ) -> Int {
        guard domainSize > 1 else {
            return trueIndex
        }

        let expEpsilon = exp(epsilon)
        let truthProbability = expEpsilon / (expEpsilon + Double(domainSize - 1))
        if nextUnitInterval(rng: &rng) < truthProbability {
            return trueIndex
        }

        let offset = Int(nextUnitInterval(rng: &rng) * Double(domainSize - 1))
        return offset >= trueIndex ? offset + 1 : offset
    }

    private static func optimizedLocalHashingTruthfulProbability(epsilon: Double) -> Double {
        let expEpsilon = exp(epsilon)
        return expEpsilon / (expEpsilon + 1)
    }

    private static func sampleLaplace<RNG: RandomNumberGenerator>(
        scale: Double,
        rng: inout RNG
    ) -> Double {
        let uniform = nextUnitInterval(rng: &rng) - 0.5
        if uniform == 0 {
            return 0
        }
        let sign = uniform < 0 ? -1.0 : 1.0
        return -scale * sign * log(1 - 2 * abs(uniform))
    }

    private static func nextUnitInterval<RNG: RandomNumberGenerator>(rng: inout RNG) -> Double {
        let random = rng.next() >> 11
        return Double(random) / 9_007_199_254_740_992
    }

    private static func stableHash(category: String, salt: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        let bytes = Array((salt + "\u{1f}" + category).utf8)
        for byte in bytes {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }

    private static func stableBucket(category: String, salt: String, bucketCount: Int) -> Int {
        let hash = UInt64(stableHash(category: category, salt: salt), radix: 16) ?? 0
        return Int(hash % UInt64(bucketCount))
    }
}
