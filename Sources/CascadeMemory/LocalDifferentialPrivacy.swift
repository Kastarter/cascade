import Foundation

public enum LocalDPMechanism: String, Codable, Equatable, Sendable {
    case laplaceBoundedCount = "laplace_bounded_count"
    case laplaceBoundedSum = "laplace_bounded_sum"
    case kAryRandomizedResponse = "k_ary_randomized_response"
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

public struct FleetDPBudgetSpend: Codable, Equatable, Sendable {
    public let period: String
    public let metricFamily: String
    public let epsilon: Double
    public let delta: Double
    public let mechanism: LocalDPMechanism

    public init(
        period: String,
        metricFamily: String,
        epsilon: Double,
        delta: Double,
        mechanism: LocalDPMechanism
    ) {
        self.period = period
        self.metricFamily = metricFamily
        self.epsilon = epsilon
        self.delta = delta
        self.mechanism = mechanism
    }
}

public struct FleetDPMonthlyBudget: Codable, Equatable, Sendable {
    public let period: String
    public let epsilonCap: Double
    public let deltaCap: Double
    public private(set) var spends: [FleetDPBudgetSpend]

    public init(
        period: String,
        epsilonCap: Double,
        deltaCap: Double = 1,
        spends: [FleetDPBudgetSpend] = []
    ) {
        self.period = period
        self.epsilonCap = max(0, epsilonCap)
        self.deltaCap = max(0, deltaCap)
        self.spends = spends.filter { $0.period == period }
    }

    public var spentEpsilon: Double {
        spends.reduce(0) { $0 + $1.epsilon }
    }

    public var spentDelta: Double {
        spends.reduce(0) { $0 + $1.delta }
    }

    public mutating func reserve(
        metricFamily: String,
        parameters: LocalDPPrivacyParameters
    ) throws -> FleetDPBudgetSpend {
        let nextEpsilon = spentEpsilon + parameters.epsilon
        let nextDelta = spentDelta + parameters.delta
        guard nextEpsilon <= epsilonCap && nextDelta <= deltaCap else {
            throw LocalDifferentialPrivacyError.monthlyBudgetExceeded
        }

        let spend = FleetDPBudgetSpend(
            period: period,
            metricFamily: metricFamily,
            epsilon: parameters.epsilon,
            delta: parameters.delta,
            mechanism: parameters.mechanism
        )
        spends.append(spend)
        return spend
    }
}

public struct LocalDPFleetExport: Codable, Equatable, Sendable {
    public let manifest: FleetExportManifest
    public let metrics: [LocalDPMetricRecord]
    public let budgetSpends: [FleetDPBudgetSpend]

    public init(
        manifest: FleetExportManifest,
        metrics: [LocalDPMetricRecord],
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
        let base = policy.export(candidates: candidates, sourceAuditHead: sourceAuditHead)
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
            return LocalDPMetricRecord(
                name: record.name,
                value: record.value,
                clippedValue: record.clippedValue,
                wasClipped: metric.wasClipped,
                epsilon: record.epsilon,
                delta: record.delta,
                mechanism: record.mechanism
            )
        }
        return LocalDPFleetExport(
            manifest: base.manifest,
            metrics: metrics,
            budgetSpends: budgetSpends
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
}
